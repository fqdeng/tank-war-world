# Scoreboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a per-match scoreboard the server tracks in memory (kills / deaths / assists / hits / damage for all tanks, humans + AI), broadcast at 1 Hz as a new `SCOREBOARD` message, and rendered client-side as a two-column Tab-hold overlay. Wiped on match restart.

**Architecture:** Pure-GDScript `Scoreboard` module on the server, instantiated once in `tick_loop.gd` and hooked into the existing `_on_shell_hit` / `_on_client_connected` / `_spawn_ai` / `_restart_match` call sites. New append-only message type `SCOREBOARD = 16` with a small binary format. Client carries a latest-snapshot mirror and toggles a top-layer `CanvasLayer` overlay on Tab press/release.

**Tech Stack:** Godot 4.6.2, GDScript, GUT for tests. Binary message codec at `common/protocol/codec.gd`. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-04-22-scoreboard-design.md`

---

## File structure

**Create:**
- `server/sim/scoreboard.gd` — pure-logic scoring state (no Node inheritance)
- `client/hud/scoreboard.gd` — overlay UI behavior
- `client/hud/scoreboard.tscn` — overlay scene
- `tests/test_scoreboard.gd` — GUT unit tests

**Modify:**
- `common/protocol/message_types.gd` — append `SCOREBOARD = 16`
- `common/protocol/messages.gd` — add `Scoreboard` + `ScoreboardEntry` classes
- `server/sim/tick_loop.gd` — instantiate scoreboard, hook HIT/DEATH/join/restart, broadcast 1 Hz
- `client/main_client.gd` — handle SCOREBOARD, Tab input, overlay lifecycle, clear on MATCH_RESTART
- `tests/test_messages.gd` — round-trip for new message
- `build.sh` — extend `SUBSET_CJK_TEXT`

---

## Task 1: Protocol — message type + roundtrip

**Files:**
- Modify: `common/protocol/message_types.gd`
- Modify: `common/protocol/messages.gd`
- Test: `tests/test_messages.gd`

- [ ] **Step 1.1: Append SCOREBOARD to the message-type enum**

Edit `common/protocol/message_types.gd`. Append one line inside the `enum`, keeping existing values untouched (the project rule is append-only):

```gdscript
enum {
    CONNECT = 0,
    CONNECT_ACK = 1,
    INPUT = 2,
    SNAPSHOT = 3,
    FIRE = 4,
    SHELL_SPAWNED = 5,
    HIT = 6,
    DEATH = 7,
    RESPAWN = 8,
    PING = 9,
    PONG = 10,
    DISCONNECT = 11,
    OBSTACLE_DESTROYED = 12,
    PICKUP_SPAWNED = 13,
    PICKUP_CONSUMED = 14,
    MATCH_RESTART = 15,
    SCOREBOARD = 16,         # server → all clients (~1 Hz full-table broadcast)
}
```

Note: the codec reserves bit 7 of the msg-type byte (`0x80`) as a compression flag. The enum value 16 is well under 0x80, so nothing breaks.

- [ ] **Step 1.2: Add ScoreboardEntry + Scoreboard classes**

Append to the bottom of `common/protocol/messages.gd` (above any trailing whitespace):

```gdscript
# ---- Scoreboard (server → all clients, ~1 Hz) ----
# Full-table broadcast. Client replaces its cached copy wholesale on receive.
# Rows persist across player disconnects / AI despawn (frozen stats still show
# in the Tab overlay) and are only cleared on MATCH_RESTART (server calls
# Scoreboard.reset()).
class ScoreboardEntry:
    var player_id: int = 0
    var team: int = 0
    var is_ai: bool = false
    var display_name: String = ""
    var kills: int = 0
    var deaths: int = 0
    var assists: int = 0
    var hits: int = 0
    var damage: int = 0

class Scoreboard:
    var entries: Array = []  # Array[ScoreboardEntry]

    func encode() -> PackedByteArray:
        var buf := PackedByteArray()
        Codec.write_u16(buf, entries.size())
        for e in entries:
            Codec.write_u16(buf, e.player_id)
            Codec.write_u8(buf, e.team)
            Codec.write_u8(buf, 1 if e.is_ai else 0)
            Codec.write_string(buf, e.display_name)
            Codec.write_u16(buf, e.kills)
            Codec.write_u16(buf, e.deaths)
            Codec.write_u16(buf, e.assists)
            Codec.write_u16(buf, e.hits)
            Codec.write_u32(buf, e.damage)
        return buf

    static func decode(buf: PackedByteArray) -> Scoreboard:
        var m := Scoreboard.new()
        var c := [0]
        var n := Codec.read_u16(buf, c)
        for i in n:
            var e := ScoreboardEntry.new()
            e.player_id = Codec.read_u16(buf, c)
            e.team = Codec.read_u8(buf, c)
            e.is_ai = Codec.read_u8(buf, c) != 0
            e.display_name = Codec.read_string(buf, c)
            e.kills = Codec.read_u16(buf, c)
            e.deaths = Codec.read_u16(buf, c)
            e.assists = Codec.read_u16(buf, c)
            e.hits = Codec.read_u16(buf, c)
            e.damage = Codec.read_u32(buf, c)
            m.entries.append(e)
        return m
```

- [ ] **Step 1.3: Write roundtrip test**

Append to `tests/test_messages.gd`:

```gdscript
func test_scoreboard_roundtrip() -> void:
    var msg := Messages.Scoreboard.new()
    var e1 := Messages.ScoreboardEntry.new()
    e1.player_id = 7
    e1.team = 0
    e1.is_ai = false
    e1.display_name = "Alice"
    e1.kills = 12
    e1.deaths = 5
    e1.assists = 3
    e1.hits = 27
    e1.damage = 6540
    var e2 := Messages.ScoreboardEntry.new()
    e2.player_id = 42
    e2.team = 1
    e2.is_ai = true
    e2.display_name = "P42"
    e2.kills = 4
    e2.deaths = 9
    e2.assists = 1
    e2.hits = 11
    e2.damage = 2410
    msg.entries = [e1, e2]
    var bytes := msg.encode()
    var decoded := Messages.Scoreboard.decode(bytes)
    assert_eq(decoded.entries.size(), 2)
    assert_eq(decoded.entries[0].player_id, 7)
    assert_eq(decoded.entries[0].team, 0)
    assert_eq(decoded.entries[0].is_ai, false)
    assert_eq(decoded.entries[0].display_name, "Alice")
    assert_eq(decoded.entries[0].kills, 12)
    assert_eq(decoded.entries[0].damage, 6540)
    assert_eq(decoded.entries[1].is_ai, true)
    assert_eq(decoded.entries[1].display_name, "P42")
    assert_eq(decoded.entries[1].damage, 2410)

func test_scoreboard_roundtrip_empty() -> void:
    var msg := Messages.Scoreboard.new()
    var bytes := msg.encode()
    var decoded := Messages.Scoreboard.decode(bytes)
    assert_eq(decoded.entries.size(), 0)
```

- [ ] **Step 1.4: Run roundtrip tests — expected to pass**

Run:
```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests -gtest=res://tests/test_messages.gd -gexit
```
Expected: all tests pass (both pre-existing and the two new ones).

- [ ] **Step 1.5: Commit**

```bash
git add common/protocol/message_types.gd common/protocol/messages.gd tests/test_messages.gd
git commit -m "feat(protocol): add SCOREBOARD message (id=16) with roundtrip tests"
```

---

## Task 2: Scoreboard module — skeleton + `on_player_joined`

**Files:**
- Create: `server/sim/scoreboard.gd`
- Test: `tests/test_scoreboard.gd`

- [ ] **Step 2.1: Write the failing test for `on_player_joined`**

Create `tests/test_scoreboard.gd`:

```gdscript
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
```

- [ ] **Step 2.2: Run to verify failure**

Run:
```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests -gtest=res://tests/test_scoreboard.gd -gexit
```
Expected: FAIL — `Could not load res://server/sim/scoreboard.gd`.

- [ ] **Step 2.3: Create the skeleton scoreboard module**

Create `server/sim/scoreboard.gd`:

```gdscript
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
```

- [ ] **Step 2.4: Run tests — expected to pass**

Run:
```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests -gtest=res://tests/test_scoreboard.gd -gexit
```
Expected: 2 passes.

- [ ] **Step 2.5: Commit**

```bash
git add server/sim/scoreboard.gd tests/test_scoreboard.gd
git commit -m "feat(server): Scoreboard module skeleton + on_player_joined"
```

---

## Task 3: `on_hit` — credit enemy hits, filter friendly fire & zero-damage

**Files:**
- Modify: `server/sim/scoreboard.gd`
- Test: `tests/test_scoreboard.gd`

- [ ] **Step 3.1: Write failing tests for `on_hit`**

Append to `tests/test_scoreboard.gd`:

```gdscript
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
```

- [ ] **Step 3.2: Run tests to verify failure**

Run:
```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests -gtest=res://tests/test_scoreboard.gd -gexit
```
Expected: FAIL — `on_hit` method not found.

- [ ] **Step 3.3: Implement `on_hit`**

Add to `server/sim/scoreboard.gd` (after `on_player_joined`, before `reset`):

```gdscript
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
```

- [ ] **Step 3.4: Run tests — expected to pass**

Run:
```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests -gtest=res://tests/test_scoreboard.gd -gexit
```
Expected: 6 passes (2 from Task 2 + 4 new).

- [ ] **Step 3.5: Commit**

```bash
git add server/sim/scoreboard.gd tests/test_scoreboard.gd
git commit -m "feat(server): Scoreboard.on_hit with friendly-fire + zero-damage filtering"
```

---

## Task 4: `on_death` — kill credit + assist attribution + dedupe

**Files:**
- Modify: `server/sim/scoreboard.gd`
- Test: `tests/test_scoreboard.gd`

- [ ] **Step 4.1: Write failing tests for `on_death`**

Append to `tests/test_scoreboard.gd`:

```gdscript
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
```

- [ ] **Step 4.2: Run to verify failure**

Run:
```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests -gtest=res://tests/test_scoreboard.gd -gexit
```
Expected: FAIL — `on_death` method not found.

- [ ] **Step 4.3: Implement `on_death`**

Add to `server/sim/scoreboard.gd` (after `on_hit`, before `reset`):

```gdscript
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
```

- [ ] **Step 4.4: Run tests — expected to pass**

Run:
```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests -gtest=res://tests/test_scoreboard.gd -gexit
```
Expected: 13 passes (6 + 7 new).

- [ ] **Step 4.5: Commit**

```bash
git add server/sim/scoreboard.gd tests/test_scoreboard.gd
git commit -m "feat(server): Scoreboard.on_death with assist attribution (15s window, dedupe)"
```

---

## Task 5: `reset()` behavior test

**Files:**
- Test: `tests/test_scoreboard.gd`

- [ ] **Step 5.1: Write test for `reset()` clearing all state**

Append to `tests/test_scoreboard.gd`:

```gdscript
func test_reset_clears_all_rows_and_damager_state() -> void:
    var sb = Scoreboard.new()
    sb.on_player_joined(1, 0, "A", false)
    sb.on_player_joined(2, 1, "B", false)
    sb.on_hit(1, 2, 100, 1_000)
    sb.on_death(1, 2, 2_000)
    assert_eq(sb.snapshot().size(), 2)
    sb.reset()
    assert_eq(sb.snapshot().size(), 0)
    # Re-joining after reset gives a clean row.
    sb.on_player_joined(1, 0, "A", false)
    var row: Dictionary = _find_row(sb.snapshot(), 1)
    assert_eq(row["kills"], 0)
    assert_eq(row["hits"], 0)
```

- [ ] **Step 5.2: Run tests — expected to pass immediately**

Run:
```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests -gtest=res://tests/test_scoreboard.gd -gexit
```
Expected: 14 passes. `reset()` already exists from Task 2 — this just locks in behavior.

- [ ] **Step 5.3: Commit**

```bash
git add tests/test_scoreboard.gd
git commit -m "test(server): Scoreboard.reset clears rows and damager state"
```

---

## Task 6: Wire Scoreboard into `tick_loop.gd`

**Files:**
- Modify: `server/sim/tick_loop.gd`

- [ ] **Step 6.1: Add preload + member**

Edit `server/sim/tick_loop.gd`. Near the top, after the existing `const PickupManager = preload(...)` line, add:

```gdscript
const Scoreboard = preload("res://server/sim/scoreboard.gd")
```

And after the existing `var _team_kills: Dictionary = {0: 0, 1: 0}` line, add:

```gdscript
var _scoreboard: Scoreboard
# Tick-based accumulator for 1 Hz SCOREBOARD broadcast (TICK_RATE_HZ ticks/s).
var _scoreboard_accum_ticks: int = 0
const _SCOREBOARD_BROADCAST_EVERY_TICKS: int = 20  # = 1 s @ 20 Hz
```

- [ ] **Step 6.2: Construct the scoreboard in `set_world`**

In `set_world`, after the existing `_pickups.setup(w.heightmap, w.terrain_size)` line, add:

```gdscript
    _scoreboard = Scoreboard.new()
```

- [ ] **Step 6.3: Hook human join**

In `_on_client_connected`, at the end of the function (after the `_ws_server.send_to_peer(...)` call), add:

```gdscript
    _scoreboard.on_player_joined(pid, team, state.display_name, false)
```

- [ ] **Step 6.4: Hook AI join**

In `_spawn_ai`, at the end of the function (after `_ai_brains[pid] = brain`), add:

```gdscript
    _scoreboard.on_player_joined(pid, team, st.display_name, true)
```

- [ ] **Step 6.5: Hook HIT on tank**

In `_on_shell_hit`, after the line `var result = PartDamage.apply(victim, part_id, Constants.TANK_FIRE_DAMAGE)` and before the `hit_msg` is built, add:

```gdscript
    _scoreboard.on_hit(shell.shooter_id, victim_id, int(round(result.actual_damage)), Time.get_ticks_msec())
```

(Note: this is placed inside the branch where `victim` is a valid tank and `victim.is_invulnerable()` has already been filtered out. Invulnerable / obstacle / missing-victim branches `return` earlier, so this line is only reached on damaging-or-would-be-damaging tank hits. The damage-zero case is filtered again inside `Scoreboard.on_hit` as a belt-and-braces check.)

- [ ] **Step 6.6: Hook DEATH**

In `_on_shell_hit`, inside the `if result.tank_just_destroyed:` block, after the existing `_respawns[victim_id] = Constants.RESPAWN_COOLDOWN_S` line, add:

```gdscript
        _scoreboard.on_death(shell.shooter_id, victim_id, Time.get_ticks_msec())
```

- [ ] **Step 6.7: Hook match restart**

In `_restart_match`, after the existing `_team_kills[1] = 0` line, add:

```gdscript
    _scoreboard.reset()
```

- [ ] **Step 6.8: Broadcast at 1 Hz**

In `_step_tick`, at the end of the function (after the existing `_ws_server.broadcast(MessageType.SNAPSHOT, snap.encode())` line), add:

```gdscript
    _scoreboard_accum_ticks += 1
    if _scoreboard_accum_ticks >= _SCOREBOARD_BROADCAST_EVERY_TICKS:
        _scoreboard_accum_ticks = 0
        var sb_msg := Messages.Scoreboard.new()
        for row in _scoreboard.snapshot():
            var e := Messages.ScoreboardEntry.new()
            e.player_id = int(row["player_id"])
            e.team = int(row["team"])
            e.is_ai = bool(row["is_ai"])
            e.display_name = String(row["display_name"])
            e.kills = int(row["kills"])
            e.deaths = int(row["deaths"])
            e.assists = int(row["assists"])
            e.hits = int(row["hits"])
            e.damage = int(row["damage"])
            sb_msg.entries.append(e)
        _ws_server.broadcast(MessageType.SCOREBOARD, sb_msg.encode())
```

- [ ] **Step 6.9: Run full test suite to confirm nothing regressed**

Run:
```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests -gexit
```
Expected: all tests pass (60+ existing plus our new tests — 14+ scoreboard tests + 2 new message tests).

- [ ] **Step 6.10: Boot the server briefly and verify no runtime errors**

Run (5 s smoke — kill after it says "Ready"):
```bash
timeout 5 /Applications/Godot.app/Contents/MacOS/Godot --headless server/main_server.tscn || true
```
Expected: sees `[Server] Ready. World seed: ...` with no GDScript errors. (The `|| true` is because timeout returns non-zero.)

- [ ] **Step 6.11: Commit**

```bash
git add server/sim/tick_loop.gd
git commit -m "feat(server): wire Scoreboard into tick_loop (hits, deaths, 1 Hz broadcast)"
```

---

## Task 7: Client — receive and cache SCOREBOARD messages

**Files:**
- Modify: `client/main_client.gd`

- [ ] **Step 7.1: Add cached scoreboard state**

In `client/main_client.gd`, near the other instance vars (after `var _my_player_id: int = 0`), add:

```gdscript
# Latest SCOREBOARD payload, cached between packets so the overlay can render
# immediately on Tab press. Cleared on MATCH_RESTART; refreshed at 1 Hz from
# the server.
var _latest_scoreboard_entries: Array = []
var _my_team: int = 0
```

- [ ] **Step 7.2: Store team from CONNECT_ACK**

In `_handle_connect_ack`, right after the existing `_my_player_id = msg.player_id` line, add:

```gdscript
    _my_team = msg.team
```

- [ ] **Step 7.3: Route SCOREBOARD in `_on_message`**

In the `match msg_type:` block in `_on_message`, add one case right below the `MessageType.PONG` case:

```gdscript
        MessageType.SCOREBOARD:
            _handle_scoreboard(Messages.Scoreboard.decode(payload))
```

- [ ] **Step 7.4: Add the handler method**

Append to the file, before `_physics_process` (any sensible location — group with other `_handle_*` methods):

```gdscript
func _handle_scoreboard(msg) -> void:
    _latest_scoreboard_entries = msg.entries
    if _scoreboard_overlay != null:
        _scoreboard_overlay.set_data(_latest_scoreboard_entries, _my_team, _my_player_id)
```

(Note: `_scoreboard_overlay` will be created in Task 8. Guarding with a null check means this handler is safe to land first.)

- [ ] **Step 7.5: Add the member for the overlay (populated in Task 8)**

Near the other UI member vars (after `var _scope_overlay`), add:

```gdscript
var _scoreboard_overlay  # CanvasLayer; created in _on_name_chosen
```

- [ ] **Step 7.6: Clear on MATCH_RESTART**

In `_handle_match_restart`, after the existing `_shells.clear()` line, add:

```gdscript
    _latest_scoreboard_entries = []
    if _scoreboard_overlay != null:
        _scoreboard_overlay.set_data([], _my_team, _my_player_id)
```

- [ ] **Step 7.7: Smoke-run the server + native client for ~8 seconds to confirm SCOREBOARD decode is error-free**

Start the server in the background, connect a client, kill both after ~8 s:
```bash
timeout 8 /Applications/Godot.app/Contents/MacOS/Godot --headless server/main_server.tscn > /tmp/srv.log 2>&1 &
SRV_PID=$!
sleep 1
timeout 6 /Applications/Godot.app/Contents/MacOS/Godot --headless client/main_client.tscn > /tmp/cli.log 2>&1 || true
wait $SRV_PID 2>/dev/null || true
grep -i -E "error|script" /tmp/cli.log /tmp/srv.log | head -50
```
Expected: no GDScript errors mentioning `scoreboard`, `SCOREBOARD`, or the new message classes. (The native client has no name-entry bypass, so it stalls at the menu screen — that's fine; this step only checks that the message-handling code path doesn't crash. The server logs are the meaningful signal.) If the native client can't auto-connect due to the name screen, this step is still useful as a server-side smoke.

- [ ] **Step 7.8: Commit**

```bash
git add client/main_client.gd
git commit -m "feat(client): receive + cache SCOREBOARD messages, clear on match restart"
```

---

## Task 8: Client overlay — `scoreboard.tscn` + `scoreboard.gd`

**Files:**
- Create: `client/hud/scoreboard.gd`
- Create: `client/hud/scoreboard.tscn`

- [ ] **Step 8.1: Write the overlay script**

Create `client/hud/scoreboard.gd`:

```gdscript
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
```

- [ ] **Step 8.2: Write the scene file**

Create `client/hud/scoreboard.tscn`:

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://client/hud/scoreboard.gd" id="1"]

[node name="Scoreboard" type="CanvasLayer"]
layer = 2
visible = false
script = ExtResource("1")

[node name="Panel" type="Panel" parent="."]
anchor_right = 1.0
anchor_bottom = 1.0
mouse_filter = 2
self_modulate = Color(0, 0, 0, 0.7)

[node name="VBox" type="VBoxContainer" parent="Panel"]
anchor_left = 0.5
anchor_top = 0.08
anchor_right = 0.5
anchor_bottom = 0.92
offset_left = -720
offset_right = 720
size_flags_horizontal = 4
mouse_filter = 2

[node name="HeaderLabel" type="Label" parent="Panel/VBox"]
horizontal_alignment = 1
text = "本局战绩"
theme_override_font_sizes/font_size = 44
theme_override_colors/font_color = Color(1, 1, 1, 1)
mouse_filter = 2

[node name="Columns" type="HBoxContainer" parent="Panel/VBox"]
custom_minimum_size = Vector2(0, 520)
mouse_filter = 2

[node name="OwnColumn" type="VBoxContainer" parent="Panel/VBox/Columns"]
size_flags_horizontal = 3
mouse_filter = 2

[node name="Title" type="Label" parent="Panel/VBox/Columns/OwnColumn"]
horizontal_alignment = 1
text = "本方"
theme_override_font_sizes/font_size = 32
theme_override_colors/font_color = Color(0.3, 0.7, 1, 1)
mouse_filter = 2

[node name="Grid" type="GridContainer" parent="Panel/VBox/Columns/OwnColumn"]
size_flags_horizontal = 3
columns = 6
mouse_filter = 2

[node name="EnemyColumn" type="VBoxContainer" parent="Panel/VBox/Columns"]
size_flags_horizontal = 3
mouse_filter = 2

[node name="Title" type="Label" parent="Panel/VBox/Columns/EnemyColumn"]
horizontal_alignment = 1
text = "敌方"
theme_override_font_sizes/font_size = 32
theme_override_colors/font_color = Color(1, 0.31, 0.31, 1)
mouse_filter = 2

[node name="Grid" type="GridContainer" parent="Panel/VBox/Columns/EnemyColumn"]
size_flags_horizontal = 3
columns = 6
mouse_filter = 2
```

- [ ] **Step 8.3: Open the scene in Godot headless to confirm it parses**

Run:
```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --check-only client/hud/scoreboard.tscn 2>&1 | grep -i error || echo "OK: no scene errors"
```
Expected: prints `OK: no scene errors`. (If Godot's CLI doesn't support `--check-only` on a tscn, skip and rely on the next task's manual smoke.)

- [ ] **Step 8.4: Commit**

```bash
git add client/hud/scoreboard.gd client/hud/scoreboard.tscn
git commit -m "feat(client): scoreboard overlay scene + script (no Tab handling yet)"
```

---

## Task 9: Client — instantiate overlay + Tab input

**Files:**
- Modify: `client/main_client.gd`

- [ ] **Step 9.1: Preload the scene**

In `client/main_client.gd`, near the other `preload("res://client/hud/*")` lines (look for `const BasicHUD = preload(...)`), add:

```gdscript
const ScoreboardOverlay = preload("res://client/hud/scoreboard.tscn")
```

- [ ] **Step 9.2: Instantiate in `_on_name_chosen`**

In `_on_name_chosen`, right after the existing `_scope_overlay = ScopeOverlay.instantiate(); add_child(_scope_overlay)` block, add:

```gdscript
    _scoreboard_overlay = ScoreboardOverlay.instantiate()
    add_child(_scoreboard_overlay)
```

- [ ] **Step 9.3: Add Tab input handler**

Append to `main_client.gd` as a top-level function:

```gdscript
# Tab is hold-to-view. We listen in _unhandled_input (not tank_input.gd) so it
# works even while the pointer isn't locked (e.g. during respawn or after Esc).
# ev.echo is guarded so the held-down repeat doesn't toggle off.
func _unhandled_input(ev: InputEvent) -> void:
    if ev is InputEventKey and ev.keycode == KEY_TAB and not ev.echo:
        if _scoreboard_overlay != null:
            if ev.pressed:
                _scoreboard_overlay.set_data(_latest_scoreboard_entries, _my_team, _my_player_id)
                _scoreboard_overlay.visible = true
            else:
                _scoreboard_overlay.visible = false
```

- [ ] **Step 9.4: Smoke run native**

Run the server in the background, then the native client in the foreground:
```bash
timeout 30 /Applications/Godot.app/Contents/MacOS/Godot --headless server/main_server.tscn > /tmp/srv.log 2>&1 &
SRV_PID=$!
sleep 1
/Applications/Godot.app/Contents/MacOS/Godot client/main_client.tscn &
CLI_PID=$!
echo "Connect in the client window, fire a few shots, hold Tab to verify scoreboard shows entries. Ctrl-C the client when done."
wait $CLI_PID
kill $SRV_PID 2>/dev/null || true
grep -i -E "error|script error" /tmp/srv.log | head -20
```
Expected: the overlay shows two columns with rows for live tanks; own row is yellow-highlighted; AI rows show `(AI)` suffix; numbers update ~1 Hz after kills/hits. No GDScript errors in `/tmp/srv.log`.

- [ ] **Step 9.5: Commit**

```bash
git add client/main_client.gd
git commit -m "feat(client): Tab-hold to show scoreboard overlay"
```

---

## Task 10: Web font CJK subset + full verification

**Files:**
- Modify: `build.sh`

- [ ] **Step 10.1: Identify new CJK characters**

The overlay renders: `本局战绩` (header), `本方` / `敌方` (column titles), `名字`, `命中`, `伤害` (column headers). `(AI)` is ASCII. Numbers are ASCII.

Current `SUBSET_CJK_TEXT="炮管损坏重生阵亡击中了装填就绪护盾"`.

New chars to add: `本` `局` `战` `绩` `方` `敌` `名` `字` `命` `伤` `害`. (`中` is already in `击中了`.)

- [ ] **Step 10.2: Update `build.sh`**

Edit `build.sh`. Find the line:

```
SUBSET_CJK_TEXT="炮管损坏重生阵亡击中了装填就绪护盾"
```

Replace with:

```
SUBSET_CJK_TEXT="炮管损坏重生阵亡击中了装填就绪护盾本局战绩方敌名字命伤害"
```

And update the comment two lines above from:

```
# Sources (greppable): "炮管损坏", "重生", "阵亡", "击中了", "装填", "就绪", "护盾".
```

to:

```
# Sources (greppable): "炮管损坏", "重生", "阵亡", "击中了", "装填", "就绪", "护盾",
# scoreboard: "本局战绩", "本方", "敌方", "名字", "命中", "伤害".
```

- [ ] **Step 10.3: Run the full test suite**

Run:
```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests -gexit
```
Expected: all 60+ existing tests plus 14+ scoreboard tests plus 2 message-roundtrip tests pass (total ≥ 76).

- [ ] **Step 10.4: Manual verification — end-to-end on native**

```bash
timeout 60 /Applications/Godot.app/Contents/MacOS/Godot --headless server/main_server.tscn > /tmp/srv.log 2>&1 &
SRV_PID=$!
sleep 1
/Applications/Godot.app/Contents/MacOS/Godot client/main_client.tscn
kill $SRV_PID 2>/dev/null || true
```

Manually verify, in order:
1. Hold Tab: overlay appears with your row on the left (BLUE), AI opponents on the right (RED).
2. Fire and hit an enemy AI: after ~1 s, Tab shows your `命中` and `伤害` incremented.
3. Kill an AI: `K` column shows 1 for you; victim's `D` shows 1. No `A` increment for you.
4. Have one AI damage another enemy then finish it yourself: check that the damaging AI gets `A` +1, and you still get the kill.
5. Get damaged by an enemy AI, then die: your `D` increments.
6. Play until a team hits 100 → world regenerates; Tab shows all zeros.
7. Leave Tab: overlay hides.

- [ ] **Step 10.5: Manual verification — web build**

Only if pyftsubset / fonttools is installed. Otherwise skip and note as manual-later.

```bash
./build.sh
```
Expected: no errors. Then open the served bundle (e.g. via `./deploy.sh` which calls `python3 tools/serve_web.py 8000`) in a browser, connect to a running server, hold Tab, verify: no tofu (□) glyphs in the overlay; `本局战绩`, `本方`, `敌方`, `名字`, `命中`, `伤害` all render correctly.

- [ ] **Step 10.6: Commit**

```bash
git add build.sh
git commit -m "build(web): extend CJK subset for scoreboard overlay glyphs"
```

---

## Task 11: Final cleanup + sanity

- [ ] **Step 11.1: Run full tests once more**

Run:
```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests -gexit
```
Expected: all tests pass.

- [ ] **Step 11.2: `git status` — confirm nothing left behind**

Run:
```bash
git status
```
Expected: clean tree (or only unrelated pre-existing untracked files like `tests/test_tank_tank_collision.gd` from before this feature).

- [ ] **Step 11.3: Verify commit history**

Run:
```bash
git log --oneline -n 10
```
Expected: ~6 new commits on top of `main`, each one a small self-contained step (protocol, skeleton, on_hit, on_death, wiring, client receive, overlay scene, Tab input, CJK, etc.). No fixup / squash required.

---

## Self-review checklist (done during plan authoring)

- **Spec coverage**: Every spec section maps to at least one task.
  - Architecture → Tasks 2, 6, 8, 9 (server module, wiring, overlay, Tab)
  - Data structures → Task 2
  - Wire format → Task 1
  - Scoring rules → Tasks 3, 4
  - Integration points → Task 6
  - Client UI layout → Task 8
  - Tab handling → Task 9
  - Testing → Tasks 2–5 (unit), Task 1 (message), Task 10 (e2e)
  - Edge cases → covered by unit tests in Tasks 3–5 (friendly fire, zero damage, suicide, assist window, dedupe)
  - CJK subset → Task 10
- **No placeholders**: every step has concrete code + paths + commands.
- **Type consistency**: `on_player_joined(pid, team, display_name, is_ai)`, `on_hit(shooter_id, victim_id, damage, now_ms)`, `on_death(killer_id, victim_id, now_ms)`, `reset()`, `snapshot()` — signatures identical across the plan and spec. `ScoreboardEntry` field list identical between protocol, snapshot builder (Task 6.8), and UI consumer (Task 8). Message class uses `entries: Array` on both ends.
- **Non-fussed YAGNI**: no shots-fired/accuracy; no per-player history; no leaderboard query path; no persistence anywhere.
