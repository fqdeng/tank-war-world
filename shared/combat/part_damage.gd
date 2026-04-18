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

# Apply base_damage to state at part. Mutates state; returns Result.
# Tank is destroyed when: total HP <= 0 OR hull HP <= 0 OR top HP <= 0.
static func apply(state: TankState, part: int, base_damage: int) -> Result:
    var r := Result.new()
    if not state.alive:
        return r
    var mult: float = multiplier_for(part)
    var dmg: float = float(base_damage) * mult
    r.actual_damage = dmg
    var before: float = state.parts.get(part, 0.0)
    var after: float = max(0.0, before - dmg)
    state.parts[part] = after
    if before > 0.0 and after <= 0.0:
        r.part_just_destroyed = true
    var total: float = 0.0
    for p in state.parts.values():
        total += p
    state.hp = int(round(total))
    var hull_dead: bool = state.parts.get(TankState.Part.HULL, 1.0) <= 0.0
    var top_dead: bool = state.parts.get(TankState.Part.TOP, 1.0) <= 0.0
    if state.hp <= 0 or hull_dead or top_dead:
        if state.alive:
            state.alive = false
            state.hp = 0
            r.tank_just_destroyed = true
    return r
