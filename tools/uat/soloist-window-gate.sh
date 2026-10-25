#!/usr/bin/env bash
# tools/uat/soloist-window-gate.sh -- Maschinen-Tor fuer T-3 (82-32)
#
# ZWEI unabhaengige Funktionen in einem Skript:
#
# (A) Verdikt-Klassifikation. Liest server.log DIREKT per sudo grep, im
#     REALEN Zeilenformat
#     "[YY-MM-DD HH:MM:SS.ffff] Package::Sub (Zeile) Nachricht" (selbst
#     gegen /var/log/squeezeboxserver/server.log gegengelesen, 2026-09-12).
#     Niemals ein "command"-praefixiertes grep unter sudo aufrufen --
#     "command" ist ein Shell-Builtin und existiert im sudo-Subprozess
#     nicht; ein blankes "sudo grep" ruft ohnehin das echte /usr/bin/grep
#     auf, nicht die interaktive ugrep-Huelle dieser Sitzung.
#     extract-run.pl (--jsonl) liefert NUR den dokumentarischen Belegblock
#     auf stderr -- NICHT die Verdikt-Quelle, siehe extract-run.pl @SRV_CATS
#     (kein Muster fuer "Control: Treffer seek").
#
#     Sieben Ausgaenge, erster Treffer gewinnt:
#       1. "Control: Treffer seek wantMs=N haveMs=undef" vorhanden im Fenster
#          -> folgt im Fenster (NACH dieser Zeile) ein
#          "Control: dispatch play armed=0|1 uri=-"? Ja: GETROFFEN_PAUSED.
#          Nein: GETROFFEN_PLAYING.
#       2. sonst "Control: Treffer seek wantMs=N haveMs=<Zahl>" -> VERFEHLT_DRIFT
#       3. sonst "Control: dispatch play armed=0|1 uri=-" -> VERFEHLT_POSITION_BEKANNT
#       4. sonst "Control: dispatch play armed=0|1 uri=spotify:..." -> VERFEHLT_MISMATCH
#       5. sonst irgendeine ANDERE Soloist-Control:-Zeile -> VERFEHLT_ANDERER_GRUND (zitiert)
#       6. sonst GAR KEINE Soloist-Control:-Zeile -> INSTRUMENT_NICHT_SCHARF
#
#     "Soloist-Control:"-Zeilen sind Zeilen, die (nach der schliessenden
#     Klammer "] " des Zeitstempel-Praefixes) mit dem Paketpraefix
#     "Plugins::SpotOn::Soloist::Control::" beginnen -- ein Positivmatch,
#     kein Ausschluss mehr (WR-01-Korrektur, 82-33: die vormalige
#     Negativliste, ein blankes `grep "Control:" | grep -v
#     "Slim::Control::Request"`, traf faelschlich JEDES andere
#     `Slim::Control::*`-Geschwisterpaket, z. B.
#     `Slim::Control::Commands::playlistJumpCommand`, dessen Paketname
#     ebenfalls die Teilzeichenkette "Control:" enthaelt). Ist eine MAC
#     uebergeben (--mac, Pflicht im Live-Modus), muss die Zeile zusaetzlich
#     mit "(<mac>)" enden (CR-01-Korrektur, 82-33: Cross-Player-Filter --
#     eine Zeile mit einer ANDEREN MAC am Ende zaehlt nie fuer die
#     angefragte MAC).
#
#     Zwei Aufrufmodi, DIESELBE Klassifikationsfunktion:
#       Live: --mac <mac> --t0 HH:MM:SS --t1 HH:MM:SS --date YY-MM-DD
#             [--server-log <pfad>] [--jsonl <datei> --recorder-seconds <n>]
#       Test: --from-file <textdatei>  (GESAMTER Dateiinhalt = Fenster,
#             keine Zeitfilterung)
#
#     Exit 0 bei GETROFFEN_*, Exit 1 sonst. Letzte STDOUT-Zeile ist immer
#     "VERDIKT: <WERT>" (der dokumentarische Belegblock geht nach stderr).
#
# (B) Ausloeser-Klassifikator, --check-trigger [--trigger-mode <track-match|
#     connect>] --target-uri <uri>. Liest EINE JSONL-Zeile von stdin.
#
#     Modus track-match (Default, Rueckwaertskompatibilitaet 82-32/82-33):
#     doppelter JSON::PP-Decode (Aussenhuelle {ts,epoch,dir,frame}, dann --
#     nur wenn dir=rx und frame mit { beginnt -- frame selbst nochmal
#     decodiert). track_changed/playback_state mit passender item.uri ->
#     QUALIFIES (exit 0). position_sync -> immer DISQUALIFIES (exit 2),
#     unabhaengig von --target-uri (position_sync traegt keine uri, ist
#     aber IMMER das "Fenster ist zu"-Signal). auth_state und alles
#     andere -> NEUTRAL (exit 1). auth_state qualifiziert AUSDRUECKLICH
#     NICHT (jede neue WS-Verbindung, auch die des Recorders selbst,
#     bekommt sofort eines).
#
#     Modus connect (82-35, Luecke 1 Teil A aus 82-VERIFICATION.md): ein
#     reiner Verbindungsaufbau-Marker OHNE Payload-Auswertung. Nur die
#     AEUSSERE Huelle wird decodiert -- dir=meta UND frame=HANDSHAKE-OK ->
#     QUALIFIES (exit 0), --target-uri wird ignoriert (falls mitgegeben).
#     Jede andere Zeile (inkl. jedes dir=rx-Frames, auch bei passender
#     URI) -> NEUTRAL (exit 1). HANDSHAKE-OK wird von
#     tools/soloist-ws-record.pl im connect-Callback geschrieben, BEVOR
#     die erste vom Daemon gepushte Nachricht (auth_state) ueberhaupt
#     gelesen wird -- strukturell frueher als jedes track-match-Kriterium,
#     das mindestens ein rx-Frame voraussetzt. Ein unbekannter
#     --trigger-mode-Wert bricht mit Exit 2 ab.
#
# Siehe .planning/phases/82-soloist-control-browse/82-32-PLAN.md Task 1
# und .planning/phases/82-soloist-control-browse/82-35-PLAN.md Task 2.

set -u

SERVER_LOG_DEFAULT="/var/log/squeezeboxserver/server.log"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'USAGE'
tools/uat/soloist-window-gate.sh -- Verdikt-Klassifikation + Ausloeser-Klassifikator (82-32)

Verdikt (Live):
  soloist-window-gate.sh --mac <mac> --t0 HH:MM:SS --t1 HH:MM:SS --date YY-MM-DD \
      [--server-log <pfad>] [--jsonl <datei> --recorder-seconds <n>]

Verdikt (Test):
  soloist-window-gate.sh --from-file <textdatei>

Ausloeser (track-match, Default):
  soloist-window-gate.sh --check-trigger --target-uri <uri>   (liest 1 JSONL-Zeile von stdin)

Ausloeser (connect, 82-35): payload-freier Verbindungsaufbau-Marker.
  QUALIFIES auf die allererste dir=meta/frame=HANDSHAKE-OK-Zeile des
  Recorders, ohne jede Payload-Auswertung; --target-uri wird ignoriert.
  Strukturell frueher als track-match (adressiert den in
  82-VERIFICATION.md benannten Race gegen LMS' eigenen WS-Reconnect-
  Handshake, der track-match's Qualifikationskriterium bereits selbst
  ausloest, bevor eine externe Reanforderung eintrifft):
  soloist-window-gate.sh --check-trigger --trigger-mode connect

Exit-Codes Verdikt: 0 = GETROFFEN_* , 1 = alles andere.
Exit-Codes Ausloeser: 0 = QUALIFIES, 1 = NEUTRAL, 2 = DISQUALIFIES (track-match) / FEHLER (unbekannter --trigger-mode).
USAGE
}

# ---------------------------------------------------------------------------
# classify_window -- liest das Fenster (bereits vorgefiltert bei Live-Modus,
# unveraendert bei --from-file) von stdin, druckt genau EINE Zeile
# "VERDIKT: <WERT>" (letzte STDOUT-Zeile), gibt per Exit-Code GETROFFEN_*
# (0) von allem anderen (1) zurueck.
# ---------------------------------------------------------------------------
classify_window() {
    local mac="${1:-}"
    local tmp
    tmp=$(mktemp)
    cat > "$tmp"

    # MAC-Anker-Suffix (CR-01, 82-33): leer, wenn keine MAC uebergeben wurde
    # (Rueckwaertskompatibilitaet fuer --from-file-Aufrufer ohne --mac).
    # MAC-Zeichen (Hex-Ziffern + Doppelpunkte) sind ERE-neutral, keine
    # Escaping-Behandlung noetig.
    local mac_suffix=""
    if [ -n "$mac" ]; then
        mac_suffix=".*\\($mac\\)\$"
    fi

    local treffer_undef_line
    treffer_undef_line=$(grep -nE "Control: Treffer seek wantMs=[0-9]+ haveMs=undef${mac_suffix}" "$tmp" | head -1 | cut -d: -f1)

    local treffer_drift_line
    treffer_drift_line=$(grep -nE "Control: Treffer seek wantMs=[0-9]+ haveMs=[0-9.]+${mac_suffix}" "$tmp" | head -1 | cut -d: -f1)

    local dispatch_play_dash_lines
    dispatch_play_dash_lines=$(grep -nE "Control: dispatch play armed=[01].*uri=-${mac_suffix}" "$tmp" | cut -d: -f1)

    local dispatch_play_mismatch_line
    dispatch_play_mismatch_line=$(grep -nE "Control: dispatch play armed=[01].*uri=spotify:${mac_suffix}" "$tmp" | head -1 | cut -d: -f1)

    # "Soloist-Control:"-Zeile (WR-01, 82-33): Positivmatch auf das
    # Paketpraefix zwischen "] " und dem naechsten Leerzeichen, statt
    # Ausschluss eines einzelnen Geschwisterpakets -- s. Kopfkommentar.
    # Optional zusaetzlich MAC-gescoped (CR-01, an alle vier Muster UND
    # diesen Fallback angehaengt).
    #
    # WR-01 (82-37): die vier Hauptmuster oben verwenden weiterhin den
    # End-verankerten $mac_suffix unveraendert (dort steht die MAC
    # nachweislich als letztes Klammer-Token). Der Fallback hier braucht
    # eine lockerere Pruefung: _recordErrorOnce- und onEvent-Nachrichten
    # (Control.pm:794, Control.pm:1764) betten die MAC an ANDERER Stelle
    # ein, nicht als letztes Klammer-Token -- ein End-Anker wuerde diese
    # echten Fundstellen stumm als INSTRUMENT_NICHT_SCHARF verwerfen. Die
    # Pruefung ist daher: MAC-Zeichenkette IRGENDWO nach dem Paketpraefix,
    # kein Zeilenende-Anker, keine Klammerpflicht. Das Paketpraefix selbst
    # bleibt Pflichtbestandteil -- das ist CR-01s eigentlicher
    # Cross-Player-Filter, nicht die MAC-Position.
    #
    # R9-WR-04 (82-41 Task 3, Korrektur einer bisher irrefuehrenden
    # Aussage): "MAC-Zeichenkette IRGENDWO nach dem Paketpraefix" deckt
    # NICHT jede Plugins::SpotOn::Soloist::Control::-Zeile ab. Die
    # `SpotOn G3-INSTR:`/`SpotOn G4-INSTR:`-Debugzeilen (Control.pm, ueber
    # denselben Paketpraefix ausgegeben) tragen in ihrem Nachrichtentext
    # KEINE MAC -- unter gesetztem --mac bleiben sie deshalb strukturell
    # unsichtbar fuer diesen Fallback und fuehren zu INSTRUMENT_NICHT_SCHARF,
    # nicht zu VERFEHLT_ANDERER_GRUND. Das ist ein bekanntes, akzeptiertes
    # Restrisiko (82-VERIFICATION.md: betrifft keinen der 16
    # 82-39-Verdikte, alle Live-Auswertungen liefen ohne --mac-gescopte
    # G3/G4-INSTR-Abhaengigkeit), KEIN offener Bug dieses oder eines
    # frueheren Plans -- ohne --mac (siehe --from-file-Testmodus oben)
    # bleiben G3/G4-INSTR-Zeilen weiterhin ueber diesen Fallback auffindbar.
    local any_control_pattern="\\] Plugins::SpotOn::Soloist::Control::"
    if [ -n "$mac" ]; then
        any_control_pattern="${any_control_pattern}.*${mac}"
    fi
    local any_control_line
    any_control_line=$(grep -E "$any_control_pattern" "$tmp" | head -1)

    if [ -n "$treffer_undef_line" ]; then
        local followed=0
        local ln
        for ln in $dispatch_play_dash_lines; do
            if [ "$ln" -gt "$treffer_undef_line" ]; then
                followed=1
                break
            fi
        done
        rm -f "$tmp"
        if [ "$followed" -eq 1 ]; then
            echo "VERDIKT: GETROFFEN_PAUSED"
            return 0
        else
            echo "VERDIKT: GETROFFEN_PLAYING"
            return 0
        fi
    fi

    if [ -n "$treffer_drift_line" ]; then
        rm -f "$tmp"
        echo "VERDIKT: VERFEHLT_DRIFT"
        return 1
    fi

    if [ -n "$dispatch_play_dash_lines" ]; then
        rm -f "$tmp"
        echo "VERDIKT: VERFEHLT_POSITION_BEKANNT"
        return 1
    fi

    if [ -n "$dispatch_play_mismatch_line" ]; then
        rm -f "$tmp"
        echo "VERDIKT: VERFEHLT_MISMATCH"
        return 1
    fi

    if [ -n "$any_control_line" ]; then
        rm -f "$tmp"
        echo "VERDIKT: VERFEHLT_ANDERER_GRUND ($any_control_line)"
        return 1
    fi

    rm -f "$tmp"
    echo "VERDIKT: INSTRUMENT_NICHT_SCHARF"
    return 1
}

# ---------------------------------------------------------------------------
# --check-trigger -- doppelter JSON::PP-Decode, siehe Kopfkommentar (B).
# Eingebettet als Perl-Einzeiler (single-quoted Bash-Variable -- KEINE
# Shell-Interpolation von $-Zeichen, die sind alle Perl-eigen).
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016
PERL_CHECK_TRIGGER='
use strict;
use warnings;
use JSON::PP qw(decode_json);

my $target = shift @ARGV;
my $mode   = shift @ARGV || "track-match";
my $line = <STDIN>;
if (!defined $line) { print "NEUTRAL\n"; exit 1; }
chomp $line;

my $envelope = eval { decode_json($line) };
if (!$envelope) { print "NEUTRAL\n"; exit 1; }

# Modus connect (82-35): reiner Verbindungsaufbau-Marker, KEINE
# Payload-Auswertung -- $target (--target-uri) wird hier bewusst nicht
# gelesen. Laeuft VOR der track-match-Logik unten und kehrt in jedem
# Fall zurueck (fall-through in die track-match-Logik waere falsch:
# jedes rx-Frame muss im connect-Modus NEUTRAL bleiben, nie QUALIFIES).
if ($mode eq "connect") {
    if ((($envelope->{dir} // q()) eq "meta") && (($envelope->{frame} // q()) eq "HANDSHAKE-OK")) {
        print "QUALIFIES\n";
        exit 0;
    }
    print "NEUTRAL\n";
    exit 1;
}

if (($envelope->{dir} // q()) ne "rx") { print "NEUTRAL\n"; exit 1; }

my $frame_raw = $envelope->{frame};
if (!defined($frame_raw) || $frame_raw !~ /^\{/) { print "NEUTRAL\n"; exit 1; }

my $inner = eval { decode_json($frame_raw) };
if (!$inner) { print "NEUTRAL\n"; exit 1; }

my $type = $inner->{type} // q();

# position_sync disqualifiziert IMMER -- traegt keine uri, ist aber das
# "die Sitzung hat jetzt einen Positionsanker"-Signal, unabhaengig vom
# Zieltitel (PLAN-CHECK-KORREKTUR Runde 2).
if ($type eq "position_sync") { print "DISQUALIFIES\n"; exit 2; }

if (($type eq "track_changed" || $type eq "playback_state")
    && ref($inner->{item}) eq "HASH"
    && defined($inner->{item}{uri})
    && $inner->{item}{uri} eq $target)
{
    print "QUALIFIES\n";
    exit 0;
}

# auth_state und alles andere: NEUTRAL. auth_state qualifiziert
# AUSDRUECKLICH NICHT (jede neue WS-Verbindung, auch die des Recorders
# selbst, bekommt sofort eines -- HANDSHAKE-OK in soloist-ws-record.pl:75).
print "NEUTRAL\n";
exit 1;
'

# ---------------------------------------------------------------------------
# Argumente
# ---------------------------------------------------------------------------

# need() -- WR-02, 82-33: bricht SOFORT mit Exit 2 ab, wenn die aktuelle
# Option (need "$@" -- $1 ist der Optionsname) keinen zweiten Positionswert
# mehr hat. Ohne diese Vorpruefung liest "${2:-}" einen fehlenden Wert
# stillschweigend als leeren String und "shift 2" versucht, mehr Argumente
# zu verschieben als vorhanden sind -- das fuehrte zur Endlosschleife, da
# $# danach nie auf 0 sinkt. "shift 2" selbst bleibt unveraendert (es
# verschiebt korrekt, wenn ein Wert vorhanden ist).
need() {
    if [ $# -lt 2 ]; then
        echo "FEHLER: $1 benoetigt einen Wert" >&2
        exit 2
    fi
}

FROM_FILE=""
MAC=""
T0=""
T1=""
DATE=""
SERVER_LOG="$SERVER_LOG_DEFAULT"
JSONL=""
RECORDER_SECONDS=""
CHECK_TRIGGER=0
TARGET_URI=""
TRIGGER_MODE="track-match"

while [ $# -gt 0 ]; do
    case "$1" in
        --from-file) need "$@"; FROM_FILE="${2:-}"; shift 2 ;;
        --mac) need "$@"; MAC="${2:-}"; shift 2 ;;
        --t0) need "$@"; T0="${2:-}"; shift 2 ;;
        --t1) need "$@"; T1="${2:-}"; shift 2 ;;
        --date) need "$@"; DATE="${2:-}"; shift 2 ;;
        --server-log) need "$@"; SERVER_LOG="${2:-}"; shift 2 ;;
        --jsonl) need "$@"; JSONL="${2:-}"; shift 2 ;;
        --recorder-seconds) need "$@"; RECORDER_SECONDS="${2:-}"; shift 2 ;;
        --check-trigger) CHECK_TRIGGER=1; shift ;;
        --target-uri) need "$@"; TARGET_URI="${2:-}"; shift 2 ;;
        --trigger-mode) need "$@"; TRIGGER_MODE="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "FEHLER: unbekannte Option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# WR-04 (82-37): --mac wird auf das MAC-Format geprueft, BEVOR irgendein
# Aufrufmodus (Live oder --from-file) es verwendet -- ein Nicht-MAC-Wert
# (z. B. ein Spielername) wurde bislang ungeprueft in ein ERE-Muster
# interpoliert und lief unbemerkt als stiller INSTRUMENT_NICHT_SCHARF statt
# eines expliziten Fehlers durch. Bei Treffer wird $MAC auf Kleinschreibung
# normalisiert, damit `--mac AA:BB:...` identisch zu `--mac aa:bb:...`
# klassifiziert. Derselbe Fehlermeldungsstil wie need() oben und die
# Live-Modus-Pflichtpruefung unten.
if [ -n "$MAC" ]; then
    if [[ "$MAC" =~ ^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$ ]]; then
        MAC="${MAC,,}"
    else
        echo "FEHLER: --mac ist ungueltig (erwartet aa:bb:cc:dd:ee:ff): '$MAC'" >&2
        exit 2
    fi
fi

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
if [ "$CHECK_TRIGGER" -eq 1 ]; then
    if [ "$TRIGGER_MODE" != "track-match" ] && [ "$TRIGGER_MODE" != "connect" ]; then
        echo "FEHLER: unbekannter --trigger-mode: $TRIGGER_MODE" >&2
        exit 2
    fi
    if [ "$TRIGGER_MODE" != "connect" ] && [ -z "$TARGET_URI" ]; then
        echo "FEHLER: --check-trigger benoetigt --target-uri" >&2
        exit 2
    fi
    perl -e "$PERL_CHECK_TRIGGER" "$TARGET_URI" "$TRIGGER_MODE"
    exit $?
fi

if [ -n "$FROM_FILE" ]; then
    if [ ! -f "$FROM_FILE" ]; then
        echo "FEHLER: --from-file '$FROM_FILE' nicht gefunden" >&2
        exit 2
    fi
    classify_window "$MAC" < "$FROM_FILE"
    exit $?
fi

# Live-Modus
if [ -z "$MAC" ] || [ -z "$T0" ] || [ -z "$T1" ] || [ -z "$DATE" ]; then
    echo "FEHLER: Live-Modus benoetigt --mac --t0 --t1 --date (oder --from-file / --check-trigger)" >&2
    usage >&2
    exit 2
fi

WINDOW=$(mktemp)
WINDOW_ERR=$(mktemp)
trap 'rm -f "$WINDOW" "$WINDOW_ERR"' EXIT

# Verdikt-Quelle: DIREKT aus server.log, per sudo grep (NIE "sudo command
# grep" -- command ist ein Shell-Builtin, im sudo-Subprozess unerreichbar;
# "sudo grep" ruft ohnehin das echte /usr/bin/grep auf, nicht die
# interaktive ugrep-Huelle dieser Sitzung). Eigenes, simples Windowing
# anhand des REALEN "[YY-MM-DD HH:MM:SS.ffff]"-Praefixes -- NICHT
# extract-run.pl's Windowing wiederverwendet.
#
# Datum steht an Zeichenposition 2..9 (0-basiert: Index 1, Laenge 8), Zeit
# an Position 11..18 (0-basiert: Index 10, Laenge 8) -- "[26-09-12
# 08:57:19.1555] ...". Vorfilter per sudo grep -F auf das Datum (schnell,
# reduziert die Zeilenzahl drastisch), danach awk fuer den Zeitvergleich
# (String-Vergleich funktioniert lexikalisch fuer HH:MM:SS).
#
# WR-03 (82-33): stderr geht NICHT mehr nach /dev/null, sondern in
# $WINDOW_ERR -- PIPESTATUS[0] allein reicht NICHT als Diskriminator, denn
# "sudo -n" bricht bei Credential-Verweigerung mit demselben Exit 1 ab wie
# ein echtes grep-"keine Treffer" (0=Treffer, 1=keine Treffer ODER
# verweigert, >1=echter grep-Fehler). Der Diskriminator ist daher: rc>1
# ODER (rc=1 UND $WINDOW_ERR nicht leer) -- eine sudo-Verweigerung schreibt
# IMMER eine eigene Fehlermeldung auf stderr (z. B. "a password is
# required"), ein echter Leerfund erzeugt dort NIE Text.
#
# WR-03 (82-37): "-a" erzwingt Textmodus unabhaengig von eingebetteten
# NUL-Bytes im server.log -- ohne dieses Flag behandelt GNU grep eine
# Datei mit einem NUL-Byte als "binary" und meldet Treffer nur noch als
# "Binary file ... matches" (oder gar keinen Treffer im vorgefilterten
# Datenstrom), was ein echtes Treffer-Fenster stumm maskieren kann.
set -o pipefail
sudo -n grep -aF "[$DATE" "$SERVER_LOG" 2> "$WINDOW_ERR" \
    | awk -v t0="$T0" -v t1="$T1" '{ t = substr($0, 11, 8); if (t >= t0 && t <= t1) print }' \
    > "$WINDOW"
rc=${PIPESTATUS[0]}
set +o pipefail

if [ "$rc" -gt 1 ] || { [ "$rc" -eq 1 ] && [ -s "$WINDOW_ERR" ]; }; then
    echo "FEHLER: server.log nicht lesbar (rc=$rc): $(cat "$WINDOW_ERR")" >&2
    exit 2
fi

# Dokumentarischer Belegblock (extract-run.pl), NACHRANGIG -- geht nach
# stderr, ist NICHT die Verdikt-Quelle (@SRV_CATS kennt kein Muster fuer
# "Control: Treffer seek"). Best-effort: ein Fehlschlag hier darf das
# Verdikt nicht verhindern.
if [ -n "$JSONL" ]; then
    Y2="20${DATE:0:2}"
    REST="${DATE:3}"
    ERDATE="${Y2}-${REST}"
    {
        echo "--- Dokumentarischer Belegblock (extract-run.pl, NICHT Verdikt-Quelle) ---"
        if [ -n "$RECORDER_SECONDS" ]; then
            perl "$SELF_DIR/extract-run.pl" "$MAC" "$T0" "$T1" \
                --recorder "$JSONL" --recorder-seconds "$RECORDER_SECONDS" \
                --server-log "$SERVER_LOG" --date "$ERDATE" 2>&1
        else
            perl "$SELF_DIR/extract-run.pl" "$MAC" "$T0" "$T1" \
                --recorder "$JSONL" \
                --server-log "$SERVER_LOG" --date "$ERDATE" 2>&1
        fi
    } >&2 || true
fi

classify_window "$MAC" < "$WINDOW"
exit $?
