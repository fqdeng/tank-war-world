# server/combat/shell_sim.gd
extends Node

const Ballistics = preload("res://shared/combat/ballistics.gd")
const PartClassifier = preload("res://shared/combat/part_classifier.gd")
const TerrainGenerator = preload("res://shared/world/terrain_generator.gd")

class Shell:
    var id: int = 0
    var shooter_id: int = 0
    var origin: Vector3
    var velocity: Vector3
    var fire_time_s: float

var _next_id: int = 1
var _shells: Array = []  # Array[Shell]
var _world
var _hit_callback: Callable

func set_world(w) -> void:
    _world = w

func set_hit_callback(cb: Callable) -> void:
    _hit_callback = cb

func spawn(shooter_id: int, origin: Vector3, velocity: Vector3) -> Shell:
    var s := Shell.new()
    s.id = _next_id
    _next_id += 1
    s.shooter_id = shooter_id
    s.origin = origin
    s.velocity = velocity
    s.fire_time_s = Time.get_ticks_msec() / 1000.0
    _shells.append(s)
    return s

func tick(dt: float) -> void:
    var now: float = Time.get_ticks_msec() / 1000.0
    var to_remove: Array = []
    for s in _shells:
        var t0: float = max(0.0, now - dt - s.fire_time_s)
        var t1: float = now - s.fire_time_s
        if t1 > Constants.SHELL_MAX_LIFETIME_S:
            to_remove.append(s)
            continue
        var subs: int = Constants.SHELL_STEP_SUBDIVISIONS
        var hit_info := _swept_collide(s, t0, t1, subs)
        if hit_info["hit"]:
            to_remove.append(s)
            if _hit_callback.is_valid():
                _hit_callback.call(s, hit_info["victim_id"], hit_info["point"], hit_info["part_id"])
    for s in to_remove:
        _shells.erase(s)

func _swept_collide(s: Shell, t0: float, t1: float, subs: int) -> Dictionary:
    var dt: float = (t1 - t0) / float(subs)
    var prev_pos: Vector3 = Ballistics.position_at(s.origin, s.velocity, t0)
    for i in range(1, subs + 1):
        var t: float = t0 + dt * i
        var pos: Vector3 = Ballistics.position_at(s.origin, s.velocity, t)
        # Terrain
        if _world.heightmap.size() > 0:
            var terrain_h: float = TerrainGenerator.sample_height(_world.heightmap, _world.terrain_size, pos.x, pos.z)
            if pos.y <= terrain_h:
                return {"hit": true, "victim_id": 0, "point": Vector3(pos.x, terrain_h, pos.z), "part_id": 0}
        # Tanks
        for pid in _world.tanks:
            if pid == s.shooter_id:
                continue
            var target = _world.tanks[pid]
            if not target.alive:
                continue
            if target.team == _world.tanks[s.shooter_id].team:
                continue
            var center: Vector3 = target.pos + Vector3(0, 1.2, 0)
            var seg_dir: Vector3 = pos - prev_pos
            var to_center: Vector3 = center - prev_pos
            var seg_len: float = seg_dir.length()
            if seg_len < 0.001:
                continue
            var seg_norm: Vector3 = seg_dir / seg_len
            var proj: float = to_center.dot(seg_norm)
            proj = clamp(proj, 0.0, seg_len)
            var closest: Vector3 = prev_pos + seg_norm * proj
            if closest.distance_to(center) <= 3.0:
                var part: int = PartClassifier.classify(target.pos, target.yaw, closest)
                return {"hit": true, "victim_id": pid, "point": closest, "part_id": part}
        prev_pos = pos
    return {"hit": false, "victim_id": 0, "point": Vector3.ZERO, "part_id": 0}

func all_active() -> Array:
    return _shells
