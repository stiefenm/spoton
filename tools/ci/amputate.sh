#!/usr/bin/env bash
# Backend amputation (84-12, SEAM-6.3.2): removes one backend side from a tree.
#
# Warum: der Kern muss ohne eine der beiden Backend-Seiten laden und laufen.
# Stubs in den Tests verdecken eine Loeschung (gemessen: nur t/10 wird rot),
# darum entfernt dieses Skript die Dateien einer Seite WIRKLICH -- in einer
# Wegwerfkopie (git archive / mktemp -d), nie im Arbeitsbaum -- und
# tools/ci/refcheck.pl prueft danach, was uebrig ist.
#
# Aufruf:  amputate.sh <librespot|soloist> [root]
#          root: Wurzel der Wegwerfkopie (Default .); das Manifest wird aus
#          <root>/tools/ci/amputation/<side>.files gelesen.
# Ausgabe: je entfernter Pfad nichts; am Ende genau EINE Zeile
#            AMPUTATED <side> <n> paths
#          oder bei einem Manifestpfad, den es nicht gibt:
#            MISSING <pfad>
# Exit:    0 = alle Pfade entfernt | 1 = MISSING (veraltetes Manifest ist rot)
#          | 2 = Aufruffehler
#
# Reihenfolge fuer einen Lauf: refcheck.pl --collect <side> <root> (Namen
# VOR dem Loeschen sammeln) -> amputate.sh <side> <root> -> refcheck.pl <side> <root>.
set -eu

side="${1:-}"
root="${2:-.}"
case "$side" in
  librespot|soloist) ;;
  *) echo "usage: amputate.sh <librespot|soloist> [root]" >&2; exit 2 ;;
esac

manifest="$root/tools/ci/amputation/$side.files"
[ -f "$manifest" ] || { echo "MISSING $manifest"; exit 1; }

n=0
while IFS= read -r p || [ -n "$p" ]; do
  case "$p" in ''|\#*) continue ;; esac
  [ -e "$root/$p" ] || { echo "MISSING $p"; exit 1; }
  rm -rf "${root:?}/$p"
  n=$((n + 1))
done < "$manifest"

echo "AMPUTATED $side $n paths"
