#!/usr/bin/env bash
# Builds the web client end-to-end:
#   1. Re-subsets NotoSansSC-Regular.otf so new UI strings render and the
#      bundle stays ~68 KB instead of the pristine ~8 MB.
#   2. Runs the Godot web export.
#   3. Pre-compresses large static artifacts for nginx's gzip_static / brotli_static.
#
# When new Chinese text is added to any client Label/RichTextLabel, append
# the new characters to SUBSET_CJK_TEXT below before rebuilding.
#
# pyftsubset (fonttools) is required: `uv tool install fonttools --with brotli`.
set -euo pipefail
cd "$(dirname "$0")"

# --- 1. Font subsetting ---------------------------------------------------
FONT_DIR="client/assets/fonts"
SRC_FONT="$FONT_DIR/NotoSansSC-Regular.otf"
ORIG_FONT="$FONT_DIR/NotoSansSC-Regular.full.otf"
OUT_FONT="$FONT_DIR/NotoSansSC-Regular.otf"

# Every CJK character currently rendered by client/hud/*.gd.
# Sources (greppable): "炮管损坏", "重生", "阵亡", "击中了", "装填", "就绪".
SUBSET_CJK_TEXT="炮管损坏重生阵亡击中了装填就绪"

# Unicode ranges kept verbatim:
#   U+0020-007E  basic ASCII (labels, digits, punctuation, %, —, x, +)
#   U+00A0-00FF  Latin-1 supplement (degree sign U+00B0 for "GUN %+.1f°")
#   U+2014       em dash "—" used between Chinese words
#   U+221E       infinity "∞" used in the AP x ∞ ammo label
SUBSET_UNICODES="U+0020-007E,U+00A0-00FF,U+2014,U+221E"

# Keep a pristine copy the first time we run so re-subsetting stays idempotent.
if [[ ! -f "$ORIG_FONT" ]]; then
    echo "[subset] backing up original → $ORIG_FONT"
    cp "$SRC_FONT" "$ORIG_FONT"
fi

echo "[subset] running pyftsubset"
pyftsubset "$ORIG_FONT" \
    --output-file="$OUT_FONT" \
    --unicodes="$SUBSET_UNICODES" \
    --text="$SUBSET_CJK_TEXT" \
    --layout-features='*' \
    --glyph-names \
    --symbol-cmap \
    --legacy-cmap \
    --notdef-glyph \
    --notdef-outline \
    --recommended-glyphs \
    --name-legacy \
    --drop-tables+=DSIG \
    --name-IDs='*' \
    --name-languages='*'

orig_size=$(wc -c < "$ORIG_FONT")
new_size=$(wc -c < "$OUT_FONT")
echo "[subset] done: $(printf '%d' "$orig_size") → $(printf '%d' "$new_size") bytes"

# --- 1b. Emoji font subsetting (single glyph: 🎲) -------------------------
EMOJI_SRC="$FONT_DIR/NotoEmoji-Regular.ttf"
EMOJI_ORIG="$FONT_DIR/NotoEmoji-Regular.full.ttf"
EMOJI_OUT="$FONT_DIR/NotoEmoji-Regular.ttf"

if [[ ! -f "$EMOJI_ORIG" ]]; then
    echo "[subset-emoji] backing up original → $EMOJI_ORIG"
    cp "$EMOJI_SRC" "$EMOJI_ORIG"
fi

echo "[subset-emoji] running pyftsubset"
pyftsubset "$EMOJI_ORIG" \
    --output-file="$EMOJI_OUT" \
    --unicodes=U+1F3B2 \
    --layout-features='*' \
    --glyph-names \
    --symbol-cmap \
    --legacy-cmap \
    --notdef-glyph \
    --notdef-outline \
    --recommended-glyphs \
    --name-legacy \
    --drop-tables+=DSIG \
    --name-IDs='*' \
    --name-languages='*'

emoji_orig_size=$(wc -c < "$EMOJI_ORIG")
emoji_new_size=$(wc -c < "$EMOJI_OUT")
echo "[subset-emoji] done: $(printf '%d' "$emoji_orig_size") → $(printf '%d' "$emoji_new_size") bytes"

# --- 2. Godot web export --------------------------------------------------
/Applications/Godot.app/Contents/MacOS/Godot --headless \
    --export-release "Web" build/web/index.html

# --- 3. Pre-compress shipped artifacts ------------------------------------
# So nginx's gzip_static / brotli_static can serve them without per-request CPU.
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
