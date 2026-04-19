# client/hud/basic_hud.gd
extends CanvasLayer

@onready var _status: Label = $Container/StatusLabel
@onready var _hp: Label = $Container/HpLabel
@onready var _id: Label = $Container/IdLabel
@onready var _ammo: Label = $Container/AmmoLabel
@onready var _reload: ProgressBar = $Container/ReloadBar
@onready var radar: Control = $Radar

func _ready() -> void:
    get_viewport().size_changed.connect(_resize_radar)
    _resize_radar.call_deferred()

func _resize_radar() -> void:
    if radar == null:
        return
    var vp: Vector2 = get_viewport().get_visible_rect().size
    var s: float = clamp(vp.y * 0.28, 240.0, 440.0)
    var margin: float = 16.0
    radar.set_anchors_preset(Control.PRESET_TOP_LEFT)
    radar.position = Vector2(margin, vp.y - s - margin)
    radar.size = Vector2(s, s)
    # Push HP/Player labels right of the radar so they aren't covered.
    var label_left: float = s + 20.0
    if _hp:
        _hp.offset_left = label_left
    if _id:
        _id.offset_left = label_left

func set_status(s: String) -> void:
    if _status:
        _status.text = "STATUS: " + s

func set_hp(v: int) -> void:
    if _hp:
        _hp.text = "HP: %d" % v

func set_player_id(pid: int) -> void:
    if _id:
        _id.text = "Player: %d" % pid

func set_ammo(n: int) -> void:
    if _ammo:
        _ammo.text = "AP x %d" % n

# remaining_s: seconds left on reload; total_s: reload duration. 0 remaining = full bar.
func set_reload(remaining_s: float, total_s: float) -> void:
    if _reload == null or total_s <= 0.0:
        return
    var frac: float = 1.0 - clamp(remaining_s / total_s, 0.0, 1.0)
    _reload.value = frac
