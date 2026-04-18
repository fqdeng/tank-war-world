extends GutTest

const ObstaclePlacer = preload("res://shared/world/obstacle_placer.gd")
const TerrainGenerator = preload("res://shared/world/terrain_generator.gd")

func _make_terrain() -> Dictionary:
    return {"hm": TerrainGenerator.generate_heightmap(5, 128), "size": 128}

func test_same_seed_same_obstacles() -> void:
    var t := _make_terrain()
    var a := ObstaclePlacer.place(5, t["hm"], t["size"], 50, 20, 30)
    var b := ObstaclePlacer.place(5, t["hm"], t["size"], 50, 20, 30)
    assert_eq(a.size(), b.size())
    for i in a.size():
        assert_eq(a[i].kind, b[i].kind)
        assert_almost_eq(a[i].pos.x, b[i].pos.x, 0.001)
        assert_almost_eq(a[i].pos.z, b[i].pos.z, 0.001)

func test_counts_match_request() -> void:
    var t := _make_terrain()
    var obs := ObstaclePlacer.place(9, t["hm"], t["size"], 50, 20, 30)
    var counts := {0: 0, 1: 0, 2: 0}
    for o in obs:
        counts[o.kind] += 1
    assert_eq(counts[0], 50, "small rocks")
    assert_eq(counts[1], 20, "large rocks")
    assert_eq(counts[2], 30, "trees")

func test_positions_sit_on_terrain() -> void:
    var t := _make_terrain()
    var obs := ObstaclePlacer.place(11, t["hm"], t["size"], 10, 0, 0)
    for o in obs:
        var h := TerrainGenerator.sample_height(t["hm"], t["size"], o.pos.x, o.pos.z)
        assert_almost_eq(o.pos.y, h, 0.01, "Obstacle y should equal terrain height at its xz")

func test_each_obstacle_has_unique_id() -> void:
    var t := _make_terrain()
    var obs := ObstaclePlacer.place(1, t["hm"], t["size"], 10, 5, 10)
    var ids := {}
    for o in obs:
        assert_false(ids.has(o.id), "Duplicate id %d" % o.id)
        ids[o.id] = true
