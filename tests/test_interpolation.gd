extends GutTest

const Interpolation = preload("res://client/tank/interpolation.gd")

func test_empty_buffer_returns_null() -> void:
    var interp := Interpolation.new()
    assert_null(interp.sample(1000))

func test_single_snapshot_returns_itself() -> void:
    var interp := Interpolation.new()
    interp.push_snapshot(1000, Vector3(10, 0, 20), 0.5, 0.0, 0.0, 900)
    var r = interp.sample(2000)
    assert_almost_eq(r["pos"].x, 10.0, 0.001)

func test_interpolation_between_two_snapshots() -> void:
    var interp := Interpolation.new()
    interp.push_snapshot(1000, Vector3(0, 0, 0), 0.0, 0.0, 0.0, 900)
    interp.push_snapshot(2000, Vector3(100, 0, 200), 1.0, 0.0, 0.0, 900)
    # sample at t=1500 with delay=100 → target=1400 → 40% between 1000 and 2000
    var r = interp.sample(1500)
    assert_almost_eq(r["pos"].x, 40.0, 0.01)
    assert_almost_eq(r["pos"].z, 80.0, 0.01)

func test_sample_before_first_returns_oldest() -> void:
    var interp := Interpolation.new()
    interp.push_snapshot(1000, Vector3(10, 0, 20), 0.0, 0.0, 0.0, 900)
    interp.push_snapshot(2000, Vector3(100, 0, 200), 0.0, 0.0, 0.0, 900)
    var r = interp.sample(500)
    assert_almost_eq(r["pos"].x, 10.0, 0.001)

func test_buffer_capped() -> void:
    var interp := Interpolation.new()
    for i in 40:
        interp.push_snapshot(i * 50, Vector3(i, 0, 0), 0.0, 0.0, 0.0, 900)
    var r = interp.sample(40 * 50 + 50)
    assert_almost_eq(r["pos"].x, 39.0, 0.001)

func test_set_delay_ms_clamps_and_affects_sample() -> void:
    var interp := Interpolation.new()
    # Delay should clamp into [60, 300] so an off-the-charts value doesn't
    # produce negative or unbounded target_t.
    interp.set_delay_ms(5)
    assert_eq(interp.get_delay_ms(), 60)
    interp.set_delay_ms(9999)
    assert_eq(interp.get_delay_ms(), 300)
    # Two snapshots at t=1000/2000; sample at now_ms=1500 with two different
    # delays — a larger delay shifts target_t earlier, yielding earlier pos.
    #   delay=100 → target=1400 → 40% between 1000 and 2000 → pos.x=40
    #   delay=200 → target=1300 → 30% → pos.x=30
    interp.push_snapshot(1000, Vector3(0, 0, 0), 0.0, 0.0, 0.0, 900)
    interp.push_snapshot(2000, Vector3(100, 0, 200), 0.0, 0.0, 0.0, 900)
    interp.set_delay_ms(100)
    var r1 = interp.sample(1500)
    assert_almost_eq(r1["pos"].x, 40.0, 0.01)
    interp.set_delay_ms(200)
    var r2 = interp.sample(1500)
    assert_almost_eq(r2["pos"].x, 30.0, 0.01)
