# server/sim/tick_loop.gd
extends Node

const Messages = preload("res://common/protocol/messages.gd")
const MessageType = preload("res://common/protocol/message_types.gd")
const TankMovement = preload("res://shared/tank/tank_movement.gd")
const TankState = preload("res://shared/tank/tank_state.gd")
const TerrainGenerator = preload("res://shared/world/terrain_generator.gd")
const Ballistics = preload("res://shared/combat/ballistics.gd")
const PartDamage = preload("res://shared/combat/part_damage.gd")
const ShellSim = preload("res://server/combat/shell_sim.gd")

var _world
var _ws_server
var _shell_sim
var _accum: float = 0.0
var _tick: int = 0

var _latest_input: Dictionary = {}
var _respawns: Dictionary = {}

func set_world(w) -> void:
    _world = w
    _shell_sim = ShellSim.new()
    add_child(_shell_sim)
    _shell_sim.set_world(w)
    _shell_sim.set_hit_callback(func(shell, victim_id, point, part_id, obstacle_id, obstacle_kind):
        _on_shell_hit(shell, victim_id, point, part_id, obstacle_id, obstacle_kind))

func set_ws_server(s) -> void:
    _ws_server = s
    _ws_server.connect("client_connected", _on_client_connected)
    _ws_server.connect("client_disconnected", _on_client_disconnected)
    _ws_server.connect("input_received", _on_input_received)
    _ws_server.connect("fire_received", _on_fire_received)

func start() -> void:
    set_process(true)

func _process(delta: float) -> void:
    _accum += delta
    while _accum >= Constants.TICK_INTERVAL:
        _accum -= Constants.TICK_INTERVAL
        _step_tick(Constants.TICK_INTERVAL)

func _step_tick(dt: float) -> void:
    _tick += 1
    _world.current_tick = _tick

    for pid in _world.tanks:
        var state = _world.tanks[pid]
        if not state.alive:
            continue
        var inp = _latest_input.get(pid, {"move_forward": 0.0, "move_turn": 0.0, "turret_yaw": 0.0, "gun_pitch": 0.0, "fire_pressed": false, "tick": 0})
        TankMovement.step(state, inp, dt)
        state.last_acked_input_tick = int(inp.get("tick", 0))
        # Push tank out of overlapping obstacles (xz only).
        var push: Vector3 = _resolve_obstacle_collision(state.pos)
        state.pos.x += push.x
        state.pos.z += push.z
        # If still moving into the obstacle, kill forward velocity so the tank stops pressing.
        if push.length_squared() > 0.0001:
            state.speed = 0.0
        var terrain_h: float = TerrainGenerator.sample_height(_world.heightmap, _world.terrain_size, state.pos.x, state.pos.z)
        state.pos.y = terrain_h
        state.turret_yaw = float(inp.get("turret_yaw", state.turret_yaw))
        state.gun_pitch = float(inp.get("gun_pitch", state.gun_pitch))
        if state.reload_remaining > 0.0:
            state.reload_remaining = max(0.0, state.reload_remaining - dt)
        # Ammo regeneration up to capacity
        if state.ammo < Constants.TANK_AMMO_CAPACITY:
            state.ammo_regen_accum += dt
            while state.ammo_regen_accum >= Constants.TANK_AMMO_REGEN_S and state.ammo < Constants.TANK_AMMO_CAPACITY:
                state.ammo_regen_accum -= Constants.TANK_AMMO_REGEN_S
                state.ammo += 1
        else:
            state.ammo_regen_accum = 0.0

    _shell_sim.tick(dt)

    var to_respawn: Array = []
    for pid in _respawns:
        _respawns[pid] -= dt
        if _respawns[pid] <= 0.0:
            to_respawn.append(pid)
    for pid in to_respawn:
        _respawns.erase(pid)
        _respawn_player(pid)

    var snap := Messages.Snapshot.new()
    snap.tick = _tick
    for pid in _world.tanks:
        var s = _world.tanks[pid]
        if s.alive:
            snap.add_tank(s.player_id, s.team, s.pos, s.yaw, s.turret_yaw, s.gun_pitch, s.hp, s.last_acked_input_tick, s.ammo, s.reload_remaining)
    _ws_server.broadcast(MessageType.SNAPSHOT, snap.encode())

func _on_client_connected(peer_id: int, connect_msg) -> void:
    var pid: int = _world.allocate_player_id()
    var team: int = connect_msg.preferred_team
    if team != 0 and team != 1:
        team = (pid % 2)
    _ws_server.bind_peer_to_player(peer_id, pid)
    var state = _world.spawn_tank(pid, team)
    print("[Server] Player %d (peer %d) joined team %d" % [pid, peer_id, team])
    var ack := Messages.ConnectAck.new()
    ack.player_id = pid
    ack.team = team
    ack.world_seed = _world.world_seed
    ack.spawn_pos = state.pos
    var arr := PackedInt32Array()
    for oid in _world.destroyed_obstacle_ids.keys():
        arr.append(oid)
    ack.destroyed_obstacle_ids = arr
    _ws_server.send_to_peer(peer_id, MessageType.CONNECT_ACK, ack.encode())

func _on_client_disconnected(peer_id: int) -> void:
    var pid: int = _ws_server.player_id_for_peer(peer_id)
    if pid == 0:
        return
    _world.remove_tank(pid)
    _latest_input.erase(pid)
    _respawns.erase(pid)
    _ws_server.unbind_peer(peer_id)
    print("[Server] Player %d (peer %d) disconnected" % [pid, peer_id])

func _on_input_received(peer_id: int, input_msg) -> void:
    var pid: int = _ws_server.player_id_for_peer(peer_id)
    if pid == 0:
        return
    _latest_input[pid] = {
        "move_forward": input_msg.move_forward,
        "move_turn": input_msg.move_turn,
        "turret_yaw": input_msg.turret_yaw,
        "gun_pitch": input_msg.gun_pitch,
        "fire_pressed": input_msg.fire_pressed,
        "tick": input_msg.tick,
    }

func _on_fire_received(peer_id: int, _fire_msg) -> void:
    var pid: int = _ws_server.player_id_for_peer(peer_id)
    if pid == 0 or not _world.tanks.has(pid):
        return
    var state = _world.tanks[pid]
    if not state.can_fire():
        return
    state.ammo -= 1
    state.reload_remaining = Constants.TANK_RELOAD_S
    # Use the latest client-reported aim (not state.*) so the shell direction matches
    # what the client was looking at at fire time — fixes the 1-tick desync where the
    # server applies input AFTER the FIRE signal handler runs.
    var latest_inp: Dictionary = _latest_input.get(pid, {})
    var aim_turret_yaw: float = float(latest_inp.get("turret_yaw", state.turret_yaw))
    var aim_gun_pitch: float = float(latest_inp.get("gun_pitch", state.gun_pitch))
    var muzzle_offset := 2.5
    var origin: Vector3 = state.pos + Vector3(0, 1.6, 0)
    var world_turret_yaw: float = state.yaw + aim_turret_yaw
    var velocity: Vector3 = Ballistics.initial_velocity(world_turret_yaw, aim_gun_pitch, Constants.SHELL_INITIAL_SPEED)
    origin += velocity.normalized() * muzzle_offset
    var shell = _shell_sim.spawn(pid, origin, velocity)
    var msg := Messages.ShellSpawned.new()
    msg.shell_id = shell.id
    msg.shooter_id = pid
    msg.origin = origin
    msg.velocity = velocity
    msg.fire_time_ms = Time.get_ticks_msec()
    _ws_server.broadcast(MessageType.SHELL_SPAWNED, msg.encode())

func _on_shell_hit(shell, victim_id: int, hit_point: Vector3, part_id: int, obstacle_id: int = 0, obstacle_kind: int = 0) -> void:
    # Obstacle hit?
    if obstacle_id != 0:
        var destroyed: bool = _world.apply_obstacle_damage(obstacle_id, obstacle_kind, Constants.SHELL_OBSTACLE_DAMAGE)
        var hit_msg_o := Messages.Hit.new()
        hit_msg_o.shell_id = shell.id
        hit_msg_o.shooter_id = shell.shooter_id
        hit_msg_o.victim_id = 0
        hit_msg_o.damage = Constants.SHELL_OBSTACLE_DAMAGE
        hit_msg_o.part_id = 0
        hit_msg_o.hit_point = hit_point
        _ws_server.broadcast(MessageType.HIT, hit_msg_o.encode())
        if destroyed:
            var od_msg := Messages.ObstacleDestroyed.new()
            od_msg.obstacle_id = obstacle_id
            _ws_server.broadcast(MessageType.OBSTACLE_DESTROYED, od_msg.encode())
        return
    if victim_id == 0:
        var hit_msg := Messages.Hit.new()
        hit_msg.shell_id = shell.id
        hit_msg.shooter_id = shell.shooter_id
        hit_msg.victim_id = 0
        hit_msg.damage = 0
        hit_msg.part_id = 0
        hit_msg.hit_point = hit_point
        _ws_server.broadcast(MessageType.HIT, hit_msg.encode())
        return
    if not _world.tanks.has(victim_id):
        return
    var victim = _world.tanks[victim_id]
    var result = PartDamage.apply(victim, part_id, Constants.TANK_FIRE_DAMAGE)
    var hit_msg := Messages.Hit.new()
    hit_msg.shell_id = shell.id
    hit_msg.shooter_id = shell.shooter_id
    hit_msg.victim_id = victim_id
    hit_msg.damage = int(round(result.actual_damage))
    hit_msg.part_id = part_id
    hit_msg.hit_point = hit_point
    _ws_server.broadcast(MessageType.HIT, hit_msg.encode())
    if result.tank_just_destroyed:
        _respawns[victim_id] = Constants.RESPAWN_COOLDOWN_S
        var death_msg := Messages.Death.new()
        death_msg.victim_id = victim_id
        death_msg.killer_id = shell.shooter_id
        _ws_server.broadcast(MessageType.DEATH, death_msg.encode())

# Returns cumulative push vector (xz only) to resolve overlap with obstacles.
# Simple O(N) scan — fine for the ~1080 obstacles we have in Plan 02.
func _resolve_obstacle_collision(pos: Vector3) -> Vector3:
    var push_x: float = 0.0
    var push_z: float = 0.0
    var tank_r: float = Constants.TANK_COLLISION_RADIUS
    for o in _world.obstacles:
        if _world.is_obstacle_destroyed(o.id):
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
            # Exactly overlapping center — push in arbitrary direction.
            push_x += min_d
            continue
        var overlap: float = min_d - d
        push_x += dx / d * overlap
        push_z += dz / d * overlap
    return Vector3(push_x, 0.0, push_z)

func _obstacle_collision_radius(kind: int) -> float:
    match kind:
        0: return Constants.OBSTACLE_RADIUS_SMALL_ROCK
        1: return Constants.OBSTACLE_RADIUS_LARGE_ROCK
        2: return Constants.OBSTACLE_RADIUS_TREE
    return 1.0

func _respawn_player(player_id: int) -> void:
    if not _world.tanks.has(player_id):
        return
    var state = _world.tanks[player_id]
    state.pos = _world.pick_spawn_pos(state.team)
    state.initialize_parts(Constants.TANK_MAX_HP)
    state.ammo = Constants.TANK_AMMO_CAPACITY
    state.reload_remaining = 0.0
    state.speed = 0.0
    state.alive = true
    var peer_id: int = _ws_server.peer_id_for_player(player_id)
    if peer_id != 0:
        var msg := Messages.Respawn.new()
        msg.player_id = player_id
        msg.pos = state.pos
        _ws_server.send_to_peer(peer_id, MessageType.RESPAWN, msg.encode())
