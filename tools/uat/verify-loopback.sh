#!/bin/bash
# tools/uat/verify-loopback.sh
#
# Referenzton-RMS-Gate fuer den snd-aloop-Messstand (D-02, Phase 81).
#
# Warum tools/uat/ statt flach tools/spoton-uat-verify-loopback.sh:
# tools/spoton-*.sh ist die bestehende Konvention fuer Nutzer-Diagnosen
# (spoton-account-check.sh, spoton-pkce-audiokey-test.sh). Messstand-Skripte
# fuer den bit-exakten snd-aloop-Aufbau sind eine eigene Familie, die
# Phase 84 (UAT) erweitert -- deshalb ein eigenes Unterverzeichnis statt
# eines weiteren flachen Namens.
#
# Prueft zwei Dinge am snd-aloop-Loopback-Messstand:
#   1) Ein 1kHz-Referenzton (2s, vol 0.5) kommt mit RMS 0.353553 (0.5/sqrt(2))
#      an -- Beweis, dass die Kette bit-exakt ist (kein Resampling/Mixing).
#   2) Das Stillefenster NACH dem Ton hat RMS 0.000000 -- Beweis, dass eine
#      Luecke im Signal als digitale Stille sichtbar ist (nicht verschmiert).
#
# Usage:
#   bash tools/uat/verify-loopback.sh
#
# Konfiguration ueber Env-Variablen:
#   LOOPBACK_CARD  Default "Loopback"
#   EXPECT_RMS     Default "0.353553"
#   TOLERANCE      Default "0.001"
#   WORK           Default "/tmp/spoton81"
#
# Voraussetzung: snd-aloop geladen, WirePlumber haelt die Karte NICHT
# (siehe .planning/phases/81-soloist-steuerungs-spikes/runners/rig-up.sh).

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'; BOLD='\033[1m'

LOOPBACK_CARD="${LOOPBACK_CARD:-Loopback}"
# Subdevice-Index (D-02-Nachtrag, Phase 81 Task 1): snd-aloop bietet 8
# Subdevice-Paare je Loopback-Karte. Subdevice 0 wird von der
# lavender-UAT-squeezelite-Instanz dauerhaft offen gehalten (kein -C-Timeout
# in runners/rig-up.sh), deshalb misst dieses Gate auf einem anderen,
# freien Subdevice -- Default 1. Ueberschreibbar mit LOOPBACK_SUBDEV.
LOOPBACK_SUBDEV="${LOOPBACK_SUBDEV:-1}"
EXPECT_RMS="${EXPECT_RMS:-0.353553}"
TOLERANCE="${TOLERANCE:-0.001}"
WORK="${WORK:-/tmp/spoton81}"

mkdir -p "$WORK"

fail() {
    echo -e "${RED}FAIL:${NC} $1"
    exit 1
}

# --- 1. Vorab-Gates ---

aplay -l 2>/dev/null | grep -q "$LOOPBACK_CARD" || fail "snd-aloop nicht geladen (aplay -l zeigt keine Karte '$LOOPBACK_CARD')"

if wpctl status 2>/dev/null | grep -iE "Schleifen|Loopback" >/dev/null; then
    fail "PipeWire haelt die Loopback-Karte (wpctl status zeigt eine Loopback-Zeile) -- WirePlumber-Regel fehlt oder ist nicht aktiv"
fi

LOOPBACK_CTL=$(aplay -l 2>/dev/null | grep "$LOOPBACK_CARD" | head -1 | sed -n 's/^Karte \([0-9]*\).*/\1/p')
if [ -z "$LOOPBACK_CTL" ]; then
    LOOPBACK_CTL=$(aplay -l 2>/dev/null | grep "$LOOPBACK_CARD" | head -1 | sed -n 's/^card \([0-9]*\).*/\1/p')
fi
if [ -n "$LOOPBACK_CTL" ]; then
    if sudo fuser -v "/dev/snd/controlC${LOOPBACK_CTL}" 2>&1 | grep -q wireplumber; then
        fail "WirePlumber haelt controlC${LOOPBACK_CTL} (Loopback-Karte)"
    fi
fi

# --- 2. Referenzton messen ---

arecord -D "hw:${LOOPBACK_CARD},1,${LOOPBACK_SUBDEV}" -f S32_LE -r 44100 -c 2 -d 4 "$WORK/ref.wav" 2>"$WORK/ref-rec.err" &
REC_PID=$!
sleep 0.3
sox -n -t raw -e signed -b 32 -r 44100 -c 2 - synth 2 sine 1000 vol 0.5 \
  | aplay -D "hw:${LOOPBACK_CARD},0,${LOOPBACK_SUBDEV}" -f S32_LE -r 44100 -c 2 -t raw 2>>"$WORK/ref-rec.err"
wait "$REC_PID" || true

if grep -qi "overrun\|underrun\|xrun" "$WORK/ref-rec.err" 2>/dev/null; then
    fail "xrun im Referenzlauf ($WORK/ref-rec.err)"
fi

RMS_LINE=$(sox "$WORK/ref.wav" -n trim 1 1 stat 2>&1 | grep "RMS     amplitude")
RMS_VALUE=$(echo "$RMS_LINE" | awk '{print $3}')

if [ -z "$RMS_VALUE" ]; then
    fail "konnte RMS-Wert nicht aus sox-Ausgabe parsen"
fi

RMS_OK=$(awk -v v="$RMS_VALUE" -v e="$EXPECT_RMS" -v t="$TOLERANCE" 'BEGIN { d = v - e; if (d < 0) d = -d; print (d <= t) ? "1" : "0" }')
if [ "$RMS_OK" != "1" ]; then
    fail "RMS=$RMS_VALUE weicht von EXPECT_RMS=$EXPECT_RMS (Toleranz $TOLERANCE) ab"
fi

SILENCE_LINE=$(sox "$WORK/ref.wav" -n trim 3 0.5 stat 2>&1 | grep "RMS     amplitude")
SILENCE_VALUE=$(echo "$SILENCE_LINE" | awk '{print $3}')

if [ -z "$SILENCE_VALUE" ]; then
    fail "konnte Stille-RMS-Wert nicht aus sox-Ausgabe parsen"
fi

SILENCE_OK=$(awk -v v="$SILENCE_VALUE" 'BEGIN { print (v == 0 || v == 0.000000) ? "1" : "0" }')
if [ "$SILENCE_OK" != "1" ]; then
    fail "Stillefenster hat RMS=$SILENCE_VALUE, erwartet 0.000000"
fi

echo "OK: RMS=$RMS_VALUE silence=$SILENCE_VALUE"
exit 0
