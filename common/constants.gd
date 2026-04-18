# common/constants.gd — autoloaded as `Constants`
extends Node

# Networking
const SERVER_PORT: int = 8910
const TICK_RATE_HZ: int = 20
const TICK_INTERVAL: float = 1.0 / TICK_RATE_HZ  # 0.05s

# World
const WORLD_SIZE_M: int = 1024
const TERRAIN_VERTS_PER_M: int = 1  # 1024x1024 verts
const HEIGHT_MAX_M: float = 50.0
const NOISE_OCTAVES: int = 4
const NOISE_FREQUENCY: float = 1.0 / 256.0

# Obstacles (counts in Plan 01 are reduced for performance headroom)
const SMALL_ROCK_COUNT: int = 400
const LARGE_ROCK_COUNT: int = 80
const TREE_COUNT: int = 600

# Tank (single type for Plan 01)
const TANK_MAX_HP: int = 900
const TANK_MAX_SPEED_MS: float = 10.0       # 36 km/h
const TANK_ACCEL_MS2: float = 3.0
const TANK_TURRET_ROT_DPS: float = 36.0
const TANK_TURN_RATE_DPS: float = 45.0
const TANK_FIRE_DAMAGE: int = 260
const TANK_RELOAD_S: float = 4.5
const TANK_AMMO_CAPACITY: int = 24

# Hitscan (Plan 01 placeholder for parabolic ballistics)
const HITSCAN_MAX_RANGE_M: float = 1500.0

# Respawn
const RESPAWN_COOLDOWN_S: float = 10.0
