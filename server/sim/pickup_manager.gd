# server/sim/pickup_manager.gd
#
# Server-authoritative health/shield pickup system.
#
# Lifecycle: every PICKUP_REFRESH_INTERVAL_S we wipe ALL pickups (collected or
# not) and spawn a fresh batch of PICKUP_HEART_COUNT hearts + PICKUP_SHIELD_COUNT
# shields at random positions inside the playable interior. Tanks consume a
# pickup by walking within PICKUP_PICKUP_RADIUS_M (xz distance) of it.
#
# Effects:
#   heart  → restore hp + parts to full, clear pending part-regen timers
#   shield → set tank.shield_invuln_remaining = PICKUP_SHIELD_INVULN_S (reset,
#            does not stack on top of an existing shield)
#
# step(dt, alive_tanks) returns a Dictionary of events:
#   {
#       "spawned":  Array[Dictionary] (pickup_id, kind, pos),  # batch spawn this tick
#       "consumed": Array[Dictionary] (pickup_id, consumer_id, kind),  # collected or expired
#   }
# tick_loop drains those into PICKUP_SPAWNED / PICKUP_CONSUMED broadcasts so
# clients can keep their pickup_view in sync.
extends RefCounted

const TerrainGenerator = preload("res://shared/world/terrain_generator.gd")

# pickup_id → {"kind": int, "pos": Vector3}
var pickups: Dictionary = {}
var _next_id: int = 1
var _refresh_remaining: float = 0.0
var _rng := RandomNumberGenerator.new()

# Set by tick_loop after world is constructed.
var _heightmap: PackedFloat32Array
var _terrain_size: int = 0

func setup(heightmap: PackedFloat32Array, terrain_size: int) -> void:
    _heightmap = heightmap
    _terrain_size = terrain_size
    _rng.randomize()
    # Spawn the first batch immediately on first step (refresh_remaining starts
    # at 0 so the first step() returns a fresh batch + nothing consumed).

# Returns {"spawned": [...], "consumed": [...]}.
# alive_tanks: Array of tank states with .pos, .alive, .player_id (only alive tanks
# are considered for pickup collection — dead tanks shouldn't grab hearts).
func step(dt: float, alive_tanks: Array) -> Dictionary:
    var spawned: Array = []
    var consumed: Array = []

    _refresh_remaining -= dt
    if _refresh_remaining <= 0.0:
        # Wipe + reseed. Existing pickups are reported as consumer_id=0
        # so the client can despawn them; a fresh batch is then spawned.
        for pid in pickups.keys():
            consumed.append({
                "pickup_id": pid,
                "consumer_id": 0,
                "kind": int(pickups[pid]["kind"]),
            })
        pickups.clear()
        for i in Constants.PICKUP_HEART_COUNT:
            spawned.append(_spawn_one(Constants.PICKUP_KIND_HEART))
        for i in Constants.PICKUP_SHIELD_COUNT:
            spawned.append(_spawn_one(Constants.PICKUP_KIND_SHIELD))
        _refresh_remaining = Constants.PICKUP_REFRESH_INTERVAL_S

    # Collision check: any alive tank within radius of any pickup consumes it.
    # Iterate pickups outer because there are far fewer pickups (≤10) than
    # tanks at peak (≤10), and we erase from `pickups` on hit.
    var radius_sq: float = Constants.PICKUP_PICKUP_RADIUS_M * Constants.PICKUP_PICKUP_RADIUS_M
    var to_erase: Array = []
    for pid in pickups.keys():
        var p: Dictionary = pickups[pid]
        var ppos: Vector3 = p["pos"]
        for tank in alive_tanks:
            if not tank.alive:
                continue
            var dx: float = tank.pos.x - ppos.x
            var dz: float = tank.pos.z - ppos.z
            if dx * dx + dz * dz <= radius_sq:
                _apply_effect(tank, int(p["kind"]))
                consumed.append({
                    "pickup_id": pid,
                    "consumer_id": tank.player_id,
                    "kind": int(p["kind"]),
                })
                to_erase.append(pid)
                break  # one tank per pickup, then stop scanning tanks
    for pid in to_erase:
        pickups.erase(pid)

    return {"spawned": spawned, "consumed": consumed}

# Snapshot of currently-alive pickups for late joiners (CONNECT_ACK).
# Returns Array of {pickup_id, kind, pos} dicts.
func active_pickups() -> Array:
    var out: Array = []
    for pid in pickups.keys():
        var p: Dictionary = pickups[pid]
        out.append({
            "pickup_id": pid,
            "kind": int(p["kind"]),
            "pos": p["pos"],
        })
    return out

# Test seam: drive the refresh deterministically without waiting 60s of dt.
func force_refresh_now() -> void:
    _refresh_remaining = 0.0

# Wipe all in-flight pickups and return a consumed-event list so the caller
# can broadcast PICKUP_CONSUMED for each (clients need this to despawn the
# nodes before the terrain underneath gets swapped). Also resets the refresh
# timer so the next step() spawns a fresh batch against the new heightmap.
func reset_for_new_world(new_heightmap: PackedFloat32Array, new_terrain_size: int) -> Array:
    var consumed: Array = []
    for pid in pickups.keys():
        consumed.append({
            "pickup_id": pid,
            "consumer_id": 0,
            "kind": int(pickups[pid]["kind"]),
        })
    pickups.clear()
    _heightmap = new_heightmap
    _terrain_size = new_terrain_size
    _refresh_remaining = 0.0
    return consumed

func _spawn_one(kind: int) -> Dictionary:
    var pid: int = _next_id
    _next_id += 1
    var pos: Vector3 = _random_spawn_pos()
    pickups[pid] = {"kind": kind, "pos": pos}
    return {"pickup_id": pid, "kind": kind, "pos": pos}

func _random_spawn_pos() -> Vector3:
    var lo: float = Constants.PICKUP_SPAWN_MARGIN_M
    var hi: float = float(_terrain_size) - Constants.PICKUP_SPAWN_MARGIN_M
    var x: float = _rng.randf_range(lo, hi)
    var z: float = _rng.randf_range(lo, hi)
    var y: float = 0.0
    if _heightmap.size() > 0:
        y = TerrainGenerator.sample_height(_heightmap, _terrain_size, x, z)
    return Vector3(x, y, z)

func _apply_effect(tank, kind: int) -> void:
    if kind == Constants.PICKUP_KIND_HEART:
        # Full restore. Reset every part to its init max so functional damage
        # (broken turret/engine/tracks) is also undone — a heart is a full heal,
        # not a hp-only top-up.
        tank.hp = Constants.TANK_MAX_HP
        if not tank.parts_max.is_empty():
            tank.parts = tank.parts_max.duplicate()
        tank.part_regen_remaining = {}
    elif kind == Constants.PICKUP_KIND_SHIELD:
        tank.shield_invuln_remaining = Constants.PICKUP_SHIELD_INVULN_S
