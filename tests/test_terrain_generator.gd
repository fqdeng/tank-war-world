extends GutTest

const TerrainGenerator = preload("res://shared/world/terrain_generator.gd")

func test_same_seed_produces_same_heightmap() -> void:
    var a := TerrainGenerator.generate_heightmap(42, 64)
    var b := TerrainGenerator.generate_heightmap(42, 64)
    assert_eq(a.size(), 64 * 64)
    assert_eq(b.size(), 64 * 64)
    for i in range(0, a.size(), 250):
        assert_almost_eq(a[i], b[i], 0.0001, "Mismatch at index %d" % i)

func test_different_seed_produces_different_heightmap() -> void:
    var a := TerrainGenerator.generate_heightmap(42, 64)
    var b := TerrainGenerator.generate_heightmap(43, 64)
    var differs := false
    for i in a.size():
        if abs(a[i] - b[i]) > 0.5:
            differs = true
            break
    assert_true(differs, "Different seeds should yield different heightmaps")

func test_height_within_range() -> void:
    var hm := TerrainGenerator.generate_heightmap(7, 64)
    for h in hm:
        assert_true(h >= 0.0 and h <= 50.0, "Height %f out of [0,50]" % h)

func test_sample_height_bilinear() -> void:
    var hm := TerrainGenerator.generate_heightmap(1, 64)
    var h_center := TerrainGenerator.sample_height(hm, 64, 32.0, 32.0)
    assert_true(h_center >= 0.0 and h_center <= 50.0)
    var h_edge := TerrainGenerator.sample_height(hm, 64, -10.0, 100.0)
    assert_true(h_edge >= 0.0 and h_edge <= 50.0)
