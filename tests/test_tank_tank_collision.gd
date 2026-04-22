extends GutTest

const TankCollision = preload("res://shared/world/tank_collision.gd")

func _other(id: int, pos: Vector3, alive: bool = true) -> Dictionary:
    return {"id": id, "pos": pos, "alive": alive}

func test_no_push_when_well_separated() -> void:
    var self_pos := Vector3(0, 0, 0)
    var others := [_other(2, Vector3(10, 0, 0))]
    var push := TankCollision.resolve_tank_push(self_pos, 1, others)
    assert_almost_eq(push.x, 0.0, 1e-4)
    assert_almost_eq(push.z, 0.0, 1e-4)

func test_no_push_at_exact_boundary() -> void:
    var min_d: float = 2.0 * Constants.TANK_COLLISION_RADIUS
    var self_pos := Vector3(0, 0, 0)
    var others := [_other(2, Vector3(min_d, 0, 0))]
    var push := TankCollision.resolve_tank_push(self_pos, 1, others)
    assert_almost_eq(push.x, 0.0, 1e-4)
    assert_almost_eq(push.z, 0.0, 1e-4)

func test_push_magnitude_equals_overlap() -> void:
    var r: float = Constants.TANK_COLLISION_RADIUS
    # Two tanks 1R apart on +x => overlap = 2R - R = R, pushed in -x for self at origin
    var self_pos := Vector3(0, 0, 0)
    var others := [_other(2, Vector3(r, 0, 0))]
    var push := TankCollision.resolve_tank_push(self_pos, 1, others)
    assert_almost_eq(push.x, -r, 1e-4)
    assert_almost_eq(push.z, 0.0, 1e-4)

func test_push_direction_points_away_from_other() -> void:
    # Other is diagonally ahead; push should be roughly opposite
    var self_pos := Vector3(0, 0, 0)
    var others := [_other(2, Vector3(1.0, 0, 1.0))]
    var push := TankCollision.resolve_tank_push(self_pos, 1, others)
    assert_lt(push.x, 0.0, "push.x should point away from +x other")
    assert_lt(push.z, 0.0, "push.z should point away from +z other")

func test_degenerate_overlap_pushes_along_positive_x() -> void:
    var self_pos := Vector3(0, 0, 0)
    var others := [_other(2, Vector3(0, 0, 0))]
    var push := TankCollision.resolve_tank_push(self_pos, 1, others)
    var min_d: float = 2.0 * Constants.TANK_COLLISION_RADIUS
    assert_almost_eq(push.x, min_d, 1e-4)
    assert_almost_eq(push.z, 0.0, 1e-4)

func test_self_id_skipped() -> void:
    var self_pos := Vector3(0, 0, 0)
    var others := [_other(1, Vector3(0.1, 0, 0))]  # same id as self
    var push := TankCollision.resolve_tank_push(self_pos, 1, others)
    assert_almost_eq(push.x, 0.0, 1e-4)
    assert_almost_eq(push.z, 0.0, 1e-4)

func test_dead_tanks_skipped() -> void:
    var self_pos := Vector3(0, 0, 0)
    var others := [_other(2, Vector3(0.5, 0, 0), false)]
    var push := TankCollision.resolve_tank_push(self_pos, 1, others)
    assert_almost_eq(push.x, 0.0, 1e-4)
    assert_almost_eq(push.z, 0.0, 1e-4)

func test_multiple_tanks_accumulate() -> void:
    var r: float = Constants.TANK_COLLISION_RADIUS
    var self_pos := Vector3(0, 0, 0)
    # Two overlapping others, equidistant on +x and +z at distance r
    var others := [
        _other(2, Vector3(r, 0, 0)),
        _other(3, Vector3(0, 0, r)),
    ]
    var push := TankCollision.resolve_tank_push(self_pos, 1, others)
    assert_almost_eq(push.x, -r, 1e-4)
    assert_almost_eq(push.z, -r, 1e-4)

func test_symmetric_push() -> void:
    var r: float = Constants.TANK_COLLISION_RADIUS
    var a := Vector3(0, 0, 0)
    var b := Vector3(r, 0, 0)
    var push_a := TankCollision.resolve_tank_push(a, 1, [_other(2, b)])
    var push_b := TankCollision.resolve_tank_push(b, 2, [_other(1, a)])
    assert_almost_eq(push_a.x, -push_b.x, 1e-4)
    assert_almost_eq(push_a.z, -push_b.z, 1e-4)
