# client/hud/basic_hud.gd
extends CanvasLayer

@onready var _status: Label = $StatusLabel
@onready var _hp: Label = $HpLabel
@onready var _id: Label = $IdLabel
@onready var _ammo: Label = $AmmoLabel
@onready var _reload: ProgressBar = $ReloadBar
@onready var radar: Control = $Radar
@onready var _scoreboard: RichTextLabel = $ScoreboardLabel

func _ready() -> void:
    get_viewport().size_changed.connect(_resize_radar)
    _resize_radar.call_deferred()

func _resize_radar() -> void:
    if radar == null:
        return
    var vp: Vector2 = get_viewport().get_visible_rect().size
    var s: float = clamp(vp.y * 0.56, 480.0, 880.0)
    var margin: float = 16.0
    radar.set_anchors_preset(Control.PRESET_TOP_LEFT)
    radar.position = Vector2(margin, vp.y - s - margin)
    radar.size = Vector2(s, s)
    # Push HP/Player labels above the radar (radar lives bottom-left) so they
    # aren't overlapped by it.
    var labels_bottom_offset: float = -(s + margin + 8.0)
    if _hp:
        _hp.offset_top = labels_bottom_offset - 24.0
        _hp.offset_bottom = labels_bottom_offset - 4.0
    if _id:
        _id.offset_top = labels_bottom_offset
        _id.offset_bottom = labels_bottom_offset + 20.0

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

func set_team_kills(blue: int, red: int) -> void:
    if _scoreboard:
        _scoreboard.text = "[center][color=#4db2ff]BLUE %d[/color]    —    [color=#ff5050]RED %d[/color][/center]" % [blue, red]

# remaining_s: seconds left on reload; total_s: reload duration. 0 remaining = full bar.
func set_reload(remaining_s: float, total_s: float) -> void:
    if _reload == null or total_s <= 0.0:
        return
    var frac: float = 1.0 - clamp(remaining_s / total_s, 0.0, 1.0)
    _reload.value = frac
