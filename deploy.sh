#!/usr/bin/env bash
# Builds the web client (subsets the CJK font first) and then serves it locally.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh
python3 tools/serve_web.py 8000
