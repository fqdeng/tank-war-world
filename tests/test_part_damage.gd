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
    # TOP has 10% of MAX_HP (1000 → 100) HP at 2.5x; base 100 → 250 dmg destroys it.
    var result := PartDamage.apply(t, TankState.Part.TOP, 100)
    assert_true(result.part_just_destroyed)

func test_top_destruction_does_not_kill_tank() -> void:
    var t := _make_tank()
    # Part destruction breaks the part (functional) but does not insta-kill.
    var result := PartDamage.apply(t, TankState.Part.TOP, 100)  # 250 dmg, > TOP's 100 cap
    assert_true(result.part_just_destroyed)
    assert_false(result.tank_just_destroyed)
    assert_true(t.alive)

func test_hull_destruction_does_not_kill_tank() -> void:
    var t := _make_tank()
    # Overkill hull alone — tank should still be alive (total hp > 0).
    # HULL has 400 HP at 1.0x. Base 900 → 900 dmg, HULL capped at 0 but state.hp
    # only drops by 900 from 1000 → 100 (alive).
    var result := PartDamage.apply(t, TankState.Part.HULL, 900)
    assert_true(result.part_just_destroyed)
    assert_false(result.tank_just_destroyed)
    assert_true(t.alive)

func test_track_destruction_does_not_kill() -> void:
    var t := _make_tank()
    # L-TRACK 10% of MAX_HP (1000 → 100) at 0.8x; base 300 → 240 dmg destroys it.
    var result := PartDamage.apply(t, TankState.Part.LEFT_TRACK, 300)
    assert_true(result.part_just_destroyed)
    assert_false(result.tank_just_destroyed)
    assert_true(t.alive)
    assert_false(t.left_track_ok())

func test_tank_dies_when_total_hp_depleted() -> void:
    var t := _make_tank()
    # Hammer the hull repeatedly — parts cap at 0, but total hp still drops
    # by the full scaled damage each hit (decoupled accumulator).
    # At 260 × 1.0 = 260 per hit, 4 hits = 1040 > 1000 total HP.
    for i in 3:
        var r := PartDamage.apply(t, TankState.Part.HULL, 260)
        assert_false(r.tank_just_destroyed)
    assert_true(t.alive)
    var result := PartDamage.apply(t, TankState.Part.HULL, 260)
    assert_true(result.tank_just_destroyed)
    assert_false(t.alive)
    assert_eq(t.hp, 0)

func test_total_hp_drops_through_destroyed_part() -> void:
    var t := _make_tank()
    # First hit destroys L-TRACK (100 HP × 0.8 mult on 300 base = 240 dmg).
    PartDamage.apply(t, TankState.Part.LEFT_TRACK, 300)
    var after_break: int = t.hp
    # Second hit on the same destroyed part: part stays at 0, but total hp
    # must still decrease (this is the decoupling invariant).
    PartDamage.apply(t, TankState.Part.LEFT_TRACK, 300)
    assert_lt(t.hp, after_break)

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
