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
class ConnectAck:
    var player_id: int = 0
    var team: int = 0
    var world_seed: int = 0
    var spawn_pos: Vector3 = Vector3.ZERO
    var destroyed_obstacle_ids: PackedInt32Array = PackedInt32Array()

    func encode() -> PackedByteArray:
        var buf := PackedByteArray()
        Codec.write_u16(buf, player_id)
        Codec.write_u8(buf, team)
        Codec.write_u32(buf, world_seed)
        Codec.write_vec3(buf, spawn_pos)
        Codec.write_u16(buf, destroyed_obstacle_ids.size())
        for oid in destroyed_obstacle_ids:
            Codec.write_u32(buf, oid)
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
        return m

# ---- InputMsg (client → server, 20 Hz) ----
# Named InputMsg (not Input) because Godot's built-in `Input` singleton collides.
class InputMsg:
    var tick: int = 0
    var move_forward: float = 0.0    # -1..1
    var move_turn: float = 0.0       # -1..1
    var turret_yaw: float = 0.0      # radians
    var gun_pitch: float = 0.0       # radians
    var fire_pressed: bool = false

    func encode() -> PackedByteArray:
        var buf := PackedByteArray()
        Codec.write_u32(buf, tick)
        Codec.write_f32(buf, move_forward)
        Codec.write_f32(buf, move_turn)
        Codec.write_f32(buf, turret_yaw)
        Codec.write_f32(buf, gun_pitch)
        Codec.write_u8(buf, 1 if fire_pressed else 0)
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

class Snapshot:
    var tick: int = 0
    var tanks: Array = []  # Array[TankSnapshot]

    func add_tank(pid: int, team: int, pos: Vector3, yaw: float, turret_yaw: float, gun_pitch: float, hp: int, last_input_tick: int = 0) -> void:
        var t := TankSnapshot.new()
        t.player_id = pid
        t.team = team
        t.pos = pos
        t.yaw = yaw
        t.turret_yaw = turret_yaw
        t.gun_pitch = gun_pitch
        t.hp = hp
        t.last_input_tick = last_input_tick
        tanks.append(t)

    func encode() -> PackedByteArray:
        var buf := PackedByteArray()
        Codec.write_u32(buf, tick)
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
        return buf

    static func decode(buf: PackedByteArray) -> Snapshot:
        var m := Snapshot.new()
        var c := [0]
        m.tick = Codec.read_u32(buf, c)
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
            m.tanks.append(t)
        return m

# ---- Fire (client → server) ----
class Fire:
    var tick: int = 0

    func encode() -> PackedByteArray:
        var buf := PackedByteArray()
        Codec.write_u32(buf, tick)
        return buf

    static func decode(buf: PackedByteArray) -> Fire:
        var m := Fire.new()
        var c := [0]
        m.tick = Codec.read_u32(buf, c)
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

    func encode() -> PackedByteArray:
        var buf := PackedByteArray()
        Codec.write_u32(buf, shell_id)
        Codec.write_u16(buf, shooter_id)
        Codec.write_u16(buf, victim_id)
        Codec.write_u16(buf, damage)
        Codec.write_u8(buf, part_id)
        Codec.write_vec3(buf, hit_point)
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
