#!/usr/bin/env bash
# Read-only preflight gate for the partial-settings-form trap.
#
# Incident (debug session .planning/debug/connect-transfer-split-brain.md):
# on 2026-09-26 03:29:52, .planning/phases/83.3-soloist-lebenszyklus-cdn-
# erneuerung-vor-ablauf/runners/live-checks.sh:688 POSTed a settings form
# that carried ONLY pref_soloistQuality. Plugins/SpotOn/Settings/Player.pm
# then derived three prefs from field ABSENCE on every save: enableSpotifyConnect,
# disableDiscovery (inverted from pref_enableDiscovery), enableAutoplay.
# lavender-UAT ran two days with Connect muted, producing a false
# split-brain finding. Since 84-21 (D-31 (2)) the handler writes them only
# with their has_<name> presence marker (Player.pm :45, :107, :112); this
# gate stays as the rig precondition and as the regression catch.
#
# Contract: query the four prefs below, read-only, and print exactly one
# line: RIG_PREFS=PASS|FAIL|ERROR. Never write anything -- only `?` queries
# ever leave this tool.
#
# Why null counts as FAIL for the first three keys: at runtime an undefined
# per-player pref falls back to the global pref (Control.pm:4727-4728), but
# the settings page renders it as CHECKED regardless (Player.pm:108, :189).
# A null rig state is therefore ambiguous at the page and must be treated as
# a hard FAIL here, not silently accepted.
#
# Checked keys (fixed order):
#   1. enableSpotifyConnect         (want 1)
#   2. disableDiscovery             (want 0)
#   3. enableAutoplay               (want 1)
#   4. discoveryDisabledByCrashLoop (want 0; null counts as 0 -- it is a
#      crash-loop flag that is normally unset, Unified/Daemon.pm:156-161)
#
# Usage: rig-prefs-check.sh <mac> [--snapshot] [--expect <key>=<0|1>]
#   --snapshot          print the four normalized key=value lines and exit 0
#   --expect <key>=<v>  override the wanted value for one key (dry-run only)
#
# Exit: 0 = PASS | 1 = FAIL (mismatch named) | 2 = ERROR (unreadable/usage)
set -u

LMS_URL="${LMS_URL:-http://127.0.0.1:9000/jsonrpc.js}"

usage_error() {
  echo "RIG_PREFS=ERROR reason=usage: $1"
  exit 2
}

if [ $# -lt 1 ]; then
  usage_error "missing mac"
fi

MAC="$1"; shift
if ! [[ "$MAC" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]]; then
  usage_error "invalid mac: $MAC"
fi

DO_SNAPSHOT=0
EXPECT_KEY=""
EXPECT_VAL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --snapshot)
      DO_SNAPSHOT=1
      shift
      ;;
    --expect)
      shift
      if [ $# -lt 1 ]; then
        usage_error "--expect requires an argument"
      fi
      EXPECT_ARG="$1"
      shift
      EXPECT_KEY="${EXPECT_ARG%%=*}"
      EXPECT_VAL="${EXPECT_ARG#*=}"
      case "$EXPECT_KEY" in
        enableSpotifyConnect|disableDiscovery|enableAutoplay|discoveryDisabledByCrashLoop) ;;
        *) usage_error "unknown --expect key: $EXPECT_KEY" ;;
      esac
      case "$EXPECT_VAL" in
        0|1) ;;
        *) usage_error "--expect value not 0/1: $EXPECT_VAL" ;;
      esac
      ;;
    *)
      usage_error "unknown option: $1"
      ;;
  esac
done

# query_key <key> -- sets QUERY_RESULT (0|1|undef) on success (return 0), or
# ERR_REASON on failure (return 2). One JSON-RPC playerpref `?` request per
# call; never sends anything but `?`.
query_key() {
  local key="$1"
  local req resp rc val

  req='{"id":1,"method":"slim.request","params":["'"$MAC"'",["playerpref","plugin.spoton:'"$key"'","?"]]}'
  resp=$(curl -s -m 8 -X POST -H 'Content-Type: application/json' -d "$req" "$LMS_URL" 2>/dev/null)
  rc=$?

  if [ $rc -ne 0 ]; then
    if [ $rc -eq 52 ]; then
      ERR_REASON="$key: no reply (player unknown to LMS or query rejected)"
    else
      ERR_REASON="$key: LMS unreachable (curl exit $rc)"
    fi
    return 2
  fi

  val=$(printf '%s' "$resp" | python3 -c '
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
elif v == "" or v == 0 or v == "0":
    print("0")
else:
    print("1")
' 2>/dev/null)

  if [ -z "$val" ] || [ "$val" = "__NOVAL__" ]; then
    ERR_REASON="$key: no reply (player unknown to LMS or query rejected)"
    return 2
  fi

  if [ "$val" = "__NULL__" ]; then
    QUERY_RESULT="undef"
  else
    QUERY_RESULT="$val"
  fi
  return 0
}

V_CONNECT="" V_DISCOVERY="" V_AUTOPLAY="" V_CRASHLOOP=""

for key in enableSpotifyConnect disableDiscovery enableAutoplay discoveryDisabledByCrashLoop; do
  query_key "$key"
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "RIG_PREFS=ERROR mac=$MAC reason=$ERR_REASON"
    exit 2
  fi
  case "$key" in
    enableSpotifyConnect)         V_CONNECT="$QUERY_RESULT" ;;
    disableDiscovery)             V_DISCOVERY="$QUERY_RESULT" ;;
    enableAutoplay)                V_AUTOPLAY="$QUERY_RESULT" ;;
    discoveryDisabledByCrashLoop) V_CRASHLOOP="$QUERY_RESULT" ;;
  esac
done

if [ "$DO_SNAPSHOT" -eq 1 ]; then
  echo "enableSpotifyConnect=$V_CONNECT"
  echo "disableDiscovery=$V_DISCOVERY"
  echo "enableAutoplay=$V_AUTOPLAY"
  echo "discoveryDisabledByCrashLoop=$V_CRASHLOOP"
  exit 0
fi

WANT_CONNECT=1
WANT_DISCOVERY=0
WANT_AUTOPLAY=1
WANT_CRASHLOOP=0

if [ -n "$EXPECT_KEY" ]; then
  case "$EXPECT_KEY" in
    enableSpotifyConnect)         WANT_CONNECT="$EXPECT_VAL" ;;
    disableDiscovery)             WANT_DISCOVERY="$EXPECT_VAL" ;;
    enableAutoplay)                WANT_AUTOPLAY="$EXPECT_VAL" ;;
    discoveryDisabledByCrashLoop) WANT_CRASHLOOP="$EXPECT_VAL" ;;
  esac
fi

MISMATCHES=()

compare_key() {
  local name="$1" val="$2" want="$3"
  local effective="$val"
  # discoveryDisabledByCrashLoop is normally unset; an unset flag means
  # "not crash-looping", i.e. effectively 0, regardless of what --expect asks.
  if [ "$name" = "discoveryDisabledByCrashLoop" ] && [ "$val" = "undef" ]; then
    effective="0"
  fi
  if [ "$effective" != "$want" ]; then
    MISMATCHES+=("$name=$val(want $want)")
  fi
}

compare_key enableSpotifyConnect "$V_CONNECT" "$WANT_CONNECT"
compare_key disableDiscovery "$V_DISCOVERY" "$WANT_DISCOVERY"
compare_key enableAutoplay "$V_AUTOPLAY" "$WANT_AUTOPLAY"
compare_key discoveryDisabledByCrashLoop "$V_CRASHLOOP" "$WANT_CRASHLOOP"

EXPECT_SUFFIX=""
if [ -n "$EXPECT_KEY" ]; then
  EXPECT_SUFFIX=" expect_override=$EXPECT_KEY=$EXPECT_VAL"
fi

if [ ${#MISMATCHES[@]} -eq 0 ]; then
  echo "RIG_PREFS=PASS mac=$MAC enableSpotifyConnect=$V_CONNECT disableDiscovery=$V_DISCOVERY enableAutoplay=$V_AUTOPLAY discoveryDisabledByCrashLoop=$V_CRASHLOOP$EXPECT_SUFFIX"
  exit 0
else
  REASON=$(IFS=,; echo "${MISMATCHES[*]}")
  echo "RIG_PREFS=FAIL mac=$MAC reason=$REASON$EXPECT_SUFFIX"
  exit 1
fi
