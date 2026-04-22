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

# Called from tick_loop on every HIT where the victim is a real tank. Ignores
# friendly fire and zero-damage events (shield / spawn-invuln / destroyed
# parts) so the scoreboard tracks *useful* combat contribution only.
func on_hit(shooter_id: int, victim_id: int, damage: int, now_ms: int) -> void:
    if damage <= 0:
        return
    if not _rows.has(shooter_id) or not _rows.has(victim_id):
        return
    var shooter: Dictionary = _rows[shooter_id]
    var victim: Dictionary = _rows[victim_id]
    if shooter["team"] == victim["team"]:
        return
    shooter["hits"] += 1
    shooter["damage"] += damage
    victim["recent_damagers"][shooter_id] = now_ms

# Called from tick_loop when a tank is destroyed. Credits kill (if the killer
# is on the opposing team and known to the scoreboard), always increments the
# victim's death count, pays out assists to any *other* recent damagers whose
# last-damage timestamp is within ASSIST_WINDOW_MS, and clears the victim's
# damager list so a subsequent death doesn't re-credit the same attackers.
func on_death(killer_id: int, victim_id: int, now_ms: int) -> void:
    if not _rows.has(victim_id):
        return
    var victim: Dictionary = _rows[victim_id]
    if killer_id != 0 and _rows.has(killer_id):
        var killer: Dictionary = _rows[killer_id]
        if killer["team"] != victim["team"]:
            killer["kills"] += 1
    victim["deaths"] += 1
    var damagers: Dictionary = victim["recent_damagers"]
    for aid in damagers.keys():
        if aid == killer_id:
            continue
        if not _rows.has(aid):
            continue
        var last_ms: int = damagers[aid]
        if now_ms - last_ms <= ASSIST_WINDOW_MS:
            _rows[aid]["assists"] += 1
    victim["recent_damagers"] = {}

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
