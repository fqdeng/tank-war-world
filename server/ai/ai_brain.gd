# server/ai/ai_brain.gd
# Dead-simple brain: pick a random waypoint inside the playable area, drive
# toward it. Find the nearest enemy; if within engagement range, rotate turret
# toward them and fire periodically.
extends RefCounted

const TankState = preload("res://shared/tank/tank_state.gd")
const Ballistics = preload("res://shared/combat/ballistics.gd")

var _player_id: int = 0
var _waypoint: Vector3 = Vector3.ZERO
var _repath_timer: float = 0.0
var _fire_cooldown: float = 0.0
var _rng := RandomNumberGenerator.new()

# Stuck-detection: if we're commanding forward motion but measured speed stays
# below STUCK_SPEED_THRESHOLD for STUCK_TRIGGER_S, we're pinned against a tree/
# rock. Pick a new waypoint and reverse for UNSTICK_REVERSE_S while veering
# to break free.
var _stuck_timer: float = 0.0
var _unstick_timer: float = 0.0
var _unstick_turn_sign: float = 1.0
var _stuck_grace_timer: float = 0.0
var _prev_pos: Vector3 = Vector3.ZERO
var _has_prev_pos: bool = false
const STUCK_SPEED_THRESHOLD: float = 1.5
const STUCK_TRIGGER_S: float = 1.2
const UNSTICK_REVERSE_S: float = 1.2

# Cap how fast AI can traverse the turret / elevate the gun so it can't snap
# onto a target in one tick. Before this, the brain set turret_yaw directly to
# the target bearing each tick → effectively instant aimbot.
const AI_TURRET_SLEW_DPS: float = 55.0
const AI_PITCH_SLEW_DPS: float = 30.0

# Aim-error model: AI doesn't solve ballistics perfectly. On target acquire
# it rolls a unit-signed bias in [-1, 1]; applied error = bias × MAX_ERR ×
# distance_scale, so far shots are sloppier than close ones. Each shot at the
# same target shrinks the bias by AI_ERR_DECAY → human-like "ranging in"
# across 3-5 rounds. Switching targets re-rolls the bias.
const AI_MAX_YAW_ERR: float = 0.050    # ~2.9° lateral at ref range
const AI_MAX_PITCH_ERR: float = 0.070  # ~4.0° elevation at ref range
const AI_ERR_DECAY: float = 0.55
const AI_ERR_REF_DIST_M: float = 300.0  # distance at which error scale = 1.0
const AI_ERR_MIN_SCALE: float = 0.2     # close-range floor — point-blank still has tiny wobble
const AI_ERR_MAX_SCALE: float = 1.8     # long-range ceiling — don't blow up past max engage

# Local proximity steering: every tick, offset the waypoint-heading by a
# repulsion term from obstacles inside a forward cone. Keeps AI from driving
# straight into rocks/trees instead of waiting for the stuck fallback.
const AVOID_LOOKAHEAD_M: float = 18.0
const AVOID_K: float = 1.2
const AVOID_URGENCY_SLOW: float = 0.6

var _current_target_id: int = 0
var _aim_yaw_bias: float = 0.0   # unit-signed [-1, 1], scaled by distance at use time
var _aim_pitch_bias: float = 0.0

func setup(pid: int, world) -> void:
    _player_id = pid
    _rng.seed = hash(pid) + int(Time.get_ticks_msec())
    _pick_new_waypoint(world)
    _stuck_grace_timer = 0.5

func step(state: TankState, world, dt: float) -> Dictionary:
    _repath_timer -= dt
    _fire_cooldown -= dt
    _unstick_timer = max(0.0, _unstick_timer - dt)
    _stuck_grace_timer = max(0.0, _stuck_grace_timer - dt)

    # Measure actual movement so we can detect when we're wedged against an
    # obstacle (TankCollision pushes us out every tick, so commanded forward
    # motion translates to zero real displacement).
    var actual_speed: float = 0.0
    if _has_prev_pos:
        actual_speed = (state.pos - _prev_pos).length() / max(dt, 0.0001)
    _prev_pos = state.pos
    _has_prev_pos = true

    var move_forward: float = 0.0
    var move_turn: float = 0.0

    if _unstick_timer > 0.0:
        # Backing away from whatever we were stuck on. Veering while reversing
        # makes the tank rotate off the obstacle instead of hitting it again.
        move_forward = -1.0
        move_turn = _unstick_turn_sign
    else:
        var to_wp: Vector3 = _waypoint - state.pos
        to_wp.y = 0.0
        if to_wp.length() < 20.0 or _repath_timer <= 0.0:
            _pick_new_waypoint(world)
            to_wp = _waypoint - state.pos
            to_wp.y = 0.0
        var desired_yaw: float = atan2(-to_wp.x, -to_wp.z)
        var avoid_result: Dictionary = _compute_avoid_turn(state, world)
        var adjusted_yaw: float = desired_yaw + avoid_result.turn * AVOID_K
        var yaw_err: float = wrapf(adjusted_yaw - state.yaw, -PI, PI)
        move_turn = clamp(yaw_err / 0.4, -1.0, 1.0)
        move_forward = 1.0 if abs(yaw_err) < 1.2 else 0.0
        if avoid_result.max_urgency > AVOID_URGENCY_SLOW:
            move_forward = min(move_forward, 0.3)

        # Stuck check: commanded forward motion but barely any real displacement.
        if _stuck_grace_timer <= 0.0 and move_forward > 0.5 and actual_speed < STUCK_SPEED_THRESHOLD:
            _stuck_timer += dt
        else:
            _stuck_timer = 0.0
        if _stuck_timer >= STUCK_TRIGGER_S:
            _stuck_timer = 0.0
            _unstick_timer = UNSTICK_REVERSE_S
            _unstick_turn_sign = 1.0 if _rng.randf() > 0.5 else -1.0
            _pick_new_waypoint(world)
            move_forward = -1.0
            move_turn = _unstick_turn_sign

    # Engage nearest enemy ONLY if line-of-sight is not blocked by an obstacle.
    # Turret/gun slew toward the desired bearing at a capped rate so aim feels
    # gradual — fires only after current aim is within tolerance AND settled.
    var target_id: int = _find_visible_enemy(state, world)
    var turret_yaw: float = state.turret_yaw
    var gun_pitch: float = state.gun_pitch
    var fire_pressed: bool = false
    if target_id != 0:
        # Re-roll aim bias on target switch; shrink it each shot at the same
        # target (next-shot adjustment). First shot on a new target lands
        # several degrees off; successive shots tighten up.
        if target_id != _current_target_id:
            _current_target_id = target_id
            _aim_yaw_bias = _rng.randf_range(-1.0, 1.0)
            _aim_pitch_bias = _rng.randf_range(-1.0, 1.0)
        var target = world.tanks[target_id]
        var to_t: Vector3 = target.pos - state.pos
        var horiz_dist: float = sqrt(to_t.x * to_t.x + to_t.z * to_t.z)
        # Distance-dependent error magnitude: close-up shots land almost on
        # target, long-range shots wander.
        var dist_scale: float = clamp(horiz_dist / AI_ERR_REF_DIST_M, AI_ERR_MIN_SCALE, AI_ERR_MAX_SCALE)
        var yaw_err: float = _aim_yaw_bias * AI_MAX_YAW_ERR * dist_scale
        var pitch_err: float = _aim_pitch_bias * AI_MAX_PITCH_ERR * dist_scale
        var world_turret_yaw: float = atan2(-to_t.x, -to_t.z)
        var desired_turret_yaw: float = wrapf(world_turret_yaw - state.yaw + yaw_err, -PI, PI)
        var max_dyaw: float = deg_to_rad(AI_TURRET_SLEW_DPS) * dt
        var yaw_delta: float = clamp(wrapf(desired_turret_yaw - state.turret_yaw, -PI, PI), -max_dyaw, max_dyaw)
        turret_yaw = state.turret_yaw + yaw_delta
        var desired_pitch: float = clamp(_estimate_pitch(horiz_dist, to_t.y) + pitch_err, deg_to_rad(-8.0), deg_to_rad(12.0))
        var max_dpitch: float = deg_to_rad(AI_PITCH_SLEW_DPS) * dt
        gun_pitch = state.gun_pitch + clamp(desired_pitch - state.gun_pitch, -max_dpitch, max_dpitch)
        var aim_err: float = abs(wrapf(desired_turret_yaw - turret_yaw, -PI, PI))
        if aim_err < 0.04 and _fire_cooldown <= 0.0:
            fire_pressed = true
            _fire_cooldown = Constants.TANK_RELOAD_S + _rng.randf_range(1.2, 2.5)
            # "Ranging in" — next shot at the same target is more accurate.
            _aim_yaw_bias *= AI_ERR_DECAY
            _aim_pitch_bias *= AI_ERR_DECAY
    else:
        _current_target_id = 0
    return {
        "move_forward": move_forward,
        "move_turn": move_turn,
        "turret_yaw": turret_yaw,
        "gun_pitch": gun_pitch,
        "fire_pressed": fire_pressed,
        "tick": 0,
    }

# Closest enemy tank with clear line-of-sight (no obstacle blocking xz line).
func _find_visible_enemy(state: TankState, world) -> int:
    var best_id: int = 0
    var best_d2: float = INF
    var max_engage_sq: float = 600.0 * 600.0
    for pid in world.tanks:
        if pid == state.player_id:
            continue
        var other = world.tanks[pid]
        if not other.alive or other.team == state.team:
            continue
        var dx: float = other.pos.x - state.pos.x
        var dz: float = other.pos.z - state.pos.z
        var d2: float = dx * dx + dz * dz
        if d2 > max_engage_sq or d2 >= best_d2:
            continue
        if not _has_los(state.pos, other.pos, world):
            continue
        best_d2 = d2
        best_id = pid
    return best_id

# True when no non-destroyed obstacle intersects the xz line between `from` and `to`.
func _has_los(from: Vector3, to: Vector3, world) -> bool:
    var dx: float = to.x - from.x
    var dz: float = to.z - from.z
    var len_sq: float = dx * dx + dz * dz
    if len_sq < 0.01:
        return true
    for o in world.obstacles:
        if world.is_obstacle_destroyed(o.id):
            continue
        var r: float = _obstacle_radius(o.kind)
        var ox: float = o.pos.x - from.x
        var oz: float = o.pos.z - from.z
        var dot: float = ox * dx + oz * dz
        if dot < 0.0 or dot > len_sq:
            continue
        var t: float = dot / len_sq
        var px: float = ox - dx * t
        var pz: float = oz - dz * t
        if px * px + pz * pz < r * r:
            return false
    return true

func _obstacle_radius(kind: int) -> float:
    match kind:
        0: return Constants.OBSTACLE_RADIUS_SMALL_ROCK
        1: return Constants.OBSTACLE_RADIUS_LARGE_ROCK
        2: return Constants.OBSTACLE_RADIUS_TREE
    return 1.0

func _estimate_pitch(horiz_dist: float, dy: float) -> float:
    var v: float = Constants.SHELL_INITIAL_SPEED
    var g: float = Constants.GRAVITY
    var s: float = g * horiz_dist / (v * v)
    if s >= 1.0:
        return deg_to_rad(12.0)
    var pitch: float = 0.5 * asin(s)
    if abs(dy) > 1.0:
        pitch += atan2(dy, horiz_dist) * 0.5
    return pitch

func _pick_new_waypoint(world) -> void:
    var margin: float = Constants.PLAYABLE_MARGIN_M + 20.0
    var size: float = float(world.terrain_size)
    var chosen: Vector3 = Vector3.ZERO
    var have_chosen: bool = false
    for i in range(6):
        var x: float = _rng.randf_range(margin, size - margin)
        var z: float = _rng.randf_range(margin, size - margin)
        var cand := Vector3(x, 0.0, z)
        chosen = cand
        have_chosen = true
        if not _line_blocked_by_large_rock(_prev_pos if _has_prev_pos else cand, cand, world):
            break
    if not have_chosen:
        # Unreachable — loop always sets chosen at least once. Guard kept for clarity.
        chosen = Vector3(margin, 0.0, margin)
    _waypoint = chosen
    _repath_timer = _rng.randf_range(6.0, 12.0)

# Straight-line blocker check: only LARGE_ROCK (kind == 1) vetoes a waypoint.
# Trees (kind 2) and small rocks (kind 0) can be pushed through by a tank and
# should not force repath churn.
func _line_blocked_by_large_rock(from: Vector3, to: Vector3, world) -> bool:
    var dx: float = to.x - from.x
    var dz: float = to.z - from.z
    var len_sq: float = dx * dx + dz * dz
    if len_sq < 0.01:
        return false
    for o in world.obstacles:
        if o.kind != 1:
            continue
        if world.is_obstacle_destroyed(o.id):
            continue
        var r: float = Constants.OBSTACLE_RADIUS_LARGE_ROCK + Constants.TANK_COLLISION_RADIUS
        var ox: float = o.pos.x - from.x
        var oz: float = o.pos.z - from.z
        var dot: float = ox * dx + oz * dz
        if dot < 0.0 or dot > len_sq:
            continue
        var t: float = dot / len_sq
        var px: float = ox - dx * t
        var pz: float = oz - dz * t
        if px * px + pz * pz < r * r:
            return true
    return false

# Returns {"turn": float, "max_urgency": float}.
# turn: signed steering offset (radians-ish, scaled by AVOID_K by caller).
# max_urgency: 0..~1, used by caller to decide whether to throttle forward speed.
func _compute_avoid_turn(state: TankState, world) -> Dictionary:
    # Forward and right in world. Tank yaw convention (see desired_yaw in step()):
    # desired_yaw = atan2(-dx, -dz), so at yaw=0 the tank faces -Z and
    # pilot's right is +X. Derivation: right = forward × up.
    var fwd_x: float = -sin(state.yaw)
    var fwd_z: float = -cos(state.yaw)
    var right_x: float =  cos(state.yaw)
    var right_z: float = -sin(state.yaw)
    var turn: float = 0.0
    var max_urgency: float = 0.0
    var stable_side: float = 1.0 if (_player_id & 1) == 0 else -1.0
    for o in world.obstacles:
        if world.is_obstacle_destroyed(o.id):
            continue
        var r: float = _obstacle_radius(o.kind)
        var dx: float = o.pos.x - state.pos.x
        var dz: float = o.pos.z - state.pos.z
        var d_sq: float = dx * dx + dz * dz
        if d_sq < 0.0001:
            continue
        var d: float = sqrt(d_sq)
        var fwd_dot: float = (fwd_x * dx + fwd_z * dz) / d
        if fwd_dot < 0.2:
            continue
        var reach: float = AVOID_LOOKAHEAD_M + r
        if d > reach:
            continue
        var right_dot: float = (right_x * dx + right_z * dz) / d
        var urgency: float = (1.0 - d / reach) * fwd_dot
        var side: float = sign(right_dot)
        if abs(right_dot) < 0.1:
            side = stable_side
        # Obstacle on right (side > 0) → turn LEFT (positive yaw delta, since
        # +yaw rotates forward toward -X which is the tank's left half).
        turn += side * urgency
        if urgency > max_urgency:
            max_urgency = urgency
    return {"turn": turn, "max_urgency": max_urgency}

