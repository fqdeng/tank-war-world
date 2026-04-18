# shared/combat/ballistics.gd
class_name Ballistics

# Position of a shell at `elapsed` seconds since fire. Gravity acts along -Y.
static func position_at(origin: Vector3, velocity: Vector3, elapsed: float) -> Vector3:
    return origin + velocity * elapsed + Vector3(0.0, -0.5 * Constants.GRAVITY * elapsed * elapsed, 0.0)

static func velocity_at(velocity: Vector3, elapsed: float) -> Vector3:
    return velocity + Vector3(0.0, -Constants.GRAVITY * elapsed, 0.0)

# Initial velocity vector given world yaw, gun pitch, and speed (Godot -Z forward).
static func initial_velocity(yaw: float, pitch: float, speed: float) -> Vector3:
    var horiz := Vector3(-sin(yaw), 0.0, -cos(yaw))
    var dir := horiz * cos(pitch) + Vector3(0.0, sin(pitch), 0.0)
    return dir.normalized() * speed
