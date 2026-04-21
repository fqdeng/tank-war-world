# client/world/terrain_builder.gd
extends Node3D

const TerrainGenerator = preload("res://shared/world/terrain_generator.gd")

var heightmap: PackedFloat32Array
var terrain_size: int

# Drop any previously-built terrain mesh so build() can be called again after
# a match restart without stacking meshes.
func reset() -> void:
    for child in get_children():
        child.queue_free()
    heightmap = PackedFloat32Array()
    terrain_size = 0

func build(world_seed: int) -> void:
    terrain_size = Constants.WORLD_SIZE_M
    heightmap = TerrainGenerator.generate_heightmap(world_seed, terrain_size)
    # Reduced-resolution visual mesh (8m grid) for Web performance.
    var step := 8
    var verts_per_side := terrain_size / step + 1
    var st := SurfaceTool.new()
    st.begin(Mesh.PRIMITIVE_TRIANGLES)
    for z in verts_per_side:
        for x in verts_per_side:
            var wx := x * step
            var wz := z * step
            var wh: float = TerrainGenerator.sample_height(heightmap, terrain_size, float(wx), float(wz))
            st.set_uv(Vector2(float(wx) / terrain_size, float(wz) / terrain_size))
            st.add_vertex(Vector3(wx, wh, wz))
    for z in verts_per_side - 1:
        for x in verts_per_side - 1:
            var i00: int = z * verts_per_side + x
            var i10: int = z * verts_per_side + x + 1
            var i01: int = (z + 1) * verts_per_side + x
            var i11: int = (z + 1) * verts_per_side + x + 1
            st.add_index(i00); st.add_index(i01); st.add_index(i10)
            st.add_index(i10); st.add_index(i01); st.add_index(i11)
    st.generate_normals()
    var mesh := st.commit()
    var mi := MeshInstance3D.new()
    mi.mesh = mesh
    var mat := StandardMaterial3D.new()
    mat.albedo_color = Color(0.35, 0.5, 0.28)
    mat.roughness = 1.0
    # Render both sides so the ground doesn't look "see-through" when the
    # camera dips below terrain height (inside hills, behind slopes).
    mat.cull_mode = BaseMaterial3D.CULL_DISABLED
    mi.material_override = mat
    add_child(mi)
