#!/usr/bin/env bash
# Builds the web client. Always re-subsets the CJK font first so new UI
# strings are included and the bundle stays ~68 KB instead of 8 MB.
set -euo pipefail
cd "$(dirname "$0")"

./tools/subset_font.sh

/Applications/Godot.app/Contents/MacOS/Godot --headless \
    --export-release "Web" build/web/index.html
