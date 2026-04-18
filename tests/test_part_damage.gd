extends GutTest

const PartDamage = preload("res://shared/combat/part_damage.gd")
const TankState = preload("res://shared/tank/tank_state.gd")

func _make_tank() -> TankState:
    var t := TankState.new()
    t.initialize_parts(Constants.TANK_MAX_HP)
    t.alive = true
    return t

func test_hull_hit_applies_1x_multiplier() -> void:
    var t := _make_tank()
    var result := PartDamage.apply(t, TankState.Part.HULL, 100)
    assert_almost_eq(result.actual_damage, 100.0, 0.01)

func test_top_hit_applies_2_5x_multiplier() -> void:
    var t := _make_tank()
    var result := PartDamage.apply(t, TankState.Part.TOP, 100)
    assert_almost_eq(result.actual_damage, 250.0, 0.01)

func test_part_destruction_flagged() -> void:
    var t := _make_tank()
    # TOP has 10% of 900 = 90 HP, mult 2.5; 40 base → 100 dmg, overkills
    var result := PartDamage.apply(t, TankState.Part.TOP, 40)
    assert_true(result.part_just_destroyed)

func test_top_destruction_kills_tank() -> void:
    var t := _make_tank()
    var result := PartDamage.apply(t, TankState.Part.TOP, 1000)
    assert_true(result.tank_just_destroyed)
    assert_false(t.alive)

func test_hull_destruction_kills_tank() -> void:
    var t := _make_tank()
    # HULL 40% of 900 = 360; 1x; 400 base = 400 dmg → destroyed
    var result := PartDamage.apply(t, TankState.Part.HULL, 400)
    assert_true(result.tank_just_destroyed)

func test_track_destruction_does_not_kill() -> void:
    var t := _make_tank()
    # L-TRACK 10% of 900 = 90; 0.8x; 200 base = 160 dmg → destroyed track but alive
    var result := PartDamage.apply(t, TankState.Part.LEFT_TRACK, 200)
    assert_true(result.part_just_destroyed)
    assert_false(result.tank_just_destroyed)
    assert_true(t.alive)
    assert_false(t.left_track_ok())

func test_total_hp_recomputed_as_sum() -> void:
    var t := _make_tank()
    PartDamage.apply(t, TankState.Part.HULL, 50)
    var expected: float = Constants.TANK_MAX_HP - 50
    assert_eq(t.hp, int(round(expected)))

func test_applying_to_dead_tank_is_noop() -> void:
    var t := _make_tank()
    t.alive = false
    var result := PartDamage.apply(t, TankState.Part.HULL, 100)
    assert_almost_eq(result.actual_damage, 0.0, 0.01)
