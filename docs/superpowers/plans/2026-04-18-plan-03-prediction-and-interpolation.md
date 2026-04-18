# Plan 03: Client Prediction + Remote Interpolation — Implementation Plan

**Goal:** Replace the naive "lerp toward last snapshot" smoothing with (a) proper client-side prediction for the local player's own tank (instant input response + reconcile on server ack) and (b) 2-snapshot interpolation for remote tanks (100 ms delay buffer → smooth motion regardless of network jitter).

**Out of scope:** Server-side lag compensation for shells (separate follow-up Plan 03b — ballistic flight times make this less urgent).

**Architecture:**
- **Local tank**: client runs `TankMovement.step` each `_physics_process` against a local `TankState`, renders directly. On SNAPSHOT, if server's authoritative state deviates beyond a tolerance, snap and replay pending unacked inputs.
- **Remote tanks**: client keeps a ring of recent snapshots per tank. Render time = wall clock − 100 ms. Look up the two snapshots bracketing that time and interpolate.

---

## File Structure (changes)

```
common/protocol/messages.gd                    # modify: Snapshot carries last_input_tick per tank
server/sim/tick_loop.gd                        # modify: track last input tick per player, include in snapshot
client/tank/tank_view.gd                       # modify: split local (prediction) vs remote (interp) paths
client/tank/prediction.gd                      # create: local prediction state + reconcile
client/tank/interpolation.gd                   # create: snapshot buffer + interp reader
client/main_client.gd                          # modify: route snapshot per-tank to prediction OR interp
shared/tank/tank_state.gd                      # modify: add last_acked_input_tick field
tests/test_interpolation.gd                    # create: snapshot-buffer interp logic
```

---

## Task 1: Snapshot carries per-tank last_input_tick

**Why:** Client needs to know which of its inputs the server processed so it can discard acked inputs and replay unacked ones.

- [ ] Modify `common/protocol/messages.gd` — add `last_input_tick` to `TankSnapshot`:

```gdscript
class TankSnapshot:
    var player_id: int = 0
    var team: int = 0
    var pos: Vector3 = Vector3.ZERO
    var yaw: float = 0.0
    var turret_yaw: float = 0.0
    var gun_pitch: float = 0.0
    var hp: int = 0
    var last_input_tick: int = 0
```

Update `add_tank` signature:

```gdscript
    func add_tank(pid: int, team: int, pos: Vector3, yaw: float, turret_yaw: float, gun_pitch: float, hp: int, last_input_tick: int = 0) -> void:
        var t := TankSnapshot.new()
        t.player_id = pid
        t.team = team
        t.pos = pos
        t.yaw = yaw
        t.turret_yaw = turret_yaw
        t.gun_pitch = gun_pitch
        t.hp = hp
        t.last_input_tick = last_input_tick
        tanks.append(t)
```

Update `Snapshot.encode`/`decode` to read/write `last_input_tick` as `u32`:

```gdscript
            Codec.write_u32(buf, t.last_input_tick)
```

and matching read.

Update `test_messages.gd` snapshot test to assert the field round-trips. Run tests. Commit.

---

## Task 2: Server tracks last input tick per player

- [ ] Modify `server/sim/tick_loop.gd`:

Change `_latest_input` to also track `last_input_tick`. In `_on_input_received`:

```gdscript
    _latest_input[pid] = {
        "move_forward": input_msg.move_forward,
        "move_turn": input_msg.move_turn,
        "turret_yaw": input_msg.turret_yaw,
        "gun_pitch": input_msg.gun_pitch,
        "fire_pressed": input_msg.fire_pressed,
        "tick": input_msg.tick,
    }
```

In `_step_tick` when consuming input, store the tick on the tank state:

```gdscript
        var inp = _latest_input.get(pid, {...})
        TankMovement.step(state, inp, dt)
        state.last_acked_input_tick = int(inp.get("tick", 0))
```

When building the snapshot:

```gdscript
        snap.add_tank(s.player_id, s.team, s.pos, s.yaw, s.turret_yaw, s.gun_pitch, s.hp, s.last_acked_input_tick)
```

Add `last_acked_input_tick: int = 0` to `TankState`.

Commit.

---

## Task 3: Client prediction module

- [ ] Create `client/tank/prediction.gd`:

```gdscript
# client/tank/prediction.gd
extends Node

const TankState = preload("res://shared/tank/tank_state.gd")
const TankMovement = preload("res://shared/tank/tank_movement.gd")
const TerrainGenerator = preload("res://shared/world/terrain_generator.gd")

# Ring of unacked inputs (tick → Dictionary). Replayed after server correction.
var _input_history: Array = []  # each: {"tick": int, "input": Dictionary, "dt": float}
var _state: TankState
var _heightmap: PackedFloat32Array
var _terrain_size: int = 0
var _reconcile_threshold_sq: float = 0.25  # 0.5m tolerance before snap

func initialize(state: TankState, hm: PackedFloat32Array, terrain_size: int) -> void:
    _state = state
    _heightmap = hm
    _terrain_size = terrain_size

func state() -> TankState:
    return _state

# Call every physics frame after sampling input. Returns the simulated state.
func apply_local(input: Dictionary, tick: int, dt: float) -> void:
    if _state == null:
        return
    TankMovement.step(_state, input, dt)
    if _heightmap.size() > 0:
        _state.pos.y = TerrainGenerator.sample_height(_heightmap, _terrain_size, _state.pos.x, _state.pos.z)
    _state.turret_yaw = float(input.get("turret_yaw", _state.turret_yaw))
    _state.gun_pitch = float(input.get("gun_pitch", _state.gun_pitch))
    _input_history.append({"tick": tick, "input": input.duplicate(), "dt": dt})
    # Cap history to 2 seconds (40 ticks @ 20Hz)
    while _input_history.size() > 60:
        _input_history.pop_front()

# Called on snapshot receipt. Discards acked inputs; optionally reconciles.
func reconcile(server_pos: Vector3, server_yaw: float, server_turret_yaw: float,
        server_gun_pitch: float, server_hp: int, acked_tick: int) -> void:
    if _state == null:
        return
    # Drop acked inputs
    while _input_history.size() > 0 and int(_input_history[0]["tick"]) <= acked_tick:
        _input_history.pop_front()
    # Check divergence (xz only; y is heightmap-derived locally)
    var dx := server_pos.x - _state.pos.x
    var dz := server_pos.z - _state.pos.z
    var dist_sq: float = dx * dx + dz * dz
    if dist_sq > _reconcile_threshold_sq:
        # Snap to server and replay pending inputs
        _state.pos = server_pos
        _state.yaw = server_yaw
        for entry in _input_history:
            TankMovement.step(_state, entry["input"], entry["dt"])
            if _heightmap.size() > 0:
                _state.pos.y = TerrainGenerator.sample_height(_heightmap, _terrain_size, _state.pos.x, _state.pos.z)
    # Turret/pitch always taken from server (low latency, client already follows mouse)
    _state.turret_yaw = server_turret_yaw
    _state.gun_pitch = server_gun_pitch
    _state.hp = server_hp
```

Commit (no test — pure behavior best verified in playtest).

---

## Task 4: Remote tank interpolation buffer + tests

- [ ] Create `client/tank/interpolation.gd`:

```gdscript
# client/tank/interpolation.gd
extends RefCounted

# Per-tank snapshot ring; each entry: {"t_ms": int, "pos": Vector3, "yaw": float,
#   "turret_yaw": float, "gun_pitch": float, "hp": int}
var _buffer: Array = []
var _interp_delay_ms: int = 100
var _max_buffer: int = 20

func push_snapshot(t_ms: int, pos: Vector3, yaw: float, turret_yaw: float, gun_pitch: float, hp: int) -> void:
    _buffer.append({
        "t_ms": t_ms, "pos": pos, "yaw": yaw,
        "turret_yaw": turret_yaw, "gun_pitch": gun_pitch, "hp": hp,
    })
    while _buffer.size() > _max_buffer:
        _buffer.pop_front()

# Sample at now_ms − interp_delay. Returns dict with interpolated values,
# or null if buffer empty.
func sample(now_ms: int):
    if _buffer.size() == 0:
        return null
    var target_t: int = now_ms - _interp_delay_ms
    # Find the two snapshots bracketing target_t
    if target_t <= int(_buffer[0]["t_ms"]):
        return _buffer[0]
    if target_t >= int(_buffer[_buffer.size() - 1]["t_ms"]):
        return _buffer[_buffer.size() - 1]
    for i in range(_buffer.size() - 1):
        var a: Dictionary = _buffer[i]
        var b: Dictionary = _buffer[i + 1]
        if int(a["t_ms"]) <= target_t and target_t <= int(b["t_ms"]):
            var span: float = float(int(b["t_ms"]) - int(a["t_ms"]))
            var f: float = 0.0 if span <= 0.0 else float(target_t - int(a["t_ms"])) / span
            return {
                "t_ms": target_t,
                "pos": (a["pos"] as Vector3).lerp(b["pos"] as Vector3, f),
                "yaw": lerp_angle(a["yaw"], b["yaw"], f),
                "turret_yaw": lerp_angle(a["turret_yaw"], b["turret_yaw"], f),
                "gun_pitch": lerp(a["gun_pitch"], b["gun_pitch"], f),
                "hp": a["hp"],
            }
    return _buffer[_buffer.size() - 1]
```

- [ ] Create `tests/test_interpolation.gd`:

```gdscript
extends GutTest

const Interpolation = preload("res://client/tank/interpolation.gd")

func test_empty_buffer_returns_null() -> void:
    var interp := Interpolation.new()
    assert_null(interp.sample(1000))

func test_single_snapshot_returns_itself() -> void:
    var interp := Interpolation.new()
    interp.push_snapshot(1000, Vector3(10, 0, 20), 0.5, 0.0, 0.0, 900)
    var r = interp.sample(2000)
    assert_almost_eq(r["pos"].x, 10.0, 0.001)

func test_interpolation_between_two_snapshots() -> void:
    var interp := Interpolation.new()
    interp.push_snapshot(1000, Vector3(0, 0, 0), 0.0, 0.0, 0.0, 900)
    interp.push_snapshot(2000, Vector3(100, 0, 200), 1.0, 0.0, 0.0, 900)
    # sample at t=1500 with interp_delay=100 → target_t = 1400, which is 40% between the two
    var r = interp.sample(1500)
    assert_almost_eq(r["pos"].x, 40.0, 0.01, "Expected 40%% along at x=40")
    assert_almost_eq(r["pos"].z, 80.0, 0.01)

func test_sample_before_first_returns_oldest() -> void:
    var interp := Interpolation.new()
    interp.push_snapshot(1000, Vector3(10, 0, 20), 0.0, 0.0, 0.0, 900)
    interp.push_snapshot(2000, Vector3(100, 0, 200), 0.0, 0.0, 0.0, 900)
    # sample at t=500 → target_t = 400, well before first snapshot
    var r = interp.sample(500)
    assert_almost_eq(r["pos"].x, 10.0, 0.001)

func test_buffer_capped() -> void:
    var interp := Interpolation.new()
    for i in 40:
        interp.push_snapshot(i * 50, Vector3(i, 0, 0), 0.0, 0.0, 0.0, 900)
    # Internal buffer should be capped at 20
    var r = interp.sample(40 * 50 + 50)
    assert_almost_eq(r["pos"].x, 39.0, 0.001)  # latest
```

Run tests. Commit.

---

## Task 5: Refactor main_client to split local vs remote paths

- [ ] Modify `client/main_client.gd`:

At top, add:

```gdscript
const Prediction = preload("res://client/tank/prediction.gd")
const Interpolation = preload("res://client/tank/interpolation.gd")
const TankState = preload("res://shared/tank/tank_state.gd")
```

Add:

```gdscript
var _prediction: Prediction  # for local tank only
var _remote_interp: Dictionary = {}  # player_id → Interpolation
var _local_view  # TankView (for rendering local state)
```

In `_handle_connect_ack`, after terrain is built, initialize prediction state:

```gdscript
    var ls := TankState.new()
    ls.player_id = msg.player_id
    ls.team = msg.team
    ls.pos = msg.spawn_pos
    ls.initialize_parts(Constants.TANK_MAX_HP)
    ls.alive = true
    _prediction = Prediction.new()
    add_child(_prediction)
    _prediction.initialize(ls, _terrain_builder.heightmap, _terrain_builder.terrain_size)
```

Replace `_handle_snapshot`:

```gdscript
func _handle_snapshot(msg) -> void:
    var now_ms := Time.get_ticks_msec()
    var seen: Dictionary = {}
    for t in msg.tanks:
        seen[t.player_id] = true
        if t.player_id == _my_player_id:
            # Local path: reconcile prediction
            if _prediction:
                _prediction.reconcile(t.pos, t.yaw, t.turret_yaw, t.gun_pitch, t.hp, t.last_input_tick)
            _ensure_local_view(t.team)
            _hud.set_hp(t.hp)
            _camera.set_target(_local_view)
        else:
            # Remote path: push to per-player interp buffer
            if not _remote_interp.has(t.player_id):
                _remote_interp[t.player_id] = Interpolation.new()
                _ensure_remote_view(t.player_id, t.team)
            _remote_interp[t.player_id].push_snapshot(now_ms, t.pos, t.yaw, t.turret_yaw, t.gun_pitch, t.hp)
    # Cleanup gone tanks
    for pid in _tanks.keys():
        if not seen.has(pid) and pid != _my_player_id:
            _tanks[pid].queue_free()
            _tanks.erase(pid)
            _remote_interp.erase(pid)

func _ensure_local_view(team: int) -> void:
    if _local_view != null:
        return
    _local_view = TankView.new()
    add_child(_local_view)
    _local_view.setup(_my_player_id, team, true)
    _local_view.set_terrain(_terrain_builder.heightmap, _terrain_builder.terrain_size)
    _tanks[_my_player_id] = _local_view

func _ensure_remote_view(pid: int, team: int) -> void:
    if _tanks.has(pid):
        return
    var v = TankView.new()
    add_child(v)
    v.setup(pid, team, false)
    v.set_terrain(_terrain_builder.heightmap, _terrain_builder.terrain_size)
    _tanks[pid] = v
```

Replace `_physics_process` to drive prediction:

```gdscript
func _physics_process(delta: float) -> void:
    if _my_player_id == 0 or _ws == null or not _ws.is_open():
        return
    var inp = _input.build_input_message()
    var tick: int = Engine.get_physics_frames()
    inp.tick = tick
    _ws.send(MessageType.INPUT, inp.encode())
    if _input.consume_fire():
        var fire := Messages.Fire.new()
        fire.tick = tick
        _ws.send(MessageType.FIRE, fire.encode())
    # Local prediction
    if _prediction != null:
        var d := {
            "move_forward": inp.move_forward,
            "move_turn": inp.move_turn,
            "turret_yaw": inp.turret_yaw,
            "gun_pitch": inp.gun_pitch,
            "fire_pressed": inp.fire_pressed,
        }
        _prediction.apply_local(d, tick, delta)
```

Add a `_process` pass for visual sync (merged with existing shell processing):

```gdscript
func _process(_delta: float) -> void:
    # Local tank: apply predicted state to view directly
    if _local_view != null and _prediction != null:
        var s = _prediction.state()
        _local_view.apply_predicted(s.pos, s.yaw, s.turret_yaw, s.gun_pitch, s.hp)
    # Remote tanks: sample interpolation
    var now_ms := Time.get_ticks_msec()
    for pid in _remote_interp:
        var r = _remote_interp[pid].sample(now_ms)
        if r == null:
            continue
        var view = _tanks.get(pid)
        if view == null:
            continue
        view.apply_snapshot(r["pos"], r["yaw"], r["turret_yaw"], r["gun_pitch"], int(r["hp"]))
    # Advance visual shells (same as before)
    for shell_id in _shells.keys():
        var h: Node3D = _shells[shell_id]
        var start_ms: int = int(h.get_meta("start_ms"))
        var elapsed: float = float(Time.get_ticks_msec() - start_ms) / 1000.0
        if elapsed > Constants.SHELL_MAX_LIFETIME_S:
            h.queue_free()
            _shells.erase(shell_id)
            continue
        var origin: Vector3 = h.get_meta("origin")
        var vel: Vector3 = h.get_meta("velocity")
        h.position = Ballistics.position_at(origin, vel, elapsed)
```

Remove the old `_process` from main_client (replaced above).

- [ ] Modify `client/tank/tank_view.gd` — add `apply_predicted` which snaps (no lerp, for local tank):

```gdscript
func apply_predicted(pos: Vector3, yaw: float, turret_yaw: float, gun_pitch: float, hp: int) -> void:
    position = pos
    rotation.y = yaw
    if _turret:
        _turret.rotation.y = turret_yaw
    if _barrel:
        _barrel.rotation.x = gun_pitch
    _hp = hp
    _first_snapshot = false  # skip the lerp path
```

Commit.

---

## Task 6: Full verification

- [ ] Run all unit tests — expect 61+ passing (5 new interp tests).
- [ ] Boot server + client; drive locally and verify tank responds immediately to WASD (no perceptible delay).
- [ ] Verify server logs still show CONNECT_ACK and input/fire processing.
- [ ] Tag `plan-03-prediction-interpolation-complete`.
- [ ] Write completion notes.

---

## Self-Review

**Spec coverage:**
- Client prediction of own tank → Tasks 3, 5
- Entity interpolation for remote tanks → Tasks 4, 5
- 100 ms interp delay matches spec §7.4 → Task 4 default
- Reconcile with server authority on snapshot → Task 3

**Deferred:**
- Server-side lag compensation for shell hit detection (§7.5) — ballistic travel time makes this less impactful; separate plan.

**Placeholder scan:** none.
