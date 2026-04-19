#!/usr/bin/env bash
# Builds the web client. Always re-subsets the CJK font first so new UI
# strings are included and the bundle stays ~68 KB instead of 8 MB.
set -euo pipefail
cd "$(dirname "$0")"

./tools/subset_font.sh

/Applications/Godot.app/Contents/MacOS/Godot --headless \
    --export-release "Web" build/web/index.html

# Pre-compress large static artifacts so nginx's gzip_static / brotli_static
# can serve them without per-request CPU. Produces .gz and .br siblings.
compress_targets=(index.wasm index.js index.pck)
cd build/web
for f in "${compress_targets[@]}"; do
    [[ -f "$f" ]] || continue
    gzip -9 -k -f "$f"
    if command -v brotli >/dev/null 2>&1; then
        brotli -q 11 -k -f "$f"
    fi
done
cd - >/dev/null

ls -lh build/web/index.wasm build/web/index.wasm.gz build/web/index.wasm.br 2>/dev/null || true
