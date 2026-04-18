# shared/world/obstacle_placer.gd
class_name ObstaclePlacer

const TerrainGenerator = preload("res://shared/world/terrain_generator.gd")

enum Kind { SMALL_ROCK = 0, LARGE_ROCK = 1, TREE = 2 }

class Obstacle:
    var id: int = 0
    var kind: int = 0  # Kind enum
    var pos: Vector3 = Vector3.ZERO
    var yaw: float = 0.0

# Returns Array[Obstacle] placed deterministically from seed.
# Uses a shifted seed per kind to make counts independently reproducible.
static func place(world_seed: int, hm: PackedFloat32Array, size: int,
        small_rocks: int, large_rocks: int, trees: int) -> Array:
    var result: Array = []
    var id_counter := [1]  # mutable id source
    _place_kind(world_seed ^ 0xA1, hm, size, Kind.SMALL_ROCK, small_rocks, id_counter, result)
    _place_kind(world_seed ^ 0xB2, hm, size, Kind.LARGE_ROCK, large_rocks, id_counter, result)
    _place_kind(world_seed ^ 0xC3, hm, size, Kind.TREE, trees, id_counter, result)
    return result

static func _place_kind(sub_seed: int, hm: PackedFloat32Array, size: int, kind: int,
        count: int, id_counter: Array, out: Array) -> void:
    var rng := RandomNumberGenerator.new()
    rng.seed = sub_seed
    for i in count:
        var o := Obstacle.new()
        o.id = id_counter[0]
        id_counter[0] += 1
        o.kind = kind
        var x := rng.randf() * (float(size) - 1.0)
        var z := rng.randf() * (float(size) - 1.0)
        var y := TerrainGenerator.sample_height(hm, size, x, z)
        o.pos = Vector3(x, y, z)
        o.yaw = rng.randf() * TAU
        out.append(o)
