#!/usr/bin/env bash
# Wiederholt den Signatur-C-Trockenlauf und wertet je Lauf getrennt aus.
# Zaehlungen je Lauf, nie in Summe.
#
# Beleg (Messrunde 5, 2026-09-14/15), 3 Laeufe: Vorlauf Anforderung -> startHelper 1,971 /
# 1,975 / 1,970 s. Gedecktes Fenster (startHelper -> ws.port announced): 0,116 / 0,115 /
# 0,113 s.
# Umgebung: SPOTON_MAC, sonst PA_MAC = MAC von lavender-pa (Pflicht, kein Default; sonst Exit 2).
set -u
# Eigenes Verzeichnis herleiten -- nicht mehr an einen Session-Scratchpad-Pfad gebunden,
# PROBE_SCRIPT loest seinen Default relativ dazu auf.
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Testhaken (Quick 260915-bpd): SERVER_LOG macht die ausgewertete Logdatei test-passierbar.
LOG="${SERVER_LOG:-/var/log/squeezeboxserver/server.log}"
# Testhaken (Quick 260915-bpd): PROBE_SCRIPT erlaubt einen synthetischen Sonden-Stub in Tests,
# statt des echten ~90s-Trockenlaufs N Mal zu fahren. Direkter Aufruf (kein `python3`-Praefix):
# signatur-c-probe.py ist bereits ausfuehrbar (chmod +x) und traegt sein eigenes Shebang;
# ein Test-Stub fuer PROBE_SCRIPT ist ein Bash-Skript, kein Python-Skript.
PROBE_SCRIPT="${PROBE_SCRIPT:-$SELF_DIR/signatur-c-probe.py}"
# Testhaken (Quick 260915-bpd): SUDO_BIN macht jeden `sudo -n`-Aufruf test-passierbar,
# gleiche Konvention wie tools/uat/extract-run.pl.
SUDO_BIN="${SUDO_BIN:-sudo}"
# Phase 82 Plan 44 (D-13, Runde 44): MAC/LMS_URL fuer den Wirkungsnachweis --
# gleiches Testhaken-Muster wie PROBE_SCRIPT/SUDO_BIN oben. Default-MAC
# kommt wie bei signatur-c-probe.py aus SPOTON_MAC, sonst PA_MAC (lavender-pa, D-10).
MAC="${SPOTON_MAC:-${PA_MAC:-}}"
if [ -z "$MAC" ]; then
  echo "repeat-probe: weder SPOTON_MAC noch PA_MAC gesetzt (MAC von lavender-pa, D-10)" >&2
  exit 2
fi
LMS_URL="${LMS_URL:-http://127.0.0.1:9000/jsonrpc.js}"
N="${1:-3}"
for r in $(seq 1 "$N"); do
  echo "════════ LAUF $r/$N ════════"
  MARK=$("$SUDO_BIN" -n wc -l "$LOG" | awk '{print $1}')
  OUT=$("$PROBE_SCRIPT" 2>&1); RC=$?
  echo "$OUT" | grep -E "Tor C|REANFORDERUNG|ws.port neu|ROT"
  if [ $RC -eq 3 ]; then echo "  -> LAUF UNGUELTIG (nicht quittiert)"; continue; fi
  if [ $RC -ne 0 ]; then echo "  -> LAUF UNGUELTIG (Tor rot), NICHT auswerten"; continue; fi
  # auf das Ereignispaar warten
  for i in $(seq 1 25); do
    n=$("$SUDO_BIN" -n tail -n +$((MARK+1)) "$LOG" | grep -cE "Need to create Soloist daemon")
    [ "${n:-0}" -gt 0 ] && break
    sleep 1
  done
  T=$("$SUDO_BIN" -n tail -n +$((MARK+1)) "$LOG")
  DEF=$(printf '%s' "$T" | grep -cF "deferring on SoloistDaemon")
  NR=$(printf '%s' "$T"  | grep -cF "Soloist daemon not ready")
  GNT=$(printf '%s' "$T" | grep -cF "getNextTrack:")
  EXP=$(printf '%s' "$T" | grep -cF "explodePlaylist:")
  # Phase 82 Plan 44 (D-13, Runde 44): DEF_OUTER zaehlt den NEUEN Zweig aus
  # Task 3 (der alte "deferring on SoloistDaemon" bleibt DEF, wird aber bei
  # t~1,97s laut Messrunde 5 nicht mehr erwartet).
  DEF_OUTER=$(printf '%s' "$T" | grep -cF "deferring on DaemonManager")
  T_REQ=$(printf '%s' "$T" | grep -F "Song::getNextSong" | head -1 | sed -n 's/^\[\([^]]*\)\].*/\1/p')
  T_SH=$(printf '%s'  "$T" | grep -F "Need to create Soloist daemon" | head -1 | sed -n 's/^\[\([^]]*\)\].*/\1/p')
  printf '  deferring=%s  deferring_outer=%s  not_ready=%s  getNextTrack=%s  explodePlaylist=%s\n' "$DEF" "$DEF_OUTER" "$NR" "$GNT" "$EXP"
  printf '  Anforderung : %s\n  startHelper : %s\n' "${T_REQ:-<fehlt>}" "${T_SH:-<fehlt>}"
  if [ -n "${T_REQ:-}" ] && [ -n "${T_SH:-}" ]; then
    python3 - "$T_REQ" "$T_SH" <<'PY'
import sys,datetime
f="%y-%m-%d %H:%M:%S.%f"
a=datetime.datetime.strptime(sys.argv[1],f); b=datetime.datetime.strptime(sys.argv[2],f)
d=(b-a).total_seconds()
print(f"  Vorlauf     : Anforderung {d:+.3f}s vor startHelper" if d>0
      else f"  Vorlauf     : Anforderung {-d:+.3f}s NACH startHelper")
PY
  fi

  # Phase 82 Plan 44 (D-13, Runde 44): Wirkungsnachweis -- "der Zweig
  # feuert" allein belegt nur, dass Code erreicht wurde, nicht dass er
  # wirkte. Zwei Status-Polls (~3s Abstand), gleiches curl/JSON-RPC-Muster
  # wie tools/uat/lms-cmd.sh's eigener Status-Check -- NIEMALS die
  # Menschen-Ausgabe eines Werkzeugs parsen.
  PARSE_STATUS='import json,sys
try:
    d=json.load(sys.stdin)
    r=d.get("result") or {}
    print(r.get("mode",""), r.get("time",0))
except Exception:
    print("", 0)'
  POLL1=$(curl -s -m 3 -X POST -H 'Content-Type: application/json' -d \
    '{"id":1,"method":"slim.request","params":["'"$MAC"'",["status","-","1",""]]}' "$LMS_URL")
  LINE1=$(printf '%s' "$POLL1" | python3 -c "$PARSE_STATUS")
  read -r MODE1 TIME1 <<< "$LINE1"
  sleep 3
  POLL2=$(curl -s -m 3 -X POST -H 'Content-Type: application/json' -d \
    '{"id":1,"method":"slim.request","params":["'"$MAC"'",["status","-","1",""]]}' "$LMS_URL")
  LINE2=$(printf '%s' "$POLL2" | python3 -c "$PARSE_STATUS")
  read -r MODE2 TIME2 <<< "$LINE2"
  printf '  Status-Poll1: mode=%s time=%s\n  Status-Poll2: mode=%s time=%s\n' "${MODE1:-?}" "${TIME1:-0}" "${MODE2:-?}" "${TIME2:-0}"

  # Phase 82 Plan 44 (D-13, Ausfuehrung -- Deviation, dokumentiert im
  # SUMMARY): SONGOPEN NICHT aus dem frueh (direkt nach "Need to create
  # Soloist daemon") erfassten $T zaehlen -- Slim::Player::Song::open's
  # "seek=false time=0"-Zeile entsteht laut Geraetemessung erst ~0,3s NACH
  # jener fruehen Marke (Handshake+Stream-Oeffnung brauchen Zeit), und war
  # in allen 3 Laeufen dieser Runde im fruehen $T noch nicht vorhanden
  # (songopen=0 trotz sichtbar startender Wiedergabe). Frischer Tail NACH
  # den beiden Status-Polls (durch das 3s-Intervall ist genug Zeit
  # vergangen) behebt das, ohne den bestehenden Zaehl-Code fuer
  # DEF/DEF_OUTER/NR/GNT/EXP anzufassen.
  T2=$("$SUDO_BIN" -n tail -n +$((MARK+1)) "$LOG")
  SONGOPEN=$(printf '%s' "$T2" | grep -cE 'Song::open.*seek=false time=0')
  printf '  songopen=%s\n' "$SONGOPEN"

  WIRKUNG=nein
  TIME_RISING=$(python3 -c "print('1' if float('${TIME2:-0}') > float('${TIME1:-0}') else '0')" 2>/dev/null || echo 0)
  if { [ "${DEF:-0}" -gt 0 ] || [ "${DEF_OUTER:-0}" -gt 0 ]; } \
     && [ "${MODE1:-}" = "play" ] \
     && [ "$TIME_RISING" = "1" ] \
     && [ "${SONGOPEN:-0}" -gt 0 ]; then
    WIRKUNG=ja
  fi
  printf 'WIRKUNG: %s\n' "$WIRKUNG"
done
