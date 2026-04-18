# client/world/obstacle_builder.gd
extends Node3D

const ObstaclePlacer = preload("res://shared/world/obstacle_placer.gd")

func build(world_seed: int, heightmap: PackedFloat32Array, terrain_size: int) -> void:
    var obs := ObstaclePlacer.place(
        world_seed, heightmap, terrain_size,
        Constants.SMALL_ROCK_COUNT,
        Constants.LARGE_ROCK_COUNT,
        Constants.TREE_COUNT,
    )
    for o in obs:
        var node := _make_node(o)
        node.position = o.pos
        node.rotation.y = o.yaw
        add_child(node)

func _make_node(o) -> Node3D:
    var n := Node3D.new()
    match o.kind:
        0:  # SMALL_ROCK
            var mi := MeshInstance3D.new()
            var m := BoxMesh.new()
            m.size = Vector3(1.6, 1.2, 1.6)
            mi.mesh = m
            var mat := StandardMaterial3D.new()
            mat.albedo_color = Color(0.55, 0.52, 0.5)
            mat.roughness = 1.0
            mi.material_override = mat
            mi.position.y = 0.6
            n.add_child(mi)
        1:  # LARGE_ROCK
            var mi := MeshInstance3D.new()
            var m := BoxMesh.new()
            m.size = Vector3(3.5, 2.6, 3.5)
            mi.mesh = m
            var mat := StandardMaterial3D.new()
            mat.albedo_color = Color(0.45, 0.42, 0.4)
            mat.roughness = 1.0
            mi.material_override = mat
            mi.position.y = 1.3
            n.add_child(mi)
        2:  # TREE
            var trunk := MeshInstance3D.new()
            var trunk_mesh := CylinderMesh.new()
            trunk_mesh.top_radius = 0.25
            trunk_mesh.bottom_radius = 0.35
            trunk_mesh.height = 3.0
            trunk.mesh = trunk_mesh
            var trunk_mat := StandardMaterial3D.new()
            trunk_mat.albedo_color = Color(0.35, 0.22, 0.12)
            trunk_mat.roughness = 1.0
            trunk.material_override = trunk_mat
            trunk.position.y = 1.5
            n.add_child(trunk)
            var crown := MeshInstance3D.new()
            var crown_mesh := BoxMesh.new()
            crown_mesh.size = Vector3(2.6, 2.6, 2.6)
            crown.mesh = crown_mesh
            var crown_mat := StandardMaterial3D.new()
            crown_mat.albedo_color = Color(0.2, 0.45, 0.22)
            crown_mat.roughness = 1.0
            crown.material_override = crown_mat
            crown.position.y = 4.2
            n.add_child(crown)
    return n
