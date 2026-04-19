# Tank War World

Multiplayer tank shooter built with Godot 4.6. The server is an authoritative simulation running as a headless Godot process; the client ships either as a native Godot app or as an HTML5 web build. Client ↔ server is a custom binary protocol over WebSocket, so the same server accepts native and browser clients simultaneously.

[中文说明 → README-cn.md](README-cn.md)

---

## Requirements

- **Godot 4.6.2** — `/Applications/Godot.app` on macOS, or the `godot` binary in `PATH`.
- **Web export templates** for 4.6.2 — only needed to build the web client. Install via *Editor → Manage Export Templates → Download and Install* (≈ 700 MB). Templates land in `~/Library/Application Support/Godot/export_templates/4.6.2.stable/`.
- **Python 3** — only to serve the exported web files locally.

The examples below use the full macOS path to the Godot binary; substitute `godot` if you have it on `PATH`.

---

## 1. Start the game server

The server is always native. It listens on `ws://0.0.0.0:8910`.

```bash
cd /path/to/tank-war-world
/Applications/Godot.app/Contents/MacOS/Godot --headless server/main_server.tscn
```

Look for `[WSServer] Listening on port 8910`. The server auto-fills the lobby with bots (default 10) — see `server/ai/ai_brain.gd`.

**Port 8910 already in use?**

```bash
lsof -iTCP:8910 -sTCP:LISTEN     # find the PID
kill <pid>                        # stop the stale process
```

---

## 2. Native client (fastest dev loop)

With the server running, open a second terminal:

```bash
cd /path/to/tank-war-world
/Applications/Godot.app/Contents/MacOS/Godot client/main_client.tscn
```

Defaults to `ws://localhost:8910`. Override with `--` export arg if you want another host.

---

## 3. Web client

### 3a. Export the bundle (one-time, or after every client code change)

```bash
cd /path/to/tank-war-world
/Applications/Godot.app/Contents/MacOS/Godot --headless \
  --export-release "Web" build/web/index.html
```

Produces `build/web/{index.html, index.pck, index.wasm, index.js, index.audio.worklet.js}`. The preset (`export_presets.cfg`) excludes `server/`, `tests/`, `docs/`, and the GUT plugin from the bundle.

### 3b. Serve the bundle

Browsers can't load `.wasm` from `file://`. Start a local HTTP server:

```bash
python3 -m http.server --directory build/web 8000
```

### 3c. Open the game

```
http://localhost:8000/
```

The client auto-derives the WebSocket URL from the page's hostname (`client/main_client.gd:_derive_web_server_url`), so the same bundle works on any host without rebuilding.

**Controls**

| Input | Action |
|---|---|
| W / A / S / D | Drive (always chassis-relative) |
| Mouse | Aim turret |
| Left click | Fire |
| Right click (hold) | Scope |
| Mouse wheel | Scope zoom (2× / 4× / 8×) |
| ESC | Release pointer lock |

---

## Production deploy (brief)

- Run the Godot server on a cloud host.
- Put a TLS-terminating reverse proxy in front of it (Caddy / nginx / Cloudflare tunnel) so clients can connect via `wss://`. Browsers block plain `ws://` from an `https://` page.
- Host `build/web/` on any static host (GitHub Pages, Cloudflare Pages, S3+CloudFront). Serve it from the same hostname as the `wss://` endpoint if possible, so the auto-derived URL just works.

---

## Tests

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless \
  -s addons/gut/gut_cmdln.gd -gdir=res://tests -gexit
```

60 tests across 8 scripts. Run before every commit.
