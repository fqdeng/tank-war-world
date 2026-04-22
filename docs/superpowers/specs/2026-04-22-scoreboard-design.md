# Scoreboard — Design

## Summary

Add a per-match scoreboard the server broadcasts at 1 Hz. The client
shows it as a full-screen overlay while Tab is held down. Tracks kills,
deaths, assists, hits, and total damage for every tank (humans + AI)
currently in the match. Pure in-memory; no persistence; wiped on match
restart (when a team reaches `MATCH_KILL_TARGET = 100`).

## Decisions

- **Lifecycle**: current match only. No SQLite, no JSON, no disk.
- **Who is tracked**: all players (humans + AI).
- **Stats**: kills, deaths, assists, hits, damage. K/D derived on the
  client.
- **Assist window**: 15 s. Same attacker hitting multiple times counts
  as one assist.
- **Transport**: new `SCOREBOARD = 16` message broadcast 1 Hz (full
  snapshot, not delta).
- **UI**: two columns (own team left, enemy right), sorted by kills
  descending. Hold Tab to view.

## Non-goals

- No cross-match or cross-session persistence.
- No historical leaderboards.
- No friendly-fire kill/hit crediting (consistent with existing
  `team_kills` logic in `tick_loop.gd`).
- No shots-fired / accuracy column (would need FIRE-event counters —
  deferred until asked for).

## Architecture

### Server

New module `server/sim/scoreboard.gd` — plain GDScript class, no Node
inheritance (same style as `shared/world/tank_collision.gd`). Owns the
stats table and all scoring rules.

API:

```
func on_player_joined(pid: int, team: int, display_name: String, is_ai: bool) -> void
func on_player_left(pid: int) -> void   # optional — we keep the row; left as no-op for now
func on_hit(shooter_id: int, victim_id: int, damage: int, now_ms: int) -> void
func on_death(killer_id: int, victim_id: int, now_ms: int) -> void
func reset() -> void
func snapshot() -> Array                # returns Array[Dictionary]
```

The class is constructed once in `tick_loop.gd:set_world`, held as
`_scoreboard`, and reset from `_restart_match`.

### Client

New scene `client/hud/scoreboard.gd` + `scoreboard.tscn` — a
`CanvasLayer` separate from `basic_hud.tscn`. Layer ordering: above
`BasicHUD` (layer=2 vs BasicHUD's layer=1) so the overlay hides the
radar / combat log while visible.

Instantiated once in `main_client.gd:_on_name_chosen`, starts
`visible = false`. Calls `set_data(entries, my_team, my_player_id)` on
every SCOREBOARD message.

Tab is read in `main_client.gd:_unhandled_input` (not `tank_input.gd`,
since `tank_input.gd` is gated by `_enabled` / pointer-lock and the
scoreboard should work during respawn and before lock). On press show
overlay, on release hide. Key: `KEY_TAB`.

## Data structures

### `PlayerStats` (server, in-memory)

Plain `Dictionary` rows keyed by `player_id`:

```
{
  "player_id":   int,
  "team":        int,      # 0 or 1
  "display_name": String,
  "is_ai":       bool,
  "kills":       int,
  "deaths":      int,
  "assists":     int,
  "hits":        int,
  "damage":      int,
  "recent_damagers": Dictionary,   # attacker_id -> last_ms (dedupe structure)
}
```

`recent_damagers` is a Dictionary (not an Array) so the same attacker
landing repeated hits only occupies one slot — automatic dedupe for
assist attribution. Entries older than 15 s are cleaned lazily at death
time (no background scan).

### Wire format: `Scoreboard` message

Appended to `message_types.gd`:

```
SCOREBOARD = 16
```

`messages.gd` adds:

```
class ScoreboardEntry:
    var player_id: int
    var team: int
    var is_ai: bool
    var display_name: String
    var kills: int
    var deaths: int
    var assists: int
    var hits: int
    var damage: int

class Scoreboard:
    var entries: Array  # Array[ScoreboardEntry]
    func encode() -> PackedByteArray
    static func decode(buf: PackedByteArray) -> Scoreboard
```

Encoding per entry (little-endian):

| field        | type    | bytes |
|--------------|---------|-------|
| player_id    | u16     | 2     |
| team         | u8      | 1     |
| is_ai        | u8      | 1     |
| display_name | string  | 2+N   |
| kills        | u16     | 2     |
| deaths       | u16     | 2     |
| assists      | u16     | 2     |
| hits         | u16     | 2     |
| damage       | u32     | 4     |

With 10 tanks + 10-byte names, the full payload is ≈ 260 bytes/s — well
under the existing ZSTD threshold (128 B, enabled in the codec), so it
gets compressed like any other >128 B envelope.

## Scoring rules

| Event                              | Applies when                                                        | Effect                                                                                             |
|------------------------------------|---------------------------------------------------------------------|----------------------------------------------------------------------------------------------------|
| HIT on tank                        | `damage > 0` and `shooter.team != victim.team`                      | `shooter.hits += 1`; `shooter.damage += damage`; `victim.recent_damagers[shooter_id] = now_ms`     |
| HIT on tank (friendly fire)        | `shooter.team == victim.team`                                       | ignored                                                                                            |
| HIT with zero damage               | shield / spawn-invuln / obstacle / environment                      | ignored                                                                                            |
| DEATH — victim side                | always                                                              | `victim.deaths += 1`; clear `victim.recent_damagers` **after** assist attribution                   |
| DEATH — killer side                | `killer_id != 0` and `killer.team != victim.team`                   | `killer.kills += 1`                                                                                |
| DEATH — assist attribution         | for each `(aid, last_ms)` in `victim.recent_damagers`               | if `aid != killer_id` and `now_ms - last_ms <= 15000` → `stats[aid].assists += 1`                  |

Team comparison uses the scoreboard row's `team` field (not
`world.tanks[pid].team`) so disconnected players and despawned AI still
have their hits/kills credited correctly.

## Integration points in `tick_loop.gd`

1. **Construct**: in `set_world`, create `_scoreboard = Scoreboard.new()`.
2. **Human joined**: at the end of `_on_client_connected`, call
   `_scoreboard.on_player_joined(pid, team, display_name, false)`.
3. **AI joined**: at the end of `_spawn_ai`, call
   `_scoreboard.on_player_joined(pid, team, display_name, true)`.
4. **Hit**: inside `_on_shell_hit`, after damage is applied and before
   the HIT broadcast, call `_scoreboard.on_hit(shell.shooter_id,
   victim_id, int(round(result.actual_damage)),
   Time.get_ticks_msec())`. Only reached on the real-tank branch
   (not obstacle, not invulnerable), so friendly-fire filtering happens
   inside `on_hit` (not at the call site).
5. **Death**: in `_on_shell_hit` where `result.tank_just_destroyed` is
   true, call `_scoreboard.on_death(shell.shooter_id, victim_id,
   Time.get_ticks_msec())` right next to where `_team_kills` is
   updated.
6. **Match restart**: in `_restart_match`, call `_scoreboard.reset()`.
7. **Broadcast cadence**: new `_scoreboard_accum_ticks` counter on
   `tick_loop`. Incremented every `_step_tick`. When it reaches 20 (= 1
   s at 20 Hz), reset and broadcast the encoded `Scoreboard` payload
   via `_ws_server.broadcast(MessageType.SCOREBOARD, ...)`.

## Client UI layout

`scoreboard.tscn`:

```
Scoreboard (CanvasLayer, layer=2)
  Panel (full-screen, semi-transparent dark background)
    VBoxContainer (center-anchored, max_width=1600)
      MatchHeader (Label: "本局战绩  —  BLUE 43 / 100 / RED 31")
      HBoxContainer
        TeamColumn "BLUE"  (VBox + Grid)
        TeamColumn "RED"   (VBox + Grid)
```

Each `TeamColumn` renders:

- Header row: `名字   K   D   A   命中   伤害`
- One row per entry for that team, sorted by `kills` desc, then
  `damage` desc as tiebreaker.
- Local player's row highlighted (bold + background tint).
- AI rows: name suffix `(AI)` to disambiguate.
- Team column on the left is always the local player's team; enemy on
  the right.

Font size large enough to be legible at 1080p: header 36pt, rows 28pt.

### CJK subset

Characters added to `build.sh`'s `SUBSET_CJK_TEXT`:

```
本局战绩名字命中伤害
```

(击 杀 死 亡 助 攻 are probably already present via the combat log
"击中了" phrase, but must be verified; any missing char gets appended.)

## Tab handling

`main_client.gd`:

```
var _scoreboard_overlay: CanvasLayer
var _latest_scoreboard: Array = []
var _my_team: int = 0

func _unhandled_input(ev: InputEvent) -> void:
    if ev is InputEventKey and ev.keycode == KEY_TAB and not ev.echo:
        if _scoreboard_overlay:
            _scoreboard_overlay.visible = ev.pressed
            if ev.pressed:
                _scoreboard_overlay.refresh()
```

`_on_message` routes `SCOREBOARD` to `_handle_scoreboard`:

```
func _handle_scoreboard(msg) -> void:
    _latest_scoreboard = msg.entries
    if _scoreboard_overlay:
        _scoreboard_overlay.set_data(_latest_scoreboard, _my_team, _my_player_id)
```

`_handle_match_restart` clears the local mirror so the overlay doesn't
display stale stats during the brief window before the next
SCOREBOARD packet arrives.

## Testing

New `tests/test_scoreboard.gd` (GUT). Unit tests on the pure-logic
`scoreboard.gd`:

1. `on_hit` enemy → `shooter.hits=1`, `shooter.damage=d`,
   `victim.recent_damagers` populated
2. `on_hit` teammate → no change
3. `on_hit` zero damage → no change
4. `on_death` enemy kill → `killer.kills++`, `victim.deaths++`, no
   assist for killer
5. `on_death` with one prior damager (non-killer) within 15 s →
   `damager.assists=1`
6. `on_death` with same damager hitting three times → still
   `damager.assists=1` (dedupe)
7. `on_death` with damager from 20 s ago → no assist
8. `on_death` friendly-fire (same-team shooter) → `victim.deaths++`,
   killer does NOT get kill credit, but assists from other damagers
   still pay out
9. `on_death` suicide (killer_id == 0) → `victim.deaths++`, no kill
   credit, recent assist window still pays out
10. `reset()` → all rows cleared
11. `snapshot()` returns rows in deterministic order and includes all
    expected fields

New test `test_messages.gd` entry round-trips the `Scoreboard` message.

## Edge cases

- **Player disconnects mid-match**: scoreboard row is kept frozen;
  their historical numbers still show in Tab until match restart.
- **AI rebalance**: when `_despawn_ai_in_team` removes an AI, its row
  stays in the scoreboard. When a new AI spawns, it gets a fresh row
  with a new `player_id`. No history transfer.
- **Shield / spawn invuln**: `_on_shell_hit` already returns early for
  invulnerable victims after a zero-damage HIT broadcast. The
  scoreboard call sites are placed on the damaging-hit branch only,
  so invuln hits never touch scoreboard state.
- **Obstacle hits**: `_on_shell_hit` returns early on obstacle branch;
  scoreboard never sees them.
- **Zero-damage hits (e.g., broken part absorbing all damage via
  part cap)**: the call site gates on "scoreboard is called only when
  victim is a tank and damage was applied". If `actual_damage == 0`
  (e.g., part already destroyed), skip the hits/damage increment but
  still let the damager dictionary remain untouched — simplest rule is
  `if damage > 0`.
- **Scoreboard visible during respawn / death screen**: allowed. Tab
  should work regardless of alive state.
- **Web build font subset**: if a new Chinese char renders as tofu,
  the overlay will still work, just with a missing glyph. Verification
  step: grep the rendered strings for non-ASCII, confirm each appears
  in `SUBSET_CJK_TEXT`.

## File changes

**New:**
- `server/sim/scoreboard.gd`
- `client/hud/scoreboard.gd`
- `client/hud/scoreboard.tscn`
- `tests/test_scoreboard.gd`

**Modified:**
- `common/protocol/message_types.gd` — append `SCOREBOARD = 16`
- `common/protocol/messages.gd` — add `Scoreboard` + `ScoreboardEntry` classes
- `server/sim/tick_loop.gd` — instantiate, hook events, broadcast,
  reset on match restart
- `client/main_client.gd` — handle SCOREBOARD, Tab input, overlay
  lifecycle, match-restart clear
- `tests/test_messages.gd` — round-trip for new message
- `build.sh` — extend `SUBSET_CJK_TEXT` if needed

## Verification plan

1. `/Applications/Godot.app/Contents/MacOS/Godot --headless -s
   addons/gut/gut_cmdln.gd -gdir=res://tests -gexit` — all 60+ tests
   pass.
2. Manual: start server + native client, let AI fill the lobby, fire
   at enemies, die, hold Tab → confirm both columns populate, numbers
   look right, own row highlighted.
3. Manual: play until a team hits 100 kills → confirm MATCH_RESTART
   zeroes the Tab display.
4. Web build: `./build.sh` succeeds; Tab overlay in browser renders all
   CJK glyphs correctly (no tofu).
