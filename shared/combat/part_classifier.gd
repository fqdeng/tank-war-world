# shared/combat/part_classifier.gd
class_name PartClassifier

const TankState = preload("res://shared/tank/tank_state.gd")

# Classify a world-space hit point into a TankState.Part using the tank's pose.
# Priority: TOP > TURRET > TRACKS > ENGINE > HULL.
static func classify(tank_pos: Vector3, tank_yaw: float, hit_point: Vector3) -> int:
    var rel: Vector3 = hit_point - tank_pos
    var cy: float = cos(-tank_yaw)
    var sy: float = sin(-tank_yaw)
    var lx: float = rel.x * cy - rel.z * sy
    var lz: float = rel.x * sy + rel.z * cy
    var ly: float = rel.y

    if ly >= 2.2 and abs(lx) <= 1.5 and abs(lz) <= 2.5:
        return TankState.Part.TOP
    if ly >= 0.9 and ly <= 2.4 and abs(lx) <= 1.1 and abs(lz) <= 1.1:
        return TankState.Part.TURRET
    if ly <= 0.9:
        if lx <= -1.3:
            return TankState.Part.LEFT_TRACK
        if lx >= 1.3:
            return TankState.Part.RIGHT_TRACK
    if lz >= 1.5:
        return TankState.Part.ENGINE
    return TankState.Part.HULL
