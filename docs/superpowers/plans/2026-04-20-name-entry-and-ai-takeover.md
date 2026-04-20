# Name Entry, AI Takeover, and 3D Name Labels Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a pre-game name-entry screen (random default + dice reroll + manual input + persistence), broadcast each tank's display name in the snapshot, render a billboard label above every tank, and convert disconnected humans into AI named `P<id>`.

**Architecture:** Name lives directly on `TankSnapshot` (no out-of-band messages). Existing `_maintain_ai_population` drives the human→AI swap; a one-line addition to `_on_client_disconnected` makes the swap happen in the same tick. Sanitization is a static helper extracted to its own file for clean unit tests. Pre-game UI is a separate `Control` scene shown by `main_client.gd._ready()` before the WebSocket is created — when it emits `joined`, the existing connect path runs.

**Tech Stack:** Godot 4.6.2 GDScript, GUT for tests, custom binary WebSocket protocol (length-prefixed strings via `Codec.write_string`), `ConfigFile` for persistence (maps to IndexedDB on web).

**Spec:** `docs/superpowers/specs/2026-04-20-name-entry-and-ai-takeover-design.md`

**Run tests with:**
```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests -gexit
```

Single test script:
```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests -gtest=res://tests/test_name_pool.gd -gexit
```

---

## Task 1: Random name pool

Pure data + one static function. Easiest TDD start; no dependencies.

**Files:**
- Create: `client/menu/name_pool.gd`
- Test: `tests/test_name_pool.gd`

- [ ] **Step 1: Write the failing test**

Create `tests/test_name_pool.gd`:

```gdscript
extends GutTest

const NamePool = preload("res://client/menu/name_pool.gd")

func test_random_name_returns_value_from_pool() -> void:
    var name := NamePool.random_name()
    assert_true(NamePool.NAMES.has(name), "random_name() returned %s which is not in NAMES" % name)

func test_random_name_distribution_has_variety() -> void:
    # 100 calls should produce >= 5 distinct names — sanity check that the RNG
    # isn't stuck on a single value. With a 60-name pool the probability of
    # fewer than 5 distinct names in 100 draws is astronomically small.
    var seen: Dictionary = {}
    for i in 100:
        seen[NamePool.random_name()] = true
    assert_true(seen.size() >= 5, "Only %d distinct names in 100 draws" % seen.size())

func test_pool_is_non_empty() -> void:
    assert_true(NamePool.NAMES.size() > 0)
```

- [ ] **Step 2: Run test — verify it fails**

Run:
```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests -gtest=res://tests/test_name_pool.gd -gexit
```
Expected: FAIL — `Could not load 'res://client/menu/name_pool.gd'`.

- [ ] **Step 3: Create the implementation**

Create `client/menu/` directory if missing, then create `client/menu/name_pool.gd`:

```gdscript
class_name NamePool

const NAMES: Array[String] = [
    "Wolf", "Falcon", "Bandit", "Rogue", "Viper", "Hawk", "Maverick",
    "Bear", "Ghost", "Striker", "Raven", "Cobra", "Shadow", "Vulcan",
    "Reaper", "Hunter", "Tiger", "Lynx", "Panther", "Jaguar", "Eagle",
    "Phantom", "Wraith", "Nomad", "Drifter", "Outlaw", "Saber", "Lance",
    "Forge", "Anvil", "Titan", "Atlas", "Orion", "Nova", "Comet",
    "Blaze", "Ember", "Frost", "Storm", "Surge", "Bolt", "Pulse",
    "Echo", "Static", "Riot", "Havoc", "Mayhem", "Ronin", "Shogun",
    "Vandal", "Pirate", "Corsair", "Crusader", "Templar", "Spartan",
    "Centurion", "Legion", "Marauder", "Brawler", "Boomer",
]

static func random_name() -> String:
    return NAMES[randi() % NAMES.size()]
```

- [ ] **Step 4: Run test — verify it passes**

Run the same single-test command from Step 2.
Expected: 3/3 PASS.

- [ ] **Step 5: Commit**

```bash
git add client/menu/name_pool.gd tests/test_name_pool.gd
git commit -m "feat(client): add random name pool"
```

---

## Task 2: Name sanitizer

Static helper, pure function. Lives in `server/util/` so the test doesn't have to preload `tick_loop.gd` (which would pull in Messages, Codec, AIBrain, World, etc.).

**Files:**
- Create: `server/util/name_sanitizer.gd`
- Test: `tests/test_name_sanitizer.gd`

- [ ] **Step 1: Write the failing test**

Create `tests/test_name_sanitizer.gd`:

```gdscript
extends GutTest

const NameSanitizer = preload("res://server/util/name_sanitizer.gd")

func test_passthrough_normal_name() -> void:
    assert_eq(NameSanitizer.sanitize("Wolf", 7), "Wolf")

func test_strips_leading_and_trailing_whitespace() -> void:
    assert_eq(NameSanitizer.sanitize("  Wolf  ", 7), "Wolf")

func test_truncates_to_12_characters() -> void:
    assert_eq(NameSanitizer.sanitize("VeryLongNameOver12", 7), "VeryLongName")

func test_preserves_internal_space() -> void:
    assert_eq(NameSanitizer.sanitize("hello world", 7), "hello world")

func test_strips_cjk_then_falls_back() -> void:
    # 狼王 has no printable-ASCII chars → empty after filter → fallback to P<pid>
    assert_eq(NameSanitizer.sanitize("狼王", 42), "P42")

func test_strips_control_chars() -> void:
    assert_eq(NameSanitizer.sanitize("AB\u0001CD", 7), "ABCD")

func test_empty_input_falls_back() -> void:
    assert_eq(NameSanitizer.sanitize("", 9), "P9")

func test_whitespace_only_falls_back() -> void:
    assert_eq(NameSanitizer.sanitize("   ", 9), "P9")

func test_mixed_cjk_and_ascii_keeps_only_ascii() -> void:
    assert_eq(NameSanitizer.sanitize("Wolf王", 7), "Wolf")
```

- [ ] **Step 2: Run test — verify it fails**

Run:
```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests -gtest=res://tests/test_name_sanitizer.gd -gexit
```
Expected: FAIL — `Could not load 'res://server/util/name_sanitizer.gd'`.

- [ ] **Step 3: Create the implementation**

Create `server/util/` directory if missing, then create `server/util/name_sanitizer.gd`:

```gdscript
class_name NameSanitizer

const MAX_LEN: int = 12

static func sanitize(raw: String, pid: int) -> String:
    var s := raw.strip_edges()
    var clean := ""
    for c in s:
        var code := c.unicode_at(0)
        if code >= 0x20 and code <= 0x7E:
            clean += c
    if clean.length() > MAX_LEN:
        clean = clean.substr(0, MAX_LEN)
    if clean.is_empty():
        return "P" + str(pid)
    return clean
```

- [ ] **Step 4: Run test — verify it passes**

Run the same single-test command from Step 2.
Expected: 9/9 PASS.

- [ ] **Step 5: Commit**

```bash
git add server/util/name_sanitizer.gd tests/test_name_sanitizer.gd
git commit -m "feat(server): add name sanitizer with ASCII filter and length cap"
```

---

## Task 3: Add `display_name` field to `TankState`

Pure data addition — no behavior change yet. Existing tests must still pass.

**Files:**
- Modify: `shared/tank/tank_state.gd`

- [ ] **Step 1: Add the field**

Open `shared/tank/tank_state.gd`. Find the block of top-level `var` declarations (player_id, team, pos, yaw, etc.) and add this line near the others:

```gdscript
var display_name: String = ""
```

Place it next to `player_id` and `team` since it's identity/cosmetic metadata, not simulation state.

- [ ] **Step 2: Run full test suite — verify nothing regressed**

Run:
```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests -gexit
```
Expected: all existing tests still pass (60 + 3 + 9 = 72 tests).

- [ ] **Step 3: Commit**

```bash
git add shared/tank/tank_state.gd
git commit -m "feat(shared): add display_name field to TankState"
```

---

## Task 4: Add `display_name` to `TankSnapshot` wire format

Append a length-prefixed string to the per-tank encoding. This is the only protocol change. TDD it via `test_messages.gd`.

**Files:**
- Modify: `tests/test_messages.gd:54-73` (extend `test_snapshot_roundtrip_multiple_tanks`)
- Modify: `common/protocol/messages.gd` (TankSnapshot class + Snapshot.add_tank/encode/decode)

- [ ] **Step 1: Extend the failing test**

Open `tests/test_messages.gd`. Replace the entire `test_snapshot_roundtrip_multiple_tanks` function (currently lines 54–73) with:

```gdscript
func test_snapshot_roundtrip_multiple_tanks() -> void:
    var msg := Messages.Snapshot.new()
    msg.tick = 1234
    msg.server_time_ms = 9876543
    msg.add_tank(1, 0, Vector3(10, 0, 20), 0.5, 0.1, 0.0, 850, 777, 24, 0.0, 0.0, "Wolf")
    msg.add_tank(2, 1, Vector3(-30, 2, 40), 1.5, 0.2, 0.3, 600, 888, 12, 1.75, 6.3, "P42")
    var bytes := msg.encode()
    var decoded := Messages.Snapshot.decode(bytes)
    assert_eq(decoded.tick, 1234)
    assert_eq(decoded.server_time_ms, 9876543)
    assert_eq(decoded.tanks.size(), 2)
    assert_eq(decoded.tanks[0].player_id, 1)
    assert_eq(decoded.tanks[0].hp, 850)
    assert_eq(decoded.tanks[0].last_input_tick, 777)
    assert_eq(decoded.tanks[0].ammo, 24)
    assert_almost_eq(decoded.tanks[0].reload_remaining, 0.0, 0.001)
    assert_eq(decoded.tanks[1].ammo, 12)
    assert_almost_eq(decoded.tanks[1].reload_remaining, 1.75, 0.001)
    assert_almost_eq(decoded.tanks[0].turret_regen_remaining, 0.0, 0.001)
    assert_almost_eq(decoded.tanks[1].turret_regen_remaining, 6.3, 0.001)
    assert_eq(decoded.tanks[0].display_name, "Wolf")
    assert_eq(decoded.tanks[1].display_name, "P42")

func test_snapshot_roundtrip_default_display_name_is_empty() -> void:
    # add_tank's display_name parameter defaults to "" — verifies callers that
    # don't pass it (none expected post-rollout, but the default is part of
    # the contract) get an empty string back, not crash on encode/decode.
    var msg := Messages.Snapshot.new()
    msg.tick = 1
    msg.server_time_ms = 0
    msg.add_tank(1, 0, Vector3.ZERO, 0.0, 0.0, 0.0, 1000, 0, 0, 0.0, 0.0)
    var bytes := msg.encode()
    var decoded := Messages.Snapshot.decode(bytes)
    assert_eq(decoded.tanks[0].display_name, "")
```

- [ ] **Step 2: Run snapshot tests — verify they fail**

Run:
```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests -gtest=res://tests/test_messages.gd -gexit
```
Expected: FAIL — first assertion on `display_name` fails (or earlier failure on the extra arg to `add_tank`).

- [ ] **Step 3: Add the field to `TankSnapshot`**

Open `common/protocol/messages.gd`. In the `TankSnapshot` class (around line 98), add this line at the end of the field block (right after `var turret_regen_remaining: float = 0.0`):

```gdscript
    var display_name: String = ""
```

- [ ] **Step 4: Update `Snapshot.add_tank` signature**

In the same file, replace the `add_tank` function (around line 121) with:

```gdscript
    func add_tank(pid: int, team: int, pos: Vector3, yaw: float, turret_yaw: float, gun_pitch: float, hp: int, last_input_tick: int = 0, ammo: int = 0, reload_remaining: float = 0.0, turret_regen_remaining: float = 0.0, display_name: String = "") -> void:
        var t := TankSnapshot.new()
        t.player_id = pid
        t.team = team
        t.pos = pos
        t.yaw = yaw
        t.turret_yaw = turret_yaw
        t.gun_pitch = gun_pitch
        t.hp = hp
        t.last_input_tick = last_input_tick
        t.ammo = ammo
        t.reload_remaining = reload_remaining
        t.turret_regen_remaining = turret_regen_remaining
        t.display_name = display_name
        tanks.append(t)
```

- [ ] **Step 5: Update `Snapshot.encode` to write the field**

In the per-tank encode loop (around line 141), add this line **after** `Codec.write_f32(buf, t.turret_regen_remaining)` and **before** the loop's closing:

```gdscript
            Codec.write_string(buf, t.display_name)
```

The full updated loop body should be:
```gdscript
        for t in tanks:
            Codec.write_u16(buf, t.player_id)
            Codec.write_u8(buf, t.team)
            Codec.write_vec3(buf, t.pos)
            Codec.write_f32(buf, t.yaw)
            Codec.write_f32(buf, t.turret_yaw)
            Codec.write_f32(buf, t.gun_pitch)
            Codec.write_u16(buf, t.hp)
            Codec.write_u32(buf, t.last_input_tick)
            Codec.write_u8(buf, t.ammo)
            Codec.write_f32(buf, t.reload_remaining)
            Codec.write_f32(buf, t.turret_regen_remaining)
            Codec.write_string(buf, t.display_name)
```

- [ ] **Step 6: Update `Snapshot.decode` to read the field**

In the per-tank decode loop (around line 163), add this line **after** `t.turret_regen_remaining = Codec.read_f32(buf, c)` and **before** `m.tanks.append(t)`:

```gdscript
            t.display_name = Codec.read_string(buf, c)
```

The full updated loop body should be:
```gdscript
        for i in n:
            var t := TankSnapshot.new()
            t.player_id = Codec.read_u16(buf, c)
            t.team = Codec.read_u8(buf, c)
            t.pos = Codec.read_vec3(buf, c)
            t.yaw = Codec.read_f32(buf, c)
            t.turret_yaw = Codec.read_f32(buf, c)
            t.gun_pitch = Codec.read_f32(buf, c)
            t.hp = Codec.read_u16(buf, c)
            t.last_input_tick = Codec.read_u32(buf, c)
            t.ammo = Codec.read_u8(buf, c)
            t.reload_remaining = Codec.read_f32(buf, c)
            t.turret_regen_remaining = Codec.read_f32(buf, c)
            t.display_name = Codec.read_string(buf, c)
            m.tanks.append(t)
```

- [ ] **Step 7: Run snapshot tests — verify they pass**

Run the single-test command from Step 2.
Expected: all snapshot tests pass.

- [ ] **Step 8: Run full suite — verify no other test regressed**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests -gexit
```
Expected: all tests pass.

- [ ] **Step 9: Commit**

```bash
git add common/protocol/messages.gd tests/test_messages.gd
git commit -m "feat(protocol): add display_name to TankSnapshot"
```

---

## Task 5: Server-side wiring — sanitize on connect, name AI, push name into snapshot

Three small edits to `tick_loop.gd`. No new tests — existing GUT suite still passes; behavioral verification is the manual run in Task 6/9/10.

**Files:**
- Modify: `server/sim/tick_loop.gd`

- [ ] **Step 1: Add NameSanitizer preload at the top of the file**

Open `server/sim/tick_loop.gd`. Locate the existing `const`/`preload` block at the top (after the `extends Node` line and any other declarations). Add:

```gdscript
const NameSanitizer = preload("res://server/util/name_sanitizer.gd")
```

If a `class_name`-loaded version is preferred (NameSanitizer has `class_name`), the explicit preload still works and is consistent with how Messages/Codec are loaded elsewhere in this file.

- [ ] **Step 2: Sanitize the incoming player_name in `_on_client_connected`**

Find `_on_client_connected` (around line 150). After the line:

```gdscript
    var state = _world.spawn_tank(pid, team)
```

add:

```gdscript
    state.display_name = NameSanitizer.sanitize(connect_msg.player_name, pid)
```

- [ ] **Step 3: Name AI tanks `P<pid>` in `_spawn_ai`**

Find `_spawn_ai` (around line 245). After the line:

```gdscript
    st.is_ai = true
```

add:

```gdscript
    st.display_name = "P" + str(pid)
```

- [ ] **Step 4: Pass display_name into the snapshot tank loop**

Find the snapshot fill loop (around line 141–145). Replace:

```gdscript
            snap.add_tank(s.player_id, s.team, s.pos, s.yaw, s.turret_yaw, s.gun_pitch, s.hp, s.last_acked_input_tick, s.ammo, s.reload_remaining, turret_regen)
```

with:

```gdscript
            snap.add_tank(s.player_id, s.team, s.pos, s.yaw, s.turret_yaw, s.gun_pitch, s.hp, s.last_acked_input_tick, s.ammo, s.reload_remaining, turret_regen, s.display_name)
```

- [ ] **Step 5: Run full test suite — verify no regression**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests -gexit
```
Expected: all tests pass.

- [ ] **Step 6: Smoke-test the server boots cleanly**

Run:
```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless server/main_server.tscn
```
Expected: server starts, prints `[Server] WS listening on :8910` (or similar), no script errors. Press Ctrl-C to stop. If port 8910 is in use:
```bash
lsof -iTCP:8910 -sTCP:LISTEN
kill <pid>
```

- [ ] **Step 7: Commit**

```bash
git add server/sim/tick_loop.gd
git commit -m "feat(server): assign display_name on connect and to AI tanks"
```

---

## Task 6: Immediate AI fill on disconnect

One-line change so the AI replacement spawns in the same tick as the human leaves rather than waiting for the next tick boundary.

**Files:**
- Modify: `server/sim/tick_loop.gd:169-177` (`_on_client_disconnected`)

- [ ] **Step 1: Add the immediate top-up call**

Find `_on_client_disconnected` (currently around lines 169–177). After the existing final line:

```gdscript
    print("[Server] Player %d (peer %d) disconnected" % [pid, peer_id])
```

add:

```gdscript
    _maintain_ai_population()
```

The full function should now read:

```gdscript
func _on_client_disconnected(peer_id: int) -> void:
    var pid: int = _ws_server.player_id_for_peer(peer_id)
    if pid == 0:
        return
    _world.remove_tank(pid)
    _latest_input.erase(pid)
    _respawns.erase(pid)
    _ws_server.unbind_peer(peer_id)
    print("[Server] Player %d (peer %d) disconnected" % [pid, peer_id])
    _maintain_ai_population()
```

- [ ] **Step 2: Run full test suite — verify no regression**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests -gexit
```
Expected: all tests pass.

- [ ] **Step 3: Commit**

```bash
git add server/sim/tick_loop.gd
git commit -m "feat(server): refill AI immediately when a human disconnects"
```

---

## Task 7: Pre-game name entry UI scene

Build the scene file by hand-editing the `.tscn`. UI scenes can't be TDD'd in any meaningful way — verify by running the client and looking at it in Task 9.

**Files:**
- Create: `client/menu/name_entry.tscn`
- Create: `client/menu/name_entry.gd`

- [ ] **Step 1: Create the scene file**

Create `client/menu/name_entry.tscn` with this exact content:

```
[gd_scene load_steps=2 format=3 uid="uid://b7namentry00001"]

[ext_resource type="Script" path="res://client/menu/name_entry.gd" id="1_script"]

[node name="NameEntry" type="Control"]
anchors_preset = 15
anchor_right = 1.0
anchor_bottom = 1.0
grow_horizontal = 2
grow_vertical = 2
script = ExtResource("1_script")

[node name="Backdrop" type="ColorRect" parent="."]
anchors_preset = 15
anchor_right = 1.0
anchor_bottom = 1.0
color = Color(0.05, 0.05, 0.08, 0.9)

[node name="Center" type="CenterContainer" parent="."]
anchors_preset = 15
anchor_right = 1.0
anchor_bottom = 1.0

[node name="VBox" type="VBoxContainer" parent="Center"]
custom_minimum_size = Vector2(420, 0)
theme_override_constants/separation = 20

[node name="Title" type="Label" parent="Center/VBox"]
text = "Enter Name"
horizontal_alignment = 1
theme_override_font_sizes/font_size = 48

[node name="Row" type="HBoxContainer" parent="Center/VBox"]
theme_override_constants/separation = 12

[node name="NameField" type="LineEdit" parent="Center/VBox/Row"]
custom_minimum_size = Vector2(280, 56)
size_flags_horizontal = 3
max_length = 12
placeholder_text = "name..."

[node name="DiceButton" type="Button" parent="Center/VBox/Row"]
custom_minimum_size = Vector2(56, 56)
text = "🎲"

[node name="JoinButton" type="Button" parent="Center/VBox"]
custom_minimum_size = Vector2(0, 56)
text = "Join Battle"
```

(Don't worry if the `uid` value differs — Godot will regenerate the `.uid` sidecar on first load. The hardcoded uid above is just to make the scene file parseable on its own.)

- [ ] **Step 2: Create the script**

Create `client/menu/name_entry.gd`:

```gdscript
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
```

- [ ] **Step 3: Verify scene parses**

Open the scene briefly to make sure Godot doesn't reject it. Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --check-only client/menu/name_entry.tscn
```

Expected: exits 0 with no parse errors. If `--check-only` isn't supported in this Godot version, just open the editor and load the scene briefly:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --editor --quit-after 2
```
Expected: exits cleanly with no script errors mentioning `name_entry`.

- [ ] **Step 4: Commit**

```bash
git add client/menu/name_entry.tscn client/menu/name_entry.gd
git commit -m "feat(client): add pre-game name entry scene"
```

---

## Task 8: Defer WebSocket connection in `main_client.gd` until name is chosen

Wire the menu in. Holds the chosen name in a member var, then the existing `Connect` send uses it.

**Files:**
- Modify: `client/main_client.gd:24` (add member var)
- Modify: `client/main_client.gd:68-90` (defer WS construction)
- Modify: `client/main_client.gd:132-137` (use chosen name)

- [ ] **Step 1: Add the member var**

Open `client/main_client.gd`. Find the existing line `var _ws` (line 24). Right below it, add:

```gdscript
var _pending_player_name: String = ""
```

- [ ] **Step 2: Defer WSClient creation in `_ready`**

In `_ready()` (currently lines 68–90), find this block:

```gdscript
    _ws = WSClient.new()
    add_child(_ws)
    _ws.connected.connect(_on_connected)
    _ws.message.connect(_on_message)
    _ws.disconnected.connect(_on_disconnected)
    _ws.connect_to_url(server_url)
```

Replace it with:

```gdscript
    var menu = preload("res://client/menu/name_entry.tscn").instantiate()
    menu.joined.connect(_on_name_chosen)
    add_child(menu)
```

The other `_ready` initialization (DirectionalLight, Environment, TerrainBuilder, ObstacleBuilder, ThirdPersonCam, AudioListener3D, TankInput, BasicHUD, ScopeOverlay, sound streams) stays exactly as-is — only the WSClient block moves.

- [ ] **Step 3: Add `_on_name_chosen` handler**

Find the `_on_connected()` function (currently around line 132). Insert the new `_on_name_chosen` function **above** it:

```gdscript
func _on_name_chosen(player_name: String) -> void:
    _pending_player_name = player_name
    _ws = WSClient.new()
    add_child(_ws)
    _ws.connected.connect(_on_connected)
    _ws.message.connect(_on_message)
    _ws.disconnected.connect(_on_disconnected)
    _ws.connect_to_url(server_url)
```

- [ ] **Step 4: Use the chosen name in `_on_connected`**

In `_on_connected()` (around line 135), replace:

```gdscript
    msg.player_name = "Player"
```

with:

```gdscript
    msg.player_name = _pending_player_name
```

- [ ] **Step 5: Run full test suite — verify no regression**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests -gexit
```
Expected: all tests pass.

- [ ] **Step 6: Manual smoke test**

In one terminal, start the server:
```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless server/main_server.tscn
```

In another, launch the client:
```bash
/Applications/Godot.app/Contents/MacOS/Godot client/main_client.tscn
```

Verify:
- The Name Entry screen shows on launch (terrain/sky/HUD do NOT yet appear).
- A pre-filled name is shown in the LineEdit (random word from the pool).
- Clicking 🎲 changes the name to a different random pool word.
- Typing a custom name (e.g. `Tester`) updates the field.
- Clicking Join Battle dismisses the menu and the client connects, terrain renders, HUD shows "CONNECTED".

Stop both processes (Ctrl-C). Note: the 3D label above the tank is **not yet visible** — that comes in Task 9. The name is being sent and stored on the server, but no client renders it.

- [ ] **Step 7: Commit**

```bash
git add client/main_client.gd
git commit -m "feat(client): defer WebSocket connect until player picks name"
```

---

## Task 9: Render the player name as a `Label3D` above each tank

**Files:**
- Modify: `client/tank/tank_view.gd` (add Label3D + setter; in `_build_mesh`)
- Modify: `client/main_client.gd:189-228` (`_handle_snapshot` — call `set_display_name`)

- [ ] **Step 1: Add the `_name_label` member and Label3D in `tank_view.gd`**

Open `client/tank/tank_view.gd`. Near the existing top-level member declarations (where `_hp_bar_*` etc. live), add:

```gdscript
var _name_label: Label3D = null
```

Then, at the end of `_build_mesh` (currently lines 61–151) — directly after the last `add_child(...)` call that adds the HP bar — add the label construction:

```gdscript
    _name_label = Label3D.new()
    _name_label.text = ""
    _name_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
    _name_label.no_depth_test = false
    _name_label.pixel_size = 0.005
    _name_label.font_size = 32
    _name_label.outline_size = 8
    _name_label.outline_modulate = Color.BLACK
    _name_label.modulate = Color.WHITE
    _name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _name_label.position = Vector3(0, 4.2, 0)
    add_child(_name_label)
```

(`no_depth_test = false` is the Godot default — set explicitly so the intent ("terrain occludes the label, no x-ray names through hills") is documented at the call site.)

- [ ] **Step 2: Add the setter**

Append a new function at the end of `client/tank/tank_view.gd`:

```gdscript
func set_display_name(n: String) -> void:
    if _name_label != null and _name_label.text != n:
        _name_label.text = n
```

The early-out on `_name_label.text != n` avoids touching the `Label3D` (and its mesh re-rasterization) at 20 Hz when the name hasn't changed.

- [ ] **Step 3: Push name from snapshot in `main_client.gd`**

Open `client/main_client.gd`. In `_handle_snapshot` (currently around lines 189–228), find the inner `for t in msg.tanks:` loop. Right after the `_ensure_view(t.player_id, t.team, ...)` call **inside both branches** of the `if t.player_id == _my_player_id:` / `else:` check, add:

```gdscript
            _tanks[t.player_id].set_display_name(t.display_name)
```

Concretely, the loop body should look like:

```gdscript
    for t in msg.tanks:
        seen[t.player_id] = true
        if t.player_id == _my_player_id:
            _ensure_view(t.player_id, t.team, true)
            _tanks[t.player_id].set_display_name(t.display_name)
            if _prediction:
                # ...existing reconcile + turret-sync block, unchanged...
            _camera.set_target(_tanks[t.player_id])
            _hud.set_hp(t.hp)
            # ...rest unchanged...
        else:
            _ensure_view(t.player_id, t.team, false)
            _tanks[t.player_id].set_display_name(t.display_name)
            if not _remote_interp.has(t.player_id):
                _remote_interp[t.player_id] = Interpolation.new()
            # ...rest unchanged...
```

Place each `set_display_name` call immediately after `_ensure_view(...)` so the view is guaranteed to exist before the setter runs.

- [ ] **Step 4: Run full test suite — verify no regression**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests -gexit
```
Expected: all tests pass.

- [ ] **Step 5: Manual two-client smoke test**

Start the server:
```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless server/main_server.tscn
```

Launch two clients in separate terminals (the second after the first has joined):
```bash
/Applications/Godot.app/Contents/MacOS/Godot client/main_client.tscn
```

In Client 1, name yourself `Alice`. In Client 2, name yourself `Bob`. Verify:
- Above your own tank: your chosen name (`Alice` for client 1, `Bob` for client 2).
- Above the other player's tank: the other player's name.
- Above the AI tanks (~8 of them): each shows `P<n>` where `<n>` is the AI's player_id (e.g. `P3`, `P4`, `P5`).
- Names are camera-facing at all angles.
- Standing behind a hill, names of tanks on the far side are hidden by the terrain (depth-tested).

- [ ] **Step 6: Commit**

```bash
git add client/tank/tank_view.gd client/main_client.gd
git commit -m "feat(client): render player names as 3D billboard above tanks"
```

---

## Task 10: Disconnect-to-AI takeover end-to-end verification

No code changes — this task is purely about confirming that Tasks 5/6 produce the right behavior visually. It's a separate task because it's the most user-visible behavior change and worth an explicit checkpoint before the build-step tweak.

- [ ] **Step 1: Set up two clients + server**

Start the server. Launch two clients with names `Alice` and `Bob`. Confirm both tanks have name labels.

- [ ] **Step 2: Disconnect Client 2 (Bob)**

Close the Client 2 window (or kill its process).

- [ ] **Step 3: Verify takeover in Client 1**

In Client 1's view, within ~50 ms (one tick) of Bob's disconnect:
- Bob's tank visually disappears at his position.
- A new AI tank appears at Bob's team's standard spawn point.
- The new tank has a `P<n>` label where `<n>` is one greater than the highest existing player_id (since `allocate_player_id` is monotonic).
- Total tank count remains at `Constants.TARGET_TOTAL_TANKS = 10`.

If the AI doesn't appear within a few seconds, the immediate top-up call from Task 6 is wrong — re-check `_on_client_disconnected`.

- [ ] **Step 4: Repeat the cycle**

Reconnect Bob with a different name (e.g. `Carol`). Verify Carol appears, total stays at 10. Disconnect Alice. Verify a new `P<n>` AI takes Alice's slot. The total stays at 10 throughout.

- [ ] **Step 5: No commit needed**

This task contains no code changes. If a problem was found, fix the relevant earlier task and re-verify; once verification passes, move on to Task 11.

---

## Task 11: Add `🎲` to the web font subset

**Files:**
- Modify: `build.sh` (`SUBSET_CJK_TEXT` constant near top)

- [ ] **Step 1: Inspect current subset list**

Read `build.sh` and find the `SUBSET_CJK_TEXT` declaration (near the top, per CLAUDE.md). Note its current contents — you'll be appending one character.

- [ ] **Step 2: Append the dice glyph**

Append `🎲` to the end of the `SUBSET_CJK_TEXT` string (preserve the existing characters; just add the dice). The exact location: inside the same string literal, right before its closing quote.

- [ ] **Step 3: Verify NotoSansSC actually contains the glyph**

Before rebuilding, check whether the source font has U+1F3B2 at all. From the project root:

```bash
python3 -c "
from fontTools.ttLib import TTFont
font = TTFont('NotoSansSC-Regular.full.otf' if __import__('os').path.exists('NotoSansSC-Regular.full.otf') else 'NotoSansSC-Regular.otf')
cmap = font.getBestCmap()
print('🎲 (U+1F3B2) in font:', 0x1F3B2 in cmap)
"
```

(`fonttools` ships in many Python distros; install via `pip install fonttools` if missing. The pristine `NotoSansSC-Regular.full.otf` is the local backup that `build.sh` writes; if absent, fall back to the working file.)

If it prints `True`, continue to Step 4. If `False`, **stop here and ask the user**: NotoSansSC does not contain the dice glyph and the spec's contingency (ship a `NotoEmoji` single-glyph fallback) needs to be implemented before the dice button will render correctly on web. Don't ship a tofu glyph silently.

- [ ] **Step 4: Rebuild the web bundle**

Assuming Step 3 returned `True`:

```bash
./build.sh
```

Expected: the build runs the subsetter (re-subsetting NotoSansSC to the new character set), prints subset font size, runs the Godot web export, and pre-compresses artifacts.

- [ ] **Step 5: Visually verify in a browser**

Serve and open the built bundle:

```bash
python3 tools/serve_web.py 8000
```

Open `http://localhost:8000` in a browser. The Name Entry screen should appear with a visible dice glyph on the dice button (not a tofu rectangle). Click 🎲 — name should change. Click Join Battle — should connect to the server and show the tank with a name label.

If the dice renders as tofu despite the font containing the glyph, the subsetter probably stripped it. Inspect the post-subset font with the same fontTools snippet (pointed at `NotoSansSC-Regular.otf` after `build.sh` runs) — if it's missing, the SUBSET_CJK_TEXT change didn't take effect; re-check the edit.

- [ ] **Step 6: Commit**

```bash
git add build.sh
git commit -m "build: include 🎲 dice glyph in web font subset"
```

---

## Self-review pass

Spec requirements vs. tasks:

| Spec section | Implementation task |
|---|---|
| §1 Pre-game UI scene | Tasks 7, 8 |
| §2 Name pool | Task 1 |
| §3 Persistence (`user://player_name.cfg`) | Task 7 (in `_load_or_random` / `_save`) |
| §4 `TankState.display_name` | Task 3 |
| §4 `TankSnapshot` field + encode/decode | Task 4 |
| §4 `Connect.player_name` already exists | (no change needed) |
| §4 Server sanitize, AI naming, snapshot fill | Tasks 2 (sanitizer), 5 (wiring) |
| §5 Disconnect → AI takeover | Tasks 6 (one-line refill), 10 (verification) |
| §6 `Label3D` rendering + push from snapshot | Task 9 |
| §7 `build.sh` font subset | Task 11 |
| §8 Tests (sanitizer, name pool, snapshot) | Tasks 1, 2, 4 |

All sections covered. Type/method signatures match across tasks: `set_display_name(n: String)`, `NameSanitizer.sanitize(raw, pid)`, `Snapshot.add_tank(..., display_name: String = "")`, `joined(player_name: String)` signal — all consistent.
