#!/usr/bin/env bash
# Vorab-Tor vor JEDEM Hoerszenario. Drei Pruefungen, jede kann fuer sich rot werden.
# Rot heisst: NICHT messen. Ein Lauf, der hier durchrutscht, ist still ungueltig.
SL=/var/log/squeezeboxserver/server.log
WINDOW_MIN="${GATE_WINDOW_MIN:-5}"
FAIL=0

echo "── Tor 1: Proxy-URL-Adresse (CR-05) ──"
SRVADDR="${GATE_FAKE_ADDR:-$(curl -s -m 5 -X POST -H 'Content-Type: application/json' \
  -d '{"id":1,"method":"slim.request","params":["",["serverstatus","0","1"]]}' \
  http://127.0.0.1:9000/jsonrpc.js 2>/dev/null \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"].get("ip",""))' 2>/dev/null)}"
LOCAL=$(ip -4 -o addr show scope global | awk '{split($4,a,"/");print a[1]}')
if [ -z "$SRVADDR" ]; then echo "  UNBESTIMMT: serverAddr() nicht auslesbar"; FAIL=1
elif [ "$SRVADDR" = "127.0.0.1" ] || printf '%s\n' $LOCAL | command grep -qx "$SRVADDR"; then
  echo "  PASS  serverAddr()=$SRVADDR ist erreichbar"
else
  echo "  FAIL  serverAddr()=$SRVADDR ist auf diesem Host NICHT gebunden -- LMS neu starten"; FAIL=1
fi

echo "── Tor 2: Spotify-Erreichbarkeit (jetzt) ──"
# GATE_FAKE_NET=down|up (Quick 260910-w9q): Determinismus-Fix + neue Simulation.
# Vorher wurde der echte curl-Aufruf IMMER ausgefuehrt, auch bei simuliertem
# "down" -- das kostete bis zu 8 reale Sekunden Timeout und war damit fuer
# diesen Zweig gar nicht wirklich offline-deterministisch. Jetzt entfaellt der
# echte Netzaufruf komplett, sobald GATE_FAKE_NET gesetzt ist; "up" ist neu und
# der einzige Weg, Tor 2s PASS-Pfad ohne echten Internetzugang zu pruefen.
if [ "${GATE_FAKE_NET:-}" = "down" ]; then
  CODE="000"
elif [ "${GATE_FAKE_NET:-}" = "up" ]; then
  CODE="200"
else
  CODE=$(curl -s -o /dev/null -w '%{http_code}' -m 8 https://spclient.wg.spotify.com/ 2>/dev/null)
fi
if [ "$CODE" = "000" ] || [ -z "$CODE" ]; then
  echo "  FAIL  spclient nicht erreichbar (curl code $CODE) -- Metadaten laufen ins Timeout"; FAIL=1
else
  echo "  PASS  spclient antwortet (HTTP $CODE)"
fi

echo "── Tor 3: frische SpClient-Timeouts in den letzten ${WINDOW_MIN} min ──"
# Ein einzelner Track, der in einer Wiederholschleife haengt, ist KEIN Netzausfall.
# Blockieren wuerde hier dauerhaft messen verhindern (Fehlalarm). Deshalb nach
# VERSCHIEDENEN Zielen zaehlen: >1 Ziel = Netz haengt (rot); genau 1 Ziel = ein
# steckengebliebener Track (gelb -- messen erlaubt, aber NICHT mit diesem Track).
SINCE=$(date -d "-${WINDOW_MIN} min" '+%y-%m-%d %H:%M')
RECENT=$(command grep -E "SpClient: HTTP 0 error" "$SL" 2>/dev/null | awk -v s="[$SINCE" '$0 >= s')
if [ -n "${GATE_FAKE_TARGETS:-}" ]; then NT="$GATE_FAKE_TARGETS"; STUCK="(simuliert)"; else
  NT=$(printf '%s\n' "$RECENT" | grep -oE "for [a-z0-9/]+/[0-9a-f]{32}" | sort -u | grep -c . )
  STUCK=$(printf '%s\n' "$RECENT" | grep -oE "[0-9a-f]{32}" | sort -u | head -1)
fi
if [ "${NT:-0}" -gt 1 ]; then
  echo "  FAIL  Timeouts fuer $NT VERSCHIEDENE Ziele -- das Netz haengt, nicht messen"; FAIL=1
elif [ "${NT:-0}" -eq 1 ]; then
  echo "  WARN  Timeouts nur fuer EIN Ziel ($STUCK) -- steckengebliebener Track,"
  echo "        kein Netzausfall. Messen erlaubt, aber NICHT mit diesem Track."
  export GATE_STUCK_TARGET="$STUCK"
else
  echo "  PASS  keine Timeouts im Fenster"
fi

[ $FAIL -eq 0 ] && { echo "TOR GRUEN -- messen erlaubt"; exit 0; }
echo "TOR ROT -- NICHT messen (Ergebniszeile waere 'nicht geprueft', nie 'greift nicht')"; exit 1
