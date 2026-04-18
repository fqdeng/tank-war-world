# shared/tank/tank_state.gd
class_name TankState
extends RefCounted

var player_id: int = 0
var team: int = 0
var pos: Vector3 = Vector3.ZERO
var yaw: float = 0.0          # body yaw (radians)
var turret_yaw: float = 0.0   # turret yaw relative to body (radians)
var gun_pitch: float = 0.0    # gun pitch (radians)
var speed: float = 0.0        # forward speed (m/s, signed)
var hp: int = 0
var ammo: int = 0
var reload_remaining: float = 0.0
var alive: bool = true
var respawn_remaining: float = 0.0
