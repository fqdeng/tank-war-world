# shared/tank/tank_movement.gd
class_name TankMovement

const TankState = preload("res://shared/tank/tank_state.gd")

# Advance a TankState by dt seconds given input. Respects functional damage.
static func step(state: TankState, input: Dictionary, dt: float) -> void:
    var fwd: float = clamp(float(input.get("move_forward", 0.0)), -1.0, 1.0)
    var turn: float = clamp(float(input.get("move_turn", 0.0)), -1.0, 1.0)

    var l_ok: bool = state.left_track_ok()
    var r_ok: bool = state.right_track_ok()
    if not l_ok and not r_ok:
        fwd = 0.0
        turn = 0.0
    elif not l_ok:
        fwd = fwd * 0.4
        turn = min(turn, 0.0)
    elif not r_ok:
        fwd = fwd * 0.4
        turn = max(turn, 0.0)

    var max_speed: float = Constants.TANK_MAX_SPEED_MS
    var accel: float = Constants.TANK_ACCEL_MS2
    if not state.engine_ok():
        max_speed *= Constants.ENGINE_SPEED_FACTOR_WHEN_DEAD
        accel *= Constants.ENGINE_ACCEL_FACTOR_WHEN_DEAD

    var target_speed: float = fwd * max_speed
    var speed_diff: float = target_speed - state.speed

    # If input direction opposes current velocity, apply brake force (faster
    # deceleration). This makes S feel like a brake while moving forward rather
    # than a slow reverse-ramp.
    var accel_used: float = accel
    if fwd != 0.0 and state.speed != 0.0 and sign(fwd) != sign(state.speed):
        accel_used = Constants.TANK_BRAKE_DECEL_MS2
    var accel_step: float = accel_used * dt

    if abs(speed_diff) <= accel_step:
        state.speed = target_speed
    else:
        state.speed += sign(speed_diff) * accel_step
    state.speed = clamp(state.speed, -max_speed * 0.5, max_speed)

    var turn_speed: float = deg_to_rad(Constants.TANK_TURN_RATE_DPS)
    # When actually reversing (moving backward, not just braking), invert A/D so
    # steering matches the driver's perspective of where the rear is going —
    # same convention as cars/tanks in most driving games.
    var steering_turn: float = turn
    if state.speed < -0.1:
        steering_turn = -steering_turn
    state.yaw += steering_turn * turn_speed * dt

    var forward_dir := Vector3(-sin(state.yaw), 0.0, -cos(state.yaw))
    state.pos += forward_dir * state.speed * dt
