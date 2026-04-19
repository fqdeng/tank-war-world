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
#
# Two independent accumulators:
#   - state.parts[part]: capped at 0, tracks functional state (turret dead →
#     can't fire, track dead → reduced maneuver, engine dead → reduced speed).
#     Subsequent hits past 0 do NOT re-damage a destroyed part.
#   - state.hp: total HP, decreases by the full scaled damage every hit
#     regardless of part cap, so pounding the same spot after it's broken
#     still whittles the tank down. Tank dies when state.hp <= 0.
#
# Earlier revisions recomputed hp = sum(parts), which meant shots into a
# destroyed HULL dealt 0 total damage — enemies became unkillable if you
# fixated on one weak point. The decoupled model avoids that.
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
        # Kick off regen countdown so functional parts auto-repair; total hp
        # (state.hp) still drains each hit and can kill the tank independently.
        state.part_regen_remaining[part] = Constants.PART_REGEN_DELAY_S
    state.hp = max(0, state.hp - int(round(dmg)))
    if state.hp <= 0 and state.alive:
        state.alive = false
        r.tank_just_destroyed = true
    return r
