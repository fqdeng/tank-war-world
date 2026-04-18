# client/camera/third_person_cam.gd
extends Camera3D

@export var distance: float = 12.0
@export var height: float = 5.0
@export var smooth: float = 8.0

var _target: Node3D

func set_target(t: Node3D) -> void:
    _target = t

func _process(delta: float) -> void:
    if _target == null:
        return
    var yaw: float = _target.rotation.y
    var behind := Vector3(sin(yaw), 0, cos(yaw)) * distance
    var desired: Vector3 = _target.global_position + behind + Vector3(0, height, 0)
    global_position = global_position.lerp(desired, clamp(smooth * delta, 0, 1))
    look_at(_target.global_position + Vector3(0, 1.5, 0), Vector3.UP)
