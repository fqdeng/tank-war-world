# client/tank/interpolation.gd
extends RefCounted

# Per-tank snapshot ring; each entry: {t_ms, pos, yaw, turret_yaw, gun_pitch, hp}
var _buffer: Array = []
var _interp_delay_ms: int = 100
var _max_buffer: int = 20

func push_snapshot(t_ms: int, pos: Vector3, yaw: float, turret_yaw: float, gun_pitch: float, hp: int) -> void:
    _buffer.append({
        "t_ms": t_ms, "pos": pos, "yaw": yaw,
        "turret_yaw": turret_yaw, "gun_pitch": gun_pitch, "hp": hp,
    })
    while _buffer.size() > _max_buffer:
        _buffer.pop_front()

# Sample at now_ms - interp_delay. Returns dict or null if buffer empty.
func sample(now_ms: int):
    if _buffer.size() == 0:
        return null
    var target_t: int = now_ms - _interp_delay_ms
    if target_t <= int(_buffer[0]["t_ms"]):
        return _buffer[0]
    if target_t >= int(_buffer[_buffer.size() - 1]["t_ms"]):
        return _buffer[_buffer.size() - 1]
    for i in range(_buffer.size() - 1):
        var a: Dictionary = _buffer[i]
        var b: Dictionary = _buffer[i + 1]
        if int(a["t_ms"]) <= target_t and target_t <= int(b["t_ms"]):
            var span: float = float(int(b["t_ms"]) - int(a["t_ms"]))
            var f: float = 0.0 if span <= 0.0 else float(target_t - int(a["t_ms"])) / span
            return {
                "t_ms": target_t,
                "pos": (a["pos"] as Vector3).lerp(b["pos"] as Vector3, f),
                "yaw": lerp_angle(a["yaw"], b["yaw"], f),
                "turret_yaw": lerp_angle(a["turret_yaw"], b["turret_yaw"], f),
                "gun_pitch": lerp(a["gun_pitch"], b["gun_pitch"], f),
                "hp": a["hp"],
            }
    return _buffer[_buffer.size() - 1]
