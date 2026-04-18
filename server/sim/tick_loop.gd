# server/sim/tick_loop.gd
extends Node

const Messages = preload("res://common/protocol/messages.gd")
const MessageType = preload("res://common/protocol/message_types.gd")
const TankMovement = preload("res://shared/tank/tank_movement.gd")
const TerrainGenerator = preload("res://shared/world/terrain_generator.gd")

var _world
var _ws_server
var _accum: float = 0.0
var _tick: int = 0

# Latest input per player_id
var _latest_input: Dictionary = {}

# Pending deaths pending respawn: player_id → remaining seconds
var _respawns: Dictionary = {}

func set_world(w) -> void:
    _world = w

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

    # 1. Advance each alive tank's state based on latest input
    for pid in _world.tanks:
        var state = _world.tanks[pid]
        if not state.alive:
            continue
        var inp = _latest_input.get(pid, {"move_forward": 0.0, "move_turn": 0.0, "turret_yaw": 0.0, "gun_pitch": 0.0, "fire_pressed": false})
        TankMovement.step(state, inp, dt)
        # Lift pos.y to terrain + 1m (crude collision)
        var terrain_h: float = TerrainGenerator.sample_height(_world.heightmap, _world.terrain_size, state.pos.x, state.pos.z)
        state.pos.y = terrain_h + 1.0
        # Keep turret / gun from latest input
        state.turret_yaw = float(inp.get("turret_yaw", state.turret_yaw))
        state.gun_pitch = float(inp.get("gun_pitch", state.gun_pitch))
        # Reload
        if state.reload_remaining > 0.0:
            state.reload_remaining = max(0.0, state.reload_remaining - dt)

    # 2. Handle respawn timers
    var to_respawn: Array = []
    for pid in _respawns:
        _respawns[pid] -= dt
        if _respawns[pid] <= 0.0:
            to_respawn.append(pid)
    for pid in to_respawn:
        _respawns.erase(pid)
        _respawn_player(pid)

    # 3. Build & broadcast snapshot every tick
    var snap := Messages.Snapshot.new()
    snap.tick = _tick
    for pid in _world.tanks:
        var s = _world.tanks[pid]
        if s.alive:
            snap.add_tank(s.player_id, s.team, s.pos, s.yaw, s.turret_yaw, s.gun_pitch, s.hp)
    _ws_server.broadcast(MessageType.SNAPSHOT, snap.encode())

func _on_client_connected(peer_id: int, connect_msg) -> void:
    var pid: int = _world.allocate_player_id()
    var team: int = connect_msg.preferred_team
    if team != 0 and team != 1:
        team = (pid % 2)  # simple auto-balance
    _ws_server.bind_peer_to_player(peer_id, pid)
    var state = _world.spawn_tank(pid, team)
    print("[Server] Player %d (peer %d) joined team %d" % [pid, peer_id, team])
    var ack := Messages.ConnectAck.new()
    ack.player_id = pid
    ack.team = team
    ack.world_seed = _world.world_seed
    ack.spawn_pos = state.pos
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
    }

func _on_fire_received(peer_id: int, _fire_msg) -> void:
    var pid: int = _ws_server.player_id_for_peer(peer_id)
    if pid == 0:
        return
    if not _world.tanks.has(pid):
        return
    var state = _world.tanks[pid]
    if not state.alive or state.ammo <= 0 or state.reload_remaining > 0.0:
        return
    state.ammo -= 1
    state.reload_remaining = Constants.TANK_RELOAD_S
    var muzzle_offset := 2.5
    var origin: Vector3 = state.pos + Vector3(0, 1.0, 0)
    var world_turret_yaw: float = state.yaw + state.turret_yaw
    var dir := Vector3(
        -sin(world_turret_yaw) * cos(state.gun_pitch),
        sin(state.gun_pitch),
        -cos(world_turret_yaw) * cos(state.gun_pitch),
    ).normalized()
    origin += dir * muzzle_offset
    var shell_msg := Messages.ShellFired.new()
    shell_msg.shooter_id = pid
    shell_msg.origin = origin
    shell_msg.direction = dir
    _ws_server.broadcast(MessageType.SHELL_FIRED, shell_msg.encode())
    _resolve_hitscan(pid, origin, dir)

func _resolve_hitscan(shooter_id: int, origin: Vector3, dir: Vector3) -> void:
    var best_victim := 0
    var best_dist: float = Constants.HITSCAN_MAX_RANGE_M
    var best_point := Vector3.ZERO
    for pid in _world.tanks:
        if pid == shooter_id:
            continue
        var target = _world.tanks[pid]
        if not target.alive:
            continue
        if target.team == _world.tanks[shooter_id].team:
            continue  # no friendly fire
        # Approximate tank as sphere r=2.5 centered on pos + (0,1,0)
        var to_target: Vector3 = target.pos + Vector3(0, 1, 0) - origin
        var proj: float = to_target.dot(dir)
        if proj < 0.0 or proj > best_dist:
            continue
        var closest: Vector3 = origin + dir * proj
        var d: float = closest.distance_to(target.pos + Vector3(0, 1, 0))
        if d > 2.5:
            continue
        if proj < best_dist:
            best_dist = proj
            best_victim = pid
            best_point = closest
    if best_victim != 0:
        _apply_hit(shooter_id, best_victim, best_point)

func _apply_hit(shooter_id: int, victim_id: int, hit_point: Vector3) -> void:
    var victim = _world.tanks[victim_id]
    victim.hp -= Constants.TANK_FIRE_DAMAGE
    var hit_msg := Messages.Hit.new()
    hit_msg.shooter_id = shooter_id
    hit_msg.victim_id = victim_id
    hit_msg.damage = Constants.TANK_FIRE_DAMAGE
    hit_msg.hit_point = hit_point
    _ws_server.broadcast(MessageType.HIT, hit_msg.encode())
    if victim.hp <= 0:
        victim.hp = 0
        victim.alive = false
        _respawns[victim_id] = Constants.RESPAWN_COOLDOWN_S
        var death_msg := Messages.Death.new()
        death_msg.victim_id = victim_id
        death_msg.killer_id = shooter_id
        _ws_server.broadcast(MessageType.DEATH, death_msg.encode())

func _respawn_player(player_id: int) -> void:
    if not _world.tanks.has(player_id):
        return
    var state = _world.tanks[player_id]
    state.pos = _world.pick_spawn_pos(state.team)
    state.hp = Constants.TANK_MAX_HP
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
