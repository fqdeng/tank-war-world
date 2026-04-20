# Name Entry, AI Takeover, and 3D Name Labels — 2026-04-20

Add a pre-game name-entry screen (random default + dice reroll + manual
input + persistence), broadcast each tank's display name in the snapshot,
render it as a billboard label above every tank, and convert disconnected
humans into AI named `P<id>`.

Approach chosen: name lives directly on `TankSnapshot` (no out-of-band
messages); existing `_maintain_ai_population` drives the human→AI swap.
Snapshot bandwidth cost ≈ 2.4 KB/s/client at 10 tanks — negligible vs.
the simplicity gain.

## 1. Pre-game name-entry UI

**New scene `client/menu/name_entry.tscn`** — full-screen `Control`,
content centered. Children:

- Title `Label`: text `"Enter Name"`, font size 48.
- `HBoxContainer`:
  - `LineEdit` (`name_field`): `max_length = 12`,
    `placeholder_text = "name..."`, `custom_minimum_size.x = 280`.
  - `Button` (`dice_button`): text `"🎲"`, `custom_minimum_size = (56, 56)`.
- `Button` (`join_button`): text `"Join Battle"`, full width of HBox.

**New script `client/menu/name_entry.gd`** (attached to root Control):

```
signal joined(name: String)

const NamePool = preload("res://client/menu/name_pool.gd")
const SAVE_PATH := "user://player_name.cfg"

@onready var name_field: LineEdit = $.../NameField
@onready var dice_button: Button = $.../DiceButton
@onready var join_button: Button = $.../JoinButton

func _ready() -> void:
    name_field.text = _load_or_random()
    name_field.text_changed.connect(_on_text_changed)
    dice_button.pressed.connect(_on_roll)
    join_button.pressed.connect(_on_join)
    _update_join_enabled()

func _on_roll() -> void:
    name_field.text = NamePool.random_name()
    _update_join_enabled()

func _on_text_changed(_t: String) -> void:
    _update_join_enabled()

func _update_join_enabled() -> void:
    join_button.disabled = name_field.text.strip_edges().is_empty()

func _on_join() -> void:
    var n := name_field.text.strip_edges()
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

**Integration in `client/main_client.gd`**: add a member var declaration
near the other `var _ws` / `var _my_player_id` lines:

```
var _pending_player_name: String = ""
```

`_ready()` (currently line 68–90): move WSClient creation/connect out of
`_ready()`, gate it behind the `joined` signal. `_ws` is already untyped
(`var _ws`, line 24) and existing call sites already guard on
`_ws == null`, so deferring construction is safe.

```
# in _ready(), replace WSClient block (lines 85-90) with:
var menu := preload("res://client/menu/name_entry.tscn").instantiate()
menu.joined.connect(_on_name_chosen)
add_child(menu)

# new method:
func _on_name_chosen(player_name: String) -> void:
    _pending_player_name = player_name
    _ws = WSClient.new()
    add_child(_ws)
    _ws.connected.connect(_on_connected)
    _ws.message.connect(_on_message)
    _ws.disconnected.connect(_on_disconnected)
    _ws.connect_to_url(server_url)
```

**Update `_on_connected()`** (line 132): replace
`msg.player_name = "Player"` with `msg.player_name = _pending_player_name`.

Other `_ready()` initialization (lights, environment, camera, HUD,
TerrainBuilder, ObstacleBuilder, TankInput) stays in place — only WSClient
construction is deferred.

## 2. Random name pool

**New script `client/menu/name_pool.gd`**:

```
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

No numeric suffix; duplicates allowed (player_id is the unique key,
display names are cosmetic).

## 3. Protocol changes

**`shared/tank/tank_state.gd`** — add field:

```
var display_name: String = ""
```

**`common/protocol/messages.gd`**:

- `Connect.player_name` already exists (line 9). No change.
- `TankSnapshot` (line 98) — append:

  ```
  var display_name: String = ""
  ```

- `Snapshot.add_tank()` (line 121) — append parameter
  `display_name: String = ""` and assign to `t.display_name`.

- `Snapshot.encode()` per-tank loop (after
  `Codec.write_f32(buf, t.turret_regen_remaining)`):

  ```
  Codec.write_string(buf, t.display_name)
  ```

- `Snapshot.decode()` per-tank loop (after `t.turret_regen_remaining = ...`):

  ```
  t.display_name = Codec.read_string(buf, c)
  ```

Field order matters — both sides must update in lockstep.

## 4. Server-side wiring

**`server/sim/tick_loop.gd`**:

- Top of file, alongside other `const` preloads, add:
  `const NameSanitizer = preload("res://server/util/name_sanitizer.gd")`

- `_on_client_connected` (line 150) — after
  `_world.spawn_tank(pid, team)`:

  ```
  state.display_name = NameSanitizer.sanitize(connect_msg.player_name, pid)
  ```

- `_spawn_ai` (line 245) — after `st.is_ai = true`:

  ```
  st.display_name = "P" + str(pid)
  ```

- Snapshot tank loop (line 145) — pass display_name through:

  ```
  snap.add_tank(s.player_id, s.team, s.pos, s.yaw, s.turret_yaw,
                s.gun_pitch, s.hp, s.last_acked_input_tick, s.ammo,
                s.reload_remaining, turret_regen, s.display_name)
  ```

- `_on_client_disconnected` (line 169) — append one line at the end so
  the AI fills the slot in the same tick instead of waiting for the next
  tick boundary:

  ```
  _maintain_ai_population()
  ```

**New helper file `server/util/name_sanitizer.gd`** (extracted into its
own script so unit tests can preload it without dragging in tick_loop's
dependencies):

```
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

Rules:
1. Strip leading/trailing whitespace.
2. Keep only printable ASCII (0x20–0x7E).
3. Truncate to 12 chars.
4. Empty result → fall back to `"P<pid>"` (same format as AI).

## 5. Disconnect → AI takeover flow

No new logic needed beyond §4's one-line addition. The flow is:

1. Human disconnects → `_on_client_disconnected` calls
   `_world.remove_tank(pid)`.
2. Same tick: `_maintain_ai_population()` runs, sees that the affected
   team now has fewer total tanks than `target_per_team = 5`.
3. `_spawn_ai(team)` allocates a fresh `player_id` (monotonic, never
   reused) and assigns `display_name = "P<new_id>"`.

The new AI spawns at the team's standard spawn point, not the
disconnected player's position — matches the user's "delete and
recreate" intent. Original player_id is never reused.

## 6. Client-side rendering

**`client/tank/tank_view.gd`** — extend `_build_mesh` (lines 61–151) with
a `Label3D`, stored as `_name_label`:

```
_name_label = Label3D.new()
_name_label.text = ""
_name_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
_name_label.no_depth_test = false
_name_label.pixel_size = 0.005
_name_label.font_size = 32
_name_label.outline_size = 8
_name_label.outline_modulate = Color.BLACK
_name_label.modulate = Color.WHITE
_name_label.position = Vector3(0, 4.2, 0)  # HP bar at y=3.6
_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
add_child(_name_label)
```

**New method `set_display_name(name: String)`**:

```
func set_display_name(n: String) -> void:
    if _name_label and _name_label.text != n:
        _name_label.text = n
```

`no_depth_test = false` so terrain occludes labels (avoids names showing
through hills). `billboard` keeps text camera-facing. All tanks show
labels including own (per user choice).

**`client/main_client.gd::_handle_snapshot`** (line 189):
inside the `for t in msg.tanks:` loop, after `_ensure_view(...)`:

```
_tanks[t.player_id].set_display_name(t.display_name)
```

Applied for both own and remote tanks.

## 7. Web font subset

**`build.sh`** — append `🎲` (U+1F3B2) to `SUBSET_CJK_TEXT`. After
rebuilding, manually verify in a browser that the dice button renders
the glyph and not a tofu box. If `NotoSansSC-Regular` does not contain
the dice codepoint (likely — it's a CJK font, not an emoji font), add a
single-glyph emoji-font fallback:

1. Subset a small free emoji font (e.g. `NotoEmoji-Regular.ttf`) to the
   single character `🎲` → `assets/fonts/dice_emoji.ttf` (~1 KB).
2. Load it as a `FontFile` and chain it via the dice Button's
   `theme_override_fonts/font.set_fallbacks([dice_emoji_font])`.

The fallback path is only needed if the subset attempt fails
verification. Native build (macOS / Linux) is unaffected — system font
fallback handles the emoji.

## 8. Testing

**New `tests/test_name_sanitizer.gd`** (GUT):
- `"Wolf"` → `"Wolf"`
- `"  Wolf  "` → `"Wolf"` (strip)
- `"VeryLongNameOver12"` → `"VeryLongNam"` (truncate to 12)
- `"狼王"` → `"P42"` (CJK stripped → empty → fallback)
- `""` → `"P42"`
- `"   "` → `"P42"`
- `"AB\x01CD"` → `"ABCD"` (control char stripped)
- `"hello world"` → `"hello world"` (space is printable ASCII, kept)

**New `tests/test_name_pool.gd`** (GUT):
- `random_name()` returns a string in `NamePool.NAMES`.
- 100 calls produce ≥ 5 distinct names (sanity check on randomness).

**No automated tests** for the UI scene or 3D label rendering — Godot UI
tests are too brittle for this scope. Manual verification:
- Launch native client → name entry shows, dice rerolls, manual edit
  works, Join connects.
- Launch second client with different name → both names visible above
  both tanks.
- Disconnect one client → its tank vanishes, an AI named `P<n>` appears
  on its team within one tick.
- Reload page (web) → previous name pre-filled.

## 9. Files touched

New:
- `client/menu/name_entry.tscn`
- `client/menu/name_entry.gd`
- `client/menu/name_pool.gd`
- `server/util/name_sanitizer.gd`
- `tests/test_name_sanitizer.gd`
- `tests/test_name_pool.gd`

Modified:
- `client/main_client.gd` — defer WS connect; wire `_pending_player_name`;
  push display_name into views from snapshots.
- `client/tank/tank_view.gd` — add `Label3D` + `set_display_name`.
- `shared/tank/tank_state.gd` — add `display_name`.
- `common/protocol/messages.gd` — `TankSnapshot.display_name` +
  encode/decode + `add_tank()` signature.
- `server/sim/tick_loop.gd` — preload NameSanitizer, sanitize on
  connect, name AI, push name into snapshot, immediate
  `_maintain_ai_population()` on disconnect.
- `build.sh` — append `🎲` to `SUBSET_CJK_TEXT`.
- `tests/test_messages.gd` — extend `test_snapshot_roundtrip_multiple_tanks`
  to cover `display_name`.
