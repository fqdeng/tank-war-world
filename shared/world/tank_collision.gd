# shared/world/tank_collision.gd
# Deterministic collision helpers shared by server simulation and client
# prediction so both agree on where a tank can and cannot go. Keeping the two
# in sync prevents the 20Hz "bounce against obstacle" jitter that appears when
# only the server resolves contacts and the client keeps re-predicting into
# walls.
class_name TankCollision

# Returns cumulative push vector (xz only) to resolve overlap with obstacles.
# `destroyed` is a Dictionary {obstacle_id → true} listing destroyed ids; pass
# an empty Dictionary if the caller has no destruction state.
static func resolve_obstacle_push(pos: Vector3, obstacles: Array, destroyed: Dictionary) -> Vector3:
    var push_x: float = 0.0
    var push_z: float = 0.0
    var tank_r: float = Constants.TANK_COLLISION_RADIUS
    for o in obstacles:
        if destroyed.has(o.id):
            continue
        var o_r: float = _obstacle_collision_radius(o.kind)
        var min_d: float = tank_r + o_r
        var dx: float = pos.x - o.pos.x
        var dz: float = pos.z - o.pos.z
        var d_sq: float = dx * dx + dz * dz
        if d_sq >= min_d * min_d:
            continue
        var d: float = sqrt(d_sq)
        if d < 0.001:
            push_x += min_d
            continue
        var overlap: float = min_d - d
        push_x += dx / d * overlap
        push_z += dz / d * overlap
    return Vector3(push_x, 0.0, push_z)

# Clamps xz into the playable square. Returns true if the position was
# clamped (caller should also zero out speed).
static func clamp_to_playable(pos: Vector3, terrain_size: int) -> Dictionary:
    var margin: float = Constants.PLAYABLE_MARGIN_M
    var size: float = float(terrain_size)
    var clamped_x: float = clamp(pos.x, margin, size - margin)
    var clamped_z: float = clamp(pos.z, margin, size - margin)
    var changed: bool = clamped_x != pos.x or clamped_z != pos.z
    return {"pos": Vector3(clamped_x, pos.y, clamped_z), "clamped": changed}

# Returns cumulative push vector (xz only) to resolve overlap with other tanks.
# `others` is an Array of Dictionaries {id:int, pos:Vector3, alive:bool}; entries
# matching `self_id` or with alive == false are skipped. Each side calls this
# independently (client for its own tank, server for AIs), so both contributors
# separate simultaneously — no shared resolution needed.
static func resolve_tank_push(pos: Vector3, self_id: int, others: Array) -> Vector3:
    var push_x: float = 0.0
    var push_z: float = 0.0
    var min_d: float = 2.0 * Constants.TANK_COLLISION_RADIUS
    for o in others:
        if int(o.get("id", 0)) == self_id:
            continue
        if not bool(o.get("alive", true)):
            continue
        var op: Vector3 = o["pos"]
        var dx: float = pos.x - op.x
        var dz: float = pos.z - op.z
        var d_sq: float = dx * dx + dz * dz
        if d_sq >= min_d * min_d:
            continue
        var d: float = sqrt(d_sq)
        if d < 0.001:
            push_x += min_d
            continue
        var overlap: float = min_d - d
        push_x += dx / d * overlap
        push_z += dz / d * overlap
    return Vector3(push_x, 0.0, push_z)

static func _obstacle_collision_radius(kind: int) -> float:
    match kind:
        0: return Constants.OBSTACLE_RADIUS_SMALL_ROCK
        1: return Constants.OBSTACLE_RADIUS_LARGE_ROCK
        2: return Constants.OBSTACLE_RADIUS_TREE
    return 1.0
