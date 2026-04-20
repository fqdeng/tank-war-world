#!/usr/bin/env bash
# Subsets NotoSansSC-Regular.otf down to the glyphs actually used by the
# client UI. Saves ~8 MB off the web build. Re-run whenever new Chinese
# text is added to a Label/RichTextLabel in the client.
#
# Requires `pyftsubset` (fonttools). Install with:
#   uv tool install fonttools --with brotli
#
# The CJK character list below is the authoritative source — add any new
# characters that appear in client-side UI strings to SUBSET_CJK_TEXT.
set -euo pipefail

cd "$(dirname "$0")/.."

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
