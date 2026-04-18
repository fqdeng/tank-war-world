# client/camera/third_person_cam.gd
extends Camera3D

const TerrainGenerator = preload("res://shared/world/terrain_generator.gd")

@export var distance: float = 12.0
@export var height: float = 5.0
@export var smooth: float = 8.0
@export var min_clearance_above_terrain: float = 2.5

var _target: Node3D
# Optional heightmap to keep the camera above terrain.
var _heightmap: PackedFloat32Array
var _terrain_size: int = 0

func set_target(t: Node3D) -> void:
    _target = t

func set_heightmap(hm: PackedFloat32Array, size: int) -> void:
    _heightmap = hm
    _terrain_size = size

func _process(delta: float) -> void:
    if _target == null:
        return
    var yaw: float = _target.rotation.y
    var behind := Vector3(sin(yaw), 0, cos(yaw)) * distance
    var desired: Vector3 = _target.global_position + behind + Vector3(0, height, 0)
    # Lift above terrain if heightmap is available
    if _heightmap.size() > 0 and _terrain_size > 0:
        var th: float = TerrainGenerator.sample_height(_heightmap, _terrain_size, desired.x, desired.z)
        if desired.y < th + min_clearance_above_terrain:
            desired.y = th + min_clearance_above_terrain
    global_position = global_position.lerp(desired, clamp(smooth * delta, 0, 1))
    look_at(_target.global_position + Vector3(0, 1.5, 0), Vector3.UP)
