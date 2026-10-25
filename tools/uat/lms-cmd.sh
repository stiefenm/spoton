#!/usr/bin/env bash
# LMS-JSON-RPC mit Quittungspflicht.
#
# Warum: LMS verwirft einen UNBEKANNTEN Befehl still -- HTTP 200, leerer Rumpf,
# keine Fehlermeldung. Aus "curl war erfolgreich" folgt NICHT "Befehl ausgefuehrt".
# Am 2026-09-10 hat genau das zwei Messungen verbrannt: ["playlist","stop"]
# existiert nicht (der Befehl heisst ["stop"]), und der Fehlschlag sah wie ein
# Produktdefekt aus ("Stop greift nicht durch").
#
# Aufruf:  lms-cmd.sh <playerid|-> <cmd> [arg ...]
# Exit:    0 = von LMS quittiert | 1 = NICHT quittiert (Befehl existiert nicht) | 2 = LMS unerreichbar
set -u
PLAYER="$1"; shift
# Offline-Test-Hook (Quick 260910-w9q): macht die Quittierungslogik ohne eine echte LMS pruefbar.
LMS_URL="${LMS_URL:-http://127.0.0.1:9000/jsonrpc.js}"
ARGS=$(printf '%s\n' "$@" | python3 -c 'import sys,json;print(json.dumps([l.rstrip("\n") for l in sys.stdin]))')
REQ=$(python3 -c 'import json,sys;print(json.dumps({"id":1,"method":"slim.request","params":[sys.argv[1],json.loads(sys.argv[2])]}))' "$PLAYER" "$ARGS")

RESP=$(curl -s -m 8 -X POST -H 'Content-Type: application/json' -d "$REQ" "$LMS_URL" 2>/dev/null)
RC=$?
# curl 52 = "empty reply from server": LMS SCHLIESST die Verbindung bei einem
# unbekannten Befehl, statt einen leeren Rumpf zu senden. Das ist KEIN Rig-Defekt,
# sondern die Ablehnung des Befehls -- getrennt zu melden, sonst jagt der naechste
# Leser einem Netzwerkproblem hinterher, das es nicht gibt.
if [ $RC -eq 52 ]; then
  echo "NICHT QUITTIERT: LMS hat die Verbindung ohne Antwort geschlossen fuer [$*]." >&2
  echo "                 Diesen Befehl gibt es nicht. Nichts wurde ausgefuehrt --" >&2
  echo "                 die Messung ist UNGUELTIG, nicht 'greift nicht'." >&2
  exit 1
fi
if [ $RC -ne 0 ]; then echo "LMS UNERREICHBAR (curl exit $RC): $*" >&2; exit 2; fi
if [ -z "$RESP" ]; then
  echo "NICHT QUITTIERT: LMS lieferte einen LEEREN Rumpf fuer [$*] -- diesen Befehl gibt es nicht." >&2
  echo "                 Nichts wurde ausgefuehrt. Messung ist ungueltig, nicht 'greift nicht'." >&2
  exit 1
fi
if ! printf '%s' "$RESP" | python3 -c 'import sys,json;d=json.load(sys.stdin);sys.exit(0 if "result" in d else 1)' 2>/dev/null; then
  echo "NICHT QUITTIERT: Antwort ohne result-Feld fuer [$*]: $(printf '%s' "$RESP" | head -c 200)" >&2
  exit 1
fi
echo "quittiert: [$*]"

# Nebenwirkungs-Warnung: manche quittierten Befehle STARTEN Ton, auch wenn das
# gar nicht die Absicht war (z. B. `pause 0` als blosse Quittungsprobe). Nach
# Projektregel ist jeder Eingriff in die Wiedergabe ansagepflichtig -- eine
# unbemerkte Nebenwirkung verletzt sie genauso wie ein unangesagtes Kommando.
case "$*" in
  *"pause 0"*|*"play"*|*"power 1"*|*resume*|*button*)
    sleep 1
    M=$(curl -s -m 5 -X POST -H 'Content-Type: application/json' \
        -d "{\"id\":1,\"method\":\"slim.request\",\"params\":[\"$PLAYER\",[\"status\",\"-\",\"1\",\"\"]]}" \
        "$LMS_URL" 2>/dev/null \
        | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"].get("mode",""))' 2>/dev/null)
    [ "$M" = "play" ] && echo "  ACHTUNG: dieser Befehl hat die Wiedergabe GESTARTET (mode=play). Ansagepflicht -- aufraeumen, falls unbeabsichtigt." >&2
    ;;
esac
exit 0
