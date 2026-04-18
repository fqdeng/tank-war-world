extends GutTest

const Ballistics = preload("res://shared/combat/ballistics.gd")

func test_position_at_t0_equals_origin() -> void:
    var p := Ballistics.position_at(Vector3(10, 20, 30), Vector3(100, 0, 0), 0.0)
    assert_almost_eq(p.x, 10.0, 0.001)
    assert_almost_eq(p.y, 20.0, 0.001)
    assert_almost_eq(p.z, 30.0, 0.001)

func test_gravity_pulls_down_over_time() -> void:
    var p1 := Ballistics.position_at(Vector3.ZERO, Vector3(0, 0, -100), 1.0)
    var p2 := Ballistics.position_at(Vector3.ZERO, Vector3(0, 0, -100), 2.0)
    assert_almost_eq(p1.y, -4.9, 0.01)
    assert_almost_eq(p2.y, -19.6, 0.01)

func test_horizontal_motion_unaffected_by_gravity() -> void:
    var p := Ballistics.position_at(Vector3.ZERO, Vector3(50, 0, 0), 2.0)
    assert_almost_eq(p.x, 100.0, 0.001)
    assert_almost_eq(p.z, 0.0, 0.001)

func test_initial_velocity_magnitude() -> void:
    var v := Ballistics.initial_velocity(0.0, 0.0, 450.0)
    assert_almost_eq(v.length(), 450.0, 0.1)

func test_initial_velocity_zero_yaw_faces_negative_z() -> void:
    var v := Ballistics.initial_velocity(0.0, 0.0, 100.0)
    assert_almost_eq(v.x, 0.0, 0.1)
    assert_almost_eq(v.y, 0.0, 0.1)
    assert_almost_eq(v.z, -100.0, 0.1)

func test_initial_velocity_positive_pitch_goes_up() -> void:
    var v := Ballistics.initial_velocity(0.0, deg_to_rad(30.0), 100.0)
    assert_gt(v.y, 0.0)
    assert_lt(v.z, 0.0)

func test_velocity_at_loses_vertical_component() -> void:
    var v0 := Vector3(10, 50, 0)
    var v1 := Ballistics.velocity_at(v0, 2.0)
    assert_almost_eq(v1.x, 10.0, 0.001)
    assert_almost_eq(v1.y, 50.0 - 2.0 * 9.8, 0.01)
