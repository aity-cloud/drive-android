#!/usr/bin/env bash
# Regenerate every branded raster in overlay/ from the brand master
# drive/meta/brand/logo.svg. Outputs are COMMITTED; run this only when the
# master changes, then commit the result.
#
#   scripts/gen-icons.sh [path/to/logo.svg]
#
# Needs python3; installs Pillow into a throwaway venv under build/ on first
# run. The current master is an SVG that embeds raster layers, which the
# generator composites directly (best possible resampling). If the master
# ever becomes a true vector, install rsvg-convert and the generator will
# use it instead.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOGO="${1:-$ROOT/../meta/brand/logo.svg}"

if [ ! -f "$LOGO" ]; then
    echo "gen-icons: brand master not found at $LOGO" >&2
    echo "gen-icons: pass the path to drive/meta/brand/logo.svg explicitly" >&2
    exit 1
fi

VENV="$ROOT/build/icons-venv"
if [ ! -x "$VENV/bin/python" ]; then
    mkdir -p "$ROOT/build"
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install --quiet pillow
fi

exec "$VENV/bin/python" "$ROOT/scripts/gen_icons.py" "$LOGO" "$ROOT/overlay"
