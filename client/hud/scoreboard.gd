# client/hud/scoreboard.gd
# Tab-hold overlay. Two columns (own team left, enemy right), header row,
# body rows sorted by kills desc (damage desc as tiebreaker). Local player's
# row is highlighted. Kept in sync with the latest SCOREBOARD broadcast via
# set_data(); main_client.gd toggles `visible` on Tab press/release.
extends CanvasLayer

@onready var _header: Label = $Panel/VBox/HeaderLabel
@onready var _own_title: Label = $Panel/VBox/Columns/OwnColumn/Title
@onready var _enemy_title: Label = $Panel/VBox/Columns/EnemyColumn/Title
@onready var _own_grid: GridContainer = $Panel/VBox/Columns/OwnColumn/Grid
@onready var _enemy_grid: GridContainer = $Panel/VBox/Columns/EnemyColumn/Grid

const COL_HEADERS: Array = ["名字", "K", "D", "A", "命中", "伤害"]
const OWN_TEAM_COLOR: Color = Color(0.3, 0.7, 1.0)
const ENEMY_TEAM_COLOR: Color = Color(1.0, 0.31, 0.31)
const SELF_HIGHLIGHT: Color = Color(1.0, 0.95, 0.4)

# Entries are Array[ScoreboardEntry] (from messages.gd).
func set_data(entries: Array, my_team: int, my_player_id: int) -> void:
    var own: Array = []
    var enemy: Array = []
    for e in entries:
        if e.team == my_team:
            own.append(e)
        else:
            enemy.append(e)
    own.sort_custom(_sort_by_kills_desc)
    enemy.sort_custom(_sort_by_kills_desc)
    _own_title.text = "本方"
    _enemy_title.text = "敌方"
    _own_title.add_theme_color_override("font_color", OWN_TEAM_COLOR if my_team == 0 else ENEMY_TEAM_COLOR)
    _enemy_title.add_theme_color_override("font_color", ENEMY_TEAM_COLOR if my_team == 0 else OWN_TEAM_COLOR)
    _header.text = "本局战绩"
    _render_column(_own_grid, own, my_player_id)
    _render_column(_enemy_grid, enemy, my_player_id)

func _sort_by_kills_desc(a, b) -> bool:
    if a.kills != b.kills:
        return a.kills > b.kills
    return a.damage > b.damage

func _render_column(grid: GridContainer, rows: Array, my_player_id: int) -> void:
    for child in grid.get_children():
        child.queue_free()
    grid.columns = COL_HEADERS.size()
    # Header row
    for col in COL_HEADERS:
        var h := Label.new()
        h.text = col
        h.add_theme_font_size_override("font_size", 28)
        h.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
        grid.add_child(h)
    # Body rows
    for e in rows:
        var is_self: bool = e.player_id == my_player_id
        var highlight: Color = SELF_HIGHLIGHT if is_self else Color(1, 1, 1)
        var name_text: String = e.display_name
        if e.is_ai:
            name_text += " (AI)"
        _add_cell(grid, name_text, 28, highlight)
        _add_cell(grid, str(e.kills), 28, highlight)
        _add_cell(grid, str(e.deaths), 28, highlight)
        _add_cell(grid, str(e.assists), 28, highlight)
        _add_cell(grid, str(e.hits), 28, highlight)
        _add_cell(grid, str(e.damage), 28, highlight)

func _add_cell(grid: GridContainer, text: String, font_size: int, color: Color) -> void:
    var l := Label.new()
    l.text = text
    l.add_theme_font_size_override("font_size", font_size)
    l.add_theme_color_override("font_color", color)
    grid.add_child(l)
