# client/hud/basic_hud.gd
extends CanvasLayer

@onready var _status: Label = $Container/StatusLabel
@onready var _hp: Label = $Container/HpLabel
@onready var _id: Label = $Container/IdLabel

func set_status(s: String) -> void:
    if _status:
        _status.text = "STATUS: " + s

func set_hp(v: int) -> void:
    if _hp:
        _hp.text = "HP: %d" % v

func set_player_id(pid: int) -> void:
    if _id:
        _id.text = "Player: %d" % pid
