# client/input/tank_input.gd
extends Node

const Messages = preload("res://common/protocol/messages.gd")

signal scope_changed(active: bool)
signal zoom_cycled(direction: int)

var _enabled: bool = false
var _fire_latched: bool = false
var _turret_yaw: float = 0.0
var _gun_pitch: float = 0.0
var _mouse_sens_yaw: float = 0.0015
var _mouse_sens_pitch: float = 0.001
var _scope_zoom_factor: float = 1.0  # divides sensitivity while scoped (1.0 = third-person)
# Extra damping applied in third-person (no scope) to make fine aim easier.
const TP_SENS_SCALE: float = 0.5

func _ready() -> void:
    print("[Input] _ready, process_input=%s" % str(is_processing_input()))
    set_process_input(true)
    print("[Input] after set_process_input(true), process_input=%s" % str(is_processing_input()))

func set_scope_zoom(z: float) -> void:
    _scope_zoom_factor = max(1.0, z)

func set_enabled(v: bool) -> void:
    _enabled = v
    print("[Input] set_enabled(%s) mouse_mode=%d" % [str(v), Input.mouse_mode])
    if v:
        Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
        print("[Input] captured; post-set mouse_mode=%d" % Input.mouse_mode)

var _dbg_motion_count: int = 0
var _dbg_button_count: int = 0

func _input(ev: InputEvent) -> void:
    if ev is InputEventMouseMotion:
        _dbg_motion_count += 1
        if _dbg_motion_count % 20 == 1:
            print("[Input] motion #%d enabled=%s rel=%s" % [_dbg_motion_count, str(_enabled), str(ev.relative)])
    elif ev is InputEventMouseButton:
        _dbg_button_count += 1
        print("[Input] button #%d idx=%d pressed=%s enabled=%s" % [_dbg_button_count, ev.button_index, str(ev.pressed), str(_enabled)])
    if not _enabled:
        return
    if ev is InputEventMouseMotion:
        var sens_scale: float = TP_SENS_SCALE if _scope_zoom_factor <= 1.0 else (1.0 / _scope_zoom_factor)
        _turret_yaw += -ev.relative.x * _mouse_sens_yaw * sens_scale
        _gun_pitch += -ev.relative.y * _mouse_sens_pitch * sens_scale
        _gun_pitch = clamp(_gun_pitch, deg_to_rad(-8.0), deg_to_rad(12.0))
    elif ev is InputEventMouseButton:
        if ev.button_index == MOUSE_BUTTON_LEFT and ev.pressed:
            _fire_latched = true
        elif ev.button_index == MOUSE_BUTTON_RIGHT:
            scope_changed.emit(ev.pressed)  # hold-to-scope
        elif ev.button_index == MOUSE_BUTTON_WHEEL_UP and ev.pressed:
            zoom_cycled.emit(1)
        elif ev.button_index == MOUSE_BUTTON_WHEEL_DOWN and ev.pressed:
            zoom_cycled.emit(-1)
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
        # A (left) → positive yaw delta (CCW from above in Godot) → tank turns left
        # D (right) → negative yaw delta → tank turns right
        if Input.is_key_pressed(KEY_A): m.move_turn += 1.0
        if Input.is_key_pressed(KEY_D): m.move_turn -= 1.0
    m.turret_yaw = _turret_yaw
    m.gun_pitch = _gun_pitch
    m.fire_pressed = _fire_latched
    return m

func consume_fire() -> bool:
    var f := _fire_latched
    _fire_latched = false
    return f
