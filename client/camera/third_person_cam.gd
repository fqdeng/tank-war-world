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
    # Use the visually-interpolated transform so the camera tracks the smoothed
    # render pose (not the raw physics-tick pose that jumps at 60Hz).
    var tgt_xf: Transform3D = _target.get_global_transform_interpolated()
    var tgt_pos: Vector3 = tgt_xf.origin
    var body_yaw: float = tgt_xf.basis.get_euler().y
    # Follow the turret: combine body yaw with turret-local yaw so the camera
    # swings with aim instead of staying locked to the chassis.
    var turret_yaw: float = 0.0
    if _target.has_method("turret_local_yaw"):
        turret_yaw = _target.turret_local_yaw()
    var yaw: float = body_yaw + turret_yaw
    var behind := Vector3(sin(yaw), 0, cos(yaw)) * distance
    var desired: Vector3 = tgt_pos + behind + Vector3(0, height, 0)
    # Lift above terrain if heightmap is available
    if _heightmap.size() > 0 and _terrain_size > 0:
        var th: float = TerrainGenerator.sample_height(_heightmap, _terrain_size, desired.x, desired.z)
        if desired.y < th + min_clearance_above_terrain:
            desired.y = th + min_clearance_above_terrain
    # Frame-rate-independent exp decay. The old `clamp(smooth*delta, 0, 1)` is
    # only approximate — when render delta jitters, the decay factor jitters
    # with it, so the camera's tracking lag wobbles each frame and the tracked
    # tank appears to stutter along its motion axis.
    global_position = global_position.lerp(desired, 1.0 - exp(-smooth * delta))
    look_at(tgt_pos + Vector3(0, 1.5, 0), Vector3.UP)
