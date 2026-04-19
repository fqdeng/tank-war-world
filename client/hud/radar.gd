# client/hud/radar.gd
extends Control

const RADAR_RANGE_M: float = 350.0  # world radius shown on the radar
const DOT_TTL_MS: int = 5000

# shooter_id → {pos: Vector3, team: int, expires_ms: int}
var _blips: Dictionary = {}

# Set by owner each frame — local player's current world pos + yaw (for relative mapping).
var _self_pos: Vector3 = Vector3.ZERO
var _self_yaw: float = 0.0
var _my_team: int = -1

func set_self_pose(pos: Vector3, yaw: float) -> void:
    _self_pos = pos
    _self_yaw = yaw
    queue_redraw()

func set_my_team(team: int) -> void:
    _my_team = team

# Record / refresh a firing blip for `shooter_id`.
func ping_shot(shooter_id: int, pos: Vector3, team: int) -> void:
    _blips[shooter_id] = {
        "pos": pos,
        "team": team,
        "expires_ms": Time.get_ticks_msec() + DOT_TTL_MS,
    }
    queue_redraw()

func _process(_delta: float) -> void:
    var now: int = Time.get_ticks_msec()
    var expired: Array = []
    for pid in _blips:
        if int(_blips[pid]["expires_ms"]) <= now:
            expired.append(pid)
    if not expired.is_empty():
        for pid in expired:
            _blips.erase(pid)
        queue_redraw()

func _draw() -> void:
    var w: float = size.x
    var h: float = size.y
    var cx: float = w * 0.5
    var cy: float = h * 0.5
    var radius: float = min(w, h) * 0.5 - 2.0

    # Background disk + border
    draw_circle(Vector2(cx, cy), radius, Color(0.0, 0.0, 0.0, 0.55))
    draw_arc(Vector2(cx, cy), radius, 0.0, TAU, 48, Color(0.7, 0.85, 0.7, 0.65), 1.5)

    # Crosshair through center
    draw_line(Vector2(cx - radius, cy), Vector2(cx + radius, cy), Color(0.6, 0.8, 0.6, 0.25), 1.0)
    draw_line(Vector2(cx, cy - radius), Vector2(cx, cy + radius), Color(0.6, 0.8, 0.6, 0.25), 1.0)

    # Self marker (bright triangle pointing up = player's forward)
    _draw_self_triangle(Vector2(cx, cy))

    # Compass "N" — points to world north (-Z direction), rotates as player turns.
    _draw_north_marker(Vector2(cx, cy), radius)

    var now: int = Time.get_ticks_msec()
    for pid in _blips:
        var blip: Dictionary = _blips[pid]
        var wp: Vector3 = blip["pos"]
        var dx: float = wp.x - _self_pos.x
        var dz: float = wp.z - _self_pos.z
        var dist: float = sqrt(dx * dx + dz * dz)
        if dist > RADAR_RANGE_M:
            # Clamp to edge so you still see direction
            var scale: float = RADAR_RANGE_M / max(dist, 0.001)
            dx *= scale
            dz *= scale
            dist = RADAR_RANGE_M
        # Rotate so player's forward is up on radar (player yaw 0 = facing -Z world)
        var cy_rot: float = cos(-_self_yaw)
        var sy_rot: float = sin(-_self_yaw)
        var rx: float = dx * cy_rot - dz * sy_rot
        var rz: float = dx * sy_rot + dz * cy_rot
        # -Z in front → draw forward = up = -Y on screen
        var px: float = cx + rx / RADAR_RANGE_M * radius
        var py: float = cy + rz / RADAR_RANGE_M * radius
        var team: int = int(blip["team"])
        var col: Color
        if team == _my_team:
            col = Color(0.4, 0.75, 1.0, 1.0)
        else:
            col = Color(1.0, 0.35, 0.35, 1.0)
        var remaining: float = float(int(blip["expires_ms"]) - now) / float(DOT_TTL_MS)
        remaining = clamp(remaining, 0.0, 1.0)
        col.a = 0.35 + 0.65 * remaining
        draw_circle(Vector2(px, py), 4.0, col)

func _draw_north_marker(center: Vector2, radius: float) -> void:
    # World north := -Z direction. Transform into radar-local space (forward = up).
    var nx: float = -sin(_self_yaw)
    var nz: float = -cos(_self_yaw)
    var edge: float = radius - 10.0
    var tick_inner: float = radius - 4.0
    var p_inner := Vector2(center.x + nx * tick_inner, center.y + nz * tick_inner)
    var p_outer := Vector2(center.x + nx * radius, center.y + nz * radius)
    var col := Color(1.0, 0.95, 0.4, 0.95)
    # Notch on the ring pointing to world north
    draw_line(p_inner, p_outer, col, 2.0)
    # "N" label just inside the ring
    var label_pos := Vector2(center.x + nx * edge - 4.0, center.y + nz * edge + 5.0)
    var font: Font = ThemeDB.fallback_font
    var font_size: int = 14
    draw_string(font, label_pos, "N", HORIZONTAL_ALIGNMENT_CENTER, -1, font_size, col)

func _draw_self_triangle(center: Vector2) -> void:
    var up := Vector2(0, -8)
    var left := Vector2(-5, 4)
    var right := Vector2(5, 4)
    var col := Color(0.9, 1.0, 0.9, 0.95)
    draw_line(center + up, center + left, col, 1.5)
    draw_line(center + left, center + right, col, 1.5)
    draw_line(center + right, center + up, col, 1.5)
