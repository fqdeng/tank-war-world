# common/protocol/messages.gd
# Intentionally no `class_name` — callers preload this script.
# Using `class_name` with nested classes causes "Nonexistent function 'new'" in Godot 4.6.

const Codec = preload("res://common/protocol/codec.gd")

# ---- Connect (client → server) ----
class Connect:
    var player_name: String = ""
    var preferred_team: int = -1  # -1 = auto-assign

    func encode() -> PackedByteArray:
        var buf := PackedByteArray()
        Codec.write_string(buf, player_name)
        Codec.write_u8(buf, preferred_team + 1)  # -1 → 0, 0 → 1, 1 → 2
        return buf

    static func decode(buf: PackedByteArray) -> Connect:
        var m := Connect.new()
        var c := [0]
        m.player_name = Codec.read_string(buf, c)
        m.preferred_team = Codec.read_u8(buf, c) - 1
        return m

# ---- ConnectAck (server → client) ----
# `pickups` carries every currently-alive pickup so a late joiner sees the same
# set of hearts/shields the existing players see — same idea as
# destroyed_obstacle_ids, but additive instead of subtractive.
class PickupEntry:
    var pickup_id: int = 0
    var kind: int = 0
    var pos: Vector3 = Vector3.ZERO

class ConnectAck:
    var player_id: int = 0
    var team: int = 0
    var world_seed: int = 0
    var spawn_pos: Vector3 = Vector3.ZERO
    var destroyed_obstacle_ids: PackedInt32Array = PackedInt32Array()
    var pickups: Array = []  # Array[PickupEntry]

    func encode() -> PackedByteArray:
        var buf := PackedByteArray()
        Codec.write_u16(buf, player_id)
        Codec.write_u8(buf, team)
        Codec.write_u32(buf, world_seed)
        Codec.write_vec3(buf, spawn_pos)
        Codec.write_u16(buf, destroyed_obstacle_ids.size())
        for oid in destroyed_obstacle_ids:
            Codec.write_u32(buf, oid)
        Codec.write_u16(buf, pickups.size())
        for p in pickups:
            Codec.write_u32(buf, p.pickup_id)
            Codec.write_u8(buf, p.kind)
            Codec.write_vec3(buf, p.pos)
        return buf

    static func decode(buf: PackedByteArray) -> ConnectAck:
        var m := ConnectAck.new()
        var c := [0]
        m.player_id = Codec.read_u16(buf, c)
        m.team = Codec.read_u8(buf, c)
        m.world_seed = Codec.read_u32(buf, c)
        m.spawn_pos = Codec.read_vec3(buf, c)
        var n := Codec.read_u16(buf, c)
        var arr := PackedInt32Array()
        for i in n:
            arr.append(Codec.read_u32(buf, c))
        m.destroyed_obstacle_ids = arr
        var np := Codec.read_u16(buf, c)
        for i in np:
            var p := PickupEntry.new()
            p.pickup_id = Codec.read_u32(buf, c)
            p.kind = Codec.read_u8(buf, c)
            p.pos = Codec.read_vec3(buf, c)
            m.pickups.append(p)
        return m

# ---- InputMsg (client → server, 20 Hz) ----
# Named InputMsg (not Input) because Godot's built-in `Input` singleton collides.
# Carries client-authoritative pos/yaw so the server can trust them (we dropped
# server→client reconciliation to eliminate collision-shake — see prediction.gd).
class InputMsg:
    var tick: int = 0
    var move_forward: float = 0.0    # -1..1
    var move_turn: float = 0.0       # -1..1
    var turret_yaw: float = 0.0      # radians
    var gun_pitch: float = 0.0       # radians
    var fire_pressed: bool = false
    var pos: Vector3 = Vector3.ZERO  # client-authoritative position
    var yaw: float = 0.0             # client-authoritative body yaw

    func encode() -> PackedByteArray:
        var buf := PackedByteArray()
        Codec.write_u32(buf, tick)
        Codec.write_f32(buf, move_forward)
        Codec.write_f32(buf, move_turn)
        Codec.write_f32(buf, turret_yaw)
        Codec.write_f32(buf, gun_pitch)
        Codec.write_u8(buf, 1 if fire_pressed else 0)
        Codec.write_vec3(buf, pos)
        Codec.write_f32(buf, yaw)
        return buf

    static func decode(buf: PackedByteArray) -> InputMsg:
        var m := InputMsg.new()
        var c := [0]
        m.tick = Codec.read_u32(buf, c)
        m.move_forward = Codec.read_f32(buf, c)
        m.move_turn = Codec.read_f32(buf, c)
        m.turret_yaw = Codec.read_f32(buf, c)
        m.gun_pitch = Codec.read_f32(buf, c)
        m.fire_pressed = Codec.read_u8(buf, c) != 0
        m.pos = Codec.read_vec3(buf, c)
        m.yaw = Codec.read_f32(buf, c)
        return m

# ---- Snapshot (server → client) ----
class TankSnapshot:
    var player_id: int = 0
    var team: int = 0
    var pos: Vector3 = Vector3.ZERO
    var yaw: float = 0.0
    var turret_yaw: float = 0.0
    var gun_pitch: float = 0.0
    var hp: int = 0
    var last_input_tick: int = 0
    var ammo: int = 0
    var reload_remaining: float = 0.0
    var turret_regen_remaining: float = 0.0  # 0 when turret is functional; >0 while repairing
    var display_name: String = ""
    # 0 when no shield active. >0 = seconds of pickup-granted invulnerability
    # (separate from spawn_invuln, which isn't networked because it's short and
    # universal). Drives the head-badge on remote tanks + own HUD timer.
    var shield_invuln_remaining: float = 0.0

class Snapshot:
    var tick: int = 0
    # Server Time.get_ticks_msec() at the moment this snapshot was encoded.
    # Client uses this as the interp-buffer time base so network jitter in
    # packet arrival doesn't become interpolation step-size jitter.
    var server_time_ms: int = 0
    var tanks: Array = []  # Array[TankSnapshot]
    var team_kills_0: int = 0
    var team_kills_1: int = 0

    func add_tank(pid: int, team: int, pos: Vector3, yaw: float, turret_yaw: float, gun_pitch: float, hp: int, last_input_tick: int = 0, ammo: int = 0, reload_remaining: float = 0.0, turret_regen_remaining: float = 0.0, display_name: String = "", shield_invuln_remaining: float = 0.0) -> void:
        var t := TankSnapshot.new()
        t.player_id = pid
        t.team = team
        t.pos = pos
        t.yaw = yaw
        t.turret_yaw = turret_yaw
        t.gun_pitch = gun_pitch
        t.hp = hp
        t.last_input_tick = last_input_tick
        t.ammo = ammo
        t.reload_remaining = reload_remaining
        t.turret_regen_remaining = turret_regen_remaining
        t.display_name = display_name
        t.shield_invuln_remaining = shield_invuln_remaining
        tanks.append(t)

    func encode() -> PackedByteArray:
        var buf := PackedByteArray()
        Codec.write_u32(buf, tick)
        Codec.write_u32(buf, server_time_ms)
        Codec.write_u16(buf, tanks.size())
        for t in tanks:
            Codec.write_u16(buf, t.player_id)
            Codec.write_u8(buf, t.team)
            Codec.write_vec3(buf, t.pos)
            Codec.write_f32(buf, t.yaw)
            Codec.write_f32(buf, t.turret_yaw)
            Codec.write_f32(buf, t.gun_pitch)
            Codec.write_u16(buf, t.hp)
            Codec.write_u32(buf, t.last_input_tick)
            Codec.write_u8(buf, t.ammo)
            Codec.write_f32(buf, t.reload_remaining)
            Codec.write_f32(buf, t.turret_regen_remaining)
            Codec.write_string(buf, t.display_name)
            Codec.write_f32(buf, t.shield_invuln_remaining)
        Codec.write_u16(buf, team_kills_0)
        Codec.write_u16(buf, team_kills_1)
        return buf

    static func decode(buf: PackedByteArray) -> Snapshot:
        var m := Snapshot.new()
        var c := [0]
        m.tick = Codec.read_u32(buf, c)
        m.server_time_ms = Codec.read_u32(buf, c)
        var n := Codec.read_u16(buf, c)
        for i in n:
            var t := TankSnapshot.new()
            t.player_id = Codec.read_u16(buf, c)
            t.team = Codec.read_u8(buf, c)
            t.pos = Codec.read_vec3(buf, c)
            t.yaw = Codec.read_f32(buf, c)
            t.turret_yaw = Codec.read_f32(buf, c)
            t.gun_pitch = Codec.read_f32(buf, c)
            t.hp = Codec.read_u16(buf, c)
            t.last_input_tick = Codec.read_u32(buf, c)
            t.ammo = Codec.read_u8(buf, c)
            t.reload_remaining = Codec.read_f32(buf, c)
            t.turret_regen_remaining = Codec.read_f32(buf, c)
            t.display_name = Codec.read_string(buf, c)
            t.shield_invuln_remaining = Codec.read_f32(buf, c)
            m.tanks.append(t)
        m.team_kills_0 = Codec.read_u16(buf, c)
        m.team_kills_1 = Codec.read_u16(buf, c)
        return m

# ---- Fire (client → server) ----
# Shell data is authoritative to the client: server no longer validates rate,
# ammo, or re-derives origin/velocity — it trusts whatever the client sends
# and only runs hit detection on the trajectory.
class Fire:
    var tick: int = 0
    var origin: Vector3 = Vector3.ZERO
    var velocity: Vector3 = Vector3.ZERO

    func encode() -> PackedByteArray:
        var buf := PackedByteArray()
        Codec.write_u32(buf, tick)
        Codec.write_vec3(buf, origin)
        Codec.write_vec3(buf, velocity)
        return buf

    static func decode(buf: PackedByteArray) -> Fire:
        var m := Fire.new()
        var c := [0]
        m.tick = Codec.read_u32(buf, c)
        m.origin = Codec.read_vec3(buf, c)
        m.velocity = Codec.read_vec3(buf, c)
        return m

# ---- ShellSpawned (server → all clients) ----
class ShellSpawned:
    var shell_id: int = 0
    var shooter_id: int = 0
    var origin: Vector3 = Vector3.ZERO
    var velocity: Vector3 = Vector3.ZERO
    var fire_time_ms: int = 0

    func encode() -> PackedByteArray:
        var buf := PackedByteArray()
        Codec.write_u32(buf, shell_id)
        Codec.write_u16(buf, shooter_id)
        Codec.write_vec3(buf, origin)
        Codec.write_vec3(buf, velocity)
        Codec.write_u32(buf, fire_time_ms)
        return buf

    static func decode(buf: PackedByteArray) -> ShellSpawned:
        var m := ShellSpawned.new()
        var c := [0]
        m.shell_id = Codec.read_u32(buf, c)
        m.shooter_id = Codec.read_u16(buf, c)
        m.origin = Codec.read_vec3(buf, c)
        m.velocity = Codec.read_vec3(buf, c)
        m.fire_time_ms = Codec.read_u32(buf, c)
        return m

# ---- Hit (server → all clients) ----
class Hit:
    var shell_id: int = 0
    var shooter_id: int = 0
    var victim_id: int = 0
    var damage: int = 0
    var part_id: int = 0
    var hit_point: Vector3 = Vector3.ZERO
    var victim_hp_after: int = 0  # victim.hp after damage applied; so clients can update HP bar on fatal hits too

    func encode() -> PackedByteArray:
        var buf := PackedByteArray()
        Codec.write_u32(buf, shell_id)
        Codec.write_u16(buf, shooter_id)
        Codec.write_u16(buf, victim_id)
        Codec.write_u16(buf, damage)
        Codec.write_u8(buf, part_id)
        Codec.write_vec3(buf, hit_point)
        Codec.write_u16(buf, victim_hp_after)
        return buf

    static func decode(buf: PackedByteArray) -> Hit:
        var m := Hit.new()
        var c := [0]
        m.shell_id = Codec.read_u32(buf, c)
        m.shooter_id = Codec.read_u16(buf, c)
        m.victim_id = Codec.read_u16(buf, c)
        m.damage = Codec.read_u16(buf, c)
        m.part_id = Codec.read_u8(buf, c)
        m.hit_point = Codec.read_vec3(buf, c)
        m.victim_hp_after = Codec.read_u16(buf, c)
        return m

# ---- Death (server → all clients) ----
class Death:
    var victim_id: int = 0
    var killer_id: int = 0  # 0 if no killer (suicide, world, etc.)

    func encode() -> PackedByteArray:
        var buf := PackedByteArray()
        Codec.write_u16(buf, victim_id)
        Codec.write_u16(buf, killer_id)
        return buf

    static func decode(buf: PackedByteArray) -> Death:
        var m := Death.new()
        var c := [0]
        m.victim_id = Codec.read_u16(buf, c)
        m.killer_id = Codec.read_u16(buf, c)
        return m

# ---- Respawn (server → affected client) ----
class Respawn:
    var player_id: int = 0
    var pos: Vector3 = Vector3.ZERO

    func encode() -> PackedByteArray:
        var buf := PackedByteArray()
        Codec.write_u16(buf, player_id)
        Codec.write_vec3(buf, pos)
        return buf

    static func decode(buf: PackedByteArray) -> Respawn:
        var m := Respawn.new()
        var c := [0]
        m.player_id = Codec.read_u16(buf, c)
        m.pos = Codec.read_vec3(buf, c)
        return m

# ---- ObstacleDestroyed (server → all clients) ----
class ObstacleDestroyed:
    var obstacle_id: int = 0

    func encode() -> PackedByteArray:
        var buf := PackedByteArray()
        Codec.write_u32(buf, obstacle_id)
        return buf

    static func decode(buf: PackedByteArray) -> ObstacleDestroyed:
        var m := ObstacleDestroyed.new()
        var c := [0]
        m.obstacle_id = Codec.read_u32(buf, c)
        return m

# ---- PickupSpawned (server → all clients) ----
class PickupSpawned:
    var pickup_id: int = 0
    var kind: int = 0  # Constants.PICKUP_KIND_*
    var pos: Vector3 = Vector3.ZERO

    func encode() -> PackedByteArray:
        var buf := PackedByteArray()
        Codec.write_u32(buf, pickup_id)
        Codec.write_u8(buf, kind)
        Codec.write_vec3(buf, pos)
        return buf

    static func decode(buf: PackedByteArray) -> PickupSpawned:
        var m := PickupSpawned.new()
        var c := [0]
        m.pickup_id = Codec.read_u32(buf, c)
        m.kind = Codec.read_u8(buf, c)
        m.pos = Codec.read_vec3(buf, c)
        return m

# ---- PickupConsumed (server → all clients) ----
# Sent when a tank walks into a pickup (and on the periodic refresh-wipe, where
# every still-alive pickup is broadcast as "consumed by player 0" before the
# new batch is spawned). consumer_id = 0 means "expired by world reset".
class PickupConsumed:
    var pickup_id: int = 0
    var consumer_id: int = 0
    var kind: int = 0

    func encode() -> PackedByteArray:
        var buf := PackedByteArray()
        Codec.write_u32(buf, pickup_id)
        Codec.write_u16(buf, consumer_id)
        Codec.write_u8(buf, kind)
        return buf

    static func decode(buf: PackedByteArray) -> PickupConsumed:
        var m := PickupConsumed.new()
        var c := [0]
        m.pickup_id = Codec.read_u32(buf, c)
        m.consumer_id = Codec.read_u16(buf, c)
        m.kind = Codec.read_u8(buf, c)
        return m

# ---- MatchRestart (server → all clients) ----
# Broadcast when a team reaches MATCH_KILL_TARGET. Carries the new world_seed
# so clients can wipe + regenerate terrain + obstacles. destroyed_obstacle_ids
# is implicitly empty (server just regenerated the world). Pickups are wiped
# by the server right before this send and respawned via PICKUP_SPAWNED.
class MatchRestart:
    var world_seed: int = 0

    func encode() -> PackedByteArray:
        var buf := PackedByteArray()
        Codec.write_u32(buf, world_seed)
        return buf

    static func decode(buf: PackedByteArray) -> MatchRestart:
        var m := MatchRestart.new()
        var c := [0]
        m.world_seed = Codec.read_u32(buf, c)
        return m

# ---- Ping (client → server, ~1 Hz) ----
# Client stamps its local Time.get_ticks_msec() so server can echo it back.
class Ping:
    var client_time_ms: int = 0

    func encode() -> PackedByteArray:
        var buf := PackedByteArray()
        Codec.write_u32(buf, client_time_ms)
        return buf

    static func decode(buf: PackedByteArray) -> Ping:
        var m := Ping.new()
        var c := [0]
        m.client_time_ms = Codec.read_u32(buf, c)
        return m

# ---- Pong (server → client) ----
# Echoes client's timestamp so client can compute RTT, plus server's own clock
# so client can refine the server-time estimate used by the interp buffer.
class Pong:
    var client_time_ms: int = 0
    var server_time_ms: int = 0

    func encode() -> PackedByteArray:
        var buf := PackedByteArray()
        Codec.write_u32(buf, client_time_ms)
        Codec.write_u32(buf, server_time_ms)
        return buf

    static func decode(buf: PackedByteArray) -> Pong:
        var m := Pong.new()
        var c := [0]
        m.client_time_ms = Codec.read_u32(buf, c)
        m.server_time_ms = Codec.read_u32(buf, c)
        return m
