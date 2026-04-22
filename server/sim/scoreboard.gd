# server/sim/scoreboard.gd
# Per-match in-memory scoreboard. Owned by tick_loop.gd. Pure logic — no Node
# inheritance, no signals. Broadcast by TickLoop at 1 Hz; cleared on match
# restart. See docs/superpowers/specs/2026-04-22-scoreboard-design.md.
extends RefCounted

# Assist = any non-killer attacker who damaged the victim within the last
# ASSIST_WINDOW_MS milliseconds. Repeated hits from the same attacker dedupe
# (recent_damagers is a Dictionary keyed by attacker_id → last_ms).
const ASSIST_WINDOW_MS: int = 15000

# player_id → Dictionary row.
# Row keys: player_id, team, display_name, is_ai, kills, deaths, assists,
# hits, damage, recent_damagers (Dictionary[int, int] attacker_id → last_ms).
var _rows: Dictionary = {}

func on_player_joined(pid: int, team: int, display_name: String, is_ai: bool) -> void:
    if _rows.has(pid):
        return
    _rows[pid] = {
        "player_id": pid,
        "team": team,
        "display_name": display_name,
        "is_ai": is_ai,
        "kills": 0,
        "deaths": 0,
        "assists": 0,
        "hits": 0,
        "damage": 0,
        "recent_damagers": {},
    }

func reset() -> void:
    _rows.clear()

# Returns an Array of Dictionary rows suitable for encoding into a Scoreboard
# message. The recent_damagers field is stripped (internal-only).
func snapshot() -> Array:
    var out: Array = []
    for pid in _rows.keys():
        var r: Dictionary = _rows[pid]
        out.append({
            "player_id": r["player_id"],
            "team": r["team"],
            "display_name": r["display_name"],
            "is_ai": r["is_ai"],
            "kills": r["kills"],
            "deaths": r["deaths"],
            "assists": r["assists"],
            "hits": r["hits"],
            "damage": r["damage"],
        })
    return out
