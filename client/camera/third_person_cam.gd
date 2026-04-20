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

func _physics_process(delta: float) -> void:
    # Smoothing is done at physics-tick cadence (stable dt) instead of _process
    # (render dt, which jitters with vsync/GC). Combined with the cam's
    # physics_interpolation_mode = INHERIT, Godot interpolates the cam pose
    # between physics frames at render time — same mechanism that keeps the
    # tank body smooth. Previously the cam wrote in _process with interp=OFF,
    # so render-rate hitches translated directly into visible camera jumps.
    if _target == null:
        return
    # Physics-current target pose (no render-time interpolation here — we want
    # deterministic input for the filter; Godot interpolates the output).
    var tgt_xf: Transform3D = _target.global_transform
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
    # Frame-rate-independent exp decay. Stable dt here → the filter's discrete
    # steps are deterministic.
    global_position = global_position.lerp(desired, 1.0 - exp(-smooth * delta))
    look_at(tgt_pos + Vector3(0, 1.5, 0), Vector3.UP)
