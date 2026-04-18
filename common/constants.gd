# common/constants.gd — autoloaded as `Constants`
extends Node

# Networking
const SERVER_PORT: int = 8910
const TICK_RATE_HZ: int = 20
const TICK_INTERVAL: float = 1.0 / TICK_RATE_HZ  # 0.05s

# World
const WORLD_SIZE_M: int = 1024
const TERRAIN_VERTS_PER_M: int = 1  # 1024x1024 verts
const HEIGHT_MAX_M: float = 12.0         # was 50 — much flatter world
const NOISE_OCTAVES: int = 3             # fewer octaves = smoother
const NOISE_FREQUENCY: float = 1.0 / 384.0  # wider features = gentler slopes

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
const TANK_RELOAD_S: float = 2.5
const TANK_AMMO_CAPACITY: int = 24

# Hitscan (Plan 01 placeholder for parabolic ballistics)
const HITSCAN_MAX_RANGE_M: float = 1500.0

# Respawn
const RESPAWN_COOLDOWN_S: float = 10.0

# --- Ballistics (Plan 02) ---
const SHELL_INITIAL_SPEED: float = 280.0  # m/s — low enough for pronounced ballistic drop
const GRAVITY: float = 9.8
const SHELL_MAX_LIFETIME_S: float = 8.0
const SHELL_STEP_SUBDIVISIONS: int = 4  # per-tick sub-steps for swept collision

# --- Part HP proportions (sum to 1.0) ---
const PART_HP_HULL: float = 0.40
const PART_HP_TURRET: float = 0.15
const PART_HP_ENGINE: float = 0.15
const PART_HP_LEFT_TRACK: float = 0.10
const PART_HP_RIGHT_TRACK: float = 0.10
const PART_HP_TOP: float = 0.10

# --- Damage multipliers ---
const MULT_HULL: float = 1.0
const MULT_TURRET: float = 1.3
const MULT_ENGINE: float = 1.5
const MULT_LEFT_TRACK: float = 0.8
const MULT_RIGHT_TRACK: float = 0.8
const MULT_TOP: float = 2.5

# --- Functional damage ---
const ENGINE_SPEED_FACTOR_WHEN_DEAD: float = 0.25
const ENGINE_ACCEL_FACTOR_WHEN_DEAD: float = 0.5

# --- Obstacle collision (server authoritative) ---
# Radii use roughly the inscribed circle (half-width) of the visible mesh so
# the tank stops visually flush with the obstacle instead of with a gap.
const TANK_COLLISION_RADIUS: float = 1.7      # tank body is 3x5m, half-width 1.5 + small buffer
const OBSTACLE_RADIUS_SMALL_ROCK: float = 1.6  # box 3.2 → half-width 1.6
const OBSTACLE_RADIUS_LARGE_ROCK: float = 3.5  # box 7.0 → half-width 3.5
const OBSTACLE_RADIUS_TREE: float = 0.7        # trunk base 0.7

# --- Obstacle HP + shell damage (Plan 04) ---
const OBSTACLE_HP_SMALL_ROCK: int = 100
const OBSTACLE_HP_LARGE_ROCK: int = 400
const OBSTACLE_HP_TREE: int = 150
const SHELL_OBSTACLE_DAMAGE: int = 50  # per-shot damage to an obstacle (independent of tank damage)

# --- Scope (Plan 05) ---
const SCOPE_FOV_2X: float = 40.0
const SCOPE_FOV_4X: float = 20.0
const SCOPE_FOV_8X: float = 10.0
const SCOPE_ZOOMS: Array = [2, 4, 8]
