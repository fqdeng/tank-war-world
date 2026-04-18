# server/ai/ai_brain.gd
# Dead-simple brain: pick a random waypoint inside the playable area, drive
# toward it. Find the nearest enemy; if within engagement range, rotate turret
# toward them and fire periodically.
extends RefCounted

const TankState = preload("res://shared/tank/tank_state.gd")
const Ballistics = preload("res://shared/combat/ballistics.gd")

var _player_id: int = 0
var _waypoint: Vector3 = Vector3.ZERO
var _repath_timer: float = 0.0
var _fire_cooldown: float = 0.0
var _rng := RandomNumberGenerator.new()

func setup(pid: int, world) -> void:
    _player_id = pid
    _rng.seed = hash(pid) + int(Time.get_ticks_msec())
    _pick_new_waypoint(world)

func step(state: TankState, world, dt: float) -> Dictionary:
    _repath_timer -= dt
    _fire_cooldown -= dt
    var to_wp: Vector3 = _waypoint - state.pos
    to_wp.y = 0.0
    if to_wp.length() < 20.0 or _repath_timer <= 0.0:
        _pick_new_waypoint(world)
        to_wp = _waypoint - state.pos
        to_wp.y = 0.0
    var desired_yaw: float = atan2(-to_wp.x, -to_wp.z)
    var yaw_err: float = wrapf(desired_yaw - state.yaw, -PI, PI)
    var move_turn: float = clamp(yaw_err / 0.4, -1.0, 1.0)
    var move_forward: float = 1.0 if abs(yaw_err) < 1.2 else 0.0

    # Engage nearest enemy ONLY if line-of-sight is not blocked by an obstacle.
    var target_id: int = _find_visible_enemy(state, world)
    var turret_yaw: float = 0.0
    var gun_pitch: float = 0.0
    var fire_pressed: bool = false
    if target_id != 0:
        var target = world.tanks[target_id]
        var to_t: Vector3 = target.pos - state.pos
        var horiz_dist: float = sqrt(to_t.x * to_t.x + to_t.z * to_t.z)
        var world_turret_yaw: float = atan2(-to_t.x, -to_t.z)
        turret_yaw = wrapf(world_turret_yaw - state.yaw, -PI, PI)
        gun_pitch = clamp(_estimate_pitch(horiz_dist, to_t.y), deg_to_rad(-5.0), deg_to_rad(18.0))
        var aim_err: float = abs(wrapf(world_turret_yaw - (state.yaw + turret_yaw), -PI, PI))
        if aim_err < 0.06 and _fire_cooldown <= 0.0:
            fire_pressed = true
            _fire_cooldown = Constants.TANK_RELOAD_S + _rng.randf_range(0.3, 1.0)
    return {
        "move_forward": move_forward,
        "move_turn": move_turn,
        "turret_yaw": turret_yaw,
        "gun_pitch": gun_pitch,
        "fire_pressed": fire_pressed,
        "tick": 0,
    }

# Closest enemy tank with clear line-of-sight (no obstacle blocking xz line).
func _find_visible_enemy(state: TankState, world) -> int:
    var best_id: int = 0
    var best_d2: float = INF
    var max_engage_sq: float = 600.0 * 600.0
    for pid in world.tanks:
        if pid == state.player_id:
            continue
        var other = world.tanks[pid]
        if not other.alive or other.team == state.team:
            continue
        var dx: float = other.pos.x - state.pos.x
        var dz: float = other.pos.z - state.pos.z
        var d2: float = dx * dx + dz * dz
        if d2 > max_engage_sq or d2 >= best_d2:
            continue
        if not _has_los(state.pos, other.pos, world):
            continue
        best_d2 = d2
        best_id = pid
    return best_id

# True when no non-destroyed obstacle intersects the xz line between `from` and `to`.
func _has_los(from: Vector3, to: Vector3, world) -> bool:
    var dx: float = to.x - from.x
    var dz: float = to.z - from.z
    var len_sq: float = dx * dx + dz * dz
    if len_sq < 0.01:
        return true
    for o in world.obstacles:
        if world.is_obstacle_destroyed(o.id):
            continue
        var r: float = _obstacle_radius(o.kind)
        var ox: float = o.pos.x - from.x
        var oz: float = o.pos.z - from.z
        var dot: float = ox * dx + oz * dz
        if dot < 0.0 or dot > len_sq:
            continue
        var t: float = dot / len_sq
        var px: float = ox - dx * t
        var pz: float = oz - dz * t
        if px * px + pz * pz < r * r:
            return false
    return true

func _obstacle_radius(kind: int) -> float:
    match kind:
        0: return Constants.OBSTACLE_RADIUS_SMALL_ROCK
        1: return Constants.OBSTACLE_RADIUS_LARGE_ROCK
        2: return Constants.OBSTACLE_RADIUS_TREE
    return 1.0

func _estimate_pitch(horiz_dist: float, dy: float) -> float:
    var v: float = Constants.SHELL_INITIAL_SPEED
    var g: float = Constants.GRAVITY
    var s: float = g * horiz_dist / (v * v)
    if s >= 1.0:
        return deg_to_rad(18.0)
    var pitch: float = 0.5 * asin(s)
    if abs(dy) > 1.0:
        pitch += atan2(dy, horiz_dist) * 0.5
    return pitch

func _pick_new_waypoint(world) -> void:
    var margin: float = Constants.PLAYABLE_MARGIN_M + 20.0
    var size: float = float(world.terrain_size)
    var x: float = _rng.randf_range(margin, size - margin)
    var z: float = _rng.randf_range(margin, size - margin)
    _waypoint = Vector3(x, 0.0, z)
    _repath_timer = _rng.randf_range(6.0, 12.0)

