# shared/tank/tank_movement.gd
class_name TankMovement

# Pure function: advance a TankState by dt seconds given input.
# Does NOT touch Godot scene nodes — safe to test headless.
# Does NOT handle terrain collision — caller lifts pos.y to terrain height each tick.
# input: Dictionary with move_forward ∈ [-1,1], move_turn ∈ [-1,1]
static func step(state: TankState, input: Dictionary, dt: float) -> void:
    var fwd: float = clamp(float(input.get("move_forward", 0.0)), -1.0, 1.0)
    var turn: float = clamp(float(input.get("move_turn", 0.0)), -1.0, 1.0)

    # Accelerate/brake
    var target_speed: float = fwd * Constants.TANK_MAX_SPEED_MS
    var speed_diff: float = target_speed - state.speed
    var accel_step: float = Constants.TANK_ACCEL_MS2 * dt
    if abs(speed_diff) <= accel_step:
        state.speed = target_speed
    else:
        state.speed += sign(speed_diff) * accel_step

    # Clamp magnitude (reverse allowed up to 0.5x max)
    state.speed = clamp(state.speed, -Constants.TANK_MAX_SPEED_MS * 0.5, Constants.TANK_MAX_SPEED_MS)

    # Turn rate is a flat value (tank can pivot at rest in this simplified model)
    var turn_speed: float = deg_to_rad(Constants.TANK_TURN_RATE_DPS)
    state.yaw += turn * turn_speed * dt

    # Move forward along body yaw (Godot -Z convention)
    var forward_dir := Vector3(-sin(state.yaw), 0.0, -cos(state.yaw))
    state.pos += forward_dir * state.speed * dt
