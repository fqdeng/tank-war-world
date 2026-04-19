# client/tank/prediction.gd
extends Node

const TankState = preload("res://shared/tank/tank_state.gd")
const TankMovement = preload("res://shared/tank/tank_movement.gd")
const TerrainGenerator = preload("res://shared/world/terrain_generator.gd")

var _input_history: Array = []  # each: {tick, input, dt}
var _state: TankState
var _heightmap: PackedFloat32Array
var _terrain_size: int = 0
var _reconcile_threshold_sq: float = 0.25  # ~0.5m tolerance

func initialize(state: TankState, hm: PackedFloat32Array, terrain_size: int) -> void:
    _state = state
    _heightmap = hm
    _terrain_size = terrain_size

func state() -> TankState:
    return _state

# Called each physics frame: step state locally, record input for replay.
func apply_local(input: Dictionary, tick: int, dt: float) -> void:
    if _state == null:
        return
    TankMovement.step(_state, input, dt)
    if _heightmap.size() > 0:
        _state.pos.y = TerrainGenerator.sample_height(_heightmap, _terrain_size, _state.pos.x, _state.pos.z)
    _state.turret_yaw = float(input.get("turret_yaw", _state.turret_yaw))
    _state.gun_pitch = float(input.get("gun_pitch", _state.gun_pitch))
    _input_history.append({"tick": tick, "input": input.duplicate(), "dt": dt})
    while _input_history.size() > 60:
        _input_history.pop_front()

# On snapshot: discard acked inputs, reconcile if diverged.
func reconcile(server_pos: Vector3, server_yaw: float, server_turret_yaw: float,
        server_gun_pitch: float, server_hp: int, acked_tick: int,
        server_ammo: int = -1, server_reload: float = -1.0) -> void:
    if _state == null:
        return
    while _input_history.size() > 0 and int(_input_history[0]["tick"]) <= acked_tick:
        _input_history.pop_front()
    var dx: float = server_pos.x - _state.pos.x
    var dz: float = server_pos.z - _state.pos.z
    var dist_sq: float = dx * dx + dz * dz
    if dist_sq > _reconcile_threshold_sq:
        _state.pos = server_pos
        _state.yaw = server_yaw
        for entry in _input_history:
            TankMovement.step(_state, entry["input"], entry["dt"])
            if _heightmap.size() > 0:
                _state.pos.y = TerrainGenerator.sample_height(_heightmap, _terrain_size, _state.pos.x, _state.pos.z)
    # Turret/gun_pitch are client-authoritative (driven by mouse input) — do NOT
    # overwrite from server, or we get per-snapshot jitter on the barrel/turret.
    _state.hp = server_hp
    if server_ammo >= 0:
        _state.ammo = server_ammo
    if server_reload >= 0.0:
        _state.reload_remaining = server_reload
