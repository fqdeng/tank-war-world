# HUD and AI Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cap combat log to 15 lines, make FPV scope reload UI match TPV HUD with reload countdown text + center reload arc, and give AI local obstacle avoidance so wandering tanks don't pin against rocks/trees.

**Architecture:** All changes are client-side UI tweaks plus one server-side AI brain rewrite. No protocol changes. No shared/ changes. Spec: `docs/superpowers/specs/2026-04-20-hud-and-ai-improvements-design.md`.

**Tech Stack:** Godot 4.6.2, GDScript. Tests via GUT — no new tests per spec (manual verification).

---

## File Structure

**Modify only — no new files:**

- `client/hud/basic_hud.gd` — reduce log cap, wire reload seconds text
- `client/hud/basic_hud.tscn` — add centered `Label` overlay on the TPV `ReloadBar`
- `client/hud/scope_overlay.gd` — reload seconds text, center reload arc drawing
- `client/hud/scope_overlay.tscn` — resize ammo/reload to match TPV, add centered `Label` on scope `ReloadBar`
- `server/ai/ai_brain.gd` — clearance-aware waypoint selection, per-tick proximity steering, stuck fallback tuning

---

## Task 1: Cap combat log to 15 lines

**Files:**
- Modify: `client/hud/basic_hud.gd:87`

- [ ] **Step 1: Lower the log cap**

Edit `client/hud/basic_hud.gd` line 87:

```gdscript
const COMBAT_LOG_MAX_LINES: int = 15  # hard cap; overflow fades out FIFO
```

- [ ] **Step 2: Run tests to verify nothing broke**

Run: `/Applications/Godot.app/Contents/MacOS/Godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests -gexit`
Expected: all 60 tests pass (log cap is not covered by tests; run just to catch unrelated regressions).

- [ ] **Step 3: Commit**

```bash
git add client/hud/basic_hud.gd
git commit -m "hud: cap combat log to 15 lines"
```

---

## Task 2: Resize FPV ammo/reload to match TPV

**Files:**
- Modify: `client/hud/scope_overlay.tscn`

- [ ] **Step 1: Widen FPV `AmmoLabel` and bump font size**

In `client/hud/scope_overlay.tscn`, find the `[node name="AmmoLabel" type="Label" parent="Reticle"]` block and replace its properties with:

```
anchor_left = 1.0
anchor_right = 1.0
offset_left = -440
offset_top = 20
offset_right = -20
offset_bottom = 64
horizontal_alignment = 2
text = "AP x --"
theme_override_font_sizes/font_size = 32
```

- [ ] **Step 2: Widen FPV `ReloadBar` to match TPV**

In the same file, replace the `[node name="ReloadBar" type="ProgressBar" parent="Reticle"]` block's properties with:

```
anchor_left = 1.0
anchor_right = 1.0
offset_left = -440
offset_top = 76
offset_right = -20
offset_bottom = 116
min_value = 0.0
max_value = 1.0
step = 0.01
show_percentage = false
```

- [ ] **Step 3: Launch native client, enter scope, visually verify**

Run: `/Applications/Godot.app/Contents/MacOS/Godot client/main_client.tscn` (server must be running — `/Applications/Godot.app/Contents/MacOS/Godot --headless server/main_server.tscn` in another terminal).
Press right-mouse to enter scope, fire once, confirm the ammo label and reload bar in the top-right of the scope view now match TPV in size/font. Close.

- [ ] **Step 4: Commit**

```bash
git add client/hud/scope_overlay.tscn
git commit -m "hud: align FPV ammo/reload sizing with TPV"
```

---

## Task 3: Add reload-seconds text to TPV

**Files:**
- Modify: `client/hud/basic_hud.tscn`
- Modify: `client/hud/basic_hud.gd`

- [ ] **Step 1: Add `ReloadText` Label under `ReloadBar` in TPV scene**

In `client/hud/basic_hud.tscn`, add this node block immediately after the `[node name="ReloadBar" type="ProgressBar" parent="."]` block (and any properties attached to it):

```
[node name="ReloadText" type="Label" parent="ReloadBar"]
anchor_right = 1.0
anchor_bottom = 1.0
horizontal_alignment = 1
vertical_alignment = 1
text = ""
theme_override_colors/font_color = Color(1, 1, 1, 1)
theme_override_colors/font_outline_color = Color(0, 0, 0, 1)
theme_override_constants/outline_size = 4
theme_override_font_sizes/font_size = 28
mouse_filter = 2
```

- [ ] **Step 2: Wire `_reload_text` in `basic_hud.gd`**

In `client/hud/basic_hud.gd`, add an `@onready` next to the existing `_reload` declaration (around line 8):

```gdscript
@onready var _reload: ProgressBar = $ReloadBar
@onready var _reload_text: Label = $ReloadBar/ReloadText
```

- [ ] **Step 3: Update `set_reload` to write the label**

Replace the body of `set_reload` in `basic_hud.gd` (currently around line 143-147) with:

```gdscript
func set_reload(remaining_s: float, total_s: float) -> void:
    if _reload == null or total_s <= 0.0:
        return
    var frac: float = 1.0 - clamp(remaining_s / total_s, 0.0, 1.0)
    _reload.value = frac
    if _reload_text:
        if remaining_s > 0.0:
            _reload_text.text = "装填 %.1fs" % remaining_s
        else:
            _reload_text.text = "就绪"
```

- [ ] **Step 4: Run the game, verify text appears on TPV reload bar**

Start server and native client (commands as in Task 2 Step 3). Fire once in TPV; the reload bar should show "装填 2.5s" counting down to "就绪".

- [ ] **Step 5: Run tests**

Run: `/Applications/Godot.app/Contents/MacOS/Godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests -gexit`
Expected: all 60 tests pass.

- [ ] **Step 6: Commit**

```bash
git add client/hud/basic_hud.tscn client/hud/basic_hud.gd
git commit -m "hud: show reload countdown text on TPV reload bar"
```

---

## Task 4: Add reload-seconds text to FPV

**Files:**
- Modify: `client/hud/scope_overlay.tscn`
- Modify: `client/hud/scope_overlay.gd`

- [ ] **Step 1: Add `ReloadText` Label under FPV `ReloadBar`**

In `client/hud/scope_overlay.tscn`, add this node block immediately after the `[node name="ReloadBar" type="ProgressBar" parent="Reticle"]` block (keep its existing properties):

```
[node name="ReloadText" type="Label" parent="Reticle/ReloadBar"]
anchor_right = 1.0
anchor_bottom = 1.0
horizontal_alignment = 1
vertical_alignment = 1
text = ""
theme_override_colors/font_color = Color(1, 1, 1, 1)
theme_override_colors/font_outline_color = Color(0, 0, 0, 1)
theme_override_constants/outline_size = 4
theme_override_font_sizes/font_size = 28
mouse_filter = 2
```

- [ ] **Step 2: Wire `_reload_text` in `scope_overlay.gd`**

In `client/hud/scope_overlay.gd`, add after the existing `_reload` `@onready` (around line 8):

```gdscript
@onready var _reload: ProgressBar = $ReloadBar
@onready var _reload_text: Label = $ReloadBar/ReloadText
```

- [ ] **Step 3: Update `set_reload` to write the label**

Replace the body of `set_reload` in `scope_overlay.gd` (currently around line 34-38) with:

```gdscript
func set_reload(remaining_s: float, total_s: float) -> void:
    if _reload == null or total_s <= 0.0:
        return
    var frac: float = 1.0 - clamp(remaining_s / total_s, 0.0, 1.0)
    _reload.value = frac
    if _reload_text:
        if remaining_s > 0.0:
            _reload_text.text = "装填 %.1fs" % remaining_s
        else:
            _reload_text.text = "就绪"
```

- [ ] **Step 4: Run the game, verify text appears on FPV reload bar**

Start server and native client. Enter scope (right mouse), fire once; the top-right FPV reload bar should show "装填 2.5s" counting down to "就绪".

- [ ] **Step 5: Commit**

```bash
git add client/hud/scope_overlay.tscn client/hud/scope_overlay.gd
git commit -m "hud: show reload countdown text on FPV reload bar"
```

---

## Task 5: Scope center reload arc

**Files:**
- Modify: `client/hud/scope_overlay.gd`

- [ ] **Step 1: Add state for arc drawing**

In `client/hud/scope_overlay.gd`, add these member variables right after the existing `var _kill_tween: Tween` declaration (around line 13):

```gdscript
var _reload_frac: float = 1.0
var _ready_flash_until_msec: int = 0
const _RELOAD_ARC_RADIUS_PX: float = 36.0
const _RELOAD_ARC_WIDTH_PX: float = 4.0
const _READY_FLASH_MS: int = 400
```

- [ ] **Step 2: Update `set_reload` to drive arc state**

Replace `set_reload` again (from Task 4) with:

```gdscript
func set_reload(remaining_s: float, total_s: float) -> void:
    if _reload == null or total_s <= 0.0:
        return
    var frac: float = 1.0 - clamp(remaining_s / total_s, 0.0, 1.0)
    _reload.value = frac
    if _reload_text:
        if remaining_s > 0.0:
            _reload_text.text = "装填 %.1fs" % remaining_s
        else:
            _reload_text.text = "就绪"
    # Arc: detect ready transition (frac crossed to 1.0 this call).
    var was_loading: bool = _reload_frac < 1.0
    var is_ready: bool = frac >= 1.0
    if was_loading and is_ready:
        _ready_flash_until_msec = Time.get_ticks_msec() + _READY_FLASH_MS
    if abs(frac - _reload_frac) > 0.01 or was_loading != is_ready:
        _reload_frac = frac
        queue_redraw()
    else:
        _reload_frac = frac
```

- [ ] **Step 3: Add `_process` to tick the flash timer**

Add this function to `scope_overlay.gd` (anywhere near the other lifecycle methods, e.g., before `_draw`):

```gdscript
func _process(_dt: float) -> void:
    if _ready_flash_until_msec > 0:
        var now: int = Time.get_ticks_msec()
        if now >= _ready_flash_until_msec:
            _ready_flash_until_msec = 0
        queue_redraw()
```

- [ ] **Step 4: Draw the arc in `_draw`**

In `client/hud/scope_overlay.gd`, append this helper call at the end of `_draw(…)` (after the existing dist_marks loop, still inside `_draw`):

```gdscript
    _draw_reload_arc(cx, cy)
```

Then add the helper function at the end of the file:

```gdscript
func _draw_reload_arc(cx: float, cy: float) -> void:
    var r: float = _RELOAD_ARC_RADIUS_PX
    var w: float = _RELOAD_ARC_WIDTH_PX
    var center := Vector2(cx, cy)
    # Background ring — always drawn.
    draw_arc(center, r, 0.0, TAU, 64, Color(1.0, 1.0, 1.0, 0.2), w, true)
    var now: int = Time.get_ticks_msec()
    var flashing: bool = now < _ready_flash_until_msec
    if flashing:
        draw_arc(center, r, 0.0, TAU, 64, Color(0.4, 1.0, 0.5, 0.9), w, true)
        return
    if _reload_frac >= 1.0:
        return  # idle — background ring only
    var start: float = -PI * 0.5
    var end: float = start + _reload_frac * TAU
    draw_arc(center, r, start, end, 64, Color(1.0, 0.7, 0.2, 0.9), w, true)
```

- [ ] **Step 5: Visual verification**

Start server + client, enter scope, fire once. Should see:
- Loading: amber arc sweeps clockwise from 12 o'clock, filling over 2.5 s.
- Completion: 0.4 s full green ring flash.
- Idle: only the faint gray background ring.

- [ ] **Step 6: Run tests**

Run: `/Applications/Godot.app/Contents/MacOS/Godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests -gexit`
Expected: all 60 tests pass.

- [ ] **Step 7: Commit**

```bash
git add client/hud/scope_overlay.gd
git commit -m "hud: add reload progress arc around scope crosshair"
```

---

## Task 6: AI clearance-aware waypoint selection

**Files:**
- Modify: `server/ai/ai_brain.gd`

- [ ] **Step 1: Add helper `_line_blocked_by_large_rock` and rewrite `_pick_new_waypoint`**

Replace the existing `_pick_new_waypoint` (currently around lines 214-220) with:

```gdscript
func _pick_new_waypoint(world) -> void:
    var margin: float = Constants.PLAYABLE_MARGIN_M + 20.0
    var size: float = float(world.terrain_size)
    var chosen: Vector3 = Vector3.ZERO
    var have_chosen: bool = false
    for i in range(6):
        var x: float = _rng.randf_range(margin, size - margin)
        var z: float = _rng.randf_range(margin, size - margin)
        var cand := Vector3(x, 0.0, z)
        chosen = cand
        have_chosen = true
        if not _line_blocked_by_large_rock(_prev_pos if _has_prev_pos else cand, cand, world):
            break
    if not have_chosen:
        # Unreachable — loop always sets chosen at least once. Guard kept for clarity.
        chosen = Vector3(margin, 0.0, margin)
    _waypoint = chosen
    _repath_timer = _rng.randf_range(6.0, 12.0)

# Straight-line blocker check: only LARGE_ROCK (kind == 1) vetoes a waypoint.
# Trees (kind 2) and small rocks (kind 0) can be pushed through by a tank and
# should not force repath churn.
func _line_blocked_by_large_rock(from: Vector3, to: Vector3, world) -> bool:
    var dx: float = to.x - from.x
    var dz: float = to.z - from.z
    var len_sq: float = dx * dx + dz * dz
    if len_sq < 0.01:
        return false
    for o in world.obstacles:
        if o.kind != 1:
            continue
        if world.is_obstacle_destroyed(o.id):
            continue
        var r: float = Constants.OBSTACLE_RADIUS_LARGE_ROCK + Constants.TANK_COLLISION_RADIUS
        var ox: float = o.pos.x - from.x
        var oz: float = o.pos.z - from.z
        var dot: float = ox * dx + oz * dz
        if dot < 0.0 or dot > len_sq:
            continue
        var t: float = dot / len_sq
        var px: float = ox - dx * t
        var pz: float = oz - dz * t
        if px * px + pz * pz < r * r:
            return true
    return false
```

- [ ] **Step 2: Run tests to confirm no regressions**

Run: `/Applications/Godot.app/Contents/MacOS/Godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests -gexit`
Expected: all 60 tests pass.

- [ ] **Step 3: Commit**

```bash
git add server/ai/ai_brain.gd
git commit -m "ai: pick waypoints with clear path past large rocks"
```

---

## Task 7: AI per-tick proximity steering

**Files:**
- Modify: `server/ai/ai_brain.gd`

- [ ] **Step 1: Add avoidance constants**

In `server/ai/ai_brain.gd`, after the `AI_ERR_MAX_SCALE` constant (around line 45), add:

```gdscript
# Local proximity steering: every tick, offset the waypoint-heading by a
# repulsion term from obstacles inside a forward cone. Keeps AI from driving
# straight into rocks/trees instead of waiting for the stuck fallback.
const AVOID_LOOKAHEAD_M: float = 18.0
const AVOID_K: float = 1.2
const AVOID_URGENCY_SLOW: float = 0.6
```

- [ ] **Step 2: Integrate avoidance into the waypoint branch of `step`**

Inside `step(state, world, dt)`, replace the `else:` block that currently computes `to_wp`, `desired_yaw`, `yaw_err`, `move_turn`, and `move_forward` (lines 77-100) with:

```gdscript
    else:
        var to_wp: Vector3 = _waypoint - state.pos
        to_wp.y = 0.0
        if to_wp.length() < 20.0 or _repath_timer <= 0.0:
            _pick_new_waypoint(world)
            to_wp = _waypoint - state.pos
            to_wp.y = 0.0
        var desired_yaw: float = atan2(-to_wp.x, -to_wp.z)
        var avoid_result: Dictionary = _compute_avoid_turn(state, world)
        var adjusted_yaw: float = desired_yaw + avoid_result.turn * AVOID_K
        var yaw_err: float = wrapf(adjusted_yaw - state.yaw, -PI, PI)
        move_turn = clamp(yaw_err / 0.4, -1.0, 1.0)
        move_forward = 1.0 if abs(yaw_err) < 1.2 else 0.0
        if avoid_result.max_urgency > AVOID_URGENCY_SLOW:
            move_forward = min(move_forward, 0.3)

        # Stuck check: commanded forward motion but barely any real displacement.
        if move_forward > 0.5 and actual_speed < STUCK_SPEED_THRESHOLD:
            _stuck_timer += dt
        else:
            _stuck_timer = 0.0
        if _stuck_timer >= STUCK_TRIGGER_S:
            _stuck_timer = 0.0
            _unstick_timer = UNSTICK_REVERSE_S
            _unstick_turn_sign = 1.0 if _rng.randf() > 0.5 else -1.0
            _pick_new_waypoint(world)
            move_forward = -1.0
            move_turn = _unstick_turn_sign
```

- [ ] **Step 3: Add the `_compute_avoid_turn` helper**

Add at the end of `server/ai/ai_brain.gd`:

```gdscript
# Returns {"turn": float, "max_urgency": float}.
# turn: signed steering offset (radians-ish, scaled by AVOID_K by caller).
# max_urgency: 0..~1, used by caller to decide whether to throttle forward speed.
func _compute_avoid_turn(state: TankState, world) -> Dictionary:
    # Forward and right in world. Tank yaw convention (see ai_brain.gd L84):
    # desired_yaw = atan2(-dx, -dz), so at yaw=0 the tank faces -Z and
    # pilot's right is +X. Derivation: right = forward × up.
    var fwd_x: float = -sin(state.yaw)
    var fwd_z: float = -cos(state.yaw)
    var right_x: float =  cos(state.yaw)
    var right_z: float = -sin(state.yaw)
    var turn: float = 0.0
    var max_urgency: float = 0.0
    var stable_side: float = 1.0 if (_player_id & 1) == 0 else -1.0
    for o in world.obstacles:
        if world.is_obstacle_destroyed(o.id):
            continue
        var r: float = _obstacle_radius(o.kind)
        var dx: float = o.pos.x - state.pos.x
        var dz: float = o.pos.z - state.pos.z
        var d_sq: float = dx * dx + dz * dz
        if d_sq < 0.0001:
            continue
        var d: float = sqrt(d_sq)
        var fwd_dot: float = (fwd_x * dx + fwd_z * dz) / d
        if fwd_dot < 0.2:
            continue
        var reach: float = AVOID_LOOKAHEAD_M + r
        if d > reach:
            continue
        var right_dot: float = (right_x * dx + right_z * dz) / d
        var urgency: float = (1.0 - d / reach) * fwd_dot
        var side: float = sign(right_dot)
        if abs(right_dot) < 0.1:
            side = stable_side
        # Obstacle on right (side > 0) → turn LEFT (positive yaw delta, since
        # +yaw rotates forward toward -X which is the tank's left half).
        turn += side * urgency
        if urgency > max_urgency:
            max_urgency = urgency
    return {"turn": turn, "max_urgency": max_urgency}
```

- [ ] **Step 4: Run tests**

Run: `/Applications/Godot.app/Contents/MacOS/Godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests -gexit`
Expected: all 60 tests pass.

- [ ] **Step 5: Commit**

```bash
git add server/ai/ai_brain.gd
git commit -m "ai: steer around nearby obstacles with proximity forces"
```

---

## Task 8: AI stuck-detection tuning

**Files:**
- Modify: `server/ai/ai_brain.gd`

- [ ] **Step 1: Lower `STUCK_SPEED_THRESHOLD` and lengthen reverse**

In `server/ai/ai_brain.gd`, change the existing constants (around lines 25-27):

```gdscript
const STUCK_SPEED_THRESHOLD: float = 1.5
const STUCK_TRIGGER_S: float = 1.2
const UNSTICK_REVERSE_S: float = 1.2
```

- [ ] **Step 2: Add spawn grace timer to skip early false positives**

Add this member variable near the other stuck-related vars (around line 23):

```gdscript
var _stuck_grace_timer: float = 0.0
```

In `setup(pid, world)` (around line 50), after `_pick_new_waypoint(world)`, add:

```gdscript
    _stuck_grace_timer = 0.5
```

In `step(state, world, dt)`, right after the existing `_unstick_timer = max(0.0, _unstick_timer - dt)` line (around line 58), add:

```gdscript
    _stuck_grace_timer = max(0.0, _stuck_grace_timer - dt)
```

Finally, gate the stuck-timer accumulation: change the `if move_forward > 0.5 and actual_speed < STUCK_SPEED_THRESHOLD:` line (added in Task 7 Step 2) to:

```gdscript
        if _stuck_grace_timer <= 0.0 and move_forward > 0.5 and actual_speed < STUCK_SPEED_THRESHOLD:
```

- [ ] **Step 3: Run tests**

Run: `/Applications/Godot.app/Contents/MacOS/Godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests -gexit`
Expected: all 60 tests pass.

- [ ] **Step 4: Manual verification (AI behavior)**

Start server + native client. Watch for 30–60 seconds near a large rock cluster:
- AI tanks should visibly veer around rocks rather than pressing into them.
- If an AI does get boxed in, stuck fallback should still trigger (reverses for 1.2 s, picks a new waypoint).
- No obvious left/right oscillation in open space.

- [ ] **Step 5: Commit**

```bash
git add server/ai/ai_brain.gd
git commit -m "ai: tighten stuck fallback thresholds + add spawn grace"
```

---

## Final Verification

- [ ] **Step 1: Full test run**

Run: `/Applications/Godot.app/Contents/MacOS/Godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests -gexit`
Expected: all 60 tests pass across 8 scripts.

- [ ] **Step 2: Manual smoke**

Start server + native client. Confirm:
- Combat log: only last 15 lines visible after heavy action.
- TPV reload bar: text "装填 X.Xs" / "就绪" overlay, correct sizing.
- FPV reload bar: matches TPV size and font; same overlay text.
- Scope arc: amber fill clockwise during reload, green flash on ready, gray background ring idle.
- AI tanks: steer around rocks, no visible pinning behind obstacles.

- [ ] **Step 3: Git log sanity**

```bash
git log --oneline -n 10
```
Expected: 8 new commits (one per task) since `main@{pre-plan}`.
