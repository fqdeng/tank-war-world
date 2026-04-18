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
        if d >= 0.0:
            _dist_label.text = "DIST %d m" % int(round(d))
        else:
            _dist_label.text = "DIST --- m"

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

    # Black frame around the central optical area
    var fs: float = min(w, h) * 0.88
    var fx: float = (w - fs) * 0.5
    var fy: float = (h - fs) * 0.5
    draw_rect(Rect2(0, 0, w, fy), Color.BLACK)
    draw_rect(Rect2(0, fy + fs, w, h - fy - fs), Color.BLACK)
    draw_rect(Rect2(0, fy, fx, fs), Color.BLACK)
    draw_rect(Rect2(fx + fs, fy, w - fx - fs, fs), Color.BLACK)

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

    # Vertical drop ticks (below center) with distance labels
    var drops := [
        {"y": 80.0, "w": 18.0, "label": "400m"},
        {"y": 140.0, "w": 24.0, "label": "600m"},
        {"y": 210.0, "w": 30.0, "label": "800m"},
    ]
    var font := get_theme_default_font()
    for d in drops:
        var dy: float = cy + float(d["y"])
        var dw: float = float(d["w"])
        draw_line(Vector2(cx - dw, dy), Vector2(cx + dw, dy), yellow, 1.0)
        draw_string(font, Vector2(cx + dw + 6, dy + 4), d["label"], HORIZONTAL_ALIGNMENT_LEFT, -1, 12, yellow)
