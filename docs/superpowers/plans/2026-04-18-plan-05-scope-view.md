# Plan 05: First-Person Scope View — Implementation Plan

**Goal:** Right-click toggles between third-person follow cam and a first-person scope view mounted on the barrel. Scope shows military-optic reticle (horizontal + vertical crosshair, horizontal stadia, vertical drop ticks at 400/600/800m, black vignette frame) + overlay readings (zoom, distance under aim, ammo, reload, gun pitch). Scroll wheel cycles zoom ×2/×4/×8.

**Architecture:** A second `Camera3D` parented under the local tank's `_barrel` node so it follows both turret yaw and gun pitch automatically. A dedicated `CanvasLayer` with a `Control` using `_draw()` for the reticle graphics; hidden when not in scope mode.

**Out of scope:** Rangefinding automation (hint: matches spec §6.3 "system does not give auto-aim"); scope entry animation; blur effects.

---

## File Structure

```
client/camera/scope_cam.gd            # create: Camera3D with zoom cycling
client/hud/scope_overlay.gd           # create: Control with _draw reticle
client/hud/scope_overlay.tscn         # create: CanvasLayer scene
client/tank/tank_view.gd              # modify: expose _barrel for parenting cam
client/main_client.gd                 # modify: create scope cam, toggle on right-click, manage distance read
client/input/tank_input.gd            # modify: emit scope_toggled + zoom_changed signals
common/constants.gd                   # modify: scope zoom FOVs
```

---

## Task 1: Constants

Append:

```gdscript
# --- Scope (Plan 05) ---
const SCOPE_FOV_2X: float = 40.0
const SCOPE_FOV_4X: float = 20.0
const SCOPE_FOV_8X: float = 10.0
const SCOPE_ZOOMS: Array = [2, 4, 8]  # order for cycling
```

## Task 2: Scope camera

```gdscript
# client/camera/scope_cam.gd
extends Camera3D

var _zoom_index: int = 1  # start at ×4

func _ready() -> void:
    current = false
    _apply_zoom()

func _apply_zoom() -> void:
    var z: int = Constants.SCOPE_ZOOMS[_zoom_index]
    match z:
        2: fov = Constants.SCOPE_FOV_2X
        4: fov = Constants.SCOPE_FOV_4X
        8: fov = Constants.SCOPE_FOV_8X

func cycle_zoom(direction: int) -> void:
    _zoom_index = clamp(_zoom_index + direction, 0, Constants.SCOPE_ZOOMS.size() - 1)
    _apply_zoom()

func current_zoom() -> int:
    return Constants.SCOPE_ZOOMS[_zoom_index]
```

## Task 3: Scope overlay (reticle)

`client/hud/scope_overlay.tscn` — a `CanvasLayer` with a full-screen `Control` child running the draw script.

```
[gd_scene load_steps=2 format=3]
[ext_resource type="Script" path="res://client/hud/scope_overlay.gd" id="1"]

[node name="ScopeOverlay" type="CanvasLayer"]
visible = false

[node name="Reticle" type="Control" parent="."]
anchor_right = 1.0
anchor_bottom = 1.0
script = ExtResource("1")

[node name="ZoomLabel" type="Label" parent="Reticle"]
offset_left = 18
offset_top = 18
offset_right = 200
offset_bottom = 50
text = "ZOOM x4"

[node name="DistLabel" type="Label" parent="Reticle"]
offset_left = 18
offset_top = 44
offset_right = 240
offset_bottom = 72
text = "DIST --- m"

[node name="AmmoLabel" type="Label" parent="Reticle"]
anchor_left = 1.0
anchor_right = 1.0
offset_left = -200
offset_top = 18
offset_right = -18
offset_bottom = 50
horizontal_alignment = 2
text = "AP x --"

[node name="PitchLabel" type="Label" parent="Reticle"]
anchor_left = 1.0
anchor_top = 1.0
anchor_right = 1.0
anchor_bottom = 1.0
offset_left = -200
offset_top = -60
offset_right = -18
offset_bottom = -18
horizontal_alignment = 2
text = "GUN +0.0°"
```

```gdscript
# client/hud/scope_overlay.gd
extends Control

@onready var _zoom_label: Label = $ZoomLabel
@onready var _dist_label: Label = $DistLabel
@onready var _ammo_label: Label = $AmmoLabel
@onready var _pitch_label: Label = $PitchLabel

func set_zoom(z: int) -> void:
    if _zoom_label:
        _zoom_label.text = "ZOOM x%d" % z

func set_distance(d: float) -> void:
    if _dist_label:
        _dist_label.text = "DIST %d m" % int(round(d)) if d >= 0.0 else "DIST --- m"

func set_ammo(n: int) -> void:
    if _ammo_label:
        _ammo_label.text = "AP x %d" % n

func set_pitch(deg: float) -> void:
    if _pitch_label:
        _pitch_label.text = "GUN %+.1f°" % deg

func _draw() -> void:
    var w: float = size.x
    var h: float = size.y
    var cx: float = w * 0.5
    var cy: float = h * 0.5
    var yellow := Color(1.0, 0.86, 0.55, 0.9)

    # Black vignette around circular fov
    draw_rect(Rect2(0, 0, w, h), Color.BLACK, false)
    # Four black rectangles forming a frame around the central square area
    var inset: float = min(w, h) * 0.06
    var fs: float = min(w, h) * 0.88
    var fx: float = (w - fs) * 0.5
    var fy: float = (h - fs) * 0.5
    draw_rect(Rect2(0, 0, w, fy), Color.BLACK)  # top
    draw_rect(Rect2(0, fy + fs, w, h - fy - fs), Color.BLACK)  # bottom
    draw_rect(Rect2(0, fy, fx, fs), Color.BLACK)  # left
    draw_rect(Rect2(fx + fs, fy, w - fx - fs, fs), Color.BLACK)  # right

    # Horizontal & vertical main lines
    draw_line(Vector2(fx, cy), Vector2(fx + fs, cy), yellow, 1.0)
    draw_line(Vector2(cx, fy), Vector2(cx, fy + fs), yellow, 1.0)

    # Horizontal stadia ticks (for estimating lateral lead)
    var stadia_count := 10
    var step_px: float = fs / float(stadia_count * 2)
    for i in range(-stadia_count, stadia_count + 1):
        if i == 0:
            continue
        var tx: float = cx + i * step_px
        var th: float = 6.0 if (i % 5 == 0) else 3.0
        draw_line(Vector2(tx, cy - th), Vector2(tx, cy + th), yellow, 1.0)

    # Vertical drop ticks (below center) labeled 400/600/800m
    var drops := [{"px_offset": 80.0, "label": "400m"}, {"px_offset": 140.0, "label": "600m"}, {"px_offset": 210.0, "label": "800m"}]
    for d in drops:
        var dy: float = cy + float(d["px_offset"])
        var width: float = 18.0 if d["label"] == "400m" else (24.0 if d["label"] == "600m" else 30.0)
        draw_line(Vector2(cx - width, dy), Vector2(cx + width, dy), yellow, 1.0)
        draw_string(get_theme_default_font(), Vector2(cx + width + 6, dy + 4), d["label"], HORIZONTAL_ALIGNMENT_LEFT, -1, 12, yellow)
```

## Task 4: Input — right-click toggle + scroll zoom

Modify `client/input/tank_input.gd` — add signals + event handling:

```gdscript
signal scope_toggled
signal zoom_cycled(direction: int)

func _input(ev: InputEvent) -> void:
    if not _enabled:
        return
    if ev is InputEventMouseMotion:
        _turret_yaw += -ev.relative.x * _mouse_sens_yaw
        _gun_pitch += -ev.relative.y * _mouse_sens_pitch
        _gun_pitch = clamp(_gun_pitch, deg_to_rad(-5.0), deg_to_rad(18.0))
    elif ev is InputEventMouseButton:
        if ev.button_index == MOUSE_BUTTON_LEFT and ev.pressed:
            _fire_latched = true
        elif ev.button_index == MOUSE_BUTTON_RIGHT and ev.pressed:
            scope_toggled.emit()
        elif ev.button_index == MOUSE_BUTTON_WHEEL_UP and ev.pressed:
            zoom_cycled.emit(1)
        elif ev.button_index == MOUSE_BUTTON_WHEEL_DOWN and ev.pressed:
            zoom_cycled.emit(-1)
    elif ev is InputEventKey:
        if ev.pressed and ev.keycode == KEY_ESCAPE:
            Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
```

## Task 5: TankView exposes barrel node

Add method:

```gdscript
func barrel_node() -> Node3D:
    return _barrel
```

## Task 6: main_client wires it all

- On CONNECT_ACK after local view created: create `ScopeCam`, parent under `local_tank.barrel_node()`, add `ScopeOverlay` as child of main_client.
- Connect input signals to toggle/zoom handlers.
- In `_process`, if scope active, compute distance under aim (raycast from scope cam forward against heightmap/obstacles) and update overlay.

```gdscript
const ScopeCam = preload("res://client/camera/scope_cam.gd")
const ScopeOverlay = preload("res://client/hud/scope_overlay.tscn")

var _scope_cam
var _scope_overlay
var _in_scope: bool = false
```

In `_ready`, connect:

```gdscript
    _input.scope_toggled.connect(_toggle_scope)
    _input.zoom_cycled.connect(_on_zoom_cycled)
    _scope_overlay = ScopeOverlay.instantiate()
    add_child(_scope_overlay)
```

Add methods:

```gdscript
func _toggle_scope() -> void:
    if _scope_cam == null:
        _ensure_scope_cam()
    if _scope_cam == null:
        return
    _in_scope = not _in_scope
    if _in_scope:
        _scope_cam.current = true
        _scope_overlay.visible = true
        _hud.visible = false
    else:
        _camera.current = true
        _scope_overlay.visible = false
        _hud.visible = true

func _on_zoom_cycled(dir: int) -> void:
    if _scope_cam == null or not _in_scope:
        return
    _scope_cam.cycle_zoom(dir)
    _scope_overlay.get_node("Reticle").set_zoom(_scope_cam.current_zoom())

func _ensure_scope_cam() -> void:
    if _scope_cam != null:
        return
    if not _tanks.has(_my_player_id):
        return
    var view = _tanks[_my_player_id]
    var barrel = view.barrel_node()
    if barrel == null:
        return
    _scope_cam = ScopeCam.new()
    # Mount slightly above barrel base, looking along barrel forward (-Z)
    _scope_cam.position = Vector3(0, 0.5, -0.5)
    barrel.add_child(_scope_cam)
    # Initial zoom label
    _scope_overlay.get_node("Reticle").set_zoom(_scope_cam.current_zoom())
```

In `_process`, update reticle readings when in scope:

```gdscript
    if _in_scope and _scope_cam != null and _prediction != null:
        var s = _prediction.state()
        var reticle = _scope_overlay.get_node("Reticle")
        reticle.set_ammo(s.ammo)
        reticle.set_pitch(rad_to_deg(s.gun_pitch))
        # Distance to ground under aim point (terrain raycast only for simplicity)
        var origin: Vector3 = _scope_cam.global_position
        var fwd: Vector3 = -_scope_cam.global_transform.basis.z
        var d := _raycast_terrain_distance(origin, fwd)
        reticle.set_distance(d)
```

Add helper:

```gdscript
func _raycast_terrain_distance(origin: Vector3, dir: Vector3) -> float:
    const Ballistics = preload("res://shared/combat/ballistics.gd")  # (already imported at top; dedupe)
    var max_d: float = 1500.0
    var steps: int = 60  # ~25m per step
    var step_len: float = max_d / float(steps)
    for i in range(1, steps + 1):
        var t: float = i * step_len
        var p: Vector3 = origin + dir * t
        if _terrain_builder == null or _terrain_builder.heightmap.size() == 0:
            return -1.0
        var th: float = _terrain_builder.heightmap[int(clamp(p.z, 0, _terrain_builder.terrain_size - 1)) * _terrain_builder.terrain_size + int(clamp(p.x, 0, _terrain_builder.terrain_size - 1))]
        if p.y <= th:
            return t
    return -1.0
```

Wait — heightmap access above is a direct index, but the heightmap is `PackedFloat32Array` and indexing at row-major `[z * size + x]`. Fine — the value at that grid cell.

Actually cleaner to use `TerrainGenerator.sample_height`. Let me use that:

```gdscript
const TerrainGenerator = preload("res://shared/world/terrain_generator.gd")

func _raycast_terrain_distance(origin: Vector3, dir: Vector3) -> float:
    if _terrain_builder == null or _terrain_builder.heightmap.size() == 0:
        return -1.0
    var max_d: float = 1500.0
    var steps: int = 60
    var step_len: float = max_d / float(steps)
    for i in range(1, steps + 1):
        var t: float = i * step_len
        var p: Vector3 = origin + dir * t
        var th: float = TerrainGenerator.sample_height(_terrain_builder.heightmap, _terrain_builder.terrain_size, p.x, p.z)
        if p.y <= th:
            return t
    return -1.0
```

## Task 7: Verify + tag

- [ ] Boot, enter scope, move mouse, scroll, fire — all work.
- [ ] `plan-05-scope-view-complete` tag.
