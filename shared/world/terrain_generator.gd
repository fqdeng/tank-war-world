# shared/world/terrain_generator.gd
class_name TerrainGenerator

# Generates a deterministic heightmap from a seed.
# Returns a PackedFloat32Array of length size*size; value at (x,z) is hm[z*size + x].

static func generate_heightmap(world_seed: int, size: int) -> PackedFloat32Array:
    var noise := FastNoiseLite.new()
    noise.seed = world_seed
    noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
    noise.fractal_type = FastNoiseLite.FRACTAL_FBM
    noise.fractal_octaves = Constants.NOISE_OCTAVES
    noise.frequency = Constants.NOISE_FREQUENCY

    var result := PackedFloat32Array()
    result.resize(size * size)
    for z in size:
        for x in size:
            var n := noise.get_noise_2d(float(x), float(z))  # -1..1
            var h := (n + 1.0) * 0.5 * Constants.HEIGHT_MAX_M  # 0..HEIGHT_MAX_M
            result[z * size + x] = h
    return result

# Bilinear sample of the heightmap at world coords (x, z in meters).
# Heightmap assumed to span [0..size] in world units with 1 vert / unit.
static func sample_height(hm: PackedFloat32Array, size: int, x: float, z: float) -> float:
    x = clamp(x, 0.0, float(size) - 1.001)
    z = clamp(z, 0.0, float(size) - 1.001)
    var x0 := int(floor(x))
    var z0 := int(floor(z))
    var x1 := x0 + 1
    var z1 := z0 + 1
    var fx := x - float(x0)
    var fz := z - float(z0)
    var h00: float = hm[z0 * size + x0]
    var h10: float = hm[z0 * size + x1]
    var h01: float = hm[z1 * size + x0]
    var h11: float = hm[z1 * size + x1]
    var h0: float = lerp(h00, h10, fx)
    var h1: float = lerp(h01, h11, fx)
    return lerp(h0, h1, fz)
