# client/world/pickup_view.gd
#
# Holds and renders all currently-alive pickups (hearts + shields). The server
# is authoritative — this node never decides spawning or consumption, it just
# mirrors PICKUP_SPAWNED / PICKUP_CONSUMED broadcasts (and the initial set
# delivered via CONNECT_ACK).
#
# Visuals: deliberately distinctive primitive meshes so they're recognizable at
# distance without needing custom assets / emoji glyphs.
#   heart  → red emissive sphere (slightly squashed)
#   shield → cyan emissive disc (cylinder, very flat)
# Both bob + spin slowly so they read as collectibles vs world geometry.
extends Node3D

const TerrainGenerator = preload("res://shared/world/terrain_generator.gd")

# pickup_id → Node3D
var _nodes: Dictionary = {}
# Wall-clock seconds since this view was created — drives bob/spin so all pickups
# share a phase and the animation is independent of per-pickup spawn time.
var _t: float = 0.0

# Heightmap so we can plant pickups on the terrain even though server already
# sent a y — server's y is sampled from the same heightmap so this is mostly
# defensive (and lets us recover if pos.y was rounded).
var _heightmap: PackedFloat32Array
var _terrain_size: int = 0

# Vertical hover above terrain so the pickup floats clearly off the ground.
const HOVER_BASE_Y: float = 1.6
const BOB_AMPLITUDE: float = 0.25
const BOB_SPEED: float = 2.2
const SPIN_SPEED: float = 1.5

func set_terrain(hm: PackedFloat32Array, size: int) -> void:
    _heightmap = hm
    _terrain_size = size

# Drop every live pickup node without playing the consume tween — used on
# match restart to clear the field before the new terrain is swapped in.
func reset() -> void:
    for pid in _nodes.keys():
        var n: Node3D = _nodes[pid]
        if is_instance_valid(n):
            n.queue_free()
    _nodes.clear()

func spawn(pickup_id: int, kind: int, pos: Vector3) -> void:
    if _nodes.has(pickup_id):
        return
    var n: Node3D = _build_node(kind)
    var ground_y: float = pos.y
    if _heightmap.size() > 0:
        ground_y = TerrainGenerator.sample_height(_heightmap, _terrain_size, pos.x, pos.z)
    n.position = Vector3(pos.x, ground_y + HOVER_BASE_Y, pos.z)
    n.set_meta("ground_y", ground_y)
    add_child(n)
    _nodes[pickup_id] = n

func consume(pickup_id: int) -> void:
    if not _nodes.has(pickup_id):
        return
    var n: Node3D = _nodes[pickup_id]
    _nodes.erase(pickup_id)
    # Quick burst tween so consumption reads as "popped", not "vanished".
    var tw := n.create_tween()
    tw.set_parallel(true)
    tw.tween_property(n, "scale", Vector3(2.4, 2.4, 2.4), 0.18)
    tw.tween_property(n, "modulate", Color(1, 1, 1, 0), 0.18)
    tw.chain().tween_callback(n.queue_free)

func _process(delta: float) -> void:
    _t += delta
    var bob: float = sin(_t * BOB_SPEED) * BOB_AMPLITUDE
    for pid in _nodes:
        var n: Node3D = _nodes[pid]
        var ground_y: float = float(n.get_meta("ground_y", 0.0))
        n.position.y = ground_y + HOVER_BASE_Y + bob
        n.rotation.y = _t * SPIN_SPEED

func _build_node(kind: int) -> Node3D:
    if kind == Constants.PICKUP_KIND_HEART:
        return _build_heart()
    return _build_shield()

func _build_heart() -> Node3D:
    var n := Node3D.new()
    var mi := MeshInstance3D.new()
    var sphere := SphereMesh.new()
    sphere.radius = 0.65
    sphere.height = 1.3
    mi.mesh = sphere
    mi.scale = Vector3(1.0, 0.85, 1.0)
    var mat := StandardMaterial3D.new()
    mat.albedo_color = Color(1.0, 0.18, 0.32)
    mat.emission_enabled = true
    mat.emission = Color(1.0, 0.05, 0.18)
    mat.emission_energy_multiplier = 1.6
    mat.roughness = 0.4
    mi.material_override = mat
    n.add_child(mi)
    return n

func _build_shield() -> Node3D:
    var n := Node3D.new()
    var mi := MeshInstance3D.new()
    var disc := CylinderMesh.new()
    disc.top_radius = 0.85
    disc.bottom_radius = 0.85
    disc.height = 0.18
    mi.mesh = disc
    mi.rotation = Vector3(PI / 2, 0, 0)  # stand the disc upright so the face reads as a shield, not a coin
    var mat := StandardMaterial3D.new()
    mat.albedo_color = Color(0.25, 0.7, 1.0)
    mat.emission_enabled = true
    mat.emission = Color(0.15, 0.55, 1.0)
    mat.emission_energy_multiplier = 1.8
    mat.metallic = 0.6
    mat.roughness = 0.25
    mi.material_override = mat
    n.add_child(mi)
    return n
