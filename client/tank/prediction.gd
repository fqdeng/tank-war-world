# client/tank/prediction.gd
extends Node

const TankState = preload("res://shared/tank/tank_state.gd")
const TankMovement = preload("res://shared/tank/tank_movement.gd")
const TerrainGenerator = preload("res://shared/world/terrain_generator.gd")
const TankCollision = preload("res://shared/world/tank_collision.gd")

var _input_history: Array = []  # each: {tick, input, dt}
var _state: TankState
var _heightmap: PackedFloat32Array
var _terrain_size: int = 0
var _reconcile_threshold_sq: float = 0.25  # ~0.5m tolerance

# Shared obstacle data so the client predicts collisions identically to the
# server. Without this, the tank clips into rocks locally and the server
# snap-reconciles every snapshot, producing 20Hz body/camera shake.
var _obstacles: Array = []
var _destroyed: Dictionary = {}

func initialize(state: TankState, hm: PackedFloat32Array, terrain_size: int) -> void:
    _state = state
    _heightmap = hm
    _terrain_size = terrain_size

# Swap the heightmap reference without touching tank state — used on match
# restart so terrain sampling hits the regenerated world, while the tank
# itself keeps its identity and gets teleported via the trailing RESPAWN.
func set_heightmap(hm: PackedFloat32Array, terrain_size: int) -> void:
    _heightmap = hm
    _terrain_size = terrain_size

func set_obstacles(obstacles: Array, destroyed: Dictionary) -> void:
    _obstacles = obstacles
    _destroyed = destroyed

func mark_obstacle_destroyed(id: int) -> void:
    _destroyed[id] = true

func state() -> TankState:
    return _state

# Called each physics frame: step state locally, record input for replay.
func apply_local(input: Dictionary, tick: int, dt: float) -> void:
    if _state == null:
        return
    TankMovement.step(_state, input, dt)
    _apply_collision()
    if _heightmap.size() > 0:
        _state.pos.y = TerrainGenerator.sample_height(_heightmap, _terrain_size, _state.pos.x, _state.pos.z)
    _state.turret_yaw = float(input.get("turret_yaw", _state.turret_yaw))
    _state.gun_pitch = float(input.get("gun_pitch", _state.gun_pitch))
    if _state.reload_remaining > 0.0:
        _state.reload_remaining = max(0.0, _state.reload_remaining - dt)
    _input_history.append({"tick": tick, "input": input.duplicate(), "dt": dt})
    while _input_history.size() > 60:
        _input_history.pop_front()

# Mirror of the server's xz clamp + obstacle push. Must stay in lockstep with
# tick_loop.gd, otherwise reconcile will yank the tank back each snapshot.
func _apply_collision() -> void:
    if _terrain_size > 0:
        var cr: Dictionary = TankCollision.clamp_to_playable(_state.pos, _terrain_size)
        _state.pos = cr["pos"]
        if cr["clamped"]:
            _state.speed = 0.0
    if _obstacles.size() > 0:
        var push: Vector3 = TankCollision.resolve_obstacle_push(_state.pos, _obstacles, _destroyed)
        _state.pos.x += push.x
        _state.pos.z += push.z
        if push.length_squared() > 0.0001:
            _state.speed = 0.0

# On snapshot: sync only server-authoritative fields (hp, ammo).
# Position/yaw/turret are client-authoritative — the server no longer corrects
# them, because its 20Hz corrections produced visible body/camera shake on
# collisions. Reload is also client-authoritative now (client sets it on fire
# and ticks it down locally) since _on_fire_received trusts client-supplied
# shell data verbatim and no longer stamps reload_remaining on the server.
# Respawns come through _handle_respawn → teleport() instead.
func reconcile(_server_pos: Vector3, _server_yaw: float, _server_turret_yaw: float,
        _server_gun_pitch: float, server_hp: int, acked_tick: int,
        server_ammo: int = -1, _server_reload: float = -1.0) -> void:
    if _state == null:
        return
    while _input_history.size() > 0 and int(_input_history[0]["tick"]) <= acked_tick:
        _input_history.pop_front()
    _state.hp = server_hp
    if server_ammo >= 0:
        _state.ammo = server_ammo

# Hard teleport used on respawn — the only path that overwrites local pos now.
func teleport(pos: Vector3) -> void:
    if _state == null:
        return
    _state.pos = pos
    _state.speed = 0.0
    _input_history.clear()
