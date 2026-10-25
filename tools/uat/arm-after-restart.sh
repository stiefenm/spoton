#!/usr/bin/env bash
# arm-after-restart.sh -- LMS neu starten und die Messkanaele scharfstellen,
# BEVOR der Soloist-Daemon seine ws.port ankuendigt.
#
# Warum als Skript: die sechs DEBUG-Kategorien sind laufzeit-only, jeder
# Neustart raeumt sie weg (debugCommand kennt keinen Persist-Parameter).
# Gemessen am 2026-09-14: JSON-RPC antwortet +1,04 s nach dem Neustart,
# ws.port (-> on_found -> Control->new) wird +7,41 s geschrieben. Das Fenster
# ist ~6,4 s -- von Hand nicht zu treffen, per Skript bequem.
#
# Aufruf:  bash arm-after-restart.sh [--no-restart]
# Umgebung: SPOTON_MAC, sonst PA_MAC = MAC von lavender-pa (Pflicht, kein Default; sonst Exit 2).
# Exit:    0 = alle sieben Schalter bestaetigt UND vor ws.port gesetzt
#          1 = mindestens ein Schalter nicht bestaetigt
#          2 = scharfgestellt, aber ERST NACH ws.port (Fenster verpasst)
#
# Ergaenzt (Messrunde 5, 2026-09-14/15): von Hand hat das Scharfstellen der sechs Kategorien
# +50 s nach dem Neustart gebraucht, das Fenster bis ws.port war zu diesem Zeitpunkt bereits bei
# ~7 s -- von Hand strukturell zu spaet. Per Skript lag das Scharfstellen bei +0,26 bis +1,44 s.
set -u

# Identitaets-Parameter: Spieler-MAC treibt den WS_PATH-Default (Doppelpunkte
# entfernt); WS_PATH selbst sticht diese Ableitung, wenn direkt gesetzt.
MAC="${SPOTON_MAC:-${PA_MAC:-}}"
if [ -z "$MAC" ]; then
  echo "arm-after-restart: weder SPOTON_MAC noch PA_MAC gesetzt (MAC von lavender-pa, D-10)" >&2
  exit 2
fi
MAC_NOCOLON=$(echo "$MAC" | tr -d ':')
# Testhaken (Quick 260915-bpd): LMS_URL macht den JSON-RPC-Zielport ohne echten LMS pruefbar,
# gleiche Form wie tools/uat/lms-cmd.sh (Quick 260910-w9q).
URL="${LMS_URL:-http://127.0.0.1:9000/jsonrpc.js}"
WS="${WS_PATH:-/var/lib/squeezeboxserver/cache/spoton/soloist/players/$MAC_NOCOLON/data/ws.port}"
CATS="plugin.spoton player.source player.streaming player.streaming.direct player.streaming.remote control.command"
# Testhaken (Quick 260915-bpd): SUDO_BIN macht jeden `sudo -n`-Aufruf test-passierbar,
# gleiche Konvention wie tools/uat/extract-run.pl.
SUDO_BIN="${SUDO_BIN:-sudo}"

ws_mtime() { "$SUDO_BIN" -n stat -c %Y "$WS" 2>/dev/null; }
rpc() { curl -s -m 2 -X POST -H 'Content-Type: application/json' -d "$1" "$URL" 2>/dev/null; }
now() { date +%s.%N; }

BEFORE=$(ws_mtime)
T0=$(now)
if [ "${1:-}" != "--no-restart" ]; then
  "$SUDO_BIN" -n systemctl restart "${LMS_SERVICE:-lyrionmusicserver}" || { echo "FEHLER: Neustart fehlgeschlagen" >&2; exit 1; }
fi

# --- auf JSON-RPC warten (eng gepollt, nicht geschlafen) ---
for i in $(seq 1 300); do
  R=$(rpc '{"id":1,"method":"slim.request","params":["",["serverstatus","0","1"]]}')
  printf '%s' "$R" | python3 -c 'import sys,json;d=json.load(sys.stdin);sys.exit(0 if "result" in d else 1)' 2>/dev/null && break
  sleep 0.2
done
T_RPC=$(now)
python3 -c "print('JSON-RPC antwortet   : +%.2fs' % ($T_RPC-$T0))"

# --- scharfstellen: setzen UND je einzeln zurueckfragen ---
FAIL=0
for c in $CATS; do
  rpc "{\"id\":1,\"method\":\"slim.request\",\"params\":[\"\",[\"debug\",\"$c\",\"DEBUG\"]]}" >/dev/null
  V=$(rpc "{\"id\":1,\"method\":\"slim.request\",\"params\":[\"\",[\"debug\",\"$c\",\"?\"]]}" \
      | python3 -c 'import sys,json;print(json.load(sys.stdin).get("result",{}).get("_value","<leer>"))' 2>/dev/null)
  if [ "$V" = "DEBUG" ]; then printf '  %-30s %s\n' "$c" "$V"
  else printf '  %-30s FEHLER: %s\n' "$c" "${V:-<leer>}"; FAIL=1; fi
done
rpc '{"id":1,"method":"slim.request","params":["",["pref","plugin.spoton:diagnosticMode","1"]]}' >/dev/null
DV=$(rpc '{"id":1,"method":"slim.request","params":["",["pref","plugin.spoton:diagnosticMode","?"]]}' \
     | python3 -c 'import sys,json;print(json.load(sys.stdin).get("result",{}).get("_p2","<leer>"))' 2>/dev/null)
printf '  %-30s %s\n' "diagnosticMode" "${DV:-<leer>}"
[ "$DV" = "1" ] || FAIL=1

T_ARM=$(now)
python3 -c "print('scharfgestellt       : +%.2fs' % ($T_ARM-$T0))"

# --- hat es das Fenster getroffen? ---
# Nur nach einem ECHTEN Neustart aussagekraeftig: ohne Neustart ist ws.port
# zwangslaeufig unveraendert, und ein "Fenster offen" waere dann ein Tor, das
# nicht fehlschlagen kann.
if [ "${1:-}" = "--no-restart" ]; then
  [ $FAIL -ne 0 ] && { echo "NICHT ALLE SCHALTER BESTAETIGT -- nicht messen"; exit 1; }
  echo "SCHALTER GESETZT (--no-restart: Fenster-Tor NICHT ANWENDBAR, kein Neustart gefahren)."
  exit 0
fi
AFTER=$(ws_mtime)
if [ -n "$AFTER" ] && [ "$AFTER" != "$BEFORE" ]; then
  echo "WARNUNG: ws.port war schon neu geschrieben, als das Scharfstellen fertig war."
  echo "         Control existiert bereits -- das Signatur-C-Fenster ist fuer diesen Lauf durch."
  [ $FAIL -eq 0 ] && exit 2
fi
if [ $FAIL -ne 0 ]; then echo "NICHT ALLE SCHALTER BESTAETIGT -- nicht messen"; exit 1; fi
echo "BEREIT: alle sieben Schalter bestaetigt, ws.port noch nicht neu -- Fenster offen."
