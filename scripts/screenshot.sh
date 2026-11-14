#!/bin/zsh
# Renders the Longhand window, opened on the demo library in scripts/demo-library (the owner's
# own library is never opened or remembered), to a PNG.
#
#   ./scripts/screenshot.sh out.png                         scene editor, comments in the margin
#   ./scripts/screenshot.sh out.png LONGHAND_DARK=1         dark mode (LONGHAND_LIGHT=1 for light)
#   ./scripts/screenshot.sh out.png LONGHAND_CHAPTER=1      first chapter
#   ./scripts/screenshot.sh out.png LONGHAND_BOOK=1         first book
#   ./scripts/screenshot.sh out.png LONGHAND_NOTES=1        margin on Notes
#   ./scripts/screenshot.sh out.png LONGHAND_FOCUS=1        first comment in focus
#   ./scripts/screenshot.sh out.png LONGHAND_CARDS=1 LONGHAND_CHAPTER=1   chapter as cards
#   ./scripts/screenshot.sh out.png LONGHAND_FACE=newYork   prose in New York
#   ./scripts/screenshot.sh out.png LONGHAND_PROSESIZE=3    prose three steps bigger
#
# It runs out of sight: the window is invisible and off screen, the app never takes focus, its
# settings stay in memory, and a copy of Longhand that is already open is left alone. The
# picture includes the toolbar.
set -euo pipefail
cd "$(dirname "$0")/.."
out=${1:?usage: screenshot.sh out.png [ENV=VALUE ...]}; shift

work=$(mktemp -d)
cp -R scripts/demo-library "$work/Demo Library"
# LONGHAND_LIBRARY=… among the settings pictures that library instead of the demo's copy (given
# twice, the first one won, so it is taken out of the list and passed once).
library="$work/Demo Library"
settings=()
for setting in "$@"; do
    if [[ $setting == LONGHAND_LIBRARY=* ]]; then library=${setting#LONGHAND_LIBRARY=}; else settings+=("$setting"); fi
done
env LONGHAND_LIBRARY="$library" ${settings[@]+"${settings[@]}"} \
    timeout 30 "dist/Longhand Test.app/Contents/MacOS/Longhand" --snapshot "$out" >/dev/null 2>&1 || true
rm -rf "$work"
[[ -f "$out" ]] && echo "Saved $out" || { echo "No picture was made"; exit 1; }
