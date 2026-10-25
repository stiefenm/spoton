#!/usr/bin/env bash
# Per-file test-count gate with a skipped-list fence.
#
# Warum: zwei reproduzierte stille Gruene (84-RESEARCH.md Abschnitt 2):
#   1. ein Test, der nach einem Verschieben per skip_all MIT Exit 0 aussteigt
#      (Wurzelauflosung eine Ebene zu flach), und
#   2. ein Lauf ueber ein Verzeichnis ohne Testdateien, der "Result: NOTESTS"
#      meldet und ebenfalls mit Exit 0 endet.
# Beide sehen fuer `prove` wie Erfolg aus. Dieses Tor vergleicht deshalb je Datei
# die Anzahl der Pruefungen und den Skip-Zustand gegen eine aufgezeichnete Basis.
#
# Aufruf:
#   test-baseline.sh record <baseline-file> [test-root]
#   test-baseline.sh check  <baseline-file> [test-root]
#                           [--allow-skip a.t,b.t] [--moved-or-split <map-file>]
#
# test-root: Standard `t`. Jede *.t darunter wird rekursiv einzeln mit
#   `prove -v <datei>` gefahren (nie ein Verzeichnislauf: genau der verschluckt
#   die NOTESTS-Falle). Die Zeilen der Basis tragen den Pfad relativ zum
#   Elternverzeichnis des Roots.
#
# Basis-Format (Tabs):
#   <pfad>\t<anzahl>\t<ok|skipped:all|skipped:N>   je Testdatei
#   TOTAL_FILES=<n>
#   TOTAL_TESTS=<summe>
#   Zeilen mit # am Anfang sind Kommentare und werden von `check` ignoriert.
#
# check vergleicht nach Dateiname (basename), damit ein spaeteres Verschieben in
# t/core/ usw. passt. FAIL bei: gesunkener Anzahl, neu uebersprungener Datei
# (ausser --allow-skip, ebenfalls nach basename), Basisdatei fehlt im Baum (ausser
# --moved-or-split: Zeilen `alt.t<TAB>neu1.t[,neu2.t]`, die Anzahlen der neuen
# Dateien muessen zusammen mindestens die alte erreichen), jeder Datei, deren
# prove-Lauf rot ist oder NOTESTS ohne Skip-Zeile meldet, und gesunkenem
# TOTAL_TESTS. Eine rote Datei wird einmal wiederholt (t/48 ist als Flake
# bekannt), die Wiederholung steht in der Zeile.
#
# Letzte Ausgabezeile: BASELINE_CHECK=PASS|FAIL (Exit 0 / 1). record weigert
# sich bei weniger als MIN_FILES Testdateien (leerer oder falscher Root).
#
# Exit: 0 = ok | 1 = Befund | 2 = Aufruffehler
set -u
export LC_ALL=C

MIN_FILES=50

usage() {
    sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2
    exit 2
}

[ $# -ge 2 ] || usage
MODE=$1; BASELINE=$2; shift 2
case "$MODE" in record|check) ;; *) usage ;; esac

ROOT=t
ALLOW=""
MAPFILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --allow-skip)      [ $# -ge 2 ] || usage; ALLOW=$2; shift 2 ;;
        --moved-or-split)  [ $# -ge 2 ] || usage; MAPFILE=$2; shift 2 ;;
        --*)               echo "unbekannte Option: $1" >&2; usage ;;
        *)                 ROOT=$1; shift ;;
    esac
done

[ -d "$ROOT" ] || { echo "test-root nicht gefunden: $ROOT" >&2; exit 2; }
ROOT_ABS=$(cd "$ROOT" && pwd)
PARENT=$(dirname "$ROOT_ABS")
RNAME=$(basename "$ROOT_ABS")
BASELINE_ABS=$(cd "$(dirname "$BASELINE")" 2>/dev/null && pwd)/$(basename "$BASELINE")
[ "$MODE" = check ] && [ ! -f "$BASELINE" ] && { echo "Basis nicht gefunden: $BASELINE" >&2; exit 2; }
if [ -n "$MAPFILE" ] && [ ! -f "$MAPFILE" ]; then echo "Map-Datei nicht gefunden: $MAPFILE" >&2; exit 2; fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# run_one <datei> -> "<anzahl>\t<status>\t<urteil>[\t<wiederholt>]"
#   status : ok | skipped:all | skipped:N   (N = Tests mit "# skip"-Direktive)
#   urteil : pass | fail | notests
# Geparst wird ausschliesslich mit awk (kein grep: der ugrep-Wrapper dieser
# Maschine liefert bei Dollar-Ankern pauschal 0 Treffer).
run_one() {
    local f=$1 out="$TMP/prove.out" rc attempt retried=0
    for attempt in 1 2; do
        (cd "$PARENT" && prove -v "$f") >"$out" 2>&1
        rc=$?
        [ $rc -eq 0 ] && break
        retried=1
    done
    local parsed
    parsed=$(awk -v rc="$rc" '
        /^Files=1, Tests=[0-9]+/ { match($0, /Tests=[0-9]+/); count = substr($0, RSTART + 6, RLENGTH - 6) }
        /^Result: /              { result = $2 }
        /^[^ ]+ \.+ skipped:/    { fileskip = 1 }
        /^(not )?ok [0-9]+/      { if (tolower($0) ~ /# skip/) skips++ }
        END {
            if (count == "") count = 0
            status = "ok"
            if (fileskip) status = "skipped:all"
            else if (skips > 0) status = "skipped:" skips
            verdict = "pass"
            if (rc != 0 || result == "FAIL")       verdict = "fail"
            else if (result == "NOTESTS" && !fileskip) verdict = "notests"
            else if (result == "")                 verdict = "fail"
            printf "%s\t%s\t%s", count, status, verdict
        }' "$out")
    if [ "$retried" -eq 1 ]; then
        parsed="$parsed	retried"
    fi
    printf '%s\n' "$parsed"
}

# skipnum <status> -> Zahl (all = sehr gross)
skipnum() {
    case "$1" in
        ok)           echo 0 ;;
        skipped:all)  echo 1000000000 ;;
        skipped:*)    echo "${1#skipped:}" ;;
        *)            echo 0 ;;
    esac
}

declare -A T_COUNT T_STATUS T_VERDICT T_PATH T_RETRY
TREE_ORDER=()
TREE_TESTS=0
DUP=0

echo "scanning $ROOT_ABS ..." >&2
while IFS= read -r rel; do
    base=$(basename "$rel")
    if [ -n "${T_PATH[$base]:-}" ]; then
        echo "DUPLICATE basename in tree: $base ($rel and ${T_PATH[$base]})" >&2
        DUP=1
        continue
    fi
    echo "  run $rel" >&2
    IFS=$'\t' read -r cnt st vd rt <<<"$(run_one "$rel")"
    T_PATH[$base]=$rel
    T_COUNT[$base]=$cnt
    T_STATUS[$base]=$st
    T_VERDICT[$base]=$vd
    T_RETRY[$base]=${rt:-}
    TREE_ORDER+=("$base")
    TREE_TESTS=$((TREE_TESTS + cnt))
done < <(cd "$PARENT" && find "$RNAME" -name '*.t' -type f | sort)

TREE_FILES=${#TREE_ORDER[@]}

if [ "$DUP" -ne 0 ]; then
    echo "BASELINE_CHECK=FAIL"
    exit 1
fi

if [ "$MODE" = record ]; then
    if [ "$TREE_FILES" -lt "$MIN_FILES" ]; then
        echo "RECORD_REFUSED: only $TREE_FILES test files under $ROOT_ABS (minimum $MIN_FILES) -- empty or wrong root" >&2
        echo "BASELINE_RECORD=REFUSED"
        exit 1
    fi
    bad=0
    for b in "${TREE_ORDER[@]}"; do
        if [ "${T_VERDICT[$b]}" != pass ]; then
            echo "RECORD_REFUSED: ${T_PATH[$b]} is ${T_VERDICT[$b]} -- a baseline from a red tree certifies nothing" >&2
            bad=1
        fi
    done
    if [ "$bad" -ne 0 ]; then
        echo "BASELINE_RECORD=REFUSED"
        exit 1
    fi
    OUT="$TMP/baseline.out"
    {
        echo "# test-baseline.sh record root=$ROOT_ABS files=$TREE_FILES at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        for b in "${TREE_ORDER[@]}"; do
            printf '%s\t%s\t%s\n' "${T_PATH[$b]}" "${T_COUNT[$b]}" "${T_STATUS[$b]}"
        done
        echo "TOTAL_FILES=$TREE_FILES"
        echo "TOTAL_TESTS=$TREE_TESTS"
    } >"$OUT"
    cp "$OUT" "$BASELINE_ABS"
    echo "recorded $TREE_FILES files, $TREE_TESTS tests -> $BASELINE"
    echo "BASELINE_RECORD=OK"
    exit 0
fi

# ------------------------------------------------------------ check
declare -A B_COUNT B_STATUS B_PATH
BASE_ORDER=()
BASE_TOTAL=""
while IFS=$'\t' read -r c1 c2 c3 _rest; do
    case "$c1" in
        ''|'#'*) continue ;;
        TOTAL_FILES=*) continue ;;
        TOTAL_TESTS=*) BASE_TOTAL=${c1#TOTAL_TESTS=}; continue ;;
    esac
    [ -n "$c2" ] && [ -n "$c3" ] || { echo "malformed baseline row: $c1" >&2; echo "BASELINE_CHECK=FAIL"; exit 1; }
    bb=$(basename "$c1")
    B_PATH[$bb]=$c1; B_COUNT[$bb]=$c2; B_STATUS[$bb]=$c3
    BASE_ORDER+=("$bb")
done <"$BASELINE"

if [ "${#BASE_ORDER[@]}" -lt "$MIN_FILES" ] || [ -z "$BASE_TOTAL" ]; then
    echo "baseline unusable: ${#BASE_ORDER[@]} rows, TOTAL_TESTS='${BASE_TOTAL}'" >&2
    echo "BASELINE_CHECK=FAIL"
    exit 1
fi

declare -A ALLOWED MAP CONSUMED
IFS=',' read -r -a _allow <<<"$ALLOW"
for a in "${_allow[@]}"; do
    [ -n "$a" ] && ALLOWED[$(basename "$a")]=1
done
if [ -n "$MAPFILE" ]; then
    while IFS=$'\t' read -r old news; do
        case "$old" in ''|'#'*) continue ;; esac
        MAP[$(basename "$old")]=$news
    done <"$MAPFILE"
fi

FAILS=0
fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }

for b in "${BASE_ORDER[@]}"; do
    bc=${B_COUNT[$b]}; bs=${B_STATUS[$b]}
    if [ -n "${T_PATH[$b]:-}" ]; then
        CONSUMED[$b]=1
        tc=${T_COUNT[$b]}; ts=${T_STATUS[$b]}
        if [ "$tc" -lt "$bc" ]; then
            fail "$b count dropped: baseline=$bc tree=$tc (${T_PATH[$b]})"
        fi
        if [ "$(skipnum "$ts")" -gt "$(skipnum "$bs")" ] && [ -z "${ALLOWED[$b]:-}" ]; then
            fail "$b newly skipped: baseline=$bs tree=$ts (${T_PATH[$b]})"
        fi
    elif [ -n "${MAP[$b]:-}" ]; then
        sum=0; sk=0; missing=""
        IFS=',' read -r -a _news <<<"${MAP[$b]}"
        allowed_any="${ALLOWED[$b]:-}"
        for n in "${_news[@]}"; do
            n=$(basename "$n")
            if [ -z "${T_PATH[$n]:-}" ]; then missing="$missing $n"; continue; fi
            CONSUMED[$n]=1
            sum=$((sum + T_COUNT[$n]))
            sk=$((sk + $(skipnum "${T_STATUS[$n]}")))
            [ -n "${ALLOWED[$n]:-}" ] && allowed_any=1
        done
        if [ -n "$missing" ]; then
            fail "$b mapped to${missing} which are missing from the tree"
        elif [ "$sum" -lt "$bc" ]; then
            fail "$b split lost tests: baseline=$bc, ${MAP[$b]} sum=$sum"
        elif [ "$sk" -gt "$(skipnum "$bs")" ] && [ -z "$allowed_any" ]; then
            fail "$b split newly skipped: baseline=$bs, skips in ${MAP[$b]}=$sk"
        fi
    else
        fail "$b missing from the tree (baseline path ${B_PATH[$b]}, no --moved-or-split mapping)"
    fi
done

for b in "${TREE_ORDER[@]}"; do
    if [ "${T_VERDICT[$b]}" != pass ]; then
        fail "$b prove run is ${T_VERDICT[$b]} (${T_PATH[$b]}) count=${T_COUNT[$b]} status=${T_STATUS[$b]}${T_RETRY[$b]:+ (retried once)}"
    elif [ -n "${T_RETRY[$b]}" ]; then
        echo "NOTE $b needed a retry to pass (${T_PATH[$b]}) -- known flake risk"
    fi
done

if [ "$TREE_TESTS" -lt "$BASE_TOTAL" ]; then
    fail "TOTAL_TESTS dropped: baseline=$BASE_TOTAL tree=$TREE_TESTS"
fi

echo "BASELINE_ROWS=${#BASE_ORDER[@]} TREE_FILES=$TREE_FILES BASELINE_TESTS=$BASE_TOTAL TREE_TESTS=$TREE_TESTS"
if [ "$FAILS" -eq 0 ]; then
    echo "BASELINE_CHECK=PASS"
    exit 0
fi
echo "OFFENDING_ROWS=$FAILS"
echo "BASELINE_CHECK=FAIL"
exit 1
