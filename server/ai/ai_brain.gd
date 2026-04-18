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
    # Fire blind along the body's forward direction, with a random pitch.
    var turret_yaw: float = 0.0
    var gun_pitch: float = _rng.randf_range(deg_to_rad(1.0), deg_to_rad(10.0))
    var fire_pressed: bool = false
    if _fire_cooldown <= 0.0:
        fire_pressed = true
        _fire_cooldown = Constants.TANK_RELOAD_S + _rng.randf_range(1.0, 3.0)
    return {
        "move_forward": move_forward,
        "move_turn": move_turn,
        "turret_yaw": turret_yaw,
        "gun_pitch": gun_pitch,
        "fire_pressed": fire_pressed,
        "tick": 0,
    }

func _pick_new_waypoint(world) -> void:
    var margin: float = Constants.PLAYABLE_MARGIN_M + 20.0
    var size: float = float(world.terrain_size)
    var x: float = _rng.randf_range(margin, size - margin)
    var z: float = _rng.randf_range(margin, size - margin)
    _waypoint = Vector3(x, 0.0, z)
    _repath_timer = _rng.randf_range(6.0, 12.0)

