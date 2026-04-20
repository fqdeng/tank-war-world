# client/hud/scope_overlay.gd
extends Control

@onready var _zoom_label: Label = $ZoomLabel
@onready var _dist_label: Label = $DistLabel
@onready var _ammo_label: Label = $AmmoLabel
@onready var _pitch_label: Label = $PitchLabel
@onready var _reload: ProgressBar = $ReloadBar
@onready var _reload_text: Label = $ReloadBar/ReloadText
@onready var _hit_label: Label = $HitLabel
@onready var _kill_label: Label = $KillLabel
@onready var _turret_damage_label: Label = $TurretDamageLabel
var _hit_tween: Tween
var _kill_tween: Tween

func set_zoom(z: int) -> void:
    if _zoom_label:
        _zoom_label.text = "ZOOM x%d" % z

func set_distance(d: float) -> void:
    if _dist_label:
        if d >= 0.0:
            _dist_label.text = "DIST %d m" % int(round(d))
        else:
            _dist_label.text = "DIST --- m"

func set_ammo(_n: int) -> void:
    if _ammo_label:
        _ammo_label.text = "AP x ∞"

func set_pitch(deg: float) -> void:
    if _pitch_label:
        _pitch_label.text = "GUN %+.1f°" % deg

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

func set_turret_damaged(seconds: float) -> void:
    if _turret_damage_label == null:
        return
    if seconds > 0.0:
        _turret_damage_label.text = "炮管损坏 — 重生 %.1fs" % seconds
        _turret_damage_label.visible = true
    else:
        _turret_damage_label.visible = false
        _turret_damage_label.text = ""

func show_hit(damage: int) -> void:
    if _hit_label == null:
        return
    if _hit_tween and _hit_tween.is_valid():
        _hit_tween.kill()
    _hit_label.text = "HIT  -%d HP" % damage
    _hit_label.modulate.a = 1.0
    _hit_tween = create_tween()
    _hit_tween.tween_interval(0.6)
    _hit_tween.tween_property(_hit_label, "modulate:a", 0.0, 0.4)

func show_kill(victim_id: int) -> void:
    if _kill_label == null:
        return
    if _kill_tween and _kill_tween.is_valid():
        _kill_tween.kill()
    _kill_label.text = "KILL  P%d" % victim_id
    _kill_label.modulate.a = 1.0
    _kill_tween = create_tween()
    _kill_tween.tween_interval(1.2)
    _kill_tween.tween_property(_kill_label, "modulate:a", 0.0, 0.6)

func _draw() -> void:
    var w: float = size.x
    var h: float = size.y
    var cx: float = w * 0.5
    var cy: float = h * 0.5
    var yellow := Color(1.0, 0.86, 0.55, 0.9)

    # Circular optic window: black everything outside the inscribed circle. Four
    # per-quadrant polygons each trace one screen corner + the quarter-arc of the
    # circle. (Godot's draw APIs can't punch holes, so we fill the annular
    # exterior instead.)
    var fs: float = min(w, h) * 0.88
    var fx: float = (w - fs) * 0.5
    var fy: float = (h - fs) * 0.5
    var r: float = fs * 0.5
    _draw_circular_vignette(w, h, cx, cy, r)
    # Optic rim — subtle highlight so the circle reads as a lens edge.
    draw_arc(Vector2(cx, cy), r, 0.0, TAU, 128, Color(0.9, 0.75, 0.4, 0.5), 1.5)

    # Main crosshair lines
    draw_line(Vector2(fx, cy), Vector2(fx + fs, cy), yellow, 1.0)
    draw_line(Vector2(cx, fy), Vector2(cx, fy + fs), yellow, 1.0)

    # Horizontal stadia ticks
    var stadia_count := 10
    var step_px: float = fs / float(stadia_count * 2)
    for i in range(-stadia_count, stadia_count + 1):
        if i == 0:
            continue
        var tx: float = cx + i * step_px
        var th: float = 6.0 if (i % 5 == 0) else 3.0
        draw_line(Vector2(tx, cy - th), Vector2(tx, cy + th), yellow, 1.0)

    # Vertical drop ticks (below center) with distance labels. Y offset follows
    # the original 400/600/800 calibration extended by the same quadratic fit
    # out to 2000 m. Markers whose y falls outside the optic are skipped.
    var dist_marks: Array = [400, 600, 800, 1000, 1200, 1400, 1600, 1800, 2000]
    var font := get_theme_default_font()
    var max_y: float = fs * 0.5 - 8.0
    for d in dist_marks:
        var y_off: float = _drop_y_for(float(d))
        if y_off > max_y:
            break
        var dy: float = cy + y_off
        var dw: float = 18.0 + float(d - 400) * 0.022  # wider ticks for longer ranges
        draw_line(Vector2(cx - dw, dy), Vector2(cx + dw, dy), yellow, 1.0)
        draw_string(font, Vector2(cx + dw + 6, dy + 4), "%dm" % d, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, yellow)

# Pixel drop below the crosshair for a given range in meters. Quadratic fit
# was hand-calibrated at v=200 m/s. Drop angle scales as ~1/v² for shallow
# shots, so rescale if shell speed ever changes.
func _drop_y_for(d: float) -> float:
    var base: float = 0.000125 * d * d + 0.175 * d - 10.0
    var speed_scale: float = 40000.0 / (Constants.SHELL_INITIAL_SPEED * Constants.SHELL_INITIAL_SPEED)
    return base * speed_scale

# Fills the four screen corners outside the inscribed circle with solid black
# so the optic reads as a round window. Each polygon: screen corner → edge
# midpoint → quarter-arc along the circle → other edge midpoint → back to
# corner. Trace order is counterclockwise around each quadrant polygon.
func _draw_circular_vignette(w: float, h: float, cx: float, cy: float, r: float) -> void:
    var black := Color.BLACK
    var seg: int = 48  # arc samples per quadrant
    # Godot canvas: +X right, +Y down. Angle 0 = +X, PI/2 = +Y (down).
    var quadrants: Array = [
        {"corner": Vector2(w, 0), "e0": Vector2(w, cy), "e1": Vector2(cx, 0), "a0": 0.0, "a1": -PI * 0.5},     # top-right
        {"corner": Vector2(0, 0), "e0": Vector2(cx, 0), "e1": Vector2(0, cy), "a0": -PI * 0.5, "a1": -PI},      # top-left
        {"corner": Vector2(0, h), "e0": Vector2(0, cy), "e1": Vector2(cx, h), "a0": PI, "a1": PI * 0.5},        # bottom-left
        {"corner": Vector2(w, h), "e0": Vector2(cx, h), "e1": Vector2(w, cy), "a0": PI * 0.5, "a1": 0.0},       # bottom-right
    ]
    for q in quadrants:
        var pts := PackedVector2Array()
        pts.append(q["corner"])
        pts.append(q["e0"])
        var a0: float = q["a0"]
        var a1: float = q["a1"]
        for i in range(seg + 1):
            var t: float = float(i) / float(seg)
            var a: float = lerp(a0, a1, t)
            pts.append(Vector2(cx + cos(a) * r, cy + sin(a) * r))
        pts.append(q["e1"])
        draw_colored_polygon(pts, black)
