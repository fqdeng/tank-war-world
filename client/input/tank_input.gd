# client/input/tank_input.gd
extends Node

const Messages = preload("res://common/protocol/messages.gd")

var _enabled: bool = false
var _fire_latched: bool = false
var _turret_yaw: float = 0.0
var _gun_pitch: float = 0.0
var _mouse_sens_yaw: float = 0.003
var _mouse_sens_pitch: float = 0.002

func set_enabled(v: bool) -> void:
    _enabled = v
    if v:
        Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _input(ev: InputEvent) -> void:
    if not _enabled:
        return
    if ev is InputEventMouseMotion:
        _turret_yaw += -ev.relative.x * _mouse_sens_yaw
        _gun_pitch += -ev.relative.y * _mouse_sens_pitch
        _gun_pitch = clamp(_gun_pitch, deg_to_rad(-5.0), deg_to_rad(18.0))
    elif ev is InputEventMouseButton:
        if ev.button_index == MOUSE_BUTTON_LEFT and ev.pressed:
            _fire_latched = true
    elif ev is InputEventKey:
        if ev.pressed and ev.keycode == KEY_ESCAPE:
            Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func build_input_message():
    var m := Messages.InputMsg.new()
    m.move_forward = 0.0
    m.move_turn = 0.0
    if _enabled:
        if Input.is_key_pressed(KEY_W): m.move_forward += 1.0
        if Input.is_key_pressed(KEY_S): m.move_forward -= 1.0
        if Input.is_key_pressed(KEY_A): m.move_turn -= 1.0
        if Input.is_key_pressed(KEY_D): m.move_turn += 1.0
    m.turret_yaw = _turret_yaw
    m.gun_pitch = _gun_pitch
    m.fire_pressed = _fire_latched
    return m

func consume_fire() -> bool:
    var f := _fire_latched
    _fire_latched = false
    return f
