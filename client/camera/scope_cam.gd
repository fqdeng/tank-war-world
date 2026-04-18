# client/camera/scope_cam.gd
extends Camera3D

var _zoom_index: int = 1  # start at ×4

func _ready() -> void:
    current = false
    _apply_zoom()

func _apply_zoom() -> void:
    var z: int = Constants.SCOPE_ZOOMS[_zoom_index]
    match z:
        2: fov = Constants.SCOPE_FOV_2X
        4: fov = Constants.SCOPE_FOV_4X
        8: fov = Constants.SCOPE_FOV_8X

func cycle_zoom(direction: int) -> void:
    _zoom_index = clamp(_zoom_index + direction, 0, Constants.SCOPE_ZOOMS.size() - 1)
    _apply_zoom()

func current_zoom() -> int:
    return Constants.SCOPE_ZOOMS[_zoom_index]
