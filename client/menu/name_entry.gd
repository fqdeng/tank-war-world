extends Control

# Emitted when the player has chosen a name and clicked Join Battle.
signal joined(player_name: String)

const NamePool = preload("res://client/menu/name_pool.gd")
const SAVE_PATH := "user://player_name.cfg"

@onready var _name_field: LineEdit = $Center/VBox/Row/NameField
@onready var _dice_button: Button = $Center/VBox/Row/DiceButton
@onready var _join_button: Button = $Center/VBox/JoinButton

func _ready() -> void:
    _name_field.text = _load_or_random()
    _name_field.text_changed.connect(_on_text_changed)
    _name_field.text_submitted.connect(_on_text_submitted)
    _dice_button.pressed.connect(_on_roll)
    _join_button.pressed.connect(_on_join)
    _name_field.grab_focus()
    _name_field.select_all()
    _update_join_enabled()

func _on_roll() -> void:
    _name_field.text = NamePool.random_name()
    _update_join_enabled()

func _on_text_changed(_t: String) -> void:
    _update_join_enabled()

func _on_text_submitted(_t: String) -> void:
    if not _join_button.disabled:
        _on_join()

func _update_join_enabled() -> void:
    _join_button.disabled = _name_field.text.strip_edges().is_empty()

func _on_join() -> void:
    var n := _name_field.text.strip_edges()
    _save(n)
    emit_signal("joined", n)
    queue_free()

func _load_or_random() -> String:
    var cfg := ConfigFile.new()
    if cfg.load(SAVE_PATH) == OK:
        var saved := str(cfg.get_value("player", "name", ""))
        if not saved.is_empty():
            return saved
    return NamePool.random_name()

func _save(n: String) -> void:
    var cfg := ConfigFile.new()
    cfg.set_value("player", "name", n)
    cfg.save(SAVE_PATH)
