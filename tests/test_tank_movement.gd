extends GutTest

const TankState = preload("res://shared/tank/tank_state.gd")
const TankMovement = preload("res://shared/tank/tank_movement.gd")

func _make_input(fwd: float, turn: float) -> Dictionary:
    return {"move_forward": fwd, "move_turn": turn}

func test_forward_input_accelerates() -> void:
    var s := TankState.new()
    s.pos = Vector3.ZERO
    s.yaw = 0.0
    s.speed = 0.0
    TankMovement.step(s, _make_input(1.0, 0.0), 0.1)
    assert_gt(s.speed, 0.0, "Speed should increase with forward input")
    assert_gt(s.pos.length(), 0.0, "Position should change")

func test_no_input_decelerates() -> void:
    var s := TankState.new()
    s.speed = 5.0
    s.pos = Vector3.ZERO
    TankMovement.step(s, _make_input(0.0, 0.0), 0.1)
    assert_lt(s.speed, 5.0, "Speed should decrease with no input")

func test_turn_input_rotates() -> void:
    var s := TankState.new()
    s.yaw = 0.0
    TankMovement.step(s, _make_input(0.0, 1.0), 0.1)
    assert_gt(s.yaw, 0.0, "Yaw should increase with right turn input")

func test_speed_capped_at_max() -> void:
    var s := TankState.new()
    s.speed = 1000.0
    TankMovement.step(s, _make_input(1.0, 0.0), 0.1)
    assert_lte(s.speed, Constants.TANK_MAX_SPEED_MS + 0.01)

func test_reverse_input_moves_backwards() -> void:
    var s := TankState.new()
    s.pos = Vector3.ZERO
    s.yaw = 0.0
    TankMovement.step(s, _make_input(-1.0, 0.0), 0.1)
    assert_lt(s.speed, 0.0)
    # With -Z = forward convention, reverse moves to +Z
    assert_gt(s.pos.z, 0.0, "Reversing while facing -Z should move to +Z")
