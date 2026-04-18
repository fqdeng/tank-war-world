# Plan 02: Parabolic Ballistics + 6-Part Damage — Implementation Plan

> **For agentic workers:** Execute task-by-task using checkbox tracking.

**Goal:** Replace Plan 01's hitscan + integer HP with parabolic shell ballistics (gravity, travel time) and a 6-part damage model (Hull / Turret / Engine / L-Track / R-Track / Top) with functional damage (track destroyed → immobilized; turret destroyed → can't aim/fire; engine destroyed → slow).

**Architecture:** Server advances each in-flight shell at 20Hz through a 1-tick swept collision test; on hit it classifies the hit point into a part (tank-local coordinates) and applies damage with multipliers. Clients receive a `SHELL_SPAWNED` event and animate the projectile using the same ballistic formula (deterministic), then play an explosion on `HIT`.

**Tech stack:** Same as Plan 01. No new dependencies.

**Out of scope (later plans):**
- Repair mechanic (Plan 02b or Plan 09)
- Visual indicators on damaged parts (Plan 06 HUD)
- Armor penetration / tank-type variations (single tank type remains)
- Obstacle destruction by shells (Plan 04 — for now shells just stop on obstacle, no obstacle HP)

---

## File Structure (changes)

```
common/constants.gd                            # modify: add shell + part constants
shared/combat/
  ballistics.gd                                # create: pure projectile math
  part_classifier.gd                           # create: hit point → part id
  part_damage.gd                               # create: apply damage to TankState parts
shared/tank/tank_state.gd                      # modify: add parts dict + functional flags
shared/tank/tank_movement.gd                   # modify: respect track/engine damage
common/protocol/messages.gd                    # modify: add ShellSpawned; extend Hit with part_id
common/protocol/message_types.gd               # modify: add SHELL_SPAWNED (replaces SHELL_FIRED)
server/combat/shell_sim.gd                     # create: tick-driven shell physics + hit resolution
server/sim/tick_loop.gd                        # modify: use shell_sim, part damage, respawn resets parts
server/world/world_instance.gd                 # modify: spawn_tank initializes parts
client/main_client.gd                          # modify: handle SHELL_SPAWNED, visualize ballistic
client/tank/tank_view.gd                       # modify: accept part HP in snapshot (for future HUD)
tests/test_ballistics.gd                       # create
tests/test_part_classifier.gd                  # create
tests/test_part_damage.gd                      # create
tests/test_tank_movement.gd                    # modify: add tests for track/engine damage
```

---

## Task 1: Extend constants — shell physics + part model

- [ ] Append to `common/constants.gd`:

```gdscript

# --- Ballistics (Plan 02) ---
const SHELL_INITIAL_SPEED: float = 450.0  # m/s
const GRAVITY: float = 9.8
const SHELL_MAX_LIFETIME_S: float = 8.0
const SHELL_STEP_SUBDIVISIONS: int = 4  # per-tick sub-steps for swept collision accuracy

# --- Part HP proportions (sum to 1.0) ---
const PART_HP_HULL: float = 0.40
const PART_HP_TURRET: float = 0.15
const PART_HP_ENGINE: float = 0.15
const PART_HP_LEFT_TRACK: float = 0.10
const PART_HP_RIGHT_TRACK: float = 0.10
const PART_HP_TOP: float = 0.10

# --- Damage multipliers ---
const MULT_HULL: float = 1.0
const MULT_TURRET: float = 1.3
const MULT_ENGINE: float = 1.5
const MULT_LEFT_TRACK: float = 0.8
const MULT_RIGHT_TRACK: float = 0.8
const MULT_TOP: float = 2.5

# --- Functional damage parameters ---
const ENGINE_SPEED_FACTOR_WHEN_DEAD: float = 0.25  # 25% max speed
const ENGINE_ACCEL_FACTOR_WHEN_DEAD: float = 0.5   # 50% accel
```

- [ ] Commit: `feat(common): add ballistics + part constants`

---

## Task 2: Extend TankState with parts

- [ ] Replace `shared/tank/tank_state.gd`:

```gdscript
# shared/tank/tank_state.gd
class_name TankState
extends RefCounted

enum Part { HULL = 0, TURRET = 1, ENGINE = 2, LEFT_TRACK = 3, RIGHT_TRACK = 4, TOP = 5 }

var player_id: int = 0
var team: int = 0
var pos: Vector3 = Vector3.ZERO
var yaw: float = 0.0
var turret_yaw: float = 0.0
var gun_pitch: float = 0.0
var speed: float = 0.0
var hp: int = 0  # total HP (sum of alive parts)
var ammo: int = 0
var reload_remaining: float = 0.0
var alive: bool = true
var respawn_remaining: float = 0.0

# Parts: Part enum int → float sub HP
var parts: Dictionary = {}

func initialize_parts(total_max_hp: int) -> void:
    var t := float(total_max_hp)
    parts = {
        Part.HULL: t * Constants.PART_HP_HULL,
        Part.TURRET: t * Constants.PART_HP_TURRET,
        Part.ENGINE: t * Constants.PART_HP_ENGINE,
        Part.LEFT_TRACK: t * Constants.PART_HP_LEFT_TRACK,
        Part.RIGHT_TRACK: t * Constants.PART_HP_RIGHT_TRACK,
        Part.TOP: t * Constants.PART_HP_TOP,
    }
    hp = total_max_hp

func part_hp(p: int) -> float:
    return parts.get(p, 0.0)

func is_part_destroyed(p: int) -> bool:
    return part_hp(p) <= 0.0

func can_fire() -> bool:
    return alive and not is_part_destroyed(Part.TURRET) and reload_remaining <= 0.0 and ammo > 0

func is_turret_disabled() -> bool:
    return is_part_destroyed(Part.TURRET)

func left_track_ok() -> bool:
    return not is_part_destroyed(Part.LEFT_TRACK)

func right_track_ok() -> bool:
    return not is_part_destroyed(Part.RIGHT_TRACK)

func engine_ok() -> bool:
    return not is_part_destroyed(Part.ENGINE)
```

- [ ] Commit.

---

## Task 3: Ballistics math (pure) with tests

- [ ] Create `shared/combat/ballistics.gd`:

```gdscript
# shared/combat/ballistics.gd
class_name Ballistics

# Returns the world position of a shell at `elapsed` seconds since fire, given
# `origin` and `velocity`. Assumes gravity acts along -Y.
static func position_at(origin: Vector3, velocity: Vector3, elapsed: float) -> Vector3:
    return origin + velocity * elapsed + Vector3(0.0, -0.5 * Constants.GRAVITY * elapsed * elapsed, 0.0)

static func velocity_at(velocity: Vector3, elapsed: float) -> Vector3:
    return velocity + Vector3(0.0, -Constants.GRAVITY * elapsed, 0.0)

# Compute initial velocity vector given a yaw (world), gun pitch, and speed.
static func initial_velocity(yaw: float, pitch: float, speed: float) -> Vector3:
    # Godot convention: yaw 0 = facing -Z
    var horiz := Vector3(-sin(yaw), 0.0, -cos(yaw))
    var dir := horiz * cos(pitch) + Vector3(0.0, sin(pitch), 0.0)
    return dir.normalized() * speed
```

- [ ] Create `tests/test_ballistics.gd`:

```gdscript
extends GutTest

const Ballistics = preload("res://shared/combat/ballistics.gd")

func test_position_at_t0_equals_origin() -> void:
    var p := Ballistics.position_at(Vector3(10, 20, 30), Vector3(100, 0, 0), 0.0)
    assert_almost_eq(p.x, 10.0, 0.001)
    assert_almost_eq(p.y, 20.0, 0.001)
    assert_almost_eq(p.z, 30.0, 0.001)

func test_gravity_pulls_down_over_time() -> void:
    var p0 := Ballistics.position_at(Vector3.ZERO, Vector3(0, 0, -100), 0.0)
    var p1 := Ballistics.position_at(Vector3.ZERO, Vector3(0, 0, -100), 1.0)
    var p2 := Ballistics.position_at(Vector3.ZERO, Vector3(0, 0, -100), 2.0)
    assert_almost_eq(p0.y, 0.0, 0.001)
    assert_almost_eq(p1.y, -4.9, 0.01, "After 1s, y = -0.5 * 9.8 * 1")
    assert_almost_eq(p2.y, -19.6, 0.01, "After 2s, y = -0.5 * 9.8 * 4")

func test_horizontal_motion_unaffected_by_gravity() -> void:
    var p := Ballistics.position_at(Vector3.ZERO, Vector3(50, 0, 0), 2.0)
    assert_almost_eq(p.x, 100.0, 0.001)
    assert_almost_eq(p.z, 0.0, 0.001)

func test_initial_velocity_magnitude() -> void:
    var v := Ballistics.initial_velocity(0.0, 0.0, 450.0)
    assert_almost_eq(v.length(), 450.0, 0.1)

func test_initial_velocity_zero_yaw_faces_negative_z() -> void:
    var v := Ballistics.initial_velocity(0.0, 0.0, 100.0)
    assert_almost_eq(v.x, 0.0, 0.1)
    assert_almost_eq(v.y, 0.0, 0.1)
    assert_almost_eq(v.z, -100.0, 0.1)

func test_initial_velocity_positive_pitch_goes_up() -> void:
    var v := Ballistics.initial_velocity(0.0, deg_to_rad(30.0), 100.0)
    assert_gt(v.y, 0.0)
    assert_lt(v.z, 0.0)

func test_velocity_at_loses_vertical_component() -> void:
    var v0 := Vector3(10, 50, 0)
    var v1 := Ballistics.velocity_at(v0, 2.0)
    assert_almost_eq(v1.x, 10.0, 0.001)
    assert_almost_eq(v1.y, 50.0 - 2.0 * 9.8, 0.01)
```

- [ ] Run tests, expect pass. Commit.

---

## Task 4: Part classifier with tests

Classify a world-space hit point into a `TankState.Part` using the tank's pose. Zones are defined in tank-local space.

- [ ] Create `shared/combat/part_classifier.gd`:

```gdscript
# shared/combat/part_classifier.gd
class_name PartClassifier

const TankState = preload("res://shared/tank/tank_state.gd")

# Local-space zone bounds for a standard tank (relative to tank origin at ground center, +Y up, -Z forward).
# Priority order: TOP > TURRET > TRACKS > ENGINE > HULL (first match wins).
# These are heuristic AABBs — not physical colliders. Tune with playtesting.

static func classify(tank_pos: Vector3, tank_yaw: float, hit_point: Vector3) -> int:
    # Transform hit_point into tank local space.
    var rel := hit_point - tank_pos
    var cy := cos(-tank_yaw)
    var sy := sin(-tank_yaw)
    var lx := rel.x * cy - rel.z * sy
    var lz := rel.x * sy + rel.z * cy
    var ly := rel.y

    # TOP: hit from above and roughly within hull footprint (ly >= 2.2 and |lx| <= 1.5 and |lz| <= 2.5)
    if ly >= 2.2 and abs(lx) <= 1.5 and abs(lz) <= 2.5:
        return TankState.Part.TOP
    # TURRET: mid-height, centered (0.9 <= ly <= 2.4 and |lx| <= 1.1 and |lz| <= 1.1)
    if ly >= 0.9 and ly <= 2.4 and abs(lx) <= 1.1 and abs(lz) <= 1.1:
        return TankState.Part.TURRET
    # TRACKS: sides at low height
    if ly <= 0.9:
        if lx <= -1.3:
            return TankState.Part.LEFT_TRACK
        if lx >= 1.3:
            return TankState.Part.RIGHT_TRACK
    # ENGINE: rear half of hull (lz >= 1.5 means behind, in our -Z forward convention)
    if lz >= 1.5:
        return TankState.Part.ENGINE
    # Default: HULL
    return TankState.Part.HULL
```

- [ ] Create `tests/test_part_classifier.gd`:

```gdscript
extends GutTest

const PartClassifier = preload("res://shared/combat/part_classifier.gd")
const TankState = preload("res://shared/tank/tank_state.gd")

func test_front_hit_at_center_is_hull() -> void:
    # Tank at origin facing -Z. Shot at (0, 1, -2) — front center, chest height.
    var p := PartClassifier.classify(Vector3.ZERO, 0.0, Vector3(0, 1, -2))
    assert_eq(p, TankState.Part.HULL)

func test_top_hit_is_top() -> void:
    var p := PartClassifier.classify(Vector3.ZERO, 0.0, Vector3(0, 3, 0))
    assert_eq(p, TankState.Part.TOP)

func test_turret_center_is_turret() -> void:
    var p := PartClassifier.classify(Vector3.ZERO, 0.0, Vector3(0, 1.6, 0))
    assert_eq(p, TankState.Part.TURRET)

func test_left_side_low_is_left_track() -> void:
    var p := PartClassifier.classify(Vector3.ZERO, 0.0, Vector3(-1.5, 0.5, 0))
    assert_eq(p, TankState.Part.LEFT_TRACK)

func test_right_side_low_is_right_track() -> void:
    var p := PartClassifier.classify(Vector3.ZERO, 0.0, Vector3(1.5, 0.5, 0))
    assert_eq(p, TankState.Part.RIGHT_TRACK)

func test_rear_hit_is_engine() -> void:
    # lz = +2 (behind in -Z forward convention), low height so not turret
    var p := PartClassifier.classify(Vector3.ZERO, 0.0, Vector3(0, 0.5, 2.0))
    assert_eq(p, TankState.Part.ENGINE)

func test_rotation_applied_correctly() -> void:
    # Tank rotated 180°: now faces +Z. A world-space hit from +Z direction should be "front" (hull).
    # Front of rotated tank is at world +Z direction from tank origin.
    var p := PartClassifier.classify(Vector3.ZERO, PI, Vector3(0, 1, 2))
    assert_eq(p, TankState.Part.HULL)

func test_tank_at_offset() -> void:
    # Tank at (100, 0, 100), facing -Z. Hit point at (100, 1, 98) = 2m in front of tank = hull.
    var p := PartClassifier.classify(Vector3(100, 0, 100), 0.0, Vector3(100, 1, 98))
    assert_eq(p, TankState.Part.HULL)
```

- [ ] Run tests. Commit.

---

## Task 5: Part damage application with tests

Apply damage to a specific part; updates sub HP and total HP; returns death flag.

- [ ] Create `shared/combat/part_damage.gd`:

```gdscript
# shared/combat/part_damage.gd
class_name PartDamage

const TankState = preload("res://shared/tank/tank_state.gd")

class Result:
    var actual_damage: float = 0.0
    var part_just_destroyed: bool = false
    var tank_just_destroyed: bool = false

static func multiplier_for(part: int) -> float:
    match part:
        TankState.Part.HULL: return Constants.MULT_HULL
        TankState.Part.TURRET: return Constants.MULT_TURRET
        TankState.Part.ENGINE: return Constants.MULT_ENGINE
        TankState.Part.LEFT_TRACK: return Constants.MULT_LEFT_TRACK
        TankState.Part.RIGHT_TRACK: return Constants.MULT_RIGHT_TRACK
        TankState.Part.TOP: return Constants.MULT_TOP
    return 1.0

# Apply `base_damage` to `state` at `part`. Mutates state; returns Result.
# Tank is destroyed when: total HP <= 0 OR hull part HP <= 0 OR top part HP <= 0.
static func apply(state: TankState, part: int, base_damage: int) -> Result:
    var r := Result.new()
    if not state.alive:
        return r
    var mult := multiplier_for(part)
    var dmg: float = float(base_damage) * mult
    r.actual_damage = dmg
    var before: float = state.parts.get(part, 0.0)
    var after: float = max(0.0, before - dmg)
    state.parts[part] = after
    if before > 0.0 and after <= 0.0:
        r.part_just_destroyed = true
    # Recompute total HP as sum of parts (capped to u16 in snapshot).
    var total: float = 0.0
    for p in state.parts.values():
        total += p
    state.hp = int(round(total))
    # Death conditions
    var hull_dead := state.parts.get(TankState.Part.HULL, 1.0) <= 0.0
    var top_dead := state.parts.get(TankState.Part.TOP, 1.0) <= 0.0
    if state.hp <= 0 or hull_dead or top_dead:
        if state.alive:
            state.alive = false
            state.hp = 0
            r.tank_just_destroyed = true
    return r
```

- [ ] Create `tests/test_part_damage.gd`:

```gdscript
extends GutTest

const PartDamage = preload("res://shared/combat/part_damage.gd")
const TankState = preload("res://shared/tank/tank_state.gd")

func _make_tank() -> TankState:
    var t := TankState.new()
    t.initialize_parts(Constants.TANK_MAX_HP)
    t.alive = true
    return t

func test_hull_hit_applies_1x_multiplier() -> void:
    var t := _make_tank()
    var result := PartDamage.apply(t, TankState.Part.HULL, 100)
    assert_almost_eq(result.actual_damage, 100.0, 0.01)

func test_top_hit_applies_2_5x_multiplier() -> void:
    var t := _make_tank()
    var result := PartDamage.apply(t, TankState.Part.TOP, 100)
    assert_almost_eq(result.actual_damage, 250.0, 0.01)

func test_part_destruction_flagged() -> void:
    var t := _make_tank()
    # TOP has 10% of 900 = 90 HP, multiplier 2.5; 40 base damage → 100 dmg, overkills
    var result := PartDamage.apply(t, TankState.Part.TOP, 40)
    assert_true(result.part_just_destroyed)

func test_top_destruction_kills_tank() -> void:
    var t := _make_tank()
    var result := PartDamage.apply(t, TankState.Part.TOP, 1000)
    assert_true(result.tank_just_destroyed)
    assert_false(t.alive)

func test_hull_destruction_kills_tank() -> void:
    var t := _make_tank()
    # HULL has 40% of 900 = 360 HP, 1x mult, so 400 base = 400 dmg → destroyed
    var result := PartDamage.apply(t, TankState.Part.HULL, 400)
    assert_true(result.tank_just_destroyed)

func test_track_destruction_does_not_kill() -> void:
    var t := _make_tank()
    # L-TRACK has 10% of 900 = 90, 0.8x mult, so 200 base = 160 dmg → destroyed track but alive
    var result := PartDamage.apply(t, TankState.Part.LEFT_TRACK, 200)
    assert_true(result.part_just_destroyed)
    assert_false(result.tank_just_destroyed)
    assert_true(t.alive)
    assert_false(t.left_track_ok())

func test_total_hp_recomputed_as_sum() -> void:
    var t := _make_tank()
    PartDamage.apply(t, TankState.Part.HULL, 50)
    var expected: float = Constants.TANK_MAX_HP - 50
    assert_eq(t.hp, int(round(expected)))

func test_applying_to_dead_tank_is_noop() -> void:
    var t := _make_tank()
    t.alive = false
    var result := PartDamage.apply(t, TankState.Part.HULL, 100)
    assert_almost_eq(result.actual_damage, 0.0, 0.01)
```

- [ ] Run tests. Commit.

---

## Task 6: Update tank_movement to respect functional damage

Track-destroyed and engine-destroyed tanks should move differently.

- [ ] Replace `shared/tank/tank_movement.gd`:

```gdscript
# shared/tank/tank_movement.gd
class_name TankMovement

const TankState = preload("res://shared/tank/tank_state.gd")

# Advance a TankState by dt seconds given input.
static func step(state: TankState, input: Dictionary, dt: float) -> void:
    var fwd: float = clamp(float(input.get("move_forward", 0.0)), -1.0, 1.0)
    var turn: float = clamp(float(input.get("move_turn", 0.0)), -1.0, 1.0)

    # Track-based constraints: a destroyed track prevents its side's drive.
    var l_ok: bool = state.left_track_ok()
    var r_ok: bool = state.right_track_ok()
    if not l_ok and not r_ok:
        fwd = 0.0
        turn = 0.0
    elif not l_ok:
        # Right track only: can only turn left (negative turn, using right side thrust).
        # Simplification: allow slow forward creep + right-biased turn.
        fwd = fwd * 0.4
        turn = min(turn, 0.0)  # pinned to left-turn direction
    elif not r_ok:
        fwd = fwd * 0.4
        turn = max(turn, 0.0)

    # Engine damage scales max speed + accel.
    var max_speed: float = Constants.TANK_MAX_SPEED_MS
    var accel: float = Constants.TANK_ACCEL_MS2
    if not state.engine_ok():
        max_speed *= Constants.ENGINE_SPEED_FACTOR_WHEN_DEAD
        accel *= Constants.ENGINE_ACCEL_FACTOR_WHEN_DEAD

    # Accelerate/brake
    var target_speed: float = fwd * max_speed
    var speed_diff: float = target_speed - state.speed
    var accel_step: float = accel * dt
    if abs(speed_diff) <= accel_step:
        state.speed = target_speed
    else:
        state.speed += sign(speed_diff) * accel_step
    state.speed = clamp(state.speed, -max_speed * 0.5, max_speed)

    var turn_speed: float = deg_to_rad(Constants.TANK_TURN_RATE_DPS)
    state.yaw += turn * turn_speed * dt

    var forward_dir := Vector3(-sin(state.yaw), 0.0, -cos(state.yaw))
    state.pos += forward_dir * state.speed * dt
```

- [ ] Append to `tests/test_tank_movement.gd`:

```gdscript
func test_both_tracks_destroyed_stops_movement() -> void:
    var s := TankState.new()
    s.initialize_parts(Constants.TANK_MAX_HP)
    s.parts[TankState.Part.LEFT_TRACK] = 0.0
    s.parts[TankState.Part.RIGHT_TRACK] = 0.0
    s.pos = Vector3.ZERO
    TankMovement.step(s, _make_input(1.0, 0.0), 0.5)
    assert_almost_eq(s.speed, 0.0, 0.01)

func test_engine_destroyed_reduces_max_speed() -> void:
    var s := TankState.new()
    s.initialize_parts(Constants.TANK_MAX_HP)
    s.parts[TankState.Part.ENGINE] = 0.0
    s.pos = Vector3.ZERO
    # Drive full throttle for a long time
    for i in 200:
        TankMovement.step(s, _make_input(1.0, 0.0), 0.05)
    var max_expected: float = Constants.TANK_MAX_SPEED_MS * Constants.ENGINE_SPEED_FACTOR_WHEN_DEAD + 0.5
    assert_lt(s.speed, max_expected)

func test_healthy_tank_reaches_max_speed() -> void:
    var s := TankState.new()
    s.initialize_parts(Constants.TANK_MAX_HP)
    s.pos = Vector3.ZERO
    for i in 200:
        TankMovement.step(s, _make_input(1.0, 0.0), 0.05)
    assert_gt(s.speed, Constants.TANK_MAX_SPEED_MS - 0.1)
```

Update existing tests that `TankState.new()` to also call `s.initialize_parts(...)` where track-damage tests depend on it. The existing tests without part initialization should still pass because `left_track_ok()` returns `not is_part_destroyed(LEFT_TRACK)`, and with no parts dict, `part_hp()` returns 0.0, which IS treated as destroyed — this BREAKS existing tests.

Fix: `is_part_destroyed` should only return true when the key EXISTS and is <= 0. If no parts dict, consider everything intact.

Update `tank_state.gd`:

```gdscript
func is_part_destroyed(p: int) -> bool:
    if not parts.has(p):
        return false  # uninitialized = treat as intact (e.g. for tests of pure movement)
    return parts[p] <= 0.0
```

- [ ] Re-run all tests. Commit.

---

## Task 7: Update message types + messages

- [ ] Modify `common/protocol/message_types.gd` — rename `SHELL_FIRED` to `SHELL_SPAWNED` (same value 5):

```gdscript
    SHELL_SPAWNED = 5,   # server → all clients (was SHELL_FIRED in Plan 01)
```

Keep the numeric value 5 — no protocol breakage.

- [ ] Modify `common/protocol/messages.gd`:

Replace class `ShellFired` with:

```gdscript
# ---- ShellSpawned (server → all clients) ----
class ShellSpawned:
    var shell_id: int = 0
    var shooter_id: int = 0
    var origin: Vector3 = Vector3.ZERO
    var velocity: Vector3 = Vector3.ZERO
    var fire_time_ms: int = 0  # server millisecond timestamp for deterministic client replay

    func encode() -> PackedByteArray:
        var buf := PackedByteArray()
        Codec.write_u32(buf, shell_id)
        Codec.write_u16(buf, shooter_id)
        Codec.write_vec3(buf, origin)
        Codec.write_vec3(buf, velocity)
        Codec.write_u32(buf, fire_time_ms)
        return buf

    static func decode(buf: PackedByteArray) -> ShellSpawned:
        var m := ShellSpawned.new()
        var c := [0]
        m.shell_id = Codec.read_u32(buf, c)
        m.shooter_id = Codec.read_u16(buf, c)
        m.origin = Codec.read_vec3(buf, c)
        m.velocity = Codec.read_vec3(buf, c)
        m.fire_time_ms = Codec.read_u32(buf, c)
        return m
```

Extend `Hit` with `part_id` (u8):

```gdscript
class Hit:
    var shooter_id: int = 0
    var victim_id: int = 0
    var damage: int = 0
    var part_id: int = 0
    var hit_point: Vector3 = Vector3.ZERO

    func encode() -> PackedByteArray:
        var buf := PackedByteArray()
        Codec.write_u16(buf, shooter_id)
        Codec.write_u16(buf, victim_id)
        Codec.write_u16(buf, damage)
        Codec.write_u8(buf, part_id)
        Codec.write_vec3(buf, hit_point)
        return buf

    static func decode(buf: PackedByteArray) -> Hit:
        var m := Hit.new()
        var c := [0]
        m.shooter_id = Codec.read_u16(buf, c)
        m.victim_id = Codec.read_u16(buf, c)
        m.damage = Codec.read_u16(buf, c)
        m.part_id = Codec.read_u8(buf, c)
        m.hit_point = Codec.read_vec3(buf, c)
        return m
```

- [ ] Update `tests/test_messages.gd` Hit test to include part_id. Add a ShellSpawned roundtrip test:

```gdscript
func test_hit_roundtrip() -> void:
    var msg := Messages.Hit.new()
    msg.shooter_id = 3
    msg.victim_id = 5
    msg.damage = 260
    msg.part_id = 2
    msg.hit_point = Vector3(1, 2, 3)
    var bytes := msg.encode()
    var decoded := Messages.Hit.decode(bytes)
    assert_eq(decoded.shooter_id, 3)
    assert_eq(decoded.victim_id, 5)
    assert_eq(decoded.damage, 260)
    assert_eq(decoded.part_id, 2)

func test_shell_spawned_roundtrip() -> void:
    var msg := Messages.ShellSpawned.new()
    msg.shell_id = 42
    msg.shooter_id = 3
    msg.origin = Vector3(10, 20, 30)
    msg.velocity = Vector3(100, 50, -200)
    msg.fire_time_ms = 123456789
    var bytes := msg.encode()
    var decoded := Messages.ShellSpawned.decode(bytes)
    assert_eq(decoded.shell_id, 42)
    assert_eq(decoded.shooter_id, 3)
    assert_almost_eq(decoded.velocity.z, -200.0, 0.001)
    assert_eq(decoded.fire_time_ms, 123456789)
```

- [ ] Run tests. Commit.

---

## Task 8: Shell simulator on the server

- [ ] Create `server/combat/shell_sim.gd`:

```gdscript
# server/combat/shell_sim.gd
extends Node

const Ballistics = preload("res://shared/combat/ballistics.gd")
const PartClassifier = preload("res://shared/combat/part_classifier.gd")
const PartDamage = preload("res://shared/combat/part_damage.gd")
const TerrainGenerator = preload("res://shared/world/terrain_generator.gd")

class Shell:
    var id: int = 0
    var shooter_id: int = 0
    var origin: Vector3
    var velocity: Vector3
    var fire_time_s: float  # engine time at fire

var _next_id: int = 1
var _shells: Array = []  # Array[Shell]
var _world
var _hit_callback: Callable  # fn(shell, victim_id_or_0, hit_point, part_id_or_0)

func set_world(w) -> void:
    _world = w

func set_hit_callback(cb: Callable) -> void:
    _hit_callback = cb

func spawn(shooter_id: int, origin: Vector3, velocity: Vector3) -> Shell:
    var s := Shell.new()
    s.id = _next_id
    _next_id += 1
    s.shooter_id = shooter_id
    s.origin = origin
    s.velocity = velocity
    s.fire_time_s = Time.get_ticks_msec() / 1000.0
    _shells.append(s)
    return s

func tick(dt: float) -> void:
    var now: float = Time.get_ticks_msec() / 1000.0
    var to_remove: Array = []
    for s in _shells:
        var t0: float = now - dt - s.fire_time_s
        var t1: float = now - s.fire_time_s
        if t1 > Constants.SHELL_MAX_LIFETIME_S:
            to_remove.append(s)
            continue
        # Swept collision over this tick's interval, subdividing for accuracy.
        var subs: int = Constants.SHELL_STEP_SUBDIVISIONS
        var hit_info := _swept_collide(s, t0, t1, subs)
        if hit_info["hit"]:
            to_remove.append(s)
            if _hit_callback.is_valid():
                _hit_callback.call(s, hit_info["victim_id"], hit_info["point"], hit_info["part_id"])
    for s in to_remove:
        _shells.erase(s)

# Returns dict {hit: bool, victim_id: int, point: Vector3, part_id: int}
func _swept_collide(s: Shell, t0: float, t1: float, subs: int) -> Dictionary:
    var dt: float = (t1 - t0) / float(subs)
    var prev_pos: Vector3 = Ballistics.position_at(s.origin, s.velocity, t0)
    for i in range(1, subs + 1):
        var t: float = t0 + dt * i
        var pos: Vector3 = Ballistics.position_at(s.origin, s.velocity, t)
        # Terrain collision
        if _world.heightmap.size() > 0:
            var terrain_h: float = TerrainGenerator.sample_height(_world.heightmap, _world.terrain_size, pos.x, pos.z)
            if pos.y <= terrain_h:
                return {"hit": true, "victim_id": 0, "point": pos, "part_id": 0}
        # Tank collision
        for pid in _world.tanks:
            if pid == s.shooter_id:
                continue
            var target = _world.tanks[pid]
            if not target.alive:
                continue
            if target.team == _world.tanks[s.shooter_id].team:
                continue
            # Broad sphere check: tank is ~5m long, ~3m tall, center at pos + (0,1,0)
            var center: Vector3 = target.pos + Vector3(0, 1.2, 0)
            var seg_dir: Vector3 = pos - prev_pos
            var to_center: Vector3 = center - prev_pos
            var seg_len: float = seg_dir.length()
            if seg_len < 0.001:
                continue
            var seg_norm: Vector3 = seg_dir / seg_len
            var proj: float = to_center.dot(seg_norm)
            proj = clamp(proj, 0.0, seg_len)
            var closest: Vector3 = prev_pos + seg_norm * proj
            if closest.distance_to(center) <= 3.0:
                # Use closest point as approx hit point
                var part: int = PartClassifier.classify(target.pos, target.yaw, closest)
                return {"hit": true, "victim_id": pid, "point": closest, "part_id": part}
        prev_pos = pos
    return {"hit": false, "victim_id": 0, "point": Vector3.ZERO, "part_id": 0}

func all_active() -> Array:
    return _shells
```

- [ ] Commit.

---

## Task 9: Rewire TickLoop to use shells + part damage

- [ ] Modify `server/sim/tick_loop.gd`:

At the top add:
```gdscript
const ShellSim = preload("res://server/combat/shell_sim.gd")
const Ballistics = preload("res://shared/combat/ballistics.gd")
const PartDamage = preload("res://shared/combat/part_damage.gd")
const TankState = preload("res://shared/tank/tank_state.gd")
```

Add a `_shell_sim` field, instantiate in `set_world`:
```gdscript
var _shell_sim: ShellSim

func set_world(w) -> void:
    _world = w
    _shell_sim = ShellSim.new()
    add_child(_shell_sim)
    _shell_sim.set_world(w)
    _shell_sim.set_hit_callback(_on_shell_hit)
```

In `_step_tick`, after tank sim, add shell sim:
```gdscript
    _shell_sim.tick(dt)
```

Replace `_on_fire_received`:

```gdscript
func _on_fire_received(peer_id: int, _fire_msg) -> void:
    var pid: int = _ws_server.player_id_for_peer(peer_id)
    if pid == 0 or not _world.tanks.has(pid):
        return
    var state = _world.tanks[pid]
    if not state.can_fire():
        return
    state.ammo -= 1
    state.reload_remaining = Constants.TANK_RELOAD_S
    var muzzle_offset := 2.5
    var origin: Vector3 = state.pos + Vector3(0, 1.6, 0)  # muzzle at turret height
    var world_turret_yaw: float = state.yaw + state.turret_yaw
    var velocity: Vector3 = Ballistics.initial_velocity(world_turret_yaw, state.gun_pitch, Constants.SHELL_INITIAL_SPEED)
    origin += velocity.normalized() * muzzle_offset
    var shell = _shell_sim.spawn(pid, origin, velocity)
    # Broadcast spawn event to all clients
    var msg := Messages.ShellSpawned.new()
    msg.shell_id = shell.id
    msg.shooter_id = pid
    msg.origin = origin
    msg.velocity = velocity
    msg.fire_time_ms = Time.get_ticks_msec()
    _ws_server.broadcast(MessageType.SHELL_SPAWNED, msg.encode())

func _on_shell_hit(shell, victim_id: int, hit_point: Vector3, part_id: int) -> void:
    if victim_id == 0:
        # Terrain / miss — send Hit with victim_id=0, damage=0 so clients can play ground puff
        var hit_msg := Messages.Hit.new()
        hit_msg.shooter_id = shell.shooter_id
        hit_msg.victim_id = 0
        hit_msg.damage = 0
        hit_msg.part_id = 0
        hit_msg.hit_point = hit_point
        _ws_server.broadcast(MessageType.HIT, hit_msg.encode())
        return
    if not _world.tanks.has(victim_id):
        return
    var victim = _world.tanks[victim_id]
    var result := PartDamage.apply(victim, part_id, Constants.TANK_FIRE_DAMAGE)
    var hit_msg := Messages.Hit.new()
    hit_msg.shooter_id = shell.shooter_id
    hit_msg.victim_id = victim_id
    hit_msg.damage = int(round(result.actual_damage))
    hit_msg.part_id = part_id
    hit_msg.hit_point = hit_point
    _ws_server.broadcast(MessageType.HIT, hit_msg.encode())
    if result.tank_just_destroyed:
        _respawns[victim_id] = Constants.RESPAWN_COOLDOWN_S
        var death_msg := Messages.Death.new()
        death_msg.victim_id = victim_id
        death_msg.killer_id = shell.shooter_id
        _ws_server.broadcast(MessageType.DEATH, death_msg.encode())
```

Delete the old `_resolve_hitscan` and `_apply_hit` functions.

In `_respawn_player`, reset parts:

```gdscript
    state.initialize_parts(Constants.TANK_MAX_HP)
    state.ammo = Constants.TANK_AMMO_CAPACITY
    state.reload_remaining = 0.0
    state.speed = 0.0
    state.alive = true
```

- [ ] Modify `server/world/world_instance.gd` → in `spawn_tank`:

```gdscript
    t.initialize_parts(Constants.TANK_MAX_HP)
    # (remove the old `t.hp = Constants.TANK_MAX_HP`)
```

- [ ] Boot server, verify no errors, commit.

---

## Task 10: Client — visualize ballistic shell + update Hit handler

- [ ] Modify `client/main_client.gd`:

Replace the `MessageType.SHELL_FIRED` branch and `_handle_shell_fired` / `_spawn_tracer` with:

```gdscript
        MessageType.SHELL_SPAWNED:
            _handle_shell_spawned(Messages.ShellSpawned.decode(payload))
```

Add:

```gdscript
var _shells: Dictionary = {}  # shell_id → Node3D (visual shell)

func _handle_shell_spawned(msg) -> void:
    var mesh := MeshInstance3D.new()
    var sm := SphereMesh.new()
    sm.radius = 0.2
    sm.height = 0.4
    mesh.mesh = sm
    var mat := StandardMaterial3D.new()
    mat.albedo_color = Color(1, 0.6, 0.15)
    mat.emission_enabled = true
    mat.emission = Color(1, 0.4, 0.0)
    mesh.material_override = mat
    var holder := Node3D.new()
    holder.add_child(mesh)
    holder.set_meta("origin", msg.origin)
    holder.set_meta("velocity", msg.velocity)
    holder.set_meta("fire_time_ms", msg.fire_time_ms)
    holder.set_meta("server_time_ref_ms", Time.get_ticks_msec())
    add_child(holder)
    _shells[msg.shell_id] = holder
```

In `_process`:

```gdscript
func _process(_delta: float) -> void:
    # Advance visual shells
    const Ballistics = preload("res://shared/combat/ballistics.gd")
    for shell_id in _shells.keys():
        var h: Node3D = _shells[shell_id]
        var origin: Vector3 = h.get_meta("origin")
        var vel: Vector3 = h.get_meta("velocity")
        var fire_ms: int = h.get_meta("fire_time_ms")
        var ref_ms: int = h.get_meta("server_time_ref_ms")
        var elapsed_ms := (Time.get_ticks_msec() - ref_ms) + (ref_ms - fire_ms)
        var elapsed: float = float(elapsed_ms) / 1000.0
        if elapsed > Constants.SHELL_MAX_LIFETIME_S:
            h.queue_free()
            _shells.erase(shell_id)
            continue
        h.position = Ballistics.position_at(origin, vel, elapsed)
```

Wait — since we don't have a reliable "server now" clock on the client, use the simpler approach: track elapsed since client received the spawn. The slight latency (one-way) means the shell appears ~50ms "later" than server, but visually it's fine for a skeleton.

Simplify `_handle_shell_spawned` — drop the `fire_time_ms` tracking and use client-local start time:

```gdscript
func _handle_shell_spawned(msg) -> void:
    var mesh := MeshInstance3D.new()
    var sm := SphereMesh.new()
    sm.radius = 0.2
    sm.height = 0.4
    mesh.mesh = sm
    var mat := StandardMaterial3D.new()
    mat.albedo_color = Color(1, 0.6, 0.15)
    mat.emission_enabled = true
    mat.emission = Color(1, 0.4, 0.0)
    mesh.material_override = mat
    var holder := Node3D.new()
    holder.add_child(mesh)
    holder.set_meta("origin", msg.origin)
    holder.set_meta("velocity", msg.velocity)
    holder.set_meta("start_ms", Time.get_ticks_msec())
    add_child(holder)
    _shells[msg.shell_id] = holder
```

And `_process`:

```gdscript
func _process(_delta: float) -> void:
    for shell_id in _shells.keys():
        var h: Node3D = _shells[shell_id]
        var elapsed: float = float(Time.get_ticks_msec() - int(h.get_meta("start_ms"))) / 1000.0
        if elapsed > Constants.SHELL_MAX_LIFETIME_S:
            h.queue_free()
            _shells.erase(shell_id)
            continue
        var origin: Vector3 = h.get_meta("origin")
        var vel: Vector3 = h.get_meta("velocity")
        h.position = Ballistics.position_at(origin, vel, elapsed)
```

Add `const Ballistics = preload("res://shared/combat/ballistics.gd")` to the top-level consts.

Update `_handle_hit` to despawn the associated shell visual:

```gdscript
func _handle_hit(msg) -> void:
    # Plan 02: clients don't know which shell it was — just play puff at hit_point
    # and flash the victim. Future improvement: include shell_id in Hit.
    if msg.victim_id != 0 and _tanks.has(msg.victim_id):
        _tanks[msg.victim_id].flash_hit()
    _spawn_impact_puff(msg.hit_point)
```

Add `_spawn_impact_puff`:

```gdscript
func _spawn_impact_puff(pos: Vector3) -> void:
    var mesh := MeshInstance3D.new()
    var sm := SphereMesh.new()
    sm.radius = 1.2
    sm.height = 2.4
    mesh.mesh = sm
    var mat := StandardMaterial3D.new()
    mat.albedo_color = Color(1, 0.8, 0.2, 0.8)
    mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    mat.emission_enabled = true
    mat.emission = Color(1, 0.5, 0.0)
    mesh.material_override = mat
    mesh.position = pos
    add_child(mesh)
    get_tree().create_timer(0.3).timeout.connect(func(): mesh.queue_free())
```

Since we don't despawn visual shells on hit (they'll just linger until SHELL_MAX_LIFETIME_S elapses), that's acceptable for Plan 02. Future improvement: Hit includes shell_id and we despawn.

Actually let me add shell_id to Hit for Plan 02. It's a trivial change.

- [ ] Revisit — add `shell_id: int` to `Hit` message (after part_id), update test, and despawn shell on receipt:

In `messages.gd`, `Hit.encode` adds `Codec.write_u32(buf, shell_id)`, decode reads it.

In `shell_sim._swept_collide`, return dict also carries `shell_id` actually it has `s` (the shell) which has `.id`. Update tick_loop `_on_shell_hit` signature to include the shell id (we already pass `shell`):

```gdscript
    hit_msg.shell_id = shell.id
```

In client `_handle_hit`:

```gdscript
    if _shells.has(msg.shell_id):
        _shells[msg.shell_id].queue_free()
        _shells.erase(msg.shell_id)
```

Update test_messages to include shell_id assertion.

- [ ] Commit.

---

## Task 11: Full verification

- [ ] Run all unit tests:
  ```
  /Applications/Godot.app/Contents/MacOS/Godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests -gexit
  ```
  Expect all passing.

- [ ] Boot server, boot client; verify logs show:
  - `SHELL_SPAWNED` broadcasts on fire
  - `HIT` broadcasts when shell reaches target/ground
  - No script errors

- [ ] Tag milestone:
  ```
  git tag plan-02-ballistics-part-damage-complete
  ```

- [ ] Write completion notes to `docs/superpowers/plans/2026-04-18-plan-02-completion-notes.md`.

---

## Self-Review

**Spec coverage (Plan 02 scope):**
- Parabolic ballistics (gravity, travel time, no wind/drag) → Task 3, 8
- 6-part damage with multipliers → Task 2, 4, 5
- Functional damage (track/engine/turret) → Task 6 (movement), Task 2 (can_fire), Task 5 (kill condition)
- Part HP proportions & multipliers match spec §5.2 → Task 1 constants
- Shell visualization client-side → Task 10
- Test coverage for new logic → Tasks 3, 4, 5, 6, 7

**Deferred (documented above):**
- Repair mechanic (spec §5.2 抢修)
- Shell-obstacle damage (Plan 04)
- Armor penetration (never in Plan 0x, see spec §10 out-of-scope)

**Placeholder scan:** none.

**Type consistency:** `TankState.Part` enum used consistently; `msg.shell_id` consistent between ShellSpawned and Hit.

**Potential gotchas:**
- `is_part_destroyed` must return `false` when the part key is absent (uninitialized TankState used in movement tests without parts init). Fixed in Task 6.
- Client tracks shell time from local receipt, not server fire time — ~50ms latency offset in visual. Acceptable for Plan 02.

**Plan complete.**
