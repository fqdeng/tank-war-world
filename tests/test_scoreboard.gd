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

func _find_row(rows: Array, pid: int) -> Dictionary:
    for r in rows:
        if r["player_id"] == pid:
            return r
    return {}

func test_on_hit_enemy_increments_hits_and_damage() -> void:
    var sb = Scoreboard.new()
    sb.on_player_joined(1, 0, "A", false)
    sb.on_player_joined(2, 1, "B", false)
    sb.on_hit(1, 2, 120, 1_000)
    sb.on_hit(1, 2, 80, 2_000)
    var rows: Array = sb.snapshot()
    var shooter: Dictionary = _find_row(rows, 1)
    var victim: Dictionary = _find_row(rows, 2)
    assert_eq(shooter["hits"], 2)
    assert_eq(shooter["damage"], 200)
    assert_eq(victim["hits"], 0)
    assert_eq(victim["damage"], 0)

func test_on_hit_friendly_fire_ignored() -> void:
    var sb = Scoreboard.new()
    sb.on_player_joined(1, 0, "A", false)
    sb.on_player_joined(2, 0, "B", false)  # same team
    sb.on_hit(1, 2, 120, 1_000)
    var shooter: Dictionary = _find_row(sb.snapshot(), 1)
    assert_eq(shooter["hits"], 0)
    assert_eq(shooter["damage"], 0)

func test_on_hit_zero_damage_ignored() -> void:
    var sb = Scoreboard.new()
    sb.on_player_joined(1, 0, "A", false)
    sb.on_player_joined(2, 1, "B", false)
    sb.on_hit(1, 2, 0, 1_000)
    var shooter: Dictionary = _find_row(sb.snapshot(), 1)
    assert_eq(shooter["hits"], 0)
    assert_eq(shooter["damage"], 0)

func test_on_hit_unknown_shooter_or_victim_no_crash() -> void:
    var sb = Scoreboard.new()
    sb.on_player_joined(1, 0, "A", false)
    # shooter unknown
    sb.on_hit(99, 1, 50, 1_000)
    # victim unknown
    sb.on_hit(1, 99, 50, 1_000)
    var shooter: Dictionary = _find_row(sb.snapshot(), 1)
    assert_eq(shooter["hits"], 0)
    assert_eq(shooter["damage"], 0)

func test_on_death_enemy_kill_credits_both_sides() -> void:
    var sb = Scoreboard.new()
    sb.on_player_joined(1, 0, "A", false)
    sb.on_player_joined(2, 1, "B", false)
    sb.on_death(1, 2, 5_000)
    var killer: Dictionary = _find_row(sb.snapshot(), 1)
    var victim: Dictionary = _find_row(sb.snapshot(), 2)
    assert_eq(killer["kills"], 1)
    assert_eq(killer["assists"], 0)
    assert_eq(victim["deaths"], 1)

func test_on_death_friendly_kill_no_kill_credit_but_death_counts() -> void:
    var sb = Scoreboard.new()
    sb.on_player_joined(1, 0, "A", false)
    sb.on_player_joined(2, 0, "B", false)  # same team
    sb.on_death(1, 2, 5_000)
    var killer: Dictionary = _find_row(sb.snapshot(), 1)
    var victim: Dictionary = _find_row(sb.snapshot(), 2)
    assert_eq(killer["kills"], 0)
    assert_eq(victim["deaths"], 1)

func test_on_death_suicide_or_unknown_killer_no_kill_credit() -> void:
    var sb = Scoreboard.new()
    sb.on_player_joined(2, 1, "B", false)
    # killer_id 0 = no killer
    sb.on_death(0, 2, 5_000)
    var victim: Dictionary = _find_row(sb.snapshot(), 2)
    assert_eq(victim["deaths"], 1)

func test_on_death_pays_assist_to_recent_damager_not_killer() -> void:
    var sb = Scoreboard.new()
    sb.on_player_joined(1, 0, "A", false)  # killer
    sb.on_player_joined(3, 0, "C", false)  # assister (same team as killer)
    sb.on_player_joined(2, 1, "B", false)  # victim
    sb.on_hit(3, 2, 40, 1_000)    # assist damage at t=1s
    sb.on_hit(1, 2, 260, 2_000)   # final blow damage at t=2s (not strictly
                                   # required for attribution, but realistic)
    sb.on_death(1, 2, 2_500)      # death at t=2.5s
    var assister: Dictionary = _find_row(sb.snapshot(), 3)
    var killer: Dictionary = _find_row(sb.snapshot(), 1)
    assert_eq(assister["assists"], 1)
    assert_eq(killer["assists"], 0)  # killer gets kill, not assist

func test_on_death_same_attacker_multiple_hits_one_assist() -> void:
    var sb = Scoreboard.new()
    sb.on_player_joined(1, 0, "A", false)  # killer
    sb.on_player_joined(3, 0, "C", false)  # assister
    sb.on_player_joined(2, 1, "B", false)  # victim
    sb.on_hit(3, 2, 40, 1_000)
    sb.on_hit(3, 2, 40, 2_000)
    sb.on_hit(3, 2, 40, 3_000)
    sb.on_death(1, 2, 3_500)
    var assister: Dictionary = _find_row(sb.snapshot(), 3)
    assert_eq(assister["assists"], 1)

func test_on_death_old_damager_outside_window_no_assist() -> void:
    var sb = Scoreboard.new()
    sb.on_player_joined(1, 0, "A", false)
    sb.on_player_joined(3, 0, "C", false)
    sb.on_player_joined(2, 1, "B", false)
    sb.on_hit(3, 2, 40, 1_000)      # damage at t=1s
    sb.on_death(1, 2, 20_000)       # death at t=20s → assist window expired
    var assister: Dictionary = _find_row(sb.snapshot(), 3)
    assert_eq(assister["assists"], 0)

func test_on_death_clears_victim_damager_list_so_next_death_is_clean() -> void:
    var sb = Scoreboard.new()
    sb.on_player_joined(1, 0, "A", false)
    sb.on_player_joined(3, 0, "C", false)
    sb.on_player_joined(2, 1, "B", false)
    sb.on_hit(3, 2, 40, 1_000)
    sb.on_death(1, 2, 2_000)   # first death, C gets assist
    sb.on_death(1, 2, 3_000)   # second death from nothing — no extra assist
    var assister: Dictionary = _find_row(sb.snapshot(), 3)
    assert_eq(assister["assists"], 1)
