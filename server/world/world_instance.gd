# server/world/world_instance.gd
class_name WorldInstance
extends Node

const TerrainGenerator = preload("res://shared/world/terrain_generator.gd")
const ObstaclePlacer = preload("res://shared/world/obstacle_placer.gd")
const TankState = preload("res://shared/tank/tank_state.gd")

var world_seed: int
var heightmap: PackedFloat32Array
var terrain_size: int
var obstacles: Array  # Array[ObstaclePlacer.Obstacle]

# player_id → TankState
var tanks: Dictionary = {}

# Monotonic counter for player ids (starts at 1 so 0 can mean "none")
var _next_player_id: int = 1

# Tick counter (set by TickLoop)
var current_tick: int = 0

# Sim-clock epoch (wall ms) — stamped once when TickLoop starts. All outbound
# timestamps (SNAPSHOT.server_time_ms, PONG.server_time_ms) are expressed
# relative to this so the client's interpolation buffer sees strictly-spaced
# stamps: snapshot stamps are sim-tick-time (_tick * 50), PONG stamps are
# wall-time-since-epoch — same timeline, different resolutions.
var _sim_epoch_ms: int = 0

func start_sim_clock() -> void:
    _sim_epoch_ms = Time.get_ticks_msec()

func sim_clock_ms() -> int:
    return Time.get_ticks_msec() - _sim_epoch_ms

# Obstacle state (Plan 04)
# obstacle_id → current HP (absent = intact at max)
var obstacle_hp: Dictionary = {}
# obstacle_id → true for destroyed obstacles (fast membership lookup)
var destroyed_obstacle_ids: Dictionary = {}

func obstacle_max_hp(kind: int) -> int:
    match kind:
        0: return Constants.OBSTACLE_HP_SMALL_ROCK
        1: return Constants.OBSTACLE_HP_LARGE_ROCK
        2: return Constants.OBSTACLE_HP_TREE
    return 100

func obstacle_current_hp(id: int, kind: int) -> int:
    return obstacle_hp.get(id, obstacle_max_hp(kind))

# Returns true if this hit destroyed the obstacle.
func apply_obstacle_damage(id: int, kind: int, damage: int) -> bool:
    if destroyed_obstacle_ids.has(id):
        return false
    var current: int = obstacle_current_hp(id, kind)
    current -= damage
    if current <= 0:
        destroyed_obstacle_ids[id] = true
        obstacle_hp.erase(id)
        return true
    obstacle_hp[id] = current
    return false

func is_obstacle_destroyed(id: int) -> bool:
    return destroyed_obstacle_ids.has(id)

func _init(seed_: int = 0) -> void:
    world_seed = seed_
    terrain_size = Constants.WORLD_SIZE_M
    heightmap = TerrainGenerator.generate_heightmap(world_seed, terrain_size)
    obstacles = ObstaclePlacer.place(
        world_seed, heightmap, terrain_size,
        Constants.SMALL_ROCK_COUNT,
        Constants.LARGE_ROCK_COUNT,
        Constants.TREE_COUNT,
    )

# Rebuild terrain + obstacles against a new seed and clear per-match damage
# state. Tanks, _next_player_id, and sim clock are intentionally preserved —
# the match restart keeps the same player ids and connections, it only
# reshuffles the playfield.
func regenerate(new_seed: int) -> void:
    world_seed = new_seed
    heightmap = TerrainGenerator.generate_heightmap(world_seed, terrain_size)
    obstacles = ObstaclePlacer.place(
        world_seed, heightmap, terrain_size,
        Constants.SMALL_ROCK_COUNT,
        Constants.LARGE_ROCK_COUNT,
        Constants.TREE_COUNT,
    )
    obstacle_hp.clear()
    destroyed_obstacle_ids.clear()

func allocate_player_id() -> int:
    var pid := _next_player_id
    _next_player_id += 1
    return pid

# Pick a spawn point for a given team. Team 0 corner, team 1 opposite corner.
func pick_spawn_pos(team: int) -> Vector3:
    var margin := 60.0
    var x: float
    var z: float
    if team == 0:
        x = margin + randf() * 40.0
        z = margin + randf() * 40.0
    else:
        x = float(terrain_size) - margin - randf() * 40.0
        z = float(terrain_size) - margin - randf() * 40.0
    var y := TerrainGenerator.sample_height(heightmap, terrain_size, x, z)
    return Vector3(x, y, z)

func spawn_tank(player_id: int, team: int) -> TankState:
    var t := TankState.new()
    t.player_id = player_id
    t.team = team
    t.pos = pick_spawn_pos(team)
    t.yaw = PI if team == 1 else 0.0
    t.initialize_parts(Constants.TANK_MAX_HP)
    t.ammo = Constants.TANK_AMMO_CAPACITY
    t.alive = true
    t.spawn_invuln_remaining = Constants.SPAWN_INVULN_S
    tanks[player_id] = t
    return t

func remove_tank(player_id: int) -> void:
    tanks.erase(player_id)
