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

# Shared barrel-tip origin + muzzle velocity used by both the AI fire path
# (server) and the human fire path (client). Mirrors the tank→turret→barrel
# rig the client renders so the shell emerges on the scope crosshair.
static func compute_shell_spawn(tank_pos: Vector3, tank_yaw: float, turret_yaw: float, gun_pitch: float) -> Dictionary:
    var tank_xf := Transform3D(Basis().rotated(Vector3.UP, tank_yaw), tank_pos)
    var turret_local := Transform3D(Basis().rotated(Vector3.UP, turret_yaw), Vector3(0, 1.4, 0))
    var barrel_local := Transform3D(Basis().rotated(Vector3.RIGHT, gun_pitch), Vector3(0, 0, -1.1))
    var barrel_xf: Transform3D = tank_xf * turret_local * barrel_local
    var scope_pos: Vector3 = barrel_xf * Vector3(0, 0.2, -1.0)
    var forward: Vector3 = -barrel_xf.basis.z
    var origin: Vector3 = scope_pos + forward * 0.6
    var velocity: Vector3 = forward * Constants.SHELL_INITIAL_SPEED
    return {"origin": origin, "velocity": velocity}
