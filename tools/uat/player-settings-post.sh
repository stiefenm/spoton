#!/usr/bin/env bash
# Full-form settings-page POST -- never a partial form.
#
# Why: Plugins/SpotOn/Settings/Player.pm USED TO derive three prefs from
# field ABSENCE on every saveSettings. A form carrying only the one changed
# field muted lavender-UAT's Connect/discovery/autoplay for two days on
# 2026-09-26 (debug session .planning/debug/connect-transfer-split-brain.md).
# Since 84-21 (D-31 (2)) the handler writes the three checkbox prefs only
# when their has_<name> presence marker is posted (:45, :107, :112), so a
# one-field POST leaves them alone; this tool stays the guard for the rest
# of the form and its before/after snapshot catches a regression of that
# fix. playerpref is NOT a substitute when the page does extra work -- e.g.
# Player.pm:86-100 runs
# Plugins::SpotOn::Soloist::Quality->applyChange (a server write) when
# pref_soloistQuality changes; a playerpref write would store the value
# without ever reaching that path.
#
# This tool posts the page's full checkbox state (as a browser would: value
# 1 when checked, field omitted when unchecked) plus the caller's own
# fields, and never touches the three checkbox prefs directly as arguments
# -- changing THEM is a deliberate playerpref write, not a side effect of
# posting something else. It snapshots the three checkboxes before and
# after; if the POST flipped any of them anyway, it restores each to its
# before value via playerpref and reports failure.
#
# Routing (Quick 261019-m6b). On 2026-10-19 `player-settings-post.sh
# 02:00:00:5a:11:03 pref_streamFormat=flac` printed SETTINGS_POST=PASS, but LMS
# stored streamFormat=flac on 02:00:00:5a:11:01 (lavender-UAT) and left the
# named player untouched; the before/after snapshot only reads the checkbox
# prefs of the NAMED mac, a player the POST never reached. Cause: the POST
# named its player only in the URL (`?player=<mac>`), and LMS never reads the
# URL query on a POST -- /usr/share/perl5/Slim/Web/HTTP.pm:562 builds the
# parameter set of a POST from the BODY only. With no `playerid` in the body,
# HTTP.pm:901 falls back to clientRandom(), i.e. the first client. A settings
# handler that needs a client resolves it from the body field `playerid`
# (HTTP.pm:1164-1166); the browser sends exactly that as a hidden input
# (HTML/EN/settings/header.html:56). So the form BODY carries
# `playerid=<mac>` here; the URL repeats it (`?playerid=<mac>`) only as a
# mirror of the browser form action (header.html:49) and carries no routing
# weight.
#
# Read-back. After a 200 POST the tool reads every caller field back via
# `playerpref plugin.spoton:<name> ?` for the named mac and compares it with
# the value the handler (Player.pm) is expected to store:
#   connectOggOverride  v if auto|ogg|pcm, else auto           (Player.pm:52)
#   streamFormat        v if auto|ogg|pcm|flac|mp3, else auto  (Player.pm:58)
#   streamingMode       v if global|direct|proxy, else global  (Player.pm:78)
#   bitrateOverride     v if 96|160|320, else empty            (Player.pm:111)
#   soloistQuality      v unchanged; the valid level set comes from the live
#                       backend (:94-98) and cannot be derived here, so a
#                       level the backend rejects, or a backend without
#                       quality control (nothing stored), ends as a FAIL: the
#                       requested level did not take effect. Expected `global`
#                       also matches an unset pref (:99-100).
#   any other name      v unchanged; Player.pm has no branch for it, so it is
#                       never stored and FAILs unless the player already held
#                       that value -- a true negative, the field had no effect.
# Comparison is exact string equality; an empty expected value also matches
# an unset (null) pref. streamFormat=auto under backend soloist with an
# effective stored format of ogg is the handler's echo-skip (Player.pm:67-73):
# the write is skipped on purpose, so the value must be unchanged and the
# field is listed in echo_skip=.
#
# Residual limits. A field that already held the expected value before the
# POST proves nothing about routing (listed in already=). And a misrouted
# write to ANOTHER player can be neither seen nor undone by this tool: it
# only reads the named player and cannot know which player received the write.
#
# Usage: player-settings-post.sh <mac> <field>=<value> [...]
#   <field> must be pref_<letters>; the checkbox fields
#   pref_enableSpotifyConnect / pref_enableDiscovery / pref_enableAutoplay
#   are refused as arguments.
#
# Exit: 0 = PASS | 1 = FAIL (undef checkbox before posting, or the POST
#       flipped a checkbox -- restored) | 2 = ERROR (usage, unreadable
#       snapshot or read-back, non-200 HTTP with no flip) |
#       3 = FAIL (read-back: a posted value is not stored on the named player)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RIG_PREFS_CHECK="$SCRIPT_DIR/rig-prefs-check.sh"
LMS_CMD="$SCRIPT_DIR/lms-cmd.sh"
LMS_URL="${LMS_URL:-http://127.0.0.1:9000/jsonrpc.js}"

usage_error() {
  echo "SETTINGS_POST=ERROR reason=usage: $1"
  exit 2
}

if [ $# -lt 1 ]; then
  usage_error "missing mac"
fi
MAC="$1"; shift
if ! [[ "$MAC" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]]; then
  usage_error "invalid mac: $MAC"
fi

for arg in "$@"; do
  case "$arg" in
    *=*) : ;;
    *) usage_error "malformed field=value argument: $arg" ;;
  esac
  field="${arg%%=*}"
  value="${arg#*=}"
  if ! [[ "$field" =~ ^pref_[A-Za-z]+$ ]]; then
    usage_error "invalid field name: $field"
  fi
  case "$field" in
    pref_enableSpotifyConnect|pref_enableDiscovery|pref_enableAutoplay)
      usage_error "field $field is refused -- the three checkbox prefs are a deliberate playerpref write, not a side effect"
      ;;
  esac
  if ! [[ "$value" =~ ^[A-Za-z0-9_.-]*$ ]]; then
    usage_error "invalid value for $field: $value"
  fi
done

# snapshot -- sets CONNECT/DISCOVERY/AUTOPLAY (0|1|undef) from
# rig-prefs-check.sh --snapshot. Return 1 (no exit) on any read failure --
# every caller decides what that means at its own call site.
snapshot() {
  local out rc
  out=$(LMS_URL="$LMS_URL" bash "$RIG_PREFS_CHECK" "$MAC" --snapshot 2>/dev/null)
  rc=$?
  if [ $rc -ne 0 ]; then
    return 1
  fi
  CONNECT=$(printf '%s\n' "$out" | command grep '^enableSpotifyConnect=' | cut -d= -f2)
  DISCOVERY=$(printf '%s\n' "$out" | command grep '^disableDiscovery=' | cut -d= -f2)
  AUTOPLAY=$(printf '%s\n' "$out" | command grep '^enableAutoplay=' | cut -d= -f2)
  if [ -z "$CONNECT" ] || [ -z "$DISCOVERY" ] || [ -z "$AUTOPLAY" ]; then
    return 1
  fi
  return 0
}

# read_raw <verb> <name> -- one JSON-RPC `<verb> plugin.spoton:<name> ?` query
# for $MAC (verb: playerpref or pref; LMS ignores the client for a server-scoped
# pref, Queries.pm:3022-3049, so passing $MAC is correct). Sets RAW to the raw
# value (empty string allowed) or to the literal __NULL__ for JSON null.
# Returns 1 on a curl failure, an unparseable reply or a reply without _p2.
# A local reader: rig-prefs-check.sh normalizes every value to 0/1 and
# lms-cmd.sh never prints the JSON body, so neither can return a raw value.
read_raw() {
  local verb="$1" name="$2" req resp rc out
  req='{"id":1,"method":"slim.request","params":["'"$MAC"'",["'"$verb"'","plugin.spoton:'"$name"'","?"]]}'
  resp=$(curl -s -m 8 -X POST -H 'Content-Type: application/json' -d "$req" "$LMS_URL" 2>/dev/null)
  rc=$?
  if [ $rc -ne 0 ]; then
    return 1
  fi
  out=$(printf '%s' "$resp" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print("__NOVAL__")
    sys.exit(0)
r = d.get("result") if isinstance(d, dict) else None
if not isinstance(r, dict) or "_p2" not in r:
    print("__NOVAL__")
    sys.exit(0)
v = r["_p2"]
if v is None:
    print("__NULL__")
elif isinstance(v, str):
    print("V:" + v)
elif isinstance(v, int) and not isinstance(v, bool):
    print("V:" + str(v))
else:
    print("__NOVAL__")
' 2>/dev/null)
  case "$out" in
    V:*)      RAW="${out#V:}"; return 0 ;;
    __NULL__) RAW="__NULL__"; return 0 ;;
    *)        return 1 ;;
  esac
}

# expected_for <name> <posted> -- sets EXPECTED to the value Player.pm stores.
expected_for() {
  local name="$1" v="$2"
  case "$name" in
    connectOggOverride)
      case "$v" in auto|ogg|pcm) EXPECTED="$v" ;; *) EXPECTED="auto" ;; esac ;;
    streamFormat)
      case "$v" in auto|ogg|pcm|flac|mp3) EXPECTED="$v" ;; *) EXPECTED="auto" ;; esac ;;
    streamingMode)
      case "$v" in global|direct|proxy) EXPECTED="$v" ;; *) EXPECTED="global" ;; esac ;;
    bitrateOverride)
      case "$v" in 96|160|320) EXPECTED="$v" ;; *) EXPECTED="" ;; esac ;;
    *) EXPECTED="$v" ;;
  esac
}

# matches <name> <expected> <stored> -- exact equality; an empty expected also
# matches an unset pref; soloistQuality `global` also matches an unset or
# empty pref (Player.pm:99-100 leaves an unset pref unset).
matches() {
  local name="$1" want="$2" got="$3"
  [ "$got" = "$want" ] && return 0
  if [ -z "$want" ] && [ "$got" = "__NULL__" ]; then return 0; fi
  if [ "$name" = "soloistQuality" ] && [ "$want" = "global" ]; then
    if [ -z "$got" ] || [ "$got" = "__NULL__" ]; then return 0; fi
  fi
  return 1
}

# show <value> -- render a raw value for the FAIL line.
show() {
  case "$1" in
    "")       printf 'empty' ;;
    __NULL__) printf 'null' ;;
    *)        printf '%s' "$1" ;;
  esac
}

# 1. Before snapshot.
if ! snapshot; then
  echo "SETTINGS_POST=ERROR mac=$MAC reason=before-snapshot unreadable"
  exit 2
fi
B_CONNECT="$CONNECT"
B_DISCOVERY="$DISCOVERY"
B_AUTOPLAY="$AUTOPLAY"

# 2. Refuse to post on an undefined checkbox state (the page would render it
# checked, Player.pm:124/:204, while the runtime falls back to the global
# pref, Control.pm:4727-4728 -- ambiguous rig state, never posted).
UNDEF_KEYS=()
[ "$B_CONNECT" = "undef" ] && UNDEF_KEYS+=("enableSpotifyConnect")
[ "$B_DISCOVERY" = "undef" ] && UNDEF_KEYS+=("disableDiscovery")
[ "$B_AUTOPLAY" = "undef" ] && UNDEF_KEYS+=("enableAutoplay")
if [ ${#UNDEF_KEYS[@]} -gt 0 ]; then
  JOINED=$(IFS=,; echo "${UNDEF_KEYS[*]}")
  echo "SETTINGS_POST=FAIL mac=$MAC reason=undef: $JOINED"
  exit 1
fi

# 2b. Before-reads of every caller field (needed for the read-back verdict:
# a field that already held its expected value proves nothing about routing,
# and the streamFormat echo-skip is decided from the pre-POST state).
FIELD_NAMES=()
FIELD_POSTED=()
FIELD_EXPECTED=()
FIELD_BEFORE=()
FIELD_ECHO=()
for arg in "$@"; do
  fname="${arg%%=*}"; fname="${fname#pref_}"
  fval="${arg#*=}"
  expected_for "$fname" "$fval"
  if ! read_raw playerpref "$fname"; then
    echo "SETTINGS_POST=ERROR mac=$MAC reason=before-readback unreadable: $fname"
    exit 2
  fi
  fbefore="$RAW"
  echo_cand=0
  if [ "$fname" = "streamFormat" ] && [ "$EXPECTED" = "auto" ]; then
    # Player.pm:67-73: stored = streamFormat || connectOggOverride || auto;
    # skipped exactly when backend is soloist, stored is ogg and posted is auto.
    if ! read_raw playerpref connectOggOverride; then
      echo "SETTINGS_POST=ERROR mac=$MAC reason=before-readback unreadable: connectOggOverride"
      exit 2
    fi
    coo_before="$RAW"
    if ! read_raw pref backend; then
      echo "SETTINGS_POST=ERROR mac=$MAC reason=before-readback unreadable: backend"
      exit 2
    fi
    backend="$RAW"
    if [ -z "$backend" ] || [ "$backend" = "__NULL__" ]; then backend="librespot"; fi
    if [ -n "$fbefore" ] && [ "$fbefore" != "__NULL__" ]; then
      effective="$fbefore"
    elif [ -n "$coo_before" ] && [ "$coo_before" != "__NULL__" ]; then
      effective="$coo_before"
    else
      effective="auto"
    fi
    if [ "$backend" = "soloist" ] && [ "$effective" = "ogg" ]; then echo_cand=1; fi
  fi
  FIELD_NAMES+=("$fname")
  FIELD_POSTED+=("$fval")
  FIELD_EXPECTED+=("$EXPECTED")
  FIELD_BEFORE+=("$fbefore")
  FIELD_ECHO+=("$echo_cand")
done

# 3. Build the form body the way a browser submits the rendered page. The
# playerid field routes the write to the named player (HTTP.pm:562 parses a
# POST from the body only, HTTP.pm:1164-1166 resolves the client from it).
FORM="saveSettings=1&playerid=$MAC"
[ "$B_CONNECT" = "1" ] && FORM="$FORM&pref_enableSpotifyConnect=1"
[ "$B_DISCOVERY" = "0" ] && FORM="$FORM&pref_enableDiscovery=1"
[ "$B_AUTOPLAY" = "1" ] && FORM="$FORM&pref_enableAutoplay=1"
for arg in "$@"; do
  FORM="$FORM&$arg"
done

# 4. POST it.
BASE_URL="${LMS_URL%/jsonrpc.js}"
HTTP_CODE=$(curl -s -m 15 -o /dev/null -w '%{http_code}' -X POST -d "$FORM" \
  "$BASE_URL/plugins/SpotOn/settings/player.html?playerid=$MAC")

# 5. After snapshot, regardless of the HTTP result.
if ! snapshot; then
  echo "SETTINGS_POST=ERROR mac=$MAC reason=after-snapshot unreadable"
  exit 2
fi
A_CONNECT="$CONNECT"
A_DISCOVERY="$DISCOVERY"
A_AUTOPLAY="$AUTOPLAY"

DIFFS=()
[ "$A_CONNECT" != "$B_CONNECT" ] && DIFFS+=("enableSpotifyConnect")
[ "$A_DISCOVERY" != "$B_DISCOVERY" ] && DIFFS+=("disableDiscovery")
[ "$A_AUTOPLAY" != "$B_AUTOPLAY" ] && DIFFS+=("enableAutoplay")

# 6. Guard: the POST flipped a checkbox anyway -- restore via playerpref and
# fail loudly.
if [ ${#DIFFS[@]} -gt 0 ]; then
  REASON_PARTS=()
  RESTORED_KEYS=()
  for key in "${DIFFS[@]}"; do
    case "$key" in
      enableSpotifyConnect) bval="$B_CONNECT"; aval="$A_CONNECT" ;;
      disableDiscovery)     bval="$B_DISCOVERY"; aval="$A_DISCOVERY" ;;
      enableAutoplay)       bval="$B_AUTOPLAY"; aval="$A_AUTOPLAY" ;;
    esac
    REASON_PARTS+=("$key before=$bval after=$aval")
    bash "$LMS_CMD" "$MAC" playerpref "plugin.spoton:$key" "$bval" >/dev/null 2>&1
    RESTORED_KEYS+=("$key")
  done

  VERIFY_OK=1
  if snapshot; then
    for key in "${DIFFS[@]}"; do
      case "$key" in
        enableSpotifyConnect) cur="$CONNECT"; want="$B_CONNECT" ;;
        disableDiscovery)     cur="$DISCOVERY"; want="$B_DISCOVERY" ;;
        enableAutoplay)       cur="$AUTOPLAY"; want="$B_AUTOPLAY" ;;
      esac
      [ "$cur" != "$want" ] && VERIFY_OK=0
    done
  else
    VERIFY_OK=0
  fi

  REASON=$(IFS=,; echo "${REASON_PARTS[*]}")
  RESTORED=$(IFS=,; echo "${RESTORED_KEYS[*]}")
  echo "SETTINGS_POST=FAIL mac=$MAC reason=guard: $REASON restored=$RESTORED restore_verified=$VERIFY_OK"
  exit 1
fi

# 7. Nothing flipped, but the HTTP result was not 200.
if [ "$HTTP_CODE" != "200" ]; then
  echo "SETTINGS_POST=ERROR mac=$MAC reason=http $HTTP_CODE"
  exit 2
fi

# 8. Read-back: every caller field must be stored on the NAMED player.
MISMATCHES=()
ALREADY=()
ECHO_SKIPPED=()
nfields=${#FIELD_NAMES[@]}
for ((k = 0; k < nfields; k++)); do
  fname="${FIELD_NAMES[$k]}"
  if ! read_raw playerpref "$fname"; then
    echo "SETTINGS_POST=ERROR mac=$MAC reason=readback unreadable: $fname"
    exit 2
  fi
  fafter="$RAW"
  fbefore="${FIELD_BEFORE[$k]}"
  fwant="${FIELD_EXPECTED[$k]}"
  ok=0
  if [ "${FIELD_ECHO[$k]}" = "1" ] && [ "$fafter" = "$fbefore" ]; then
    ok=1
    ECHO_SKIPPED+=("$fname")
  elif matches "$fname" "$fwant" "$fafter"; then
    ok=1
    if matches "$fname" "$fwant" "$fbefore"; then
      ALREADY+=("$fname")
    fi
  fi
  if [ $ok -eq 0 ]; then
    MISMATCHES+=("$fname posted=$(show "${FIELD_POSTED[$k]}") expected=$(show "$fwant") stored=$(show "$fafter")")
  fi
done

# No restore on a mismatch: the tool cannot know which player received the write.
if [ ${#MISMATCHES[@]} -gt 0 ]; then
  MISMATCH_TEXT=$(IFS=,; echo "${MISMATCHES[*]}")
  echo "SETTINGS_POST=FAIL mac=$MAC reason=readback: $MISMATCH_TEXT"
  exit 3
fi

# 9. Success.
CALLER_FIELDS=$(IFS=,; echo "$*")
if [ $nfields -gt 0 ]; then READBACK="ok"; else READBACK="none"; fi
LINE="SETTINGS_POST=PASS mac=$MAC http=200 fields=$CALLER_FIELDS readback=$READBACK"
if [ ${#ALREADY[@]} -gt 0 ]; then
  LINE="$LINE already=$(IFS=,; echo "${ALREADY[*]}")"
fi
if [ ${#ECHO_SKIPPED[@]} -gt 0 ]; then
  LINE="$LINE echo_skip=$(IFS=,; echo "${ECHO_SKIPPED[*]}")"
fi
echo "$LINE"
exit 0
