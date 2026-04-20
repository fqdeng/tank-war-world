#!/usr/bin/env bash
# Runs the full web build (font subset + Godot export + gzip/brotli precompression)
# via build.sh, then serves the resulting build/web/ bundle over HTTP for local
# testing. build.sh is the single source of truth for what the bundle contains.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh
python3 tools/serve_web.py 8000
