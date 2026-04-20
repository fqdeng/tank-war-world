# HUD and AI Improvements — 2026-04-20

Four related but independent changes: log cap, FPV/TPV reload parity, scope
center reload arc, AI local obstacle avoidance. Testing: no new automated
tests — manual verification only.

## 1. Combat log cap 50 → 15

`client/hud/basic_hud.gd`: `COMBAT_LOG_MAX_LINES: int = 50` → `15`.
Existing FIFO fade-out logic unchanged.

## 2. FPV reload/ammo styling to match TPV

FPV (`client/hud/scope_overlay.tscn`) currently has ammo label and reload bar
visibly smaller than TPV. Align them so both views read the same at a glance.

Changes in `client/hud/scope_overlay.tscn`:

- `AmmoLabel`:
  - `offset_left = -440`, `offset_right = -20`, `offset_top = 20`, `offset_bottom = 64`
  - `theme_override_font_sizes/font_size = 32`
- `ReloadBar`:
  - `offset_left = -440`, `offset_right = -20`, `offset_top = 76`, `offset_bottom = 116`

Position, width, height, and font size now match TPV's `basic_hud.tscn`.

## 3. Remaining-seconds text on reload bar (both views)

Add a centered `Label` overlaying each `ReloadBar`, showing:
- `"装填 %.1fs"` while `remaining > 0`
- `"就绪"` when `remaining <= 0`

Styling (both views): font_size 28, white font, black outline size 4,
horizontal + vertical alignment center, anchored to the reload bar so it
floats on top.

`set_reload(remaining_s, total_s)` updates both the progress bar value and the
overlay label text. This change goes into both `basic_hud.gd` and
`scope_overlay.gd` and their respective `.tscn` files (new child `Label` under
each `ReloadBar`).

## 4. Scope center reload arc

Circular reload indicator drawn around the scope crosshair, inside
`scope_overlay.gd::_draw()`.

Parameters:
- Center: `(cx, cy)` (scope center, same as crosshair)
- Radius: `36px`
- Stroke: `4px`
- Start angle: `-PI/2` (top), sweep clockwise by `frac × TAU` where
  `frac = 1.0 - clamp(remaining / total, 0, 1)`
- Background ring (full 360°): `Color(1, 1, 1, 0.2)`, stroke 4px
- Progress arc color:
  - Loading (`frac < 1.0`): `Color(1.0, 0.7, 0.2, 0.9)` (amber). Draw an arc
    of length `frac × TAU` on top of the background ring.
  - Ready flash: `Color(0.4, 1.0, 0.5, 0.9)` (green), full 360° arc, shown
    for 0.4s after `remaining` transitions from `> 0` to `<= 0`.
  - Idle (ready, flash over): only the background ring is drawn — no
    foreground arc.

Because `_draw()` cannot read external mutable state implicitly, cache the
current fraction and a `_ready_flash_until_msec` timestamp inside
`scope_overlay.gd` (set from `set_reload`), and call `queue_redraw()` when
either changes enough to matter (frac delta > 0.01, or flash transition).
To make the flash timer tick without external drive, `_process(_dt)` calls
`queue_redraw()` while `_ready_flash_until_msec > now`, then stops.

Drawn via `draw_arc(center, radius, start, end, point_count, color, width,
antialiased=true)`.

## 5. AI local obstacle avoidance

Problem: wandering AI in `server/ai/ai_brain.gd` only reacts *after* being
stuck for 1.2s. It has no forward-looking avoidance, so it charges at rocks
and trees along the straight line to its random waypoint.

Fix: add (a) clearance-aware waypoint selection and (b) per-tick whisker
avoidance, while keeping the existing stuck fallback.

### 5A. Clearance-aware waypoint selection

Rewrite `_pick_new_waypoint(world)`:
- Generate up to 6 random candidates inside the playable square (same
  margin as current).
- For each candidate, test whether the straight line `state.pos → candidate`
  is clear of **large rocks** (reuse the existing `_has_los` ray-to-circle
  routine, but treat only `LARGE_ROCK` as blocking — trees and small rocks
  are knock-throughable and should not veto a waypoint).
- Pick the first clear candidate; if none clear, fall back to the last
  candidate so we still repath.
- Cost: at most 6 × ~540 distance checks — negligible.

Signature stays the same; only the body changes.

### 5B. Per-tick proximity steering

(Obstacle-center distance test, not a swept ray cast — cheaper and sufficient
for this map density.)

Applied only when not in unstick mode (i.e., inside the `else` branch of the
unstick check in `step()`). Between computing `desired_yaw` and `yaw_err`,
compute an `avoid_turn` offset:

```
const AVOID_LOOKAHEAD = 18.0  # meters
const K_AVOID = 1.2
const URGENCY_SLOW_THRESHOLD = 0.6

fwd = Vector3(-sin(state.yaw), 0, -cos(state.yaw))
right = Vector3(-cos(state.yaw), 0, sin(state.yaw))  # +90° rotation of fwd
avoid_turn = 0.0
max_urgency = 0.0

for o in world.obstacles:
    if world.is_obstacle_destroyed(o.id): continue
    r = _obstacle_radius(o.kind)
    to_o = o.pos - state.pos; to_o.y = 0
    d = to_o.length()
    if d < 0.01: continue
    fwd_dot = (fwd.x*to_o.x + fwd.z*to_o.z) / d
    if fwd_dot < 0.2: continue
    reach = AVOID_LOOKAHEAD + r
    if d > reach: continue
    right_dot = (right.x*to_o.x + right.z*to_o.z) / d
    urgency = (1.0 - d / reach) * fwd_dot
    side = sign(right_dot)
    if abs(right_dot) < 0.1:
        # head-on — pick a stable side by player_id hash to avoid oscillation
        side = 1.0 if (_player_id & 1) == 0 else -1.0
    avoid_turn += -side * urgency
    max_urgency = max(max_urgency, urgency)

adjusted_desired_yaw = desired_yaw + avoid_turn * K_AVOID
yaw_err = wrapf(adjusted_desired_yaw - state.yaw, -PI, PI)
move_turn = clamp(yaw_err / 0.4, -1.0, 1.0)
move_forward = 1.0 if abs(yaw_err) < 1.2 else 0.0
if max_urgency > URGENCY_SLOW_THRESHOLD:
    move_forward = min(move_forward, 0.3)  # slow down when a close obstacle is in front
```

### 5C. Tuning existing stuck fallback

- `STUCK_SPEED_THRESHOLD` 2.5 → 1.5 (avoid false positives during normal
  slow turning; only trip when truly pinned)
- `UNSTICK_REVERSE_S` 0.9 → 1.2 (give reverse-and-repath more room)
- Add `_stuck_grace_timer` in `setup()`, initialized to 0.5, decremented in
  `step()`; stuck timer only starts accumulating after grace hits 0. Prevents
  first-tick false positives right after spawn.

### 5D. Non-goals

- No full A* / grid pathfinding. Local steering + clearance-checked
  waypoints should be enough for this map density.
- No change to the AI firing / aiming logic.

## Verification (manual)

1. Log cap: fire/take damage rapidly; confirm only last 15 lines remain.
2. FPV reload: enter scope while reloading; the bar/text/arc should all
   reflect reload progress consistently with TPV.
3. AI pathfinding: watch AI tanks for ~30 seconds near rock clusters; they
   should veer around instead of pressing into obstacles. Stuck fallback
   should still work if AI is boxed in.
