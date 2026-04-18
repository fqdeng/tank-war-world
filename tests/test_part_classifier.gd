extends GutTest

const PartClassifier = preload("res://shared/combat/part_classifier.gd")
const TankState = preload("res://shared/tank/tank_state.gd")

func test_front_hit_at_center_is_hull() -> void:
    var p := PartClassifier.classify(Vector3.ZERO, 0.0, Vector3(0, 1, -2))
    assert_eq(p, TankState.Part.HULL)

func test_top_hit_is_top() -> void:
    var p := PartClassifier.classify(Vector3.ZERO, 0.0, Vector3(0, 3, 0))
    assert_eq(p, TankState.Part.TOP)

func test_turret_center_is_turret() -> void:
    var p := PartClassifier.classify(Vector3.ZERO, 0.0, Vector3(0, 1.6, 0))
    assert_eq(p, TankState.Part.TURRET)

func test_left_side_low_is_left_track() -> void:
    var p := PartClassifier.classify(Vector3.ZERO, 0.0, Vector3(-1.5, 0.5, 0))
    assert_eq(p, TankState.Part.LEFT_TRACK)

func test_right_side_low_is_right_track() -> void:
    var p := PartClassifier.classify(Vector3.ZERO, 0.0, Vector3(1.5, 0.5, 0))
    assert_eq(p, TankState.Part.RIGHT_TRACK)

func test_rear_hit_is_engine() -> void:
    var p := PartClassifier.classify(Vector3.ZERO, 0.0, Vector3(0, 0.5, 2.0))
    assert_eq(p, TankState.Part.ENGINE)

func test_rotation_applied_correctly() -> void:
    # Rotated 180° (faces +Z). Hit from world +Z is "front" of tank → hull.
    var p := PartClassifier.classify(Vector3.ZERO, PI, Vector3(0, 1, 2))
    assert_eq(p, TankState.Part.HULL)

func test_tank_at_offset() -> void:
    var p := PartClassifier.classify(Vector3(100, 0, 100), 0.0, Vector3(100, 1, 98))
    assert_eq(p, TankState.Part.HULL)
