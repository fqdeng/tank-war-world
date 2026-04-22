extends GutTest

const Scoreboard = preload("res://server/sim/scoreboard.gd")

func test_on_player_joined_creates_zeroed_row() -> void:
    var sb = Scoreboard.new()
    sb.on_player_joined(7, 0, "Alice", false)
    var rows: Array = sb.snapshot()
    assert_eq(rows.size(), 1)
    var r: Dictionary = rows[0]
    assert_eq(r["player_id"], 7)
    assert_eq(r["team"], 0)
    assert_eq(r["display_name"], "Alice")
    assert_eq(r["is_ai"], false)
    assert_eq(r["kills"], 0)
    assert_eq(r["deaths"], 0)
    assert_eq(r["assists"], 0)
    assert_eq(r["hits"], 0)
    assert_eq(r["damage"], 0)

func test_on_player_joined_twice_does_not_duplicate_row() -> void:
    var sb = Scoreboard.new()
    sb.on_player_joined(7, 0, "Alice", false)
    sb.on_player_joined(7, 0, "Alice", false)
    assert_eq(sb.snapshot().size(), 1)
