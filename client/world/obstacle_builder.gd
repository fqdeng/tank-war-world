# client/world/obstacle_builder.gd
extends Node3D

const ObstaclePlacer = preload("res://shared/world/obstacle_placer.gd")

# obstacle_id → Node3D (only for currently-alive obstacles)
var _nodes: Dictionary = {}

func build(world_seed: int, heightmap: PackedFloat32Array, terrain_size: int, already_destroyed: PackedInt32Array = PackedInt32Array()) -> void:
    var destroyed: Dictionary = {}
    for oid in already_destroyed:
        destroyed[oid] = true
    var obs := ObstaclePlacer.place(
        world_seed, heightmap, terrain_size,
        Constants.SMALL_ROCK_COUNT,
        Constants.LARGE_ROCK_COUNT,
        Constants.TREE_COUNT,
    )
    for o in obs:
        if destroyed.has(o.id):
            continue
        var node := _make_node(o)
        node.position = o.pos
        node.rotation.y = o.yaw
        add_child(node)
        _nodes[o.id] = node

func destroy_obstacle(id: int) -> void:
    if not _nodes.has(id):
        return
    var node: Node3D = _nodes[id]
    _nodes.erase(id)
    _play_destruction(node)

func _play_destruction(node: Node3D) -> void:
    var tw := node.create_tween()
    tw.set_parallel(true)
    tw.tween_property(node, "scale", Vector3(0.1, 0.1, 0.1), 0.4)
    tw.tween_property(node, "position:y", node.position.y - 1.0, 0.4)
    tw.chain().tween_callback(node.queue_free)

func _make_node(o) -> Node3D:
    var n := Node3D.new()
    match o.kind:
        0:  # SMALL_ROCK
            var mi := MeshInstance3D.new()
            var m := BoxMesh.new()
            m.size = Vector3(3.2, 2.4, 3.2)
            mi.mesh = m
            var mat := StandardMaterial3D.new()
            mat.albedo_color = Color(0.55, 0.52, 0.5)
            mat.roughness = 1.0
            mi.material_override = mat
            mi.position.y = 1.2
            n.add_child(mi)
        1:  # LARGE_ROCK
            var mi := MeshInstance3D.new()
            var m := BoxMesh.new()
            m.size = Vector3(7.0, 5.0, 7.0)
            mi.mesh = m
            var mat := StandardMaterial3D.new()
            mat.albedo_color = Color(0.45, 0.42, 0.4)
            mat.roughness = 1.0
            mi.material_override = mat
            mi.position.y = 2.5
            n.add_child(mi)
        2:  # TREE
            var trunk := MeshInstance3D.new()
            var trunk_mesh := CylinderMesh.new()
            trunk_mesh.top_radius = 0.5
            trunk_mesh.bottom_radius = 0.7
            trunk_mesh.height = 6.0
            trunk.mesh = trunk_mesh
            var trunk_mat := StandardMaterial3D.new()
            trunk_mat.albedo_color = Color(0.35, 0.22, 0.12)
            trunk_mat.roughness = 1.0
            trunk.material_override = trunk_mat
            trunk.position.y = 3.0
            n.add_child(trunk)
            var crown := MeshInstance3D.new()
            var crown_mesh := BoxMesh.new()
            crown_mesh.size = Vector3(5.0, 5.0, 5.0)
            crown.mesh = crown_mesh
            var crown_mat := StandardMaterial3D.new()
            crown_mat.albedo_color = Color(0.2, 0.45, 0.22)
            crown_mat.roughness = 1.0
            crown.material_override = crown_mat
            crown.position.y = 8.0
            n.add_child(crown)
    return n
