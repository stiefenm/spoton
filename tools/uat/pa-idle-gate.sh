#!/usr/bin/env bash
# pa-idle-Wache: lavender-pa darf nicht spielen, bevor ein Lauf LMS neu startet
# oder einen globalen Zustand aendert (backend-Pref, custom-convert.conf,
# Erneuerung). Der Nutzer hoert ueber lavender-pa -- ein Neustart waehrend des
# Hoerens waere ein unangekuendigter Eingriff (T-84-43).
#
# Aufruf:  pa-idle-gate.sh
# Ausgabe: genau EINE Zeile
#            PA_IDLE=PASS mode=<mode>               (mode != play)
#            PA_IDLE=FAIL mode=play time=<s>        (lavender-pa spielt)
#            PA_IDLE=ERROR <grund>                  (LMS nicht lesbar)
# Exit:    0 = PASS | 1 = FAIL (pa spielt) | 2 = ERROR (ein Fehler ist KEIN Pass)
#
# Vertrag fuer Aufrufer: bei FAIL und bei ERROR STOPPEN -- keine Warteschleife,
# kein Weitermachen. Der Aufrufer meldet zurueck und wartet auf den Nutzer.
#
# Umgebung:
#   PA_MAC             MAC von lavender-pa (Pflicht, z.B. 02:00:00:5a:11:03); ohne Wert
#                      PA_IDLE=ERROR PA_MAC not set und Exit 2 (D-10, kein Default)
#   LMS_URL            JSON-RPC-Endpunkt (Default http://127.0.0.1:9000/jsonrpc.js)
#   PA_IDLE_FAKE_MODE  play|stop|pause -- Offline-Testhook, umgeht den Netzzugriff
#                      (nur fuer Trockenlaeufe; liefert time=0)
set -u
PA="${PA_MAC:-}"
LMS_URL="${LMS_URL:-http://127.0.0.1:9000/jsonrpc.js}"

if [ -z "$PA" ]; then
  echo "PA_IDLE=ERROR PA_MAC not set"
  exit 2
fi

if [ -n "${PA_IDLE_FAKE_MODE:-}" ]; then
  MODE="$PA_IDLE_FAKE_MODE"
  TIME="0"
else
  RESP=$(curl -s -m 8 -X POST -H 'Content-Type: application/json' \
    -d "{\"id\":1,\"method\":\"slim.request\",\"params\":[\"$PA\",[\"status\",\"-\",\"1\"]]}" \
    "$LMS_URL" 2>/dev/null)
  RC=$?
  if [ $RC -ne 0 ] || [ -z "$RESP" ]; then
    echo "PA_IDLE=ERROR lms_unreachable curl_exit=$RC"
    exit 2
  fi
  PARSED=$(printf '%s' "$RESP" | python3 -c '
import sys, json
try:
    r = json.load(sys.stdin)["result"]
except Exception:
    sys.exit(1)
if "mode" not in r:
    sys.exit(1)
t = r.get("time", 0)
print("%s\t%s" % (r.get("mode", ""), "" if t is None else t))
' 2>/dev/null) || { echo "PA_IDLE=ERROR unparsable_status"; exit 2; }
  MODE=$(printf '%s' "$PARSED" | cut -f1)
  TIME=$(printf '%s' "$PARSED" | cut -f2)
  if [ -z "$MODE" ]; then
    echo "PA_IDLE=ERROR empty_mode (player unknown to LMS?)"
    exit 2
  fi
fi

if [ "$MODE" = "play" ]; then
  echo "PA_IDLE=FAIL mode=play time=$TIME"
  exit 1
fi
echo "PA_IDLE=PASS mode=$MODE"
exit 0
