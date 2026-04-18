# client/hud/basic_hud.gd
extends CanvasLayer

@onready var _status: Label = $Container/StatusLabel
@onready var _hp: Label = $Container/HpLabel
@onready var _id: Label = $Container/IdLabel
@onready var _ammo: Label = $Container/AmmoLabel
@onready var _reload: ProgressBar = $Container/ReloadBar
@onready var radar: Control = $Container/Radar

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
