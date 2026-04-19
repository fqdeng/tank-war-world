# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Stack

Godot 4.6.2 project. No package manager, no linter — the Godot binary is the whole toolchain. On macOS it lives at `/Applications/Godot.app/Contents/MacOS/Godot` (substitute `godot` if it's on `PATH`). Web export templates for 4.6.2 must be installed via the editor to build the browser client.

## Commands

**Run server** (headless, always native, listens on `ws://0.0.0.0:8910`):
```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless server/main_server.tscn
```
If port 8910 is held: `lsof -iTCP:8910 -sTCP:LISTEN` then `kill <pid>`.

**Run native client** (defaults to `ws://localhost:8910` in editor, `wss://tank.fqdeng.com` when exported to web):
```bash
/Applications/Godot.app/Contents/MacOS/Godot client/main_client.tscn
```

**Web build** — `./build.sh` wraps `--export-release "Web" build/web/index.html`. `./deploy.sh` builds then serves via `python3 tools/serve_web.py 8000`. **Before every web build**, run `tools/subset_font.sh` — it shrinks `NotoSansSC-Regular.otf` from ~8 MB to ~68 KB by keeping only the glyphs the UI actually renders. If you add new Chinese text to any `Label`/`RichTextLabel`, append those characters to `SUBSET_CJK_TEXT` in that script first.

**Tests** (GUT, 60 tests across 8 scripts — run before every commit):
```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests -gexit
```
Single test script: add `-gtest=res://tests/test_ballistics.gd`. Single test: add `-gunit_test_name=test_name`.

## Architecture

**Authoritative headless server + dual-transport client.** One Godot codebase produces three artifacts from `project.godot`: a headless server process, a native client, and a web (HTML5) client. The server is always the authority; clients talk to it over WebSocket using a custom binary protocol — so the same server process serves native and browser clients simultaneously.

**Four top-level source dirs, and the split matters:**
- `server/` — only runs on the server. Export preset excludes it from the web bundle (`export_presets.cfg: exclude_filter="server/*, tests/*, docs/*, addons/gut/*"`).
- `client/` — rendering, input, HUD, camera, prediction, interpolation. Never imported by `server/`.
- `shared/` — pure simulation code (tank movement, ballistics, terrain generation, part damage, collision). **Both sides import this** so client prediction stays in lockstep with the server. When you change anything in `shared/`, both sides change together — otherwise reconciliation drift re-emerges.
- `common/` — protocol (binary codec, message types, message classes). Also both-sided.

`common/constants.gd` is autoloaded as `Constants` (see `project.godot [autoload]`) — every tuning knob (tick rate, tank HP, shell speed, obstacle counts, etc.) lives there. Reference as `Constants.TICK_RATE_HZ`, not by preloading the file.

**Tick loop & networking:**
- Fixed 20 Hz sim tick (`Constants.TICK_INTERVAL = 0.05`). `server/sim/tick_loop.gd` accumulates real delta and runs `_step_tick(0.05)` as many times as needed, then broadcasts one `SNAPSHOT`.
- Physics runs faster for the client renderer — 120 Hz native, 60 Hz web — see `project.godot [physics]`.
- Wire format: `[u8 msg_type][payload]`. Type IDs in `common/protocol/message_types.gd` are **stable — never reorder, only append**. Codec is little-endian primitives in `common/protocol/codec.gd`.
- **Nested classes in `common/protocol/messages.gd` have no `class_name`** on purpose — combining `class_name` with nested classes triggers "Nonexistent function 'new'" in Godot 4.6. Always `preload` `messages.gd` at the top of the consumer.

**Client-authoritative body, server-authoritative everything else.** This is unusual and easy to break:
- The client runs `Prediction` (`client/tank/prediction.gd`) and sends its own `pos`/`yaw` in every `INPUT` message. The server **trusts** those fields for humans (`tick_loop.gd:94-96`). Only AI tanks run `TankMovement.step` on the server. This was intentional — server-side correction caused 20 Hz shake on obstacle collisions.
- Because of that trust, `client/tank/prediction.gd` must mirror the server's collision logic (`shared/world/tank_collision.gd`) exactly. If you edit one side, edit both.
- **Firing is also client-authoritative for humans**: the client picks `origin` and `velocity` (`Ballistics.compute_shell_spawn`) and the server just simulates the trajectory (`tick_loop.gd:_on_fire_received`). AI uses the server-side `_spawn_shell` path with `can_fire()` / reload checks. If you add server-side hit validation, don't retrofit it onto the fire-spawn path — the two halves aren't symmetric by design.
- Remote tanks (other players) use `Interpolation` with a ~100 ms render delay against the snapshot buffer.

**World generation is deterministic from a seed.** Server picks `boot_seed = Time.get_unix_time_from_system()`, sends it in `CONNECT_ACK`, and both sides regenerate the same terrain + obstacle placement via `shared/world/`. Destroyed obstacles are tracked by ID and re-sent in `CONNECT_ACK` so late joiners see the current world.

**AI fills the lobby.** `tick_loop.gd:_maintain_ai_population` keeps `TARGET_TOTAL_TANKS = 10` alive across both teams, balancing bots against human count each tick. `server/ai/ai_brain.gd` is the per-tank brain.

## Conventions

- 4-space indentation (see `.editorconfig`). GDScript; typed where it matters, but untyped dicts are common for input snapshots/messages.
- New Godot files get a paired `.uid`. Don't delete these by hand; Godot regenerates them.
- `.gitignore` excludes `.godot/`, `build/`, `export/`, and `*.full.otf` (the pristine backup created by `tools/subset_font.sh` — kept locally so re-subsetting stays idempotent).
- `deploy.server.sh` is a one-liner that just runs the headless server; actual production hosting assumes a TLS-terminating reverse proxy in front (browsers block `ws://` from an `https://` page).
