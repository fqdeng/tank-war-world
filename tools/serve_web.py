#!/usr/bin/env python3
"""Serve build/web with COOP/COEP headers for threaded Godot Web builds.

Godot's threaded HTML5 export uses pthreads / SharedArrayBuffer, which the
browser only exposes when the page is cross-origin-isolated. Plain
`python3 -m http.server` does not send the required headers, so use this
instead:

    python3 tools/serve_web.py            # default port 8000
    python3 tools/serve_web.py 8080       # custom port
"""
from __future__ import annotations

import sys
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer


class COEPRequestHandler(SimpleHTTPRequestHandler):
    def end_headers(self) -> None:
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


def main() -> None:
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
    handler = partial(COEPRequestHandler, directory="build/web")
    with ThreadingHTTPServer(("127.0.0.1", port), handler) as httpd:
        print(f"serving build/web on http://127.0.0.1:{port} (COOP/COEP on)")
        httpd.serve_forever()


if __name__ == "__main__":
    main()
