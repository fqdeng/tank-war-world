# Plan 02 completion notes

Date completed: 2026-04-18

## What works (verified)
- 56 unit tests pass (was 29 after Plan 01)
- Server + client both compile and run with zero parse/script errors
- Handshake still functional (client receives CONNECT_ACK with seed + spawn)
- Ballistic shells spawned on FIRE and broadcast via SHELL_SPAWNED
- Server shell_sim advances shells at 20 Hz with 4-substep swept collision against terrain + enemy tanks
- Part classifier maps world hit points into tank-local zones (Hull/Turret/Engine/L-Track/R-Track/Top)
- Damage application respects multipliers; death triggered by total HP ≤ 0, hull destroyed, or top destroyed
- Functional damage: both tracks dead → no move; engine dead → 25% speed, 50% accel; turret dead → can't fire
- Client visualizes shell as emissive sphere tracing parabola; puff on impact

## Known limitations (deferred)
- Client shell trajectory uses client-local start time (not server timestamp), so shell impact visual may lag server hit event by ~50 ms. Acceptable for skeleton; resolve with server-time sync later.
- Repair mechanic (spec §5.2) not yet implemented. Small add-on plan or combine into Plan 03.
- Shell-vs-obstacle collision not implemented (shells pass through trees/rocks). Will be fixed in Plan 04 (destructible environment).
- Part HP not yet sent in snapshots — clients only see total HP. Visual per-part damage indicators are a Plan 06 (HUD) concern.
- Snapshot compression/delta encoding still naive. Plan 03 target.
- Client prediction + lag compensation still missing. Plan 03 target.

## Milestone
Tagged `plan-02-ballistics-part-damage-complete`.

## Next (Plan 03 — to be written)
Client-side prediction of own tank + entity interpolation for remote tanks + server-side lag compensation for shell hit checks. Replace "snap to snapshot" with smooth interpolation.
