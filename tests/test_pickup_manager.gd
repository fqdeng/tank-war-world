extends GutTest

const PickupManager = preload("res://server/sim/pickup_manager.gd")
const TankState = preload("res://shared/tank/tank_state.gd")

# Empty heightmap → spawn falls back to y=0; that's fine for these tests since
# we only inspect xz bounds and pickup-vs-tank distance is also xz-only.
func _make_manager() -> PickupManager:
    var pm := PickupManager.new()
    pm.setup(PackedFloat32Array(), Constants.WORLD_SIZE_M)
    return pm

func _make_tank(pid: int, pos: Vector3) -> TankState:
    var t := TankState.new()
    t.player_id = pid
    t.team = 0
    t.pos = pos
    t.initialize_parts(Constants.TANK_MAX_HP)
    t.alive = true
    return t

# First step() crosses the refresh threshold (which starts at 0) and emits the
# initial batch.
func test_first_step_spawns_full_batch() -> void:
    var pm := _make_manager()
    var ev: Dictionary = pm.step(Constants.TICK_INTERVAL, [])
    var expected: int = Constants.PICKUP_HEART_COUNT + Constants.PICKUP_SHIELD_COUNT
    assert_eq(ev["spawned"].size(), expected)
    assert_eq(ev["consumed"].size(), 0)
    assert_eq(pm.pickups.size(), expected)

func test_spawn_positions_are_inside_inner_band() -> void:
    var pm := _make_manager()
    pm.step(Constants.TICK_INTERVAL, [])
    var lo: float = Constants.PICKUP_SPAWN_MARGIN_M
    var hi: float = float(Constants.WORLD_SIZE_M) - Constants.PICKUP_SPAWN_MARGIN_M
    for pid in pm.pickups.keys():
        var p: Vector3 = pm.pickups[pid]["pos"]
        assert_true(p.x >= lo and p.x <= hi, "pickup x %f outside [%f,%f]" % [p.x, lo, hi])
        assert_true(p.z >= lo and p.z <= hi, "pickup z %f outside [%f,%f]" % [p.z, lo, hi])

func test_spawn_kinds_match_configured_counts() -> void:
    var pm := _make_manager()
    pm.step(Constants.TICK_INTERVAL, [])
    var hearts: int = 0
    var shields: int = 0
    for pid in pm.pickups.keys():
        var k: int = int(pm.pickups[pid]["kind"])
        if k == Constants.PICKUP_KIND_HEART: hearts += 1
        elif k == Constants.PICKUP_KIND_SHIELD: shields += 1
    assert_eq(hearts, Constants.PICKUP_HEART_COUNT)
    assert_eq(shields, Constants.PICKUP_SHIELD_COUNT)

func test_pickup_ids_are_unique_across_refresh() -> void:
    var pm := _make_manager()
    pm.step(Constants.TICK_INTERVAL, [])
    var first_ids: Array = pm.pickups.keys().duplicate()
    pm.force_refresh_now()
    pm.step(Constants.TICK_INTERVAL, [])
    var second_ids: Array = pm.pickups.keys()
    for id in second_ids:
        assert_false(first_ids.has(id), "id %d reused after refresh" % id)

func test_refresh_emits_consumed_for_leftovers_and_respawns_full_batch() -> void:
    var pm := _make_manager()
    pm.step(Constants.TICK_INTERVAL, [])
    var leftovers: int = pm.pickups.size()
    pm.force_refresh_now()
    var ev: Dictionary = pm.step(Constants.TICK_INTERVAL, [])
    # Every prior pickup gets a consumer_id=0 ("expired") consume event…
    assert_eq(ev["consumed"].size(), leftovers)
    for c in ev["consumed"]:
        assert_eq(int(c["consumer_id"]), 0)
    # …and a fresh batch spawns.
    assert_eq(ev["spawned"].size(), Constants.PICKUP_HEART_COUNT + Constants.PICKUP_SHIELD_COUNT)

func test_heart_restores_hp_and_parts() -> void:
    var pm := _make_manager()
    pm.step(Constants.TICK_INTERVAL, [])
    # Find a heart, place a damaged tank on top of it.
    var heart_id: int = -1
    var heart_pos: Vector3 = Vector3.ZERO
    for pid in pm.pickups.keys():
        if int(pm.pickups[pid]["kind"]) == Constants.PICKUP_KIND_HEART:
            heart_id = pid
            heart_pos = pm.pickups[pid]["pos"]
            break
    assert_ne(heart_id, -1, "expected at least one heart in spawn batch")
    var tank := _make_tank(1, heart_pos)
    # Bash it up first.
    tank.hp = 50
    tank.parts[TankState.Part.HULL] = 0.0
    tank.parts[TankState.Part.TURRET] = 0.0
    tank.part_regen_remaining[TankState.Part.TURRET] = 5.0
    var ev: Dictionary = pm.step(Constants.TICK_INTERVAL, [tank])
    assert_eq(tank.hp, Constants.TANK_MAX_HP)
    assert_almost_eq(tank.parts[TankState.Part.HULL], tank.parts_max[TankState.Part.HULL], 0.001)
    assert_almost_eq(tank.parts[TankState.Part.TURRET], tank.parts_max[TankState.Part.TURRET], 0.001)
    assert_true(tank.part_regen_remaining.is_empty())
    assert_false(pm.pickups.has(heart_id))
    # And a consume event was emitted with the right consumer.
    var found: bool = false
    for c in ev["consumed"]:
        if int(c["pickup_id"]) == heart_id:
            assert_eq(int(c["consumer_id"]), tank.player_id)
            assert_eq(int(c["kind"]), Constants.PICKUP_KIND_HEART)
            found = true
    assert_true(found, "consume event for heart not emitted")

func test_shield_sets_invuln_and_resets_on_repickup() -> void:
    var pm := _make_manager()
    pm.step(Constants.TICK_INTERVAL, [])
    # First shield sets timer; deplete it partially; second shield resets to full.
    var shield_pos: Vector3 = Vector3.ZERO
    for pid in pm.pickups.keys():
        if int(pm.pickups[pid]["kind"]) == Constants.PICKUP_KIND_SHIELD:
            shield_pos = pm.pickups[pid]["pos"]
            break
    var tank := _make_tank(1, shield_pos)
    pm.step(Constants.TICK_INTERVAL, [tank])
    assert_almost_eq(tank.shield_invuln_remaining, Constants.PICKUP_SHIELD_INVULN_S, 0.001)
    # Simulate timer drain (tick_loop normally does this).
    tank.shield_invuln_remaining = 4.0
    # Move tank onto another shield.
    var second_shield_pos: Vector3 = Vector3.ZERO
    for pid in pm.pickups.keys():
        if int(pm.pickups[pid]["kind"]) == Constants.PICKUP_KIND_SHIELD:
            second_shield_pos = pm.pickups[pid]["pos"]
            break
    tank.pos = second_shield_pos
    pm.step(Constants.TICK_INTERVAL, [tank])
    # No stacking — full reset to PICKUP_SHIELD_INVULN_S, not 4 + 15.
    assert_almost_eq(tank.shield_invuln_remaining, Constants.PICKUP_SHIELD_INVULN_S, 0.001)

func test_dead_tank_does_not_consume() -> void:
    var pm := _make_manager()
    pm.step(Constants.TICK_INTERVAL, [])
    var any_pos: Vector3 = Vector3.ZERO
    var any_id: int = -1
    for pid in pm.pickups.keys():
        any_id = pid
        any_pos = pm.pickups[pid]["pos"]
        break
    var tank := _make_tank(1, any_pos)
    tank.alive = false
    var ev: Dictionary = pm.step(Constants.TICK_INTERVAL, [tank])
    assert_eq(ev["consumed"].size(), 0)
    assert_true(pm.pickups.has(any_id))

func test_one_pickup_consumed_by_one_tank_per_tick() -> void:
    # Two tanks on the same pickup → exactly one of them gets it (the inner
    # break in step() stops scanning once a tank claims a pickup).
    var pm := _make_manager()
    pm.step(Constants.TICK_INTERVAL, [])
    var any_pos: Vector3 = Vector3.ZERO
    for pid in pm.pickups.keys():
        any_pos = pm.pickups[pid]["pos"]
        break
    var t1 := _make_tank(1, any_pos)
    var t2 := _make_tank(2, any_pos)
    var ev: Dictionary = pm.step(Constants.TICK_INTERVAL, [t1, t2])
    assert_eq(ev["consumed"].size(), 1)

func test_active_pickups_returns_current_set() -> void:
    var pm := _make_manager()
    pm.step(Constants.TICK_INTERVAL, [])
    var snapshot: Array = pm.active_pickups()
    assert_eq(snapshot.size(), pm.pickups.size())
    for entry in snapshot:
        assert_true(pm.pickups.has(int(entry["pickup_id"])))
        assert_eq(int(entry["kind"]), int(pm.pickups[int(entry["pickup_id"])]["kind"]))
