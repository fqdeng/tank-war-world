# Plan 01 completion notes

Date completed: 2026-04-18

## What works (verified)
- Git repo initialized with proper .gitignore
- Project autoloads `Constants` from `common/constants.gd`
- GUT test framework runs 29 unit tests, all passing
- Binary protocol (codec + envelope + typed messages) roundtrips correctly
- Deterministic terrain generator: same seed → same heightmap; bounded to [0, 50m]
- Deterministic obstacle placer: same seed → same obstacles; positions sit on terrain; IDs unique
- Pure tank movement sim (accelerate/decelerate/turn/reverse) passes all cases
- Headless server boots on port 8910, opens WebSocket listener
- Client connects to server, completes handshake, receives CONNECT_ACK (player_id + team + world_seed + spawn_pos)
- TickLoop runs at 20 Hz broadcasting snapshots
- World generation + 1080 obstacles work on client side

## Known limitations (by design — follow-up plans)
- Hitscan combat, not ballistic (Plan 02)
- Integer HP, not 6-part damage model (Plan 02)
- No client prediction; movement visible ~50ms latency on WASD (Plan 03)
- No entity interpolation; snapshots snap directly to position (Plan 03)
- Static obstacles only; no destruction (Plan 04)
- No scope view / FPV (Plan 05)
- Minimal HUD (HP/status/id only) (Plan 06)
- Single tank type; no classes (Plan 07)
- No world reset / scoring (Plan 08)
- No audio, no repair, no command post (Plan 09)

## Known issues worth noting
- Two desktop Godot instances cannot run simultaneously on the same project (filesystem lock). True two-client testing on one machine requires Web export (multiple browser tabs) — deferred until Plan 02+ when ballistics/damage are in. Alternative for local dev: clone project dir.
- `Godot` CLI not on $PATH; use `/Applications/Godot.app/Contents/MacOS/Godot` or add an alias.
- `class_name Messages` caused "Nonexistent function 'new'" on inner-class instantiation — removed. Callers preload messages.gd instead.
- `Input` as an inner-class name collides with Godot's built-in `Input` singleton — renamed to `InputMsg`.
- PackedFloat32Array indexing inferred as Variant under strict mode — use explicit `: float` typing.

## Milestone
Tagged `plan-01-skeleton-complete`.

## Next (Plan 02 — to be written)
Replace hitscan with parabolic ballistics, replace integer HP with 6-part damage model. See spec §5.2 and §6 for target behavior.
