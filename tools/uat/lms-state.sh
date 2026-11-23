#!/bin/bash
# tools/uat/lms-state.sh -- record and restore the LMS state of the UAT player (D-20a, plan 90.1-01).
#
#   lms-state.sh record-state <run-dir>    UAT provider/power/streamFormat/volume + global diagnosticMode -> state-before.txt
#   lms-state.sh restore-state <run-dir>   write them back (lms-cmd.sh receipts, settings POST for streamFormat), then state-now
#   lms-state.sh state-now <run-dir>       read them again, STATE_RESTORED=PASS|FAIL against the before file
#   lms-state.sh query <playerid|-> <cmd> [arg ...]   one JSON-RPC read, prints the reply's result object
#
# Ported from the archived Phase 79 runner (gaps-76.sh: lms_query, lms_cmd, res_val, v_state, state_read,
# cmd_record_state, cmd_restore_state, cmd_state_now), same output lines and exit codes. tools/uat/queue-clear.sh calls
# record-state and restore-state and parses STATE_RECORDED / STATE_RESTORED=PASS; the runner moved to
# .planning/milestones/v4.0-phases/ (archive 6a49ca67) and computes its PROJECT_DIR one level too shallow there, so
# the default path of queue-clear.sh no longer reached it.
#
# Two LMS access paths, never mixed up:
#   lms_cmd    state changes, through tools/uat/lms-cmd.sh (receipt required; it never prints the reply body)
#   lms_query  every reply whose content is evidence; prints the result object, fails closed (exit 2, RIG=LMS_NO_RESULT)
#              on an empty body or a reply without the `result` key; an EMPTY result object {} counts as present
#              (the lms-cmd.sh rule), so a failed read is never mistaken for an empty answer.
#
# Exit codes: 0 ok, 1 restore without a recorded state / receipt missing (RIG=LMS_NOT_ACKNOWLEDGED) / state differs,
#             2 usage, unreadable LMS (RIG=LMS_NO_RESULT, RIG=LMS_UNREACHABLE), RIG=STATE_BEFORE_EXISTS.
# Environment: LMS_URL (default http://127.0.0.1:9000/jsonrpc.js), RIG_UAT_MAC / UAT_MAC (default the rig's UAT id).
# Rules: set -u, LC_ALL=C, `command grep`, no rm -rf, no git stash; lavender-pa is never a target here.
set -u
export LC_ALL=C
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
TOOLS="$(dirname "$SELF")"
LMS_URL="${LMS_URL:-http://127.0.0.1:9000/jsonrpc.js}"
UAT="${RIG_UAT_MAC:-${UAT_MAC:-02:00:00:5a:11:01}}"
LMS_CMD="$TOOLS/lms-cmd.sh"
GRD=""

idle() { sleep "$1" & wait $!; }

lms_result_of() {   # stdin: a JSON-RPC reply body -> the `result` object as one JSON line; rc 2 + RIG=LMS_NO_RESULT without one
  python3 -c '
import sys, json
b = sys.stdin.read()
try:
    d = json.loads(b)
except Exception:
    sys.stderr.write("RIG=LMS_NO_RESULT\n"); sys.exit(2)
if not isinstance(d, dict) or "result" not in d:
    sys.stderr.write("RIG=LMS_NO_RESULT\n"); sys.exit(2)
print(json.dumps(d["result"], separators=(",", ":"), sort_keys=True))
'
}
lms_query() {       # <playerid|-> <cmd> [arg ...]
  local player="$1" args req resp rc; shift
  args=$(printf '%s\n' "$@" | python3 -c 'import sys,json;print(json.dumps([l.rstrip("\n") for l in sys.stdin]))')
  req=$(python3 -c 'import json,sys;print(json.dumps({"id":1,"method":"slim.request","params":[sys.argv[1],json.loads(sys.argv[2])]}))' "$player" "$args")
  resp=$(curl -s -m 8 -X POST -H 'Content-Type: application/json' -d "$req" "$LMS_URL" 2>/dev/null); rc=$?
  if [ "$rc" != 0 ] || [ -z "$resp" ]; then echo "RIG=LMS_NO_RESULT" >&2; return 2; fi
  printf '%s' "$resp" | lms_result_of
}
lms_cmd() {         # <playerid|-> <cmd> [arg ...]; state changes only; exits the subcommand without a receipt
  local out rc
  out=$(bash "$LMS_CMD" "$@" 2>&1); rc=$?
  [ -n "$GRD" ] && [ -d "$GRD" ] && printf '%s rc=%s %s\n' "$(date +%T)" "$rc" "$out" >> "$GRD/lms-cmd.log"
  case $rc in
    0) return 0 ;;
    1) echo "RIG=LMS_NOT_ACKNOWLEDGED cmd=[$*]"; exit 1 ;;
    *) echo "RIG=LMS_UNREACHABLE cmd=[$*]"; exit 2 ;;
  esac
}
res_val() {         # stdin: result JSON; args: keys to try in order; prints the first non-null value, else nothing
  python3 -c '
import sys, json
try:
    r = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if isinstance(r, dict):
    for k in sys.argv[1:]:
        if r.get(k) is not None:
            print(r[k]); break
' "$@"
}

v_state() {         # <before file> <now file>: STATE_RESTORED=PASS|FAIL; no before file -> NOTHING_RECORDED (never PASS)
  if [ ! -s "$1" ]; then echo "STATE_RESTORE=NOTHING_RECORDED"; return 1; fi
  local k diff=""
  for k in provider power streamFormat volume diagnosticMode; do
    if [ "$(sed -n "s/^$k=//p" "$1" | tail -1)" != "$(sed -n "s/^$k=//p" "$2" 2>/dev/null | tail -1)" ]; then diff="$diff $k"; fi
    [ -z "$(command grep -c "^$k=" "$1" | command grep -vx 0)" ] && diff="$diff $k(not_recorded)"
  done
  if [ -z "$diff" ]; then echo "STATE_RESTORED=PASS"; return 0; fi
  echo "STATE_RESTORED=FAIL diff=$diff"; return 1
}

state_read() {      # <file to write>: the five values from lms_query bodies
  local f="$1" r p pw sf vo dm
  r=$(lms_query "$UAT" playerpref plugin.dontstopthemusic:provider '?') || return 2; p=$(printf '%s' "$r" | res_val _p2)
  r=$(lms_query "$UAT" power '?') || return 2;                                  pw=$(printf '%s' "$r" | res_val _power)
  r=$(lms_query "$UAT" playerpref plugin.spoton:streamFormat '?') || return 2;  sf=$(printf '%s' "$r" | res_val _p2)
  r=$(lms_query "$UAT" mixer volume '?') || return 2;                           vo=$(printf '%s' "$r" | res_val _volume)
  r=$(lms_query - pref plugin.spoton:diagnosticMode '?') || return 2;           dm=$(printf '%s' "$r" | res_val _p2)
  printf 'provider=%s\npower=%s\nstreamFormat=%s\nvolume=%s\ndiagnosticMode=%s\n' "$p" "$pw" "$sf" "$vo" "$dm" > "$f"
}
cmd_record_state() {
  local d="${1:-}"
  [ -d "$d" ] || { echo "Usage: record-state <run-dir>" >&2; exit 2; }
  if [ -e "$d/state-before.txt" ]; then echo "RIG=STATE_BEFORE_EXISTS $d/state-before.txt"; exit 2; fi
  GRD="$d"
  state_read "$d/state-before.txt" || { rm -f "$d/state-before.txt"; exit 2; }
  echo "STATE_RECORDED $d/state-before.txt"; sed 's/^/BEFORE /' "$d/state-before.txt"
}
cmd_state_now() {
  local d="${1:-}" rc
  [ -d "$d" ] || { echo "Usage: state-now <run-dir>" >&2; exit 2; }
  state_read "$d/state-now.txt" || exit 2
  sed 's/^/NOW /' "$d/state-now.txt"
  v_state "$d/state-before.txt" "$d/state-now.txt"; rc=$?
  exit $rc
}
cmd_restore_state() {
  local d="${1:-}" b k v
  [ -d "$d" ] || { echo "Usage: restore-state <run-dir>" >&2; exit 2; }
  b="$d/state-before.txt"
  if [ ! -s "$b" ]; then echo "STATE_RESTORE=NOTHING_RECORDED"; exit 1; fi
  GRD="$d"
  v=$(sed -n 's/^provider=//p' "$b" | tail -1);       lms_cmd "$UAT" playerpref plugin.dontstopthemusic:provider "$v"
  v=$(sed -n 's/^streamFormat=//p' "$b" | tail -1)
  if [ -n "$v" ]; then bash "$TOOLS/player-settings-post.sh" "$UAT" "pref_streamFormat=$v" > "$d/restore-streamformat.txt" 2>&1; echo "RESTORE_STREAMFORMAT_RC=$?"; fi
  v=$(sed -n 's/^volume=//p' "$b" | tail -1);         [ -n "$v" ] && lms_cmd "$UAT" mixer volume "$v"
  v=$(sed -n 's/^diagnosticMode=//p' "$b" | tail -1); [ -n "$v" ] && lms_cmd - pref plugin.spoton:diagnosticMode "$v"
  v=$(sed -n 's/^power=//p' "$b" | tail -1);          [ -n "$v" ] && lms_cmd "$UAT" power "$v"
  idle 2
  cmd_state_now "$d"
}
cmd_query() { lms_query "$@"; exit $?; }

case "${1:-}" in
  record-state)  shift; cmd_record_state "$@" ;;
  restore-state) shift; cmd_restore_state "$@" ;;
  state-now)     shift; cmd_state_now "$@" ;;
  query)         shift; cmd_query "$@" ;;
  *) echo "Usage: lms-state.sh record-state|restore-state|state-now <run-dir> | query <playerid|-> <cmd> [arg ...]" >&2; exit 2 ;;
esac
