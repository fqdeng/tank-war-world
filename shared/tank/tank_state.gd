# shared/tank/tank_state.gd
class_name TankState
extends RefCounted

enum Part { HULL = 0, TURRET = 1, ENGINE = 2, LEFT_TRACK = 3, RIGHT_TRACK = 4, TOP = 5 }

var player_id: int = 0
var team: int = 0
var pos: Vector3 = Vector3.ZERO
var yaw: float = 0.0
var turret_yaw: float = 0.0
var gun_pitch: float = 0.0
var speed: float = 0.0
var hp: int = 0  # total HP (sum of alive parts)
var ammo: int = 0
var reload_remaining: float = 0.0
var alive: bool = true
var respawn_remaining: float = 0.0
var last_acked_input_tick: int = 0  # last client-input tick this server state has consumed
var ammo_regen_accum: float = 0.0   # server-side: accumulates dt toward +1 ammo
var is_ai: bool = false             # server-only flag, not networked

# Parts: Part enum int → float sub HP
var parts: Dictionary = {}

func initialize_parts(total_max_hp: int) -> void:
    var t := float(total_max_hp)
    parts = {
        Part.HULL: t * Constants.PART_HP_HULL,
        Part.TURRET: t * Constants.PART_HP_TURRET,
        Part.ENGINE: t * Constants.PART_HP_ENGINE,
        Part.LEFT_TRACK: t * Constants.PART_HP_LEFT_TRACK,
        Part.RIGHT_TRACK: t * Constants.PART_HP_RIGHT_TRACK,
        Part.TOP: t * Constants.PART_HP_TOP,
    }
    hp = total_max_hp

func part_hp(p: int) -> float:
    return parts.get(p, 0.0)

# Parts that haven't been initialized are treated as intact (so unit tests of
# pure movement without calling initialize_parts still work).
func is_part_destroyed(p: int) -> bool:
    if not parts.has(p):
        return false
    return parts[p] <= 0.0

func can_fire() -> bool:
    return alive and not is_part_destroyed(Part.TURRET) and reload_remaining <= 0.0 and ammo > 0

func is_turret_disabled() -> bool:
    return is_part_destroyed(Part.TURRET)

func left_track_ok() -> bool:
    return not is_part_destroyed(Part.LEFT_TRACK)

func right_track_ok() -> bool:
    return not is_part_destroyed(Part.RIGHT_TRACK)

func engine_ok() -> bool:
    return not is_part_destroyed(Part.ENGINE)
