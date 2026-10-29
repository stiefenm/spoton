#!/usr/bin/env bash
# queue-clear.sh - refresh the queue state of the Soloist daemon on lavender-UAT
# through the Spotify desktop app's own device handover (quick 261022-iwm,
# DECISION.md CHOICE=app_transfer). Read before write, one recorded cycle.
#
# Background (measured, see the quick directory):
#   - Soloist has NO command that deletes or empties a queue. The WS API only
#     knows add_to_queue (writes) and skip_next (consumes by playing).
#   - An INACTIVE daemon answers get_queue from a frozen copy of its last
#     session, not from the account's live queue, and that copy can be wrong in
#     both directions. Handing the account's session to the daemon through the
#     app's device menu replaces the copy with the live session. This tool
#     automates exactly that step and nothing else.
#   - Real entries in the account queue are NEVER removed. If entries remain
#     once the live session sits on lavender-UAT, the tool reports UNBESTIMMT
#     reason=account_queue_holds_entries and the user clears them in the app.
#
# Usage:
#   queue-clear.sh [--mac <aa:bb:cc:dd:ee:ff>] --out-dir <dir> [--refresh]
#   queue-clear.sh --help
#     --mac      default 02:00:00:5a:11:01 (lavender-UAT); six hex pairs
#     --out-dir  required; created if missing; refused when it is not empty
#     --refresh  run the handover cycle even when the copy shows no entries
#
# Order of operations:
#   1. refuse lavender-pa (the MAC in PA_MAC, any case) before anything else; PA_MAC unset
#      -> UNBESTIMMT reason=pa_mac_not_set, exit 2 (no default, D-10: source rig-env.sh)
#   2. read (get_queue, expect-device lavender-UAT) -> qc-1-before.jsonl
#   3. no write when the daemon is active, or when the copy is empty without
#      --refresh. Write path only on an INACTIVE daemon: lavender-pa must be
#      idle (pa-idle-gate.sh) and the desktop app must not be running.
#   4. LMS state: gaps-76.sh record-state (provider/power/streamFormat/volume/
#      diagnosticMode of lavender-UAT) before anything is touched.
#   5. app: start, wait for CDP, connect lavender-UAT (no play), poll until
#      is_active=1, pause over the WS if it is playing, read, disconnect back
#      to "This computer", pause the desktop, stop the app, poll until
#      is_active=0. If the daemon is STILL active (live finding 2026-10-22: the
#      app's disconnect did not release it), print QC_RELEASE_FALLBACK=deactivate
#      and send the daemon's own WS deactivate (own-device command, no queue
#      write). Then check the app is gone, gaps-76.sh restore-state (must print
#      STATE_RESTORED=PASS), read once more.
#   6. classify and print exactly ONE final line (always the last line):
#        QUEUE_CLEARED=PASS|FAIL|UNBESTIMMT before=<n|-> after=<n|-> action=<none|app_transfer> [reason=<r>] view_before=<live|snapshot|-> restored=<active|inactive|->
#
# Never sent over the WS: skip_next, skip_prev, add_to_queue, play, seek,
# set_volume, set_shuffle, set_repeat_context, set_repeat_track. Only
# get_queue, pause if the daemon is found playing during the handover, and the
# daemon's own deactivate as the recorded release fallback. No raw LMS stop is
# ever sent; the LMS play mode is only read and printed (QC_LMS_MODE_CHANGED).
#
# Side effects (recorded, left as they are): while the handover is on, LMS
# lavender-UAT switches to Spotify Connect and its playlist gets the account's
# current title. The tool cannot see a phone; if a phone plays on the account
# at that moment, the handover takes playback away from it.
#
# Exit codes: 0 = PASS, 1 = FAIL, 2 = refused / usage, 3 = UNBESTIMMT.
#
# Environment hooks (tests use fakes):
#   QC_REPO            repo root (default: derived from this script)
#   QC_WS_RECORD       default "sudo -n perl <repo>/tools/soloist-ws-record.pl"
#   QC_CDP             default "node $HOME/SynologyDrive/dev/spoton-private/tools/spotify-cdp.js"
#   QC_APP_PIDS_CMD    default "ps -C spotify -o pid="  (prints pids while the app runs)
#   QC_GAPS            default "bash <repo>/.planning/phases/79-soloist-e2e-uat-v4-0-release/runners/gaps-76.sh"
#   QC_LMS_STATUS_CMD  test hook: command printing the QC_LMS line (default: curl LMS status)
#   QC_POLL_SLEEP      seconds between polls (default 3)
#   PA_MAC             MAC of lavender-pa (required, no default; rig-env.sh exports it)
#   LMS_URL            default http://127.0.0.1:9000/jsonrpc.js
#   PA_IDLE_FAKE_MODE  passed through to pa-idle-gate.sh (offline hook)
set -u

QC_REPO="${QC_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
QC_WS_RECORD="${QC_WS_RECORD:-sudo -n perl $QC_REPO/tools/soloist-ws-record.pl}"
QC_CDP="${QC_CDP:-node $HOME/SynologyDrive/dev/spoton-private/tools/spotify-cdp.js}"
QC_APP_PIDS_CMD="${QC_APP_PIDS_CMD:-ps -C spotify -o pid=}"
QC_GAPS="${QC_GAPS:-bash $QC_REPO/.planning/phases/79-soloist-e2e-uat-v4-0-release/runners/gaps-76.sh}"
QC_LMS_STATUS_CMD="${QC_LMS_STATUS_CMD:-}"
QC_POLL_SLEEP="${QC_POLL_SLEEP:-3}"
LMS_URL="${LMS_URL:-http://127.0.0.1:9000/jsonrpc.js}"
PA_MAC_FIXED=$(printf '%s' "${PA_MAC:-}" | tr 'A-F' 'a-f')
UAT_NAME="lavender-UAT"

read -r -a WS <<<"$QC_WS_RECORD"
read -r -a CDP <<<"$QC_CDP"
read -r -a GAPS <<<"$QC_GAPS"

MAC="02:00:00:5a:11:01"
OUT=""
REFRESH=0

# state used by final()
B_N=""; A_N=""; ACTION="none"; VIEW=""; RESTORED=""
SUMMARY_OK=0
PAUSED=0
CDP_CALLS=()
CDP_LAST=""
LMS_BEFORE="unreadable"

# ---------------------------------------------------------------- helpers

lms_status() {
  local resp
  if [ -n "$QC_LMS_STATUS_CMD" ]; then bash -c "$QC_LMS_STATUS_CMD" 2>/dev/null || echo unreadable; return; fi
  resp=$(curl -s -m 4 -X POST -H 'Content-Type: application/json' \
    -d "{\"id\":1,\"method\":\"slim.request\",\"params\":[\"$MAC\",[\"status\",\"-\",\"1\"]]}" \
    "$LMS_URL" 2>/dev/null) || { echo unreadable; return; }
  [ -z "$resp" ] && { echo unreadable; return; }
  printf '%s' "$resp" | perl -MJSON::PP -e '
    local $/; my $r = eval { decode_json(<STDIN>) } or do { print "unreadable\n"; exit 0 };
    my $x = ref $r eq "HASH" ? $r->{result} : undef;
    unless (ref $x eq "HASH" && exists $x->{mode}) { print "unreadable\n"; exit 0 }
    printf "mode=%s playlist_tracks=%s remote=%s\n", $x->{mode} // "-", $x->{playlist_tracks} // "-", $x->{remote} // "-";
  ' 2>/dev/null || echo unreadable
}

tx_summary() {
  perl -MJSON::PP -e '
    my %n;
    for my $f (@ARGV) {
      open(my $fh, "<", $f) or next;
      while (my $l = <$fh>) {
        my $r = eval { decode_json($l) } or next;
        next unless ref $r eq "HASH" && ($r->{dir} // "") eq "tx";
        my $fr = eval { JSON::PP->new->decode($r->{frame}) } or next;
        $n{ $fr->{command} // "?" }++ if ref $fr eq "HASH";
      }
    }
    print join(" ", map { "$_=$n{$_}" } sort keys %n), "\n";
  ' "$OUT"/qc-*.jsonl 2>/dev/null
}

# final <status> <reason|""> <exit>   - the ONE final line, always last
final() {
  local status=$1 reason=${2:-} code=$3 line
  if [ "$SUMMARY_OK" = 1 ]; then
    echo "QC_PAUSED_DURING_REFRESH=$PAUSED"
    local lms_after mb ma
    lms_after=$(lms_status)
    echo "QC_LMS_BEFORE $LMS_BEFORE"
    echo "QC_LMS_AFTER $lms_after"
    mb=$(printf '%s' "$LMS_BEFORE" | sed -n 's/.*mode=\([^ ]*\).*/\1/p')
    ma=$(printf '%s' "$lms_after" | sed -n 's/.*mode=\([^ ]*\).*/\1/p')
    if [ -n "$mb" ] && [ -n "$ma" ] && [ "$mb" != "$ma" ]; then
      echo "QC_LMS_MODE_CHANGED before=$mb after=$ma"
    fi
    echo "QC_TX_SUMMARY $(tx_summary)"
    echo "QC_CDP_CALLS $(IFS=,; echo "${CDP_CALLS[*]:-none}")"
  fi
  line="QUEUE_CLEARED=$status before=${B_N:--} after=${A_N:--} action=$ACTION"
  [ -n "$reason" ] && line="$line reason=$reason"
  line="$line view_before=${VIEW:--} restored=${RESTORED:--}"
  echo "$line"
  exit "$code"
}

# read_q <file>  -> R_RC R_ACTIVE R_DEV R_STATUS R_ITEM R_N   ("-" = not seen)
# Counting rule = acceptance-x86.sh queue_count: the tx get_queue frame, then the
# FIRST rx queue_changed; count upcoming[] entries with source == "queue".
# 79-46: the frame field is a CHARACTER string after the outer decode_json (the recorder writes
# real Unicode), so the inner decode is character-level -- decode_json there failed on any
# accented title with "malformed UTF-8" and made the read unreadable.
read_q() {
  local f=$1 info kv
  timeout 20 "${WS[@]}" --mac "$MAC" --expect-device "$UAT_NAME" \
    --send get_queue --seconds 3 --out "$f" > "$f.stderr" 2>&1
  R_RC=$?
  info=$(perl -MJSON::PP -e '
    my ($active, $dev, $status, $item, $n) = ("-") x 5; my $tx = 0;
    open(my $fh, "<", $ARGV[0]) or do { print "active=- dev=- status=- item=- n=-\n"; exit 0 };
    while (my $l = <$fh>) {
      my $r = eval { decode_json($l) } or next; next unless ref $r eq "HASH";
      my $fr = $r->{frame}; next unless defined $fr && !ref $fr && $fr =~ /^\{/;
      my $x = eval { JSON::PP->new->decode($fr) } or next; next unless ref $x eq "HASH";
      my $dir = $r->{dir} // "";
      if ($dir eq "tx" && ($x->{command} // "") eq "get_queue") { $tx = 1; next }
      next unless $dir eq "rx";
      my $t = $x->{type} // "";
      if ($t eq "auth_state" && $active eq "-") { $active = $x->{is_active} ? 1 : 0; $dev = $x->{device_name} // "-" }
      elsif ($t eq "playback_state" && $status eq "-") { $status = $x->{status} // "-"; $item = ref $x->{item} eq "HASH" ? ($x->{item}{uri} // "-") : "-" }
      elsif ($t eq "queue_changed" && $tx && $n eq "-") { $n = scalar grep { ref $_ eq "HASH" && ($_->{source} // "") eq "queue" } @{ $x->{upcoming} || [] } }
    }
    s/\s+/_/g for ($dev, $status, $item);
    print "active=$active dev=$dev status=$status item=$item n=$n\n";
  ' "$f" 2>/dev/null)
  R_ACTIVE="-"; R_DEV="-"; R_STATUS="-"; R_ITEM="-"; R_N="-"
  for kv in $info; do
    case "$kv" in
      active=*) R_ACTIVE=${kv#active=} ;;
      dev=*)    R_DEV=${kv#dev=} ;;
      status=*) R_STATUS=${kv#status=} ;;
      item=*)   R_ITEM=${kv#item=} ;;
      n=*)      R_N=${kv#n=} ;;
    esac
  done
}

# cdp_call <timeout> <args...>   output in CDP_LAST, logged to qc-cdp.log
cdp_call() {
  local t=$1 rc; shift
  CDP_CALLS+=("$1")
  CDP_LAST=$(timeout "$t" "${CDP[@]}" "$@" 2>&1)
  rc=$?
  { printf '== %s rc=%s\n' "$*" "$rc"; printf '%s\n' "$CDP_LAST"; } >> "$OUT/qc-cdp.log"
  return $rc
}

app_pids() { bash -c "$QC_APP_PIDS_CMD" 2>/dev/null | tr '\n' ' ' | sed 's/^ *//;s/ *$//'; }

usage() { sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }

# ---------------------------------------------------------------- args

while [ $# -gt 0 ]; do
  case "$1" in
    --mac)     MAC="${2:-}"; shift 2 2>/dev/null || shift ;;
    --out-dir) OUT="${2:-}"; shift 2 2>/dev/null || shift ;;
    --refresh) REFRESH=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "queue-clear.sh: unknown argument: $1" >&2; final UNBESTIMMT usage 2 ;;
  esac
done

# 1. refuse lavender-pa before anything else (any case)
# QC-PA-REFUSE-BEGIN
MAC_LC=$(printf '%s' "$MAC" | tr 'A-F' 'a-f')
if [ -z "$PA_MAC_FIXED" ]; then
  final UNBESTIMMT pa_mac_not_set 2
fi
if [ "$MAC_LC" = "$PA_MAC_FIXED" ]; then
  final UNBESTIMMT refused_target_lavender-pa 2
fi
# QC-PA-REFUSE-END

if ! printf '%s' "$MAC" | command grep -qE '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$'; then
  echo "queue-clear.sh: --mac must be six hex pairs" >&2
  final UNBESTIMMT usage 2
fi
if [ -z "$OUT" ]; then
  echo "queue-clear.sh: --out-dir is required" >&2
  final UNBESTIMMT usage 2
fi
if [ -d "$OUT" ] && [ -n "$(ls -A "$OUT" 2>/dev/null)" ]; then
  echo "queue-clear.sh: --out-dir is not empty: $OUT" >&2
  final UNBESTIMMT out_dir_not_empty 2
fi
mkdir -p "$OUT" || final UNBESTIMMT usage 2

# ---------------------------------------------------------------- 2. read before

read_q "$OUT/qc-1-before.jsonl"
if [ "$R_RC" = 3 ] || { [ "$R_DEV" != "-" ] && [ "$R_DEV" != "$UAT_NAME" ]; }; then
  echo "QC_BEFORE device_name=$R_DEV expected=$UAT_NAME"
  final UNBESTIMMT device_name_mismatch 2
fi
if [ "$R_N" = "-" ] || [ "$R_ACTIVE" = "-" ]; then
  echo "QC_BEFORE unreadable rc=$R_RC"
  final UNBESTIMMT read_before_unreadable 3
fi
B_ACTIVE=$R_ACTIVE; B_N=$R_N; B_STATUS=$R_STATUS; B_ITEM=$R_ITEM
if [ "$B_ACTIVE" = 1 ]; then VIEW=live; RESTORED=active; else VIEW=snapshot; RESTORED=inactive; fi
echo "QC_BEFORE is_active=$B_ACTIVE n=$B_N status=$B_STATUS item=$B_ITEM view=$VIEW"
LMS_BEFORE=$(lms_status)
SUMMARY_OK=1

# ---------------------------------------------------------------- 3. decide

if [ "$B_ACTIVE" = 1 ] || { [ "$B_N" = 0 ] && [ "$REFRESH" = 0 ]; }; then
  A_N=$B_N
  if [ "$B_N" = 0 ]; then final PASS "" 0; fi
  final UNBESTIMMT account_queue_holds_entries 3
fi

# write path: inactive daemon, entries in the copy (or --refresh)
# QC-PA-GATE-BEGIN
PA_OUT=$(PA_MAC="$PA_MAC_FIXED" bash "$QC_REPO/tools/uat/pa-idle-gate.sh" 2>&1)
echo "QC_PA_GATE $PA_OUT"
case "$PA_OUT" in
  *PA_IDLE=PASS*) : ;;
  *) A_N=$B_N; final UNBESTIMMT "rig_not_idle:pa" 3 ;;
esac
# QC-PA-GATE-END
APP_BEFORE=$(app_pids)
if [ -n "$APP_BEFORE" ]; then
  echo "QC_APP_PIDS_BEFORE $APP_BEFORE"
  A_N=$B_N
  final UNBESTIMMT "rig_not_idle:app" 3
fi

# LMS state of lavender-UAT, recorded before anything is touched (restored at the end)
# QC-LMS-RECORD-BEGIN
mkdir -p "$OUT/lms-state" 2>/dev/null
GAPS_OUT=$("${GAPS[@]}" record-state "$OUT/lms-state" 2>&1) || true
echo "QC_RECORD_STATE $(printf '%s' "$GAPS_OUT" | head -n 1)"
case "$GAPS_OUT" in
  *STATE_RECORDED*) : ;;
  *) A_N=$B_N; final UNBESTIMMT lms_state_not_recorded 3 ;;
esac
# QC-LMS-RECORD-END

# ---------------------------------------------------------------- 4. app handover

ACTION=app_transfer
PRELIM=""
TRANSFERRED=0
N_LIVE="-"

cdp_call 20 start
ST=""
for i in 1 2 3 4 5 6 7 8; do
  cdp_call 20 status
  ST=$(printf '%s\n' "$CDP_LAST" | sed -n '/^{/,$p')
  [ -n "$ST" ] && break
  sleep "$QC_POLL_SLEEP"
done

if [ -z "$ST" ]; then
  PRELIM=app_no_cdp
else
  # connect without play; the CDP result is informational, the daemon's is_active is the authority
  cdp_call 25 connect "$UAT_NAME"
  for i in 1 2 3 4 5; do
    read_q "$OUT/qc-2-connect-$i.jsonl"
    if [ "$R_ACTIVE" = 1 ]; then TRANSFERRED=1; break; fi
    sleep "$QC_POLL_SLEEP"
  done
  if [ "$TRANSFERRED" = 0 ]; then
    PRELIM=transfer_no_effect
  else
    if [ "$R_STATUS" = playing ]; then
      timeout 20 "${WS[@]}" --mac "$MAC" --expect-device "$UAT_NAME" \
        --send pause --seconds 3 --out "$OUT/qc-3-pause.jsonl" > "$OUT/qc-3-pause.jsonl.stderr" 2>&1
      PAUSED=1
    fi
    sleep "$QC_POLL_SLEEP"
    read_q "$OUT/qc-4-live.jsonl"
    N_LIVE=$R_N
    echo "QC_LIVE is_active=$R_ACTIVE n=$R_N status=$R_STATUS item=$R_ITEM"
  fi
fi

# release: back to "This computer", desktop pause (must not sound), stop the app
if [ "$TRANSFERRED" = 1 ]; then
  cdp_call 25 disconnect
  cdp_call 15 pause
fi
cdp_call 15 stop
for i in 1 2 3 4 5; do
  read_q "$OUT/qc-5-release-$i.jsonl"
  [ "$R_ACTIVE" = 0 ] && break
  sleep "$QC_POLL_SLEEP"
done
APP_AFTER=""
for i in 1 2 3 4 5; do
  APP_AFTER=$(app_pids)
  [ -z "$APP_AFTER" ] && break
  sleep "$QC_POLL_SLEEP"
done
echo "QC_APP_PIDS_AFTER ${APP_AFTER:-none}"

# release fallback: the app's disconnect did not release the daemon -> the daemon's own deactivate
# QC-FALLBACK-BEGIN
if [ "$R_ACTIVE" = 1 ]; then
  echo "QC_RELEASE_FALLBACK=deactivate"
  timeout 20 "${WS[@]}" --mac "$MAC" --expect-device "$UAT_NAME" \
    --send '{"type":"command","command":"deactivate"}' --seconds 3 --out "$OUT/qc-5b-deactivate.jsonl" \
    > "$OUT/qc-5b-deactivate.jsonl.stderr" 2>&1
  sleep "$QC_POLL_SLEEP"
fi
# QC-FALLBACK-END

# LMS state back to the recorded one (gaps-76.sh restore-state; never a raw LMS stop)
# QC-LMS-RESTORE-BEGIN
RESTORE_OUT=$("${GAPS[@]}" restore-state "$OUT/lms-state" 2>&1); RESTORE_RC=$?
printf '%s\n' "$RESTORE_OUT" > "$OUT/qc-lms-restore.txt"
printf '%s\n' "$RESTORE_OUT" | command grep -E '^(STATE_RESTORED|STATE_RESTORE|RIG=)' | head -n 3
LMS_RESTORED=0
if [ "$RESTORE_RC" = 0 ] && printf '%s\n' "$RESTORE_OUT" | command grep -qx 'STATE_RESTORED=PASS'; then LMS_RESTORED=1; fi
# QC-LMS-RESTORE-END

# QC-FINAL-READ-BEGIN
read_q "$OUT/qc-6-final.jsonl"
F_ACTIVE=$R_ACTIVE; F_N=$R_N; F_STATUS=$R_STATUS
# QC-FINAL-READ-END
echo "QC_FINAL is_active=$F_ACTIVE n=$F_N status=$F_STATUS"

# ---------------------------------------------------------------- 5. classify

if [ "$F_N" = "-" ] || [ "$F_ACTIVE" = "-" ]; then
  final UNBESTIMMT read_after_unreadable 3
fi
A_N=$F_N
if [ "$F_ACTIVE" = 1 ]; then RESTORED=active; else RESTORED=inactive; fi

if [ "$F_ACTIVE" != "$B_ACTIVE" ]; then final FAIL not_restored 1; fi
if [ -n "$APP_AFTER" ]; then final FAIL app_not_closed 1; fi
if [ "$F_STATUS" = playing ]; then final FAIL not_paused 1; fi
if [ "$LMS_RESTORED" != 1 ]; then final FAIL lms_state_not_restored 1; fi
if [ -n "$PRELIM" ]; then final UNBESTIMMT "$PRELIM" 3; fi
if [ "$N_LIVE" != "-" ] && [ "$N_LIVE" -ge 1 ] 2>/dev/null; then
  final UNBESTIMMT account_queue_holds_entries 3
fi
if [ "$F_N" != 0 ]; then final FAIL copy_not_refreshed 1; fi
final PASS "" 0
