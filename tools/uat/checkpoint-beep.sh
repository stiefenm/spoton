#!/usr/bin/env bash
# Akustischer Checkpoint-Melder.
# Schutztor: schweigt, solange lavender-pa spielt -- ein Ton waehrend eines
# Hoerszenarios wuerde genau den Befund verfaelschen, den er ankuendigen soll.
# Umgebung: PA_MAC = MAC von lavender-pa (Pflicht, z.B. 02:00:00:5a:11:03; kein Default).
export XDG_RUNTIME_DIR=/run/user/$(id -u)
MAC="${PA_MAC:-}"
# D-10: kein eingebauter Default -- ohne PA_MAC weder curl noch Ton (Exit 2)
if [ -z "$MAC" ]; then
  echo "BEEP=ERROR PA_MAC not set"
  exit 2
fi
VOL="${BEEP_VOL:-0.5}"
# Offline-Test-Hook (Quick 260910-w9q): macht die Quittierungslogik ohne eine echte LMS pruefbar.
LMS_URL="${LMS_URL:-http://127.0.0.1:9000/jsonrpc.js}"

MODE=$(curl -s -m 3 -X POST -H "Content-Type: application/json" \
  -d "{\"id\":1,\"method\":\"slim.request\",\"params\":[\"$MAC\",[\"status\",\"-\",\"1\",\"\"]]}" \
  "$LMS_URL" 2>/dev/null \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['result'].get('mode','?'))" 2>/dev/null)

if [ "$MODE" = "play" ]; then
  echo "STUMM: lavender-pa mode=play -- kein Ton waehrend laufender Wiedergabe."
  exit 0
fi

# aufsteigende Terz, zweimal -- klar von Systemklaengen unterscheidbar
for i in 1 2; do
  play -q -n synth 0.13 sine 784 vol "$VOL" 2>/dev/null
  play -q -n synth 0.13 sine 1047 vol "$VOL" 2>/dev/null
  [ $i -eq 1 ] && sleep 0.18
done
echo "Signal ausgegeben (mode=${MODE:-unbekannt}, vol=$VOL)"
