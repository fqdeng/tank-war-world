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
const AIBrain = preload("res://server/ai/ai_brain.gd")
const TankCollision = preload("res://shared/world/tank_collision.gd")
const NameSanitizer = preload("res://server/util/name_sanitizer.gd")
const PickupManager = preload("res://server/sim/pickup_manager.gd")

const TARGET_TOTAL_TANKS: int = 10  # fill with AI until this many alive tanks exist
const MATCH_KILL_TARGET: int = 100  # first team to this many kills wins — game restarts

var _world
var _ws_server
var _shell_sim
var _pickups: PickupManager
var _accum: float = 0.0
var _tick: int = 0

var _latest_input: Dictionary = {}
var _respawns: Dictionary = {}
var _ai_brains: Dictionary = {}  # player_id → AIBrain
var _team_kills: Dictionary = {0: 0, 1: 0}  # team → destroyed enemies

func set_world(w) -> void:
    _world = w
    _shell_sim = ShellSim.new()
    add_child(_shell_sim)
    _shell_sim.set_world(w)
    _shell_sim.set_hit_callback(func(shell, victim_id, point, part_id, obstacle_id, obstacle_kind):
        _on_shell_hit(shell, victim_id, point, part_id, obstacle_id, obstacle_kind))
    _pickups = PickupManager.new()
    _pickups.setup(w.heightmap, w.terrain_size)

func set_ws_server(s) -> void:
    _ws_server = s
    _ws_server.connect("client_connected", _on_client_connected)
    _ws_server.connect("client_disconnected", _on_client_disconnected)
    _ws_server.connect("input_received", _on_input_received)
    _ws_server.connect("fire_received", _on_fire_received)

func start() -> void:
    _world.start_sim_clock()
    set_process(true)

func _process(delta: float) -> void:
    _accum += delta
    while _accum >= Constants.TICK_INTERVAL:
        _accum -= Constants.TICK_INTERVAL
        _step_tick(Constants.TICK_INTERVAL)

func _step_tick(dt: float) -> void:
    _tick += 1
    _world.current_tick = _tick

    _maintain_ai_population()

    # Run AI brains to produce their input for this tick
    for pid in _ai_brains.keys():
        if not _world.tanks.has(pid):
            continue
        var st = _world.tanks[pid]
        if not st.alive:
            continue
        _latest_input[pid] = _ai_brains[pid].step(st, _world, dt)
        # AI firing: honor its brain's fire_pressed with reload/ammo checks
        if _latest_input[pid].get("fire_pressed", false) and st.can_fire():
            # Apply aim from latest input into state (so shell direction uses AI's aim)
            st.turret_yaw = float(_latest_input[pid].get("turret_yaw", st.turret_yaw))
            st.gun_pitch = clamp(float(_latest_input[pid].get("gun_pitch", st.gun_pitch)), deg_to_rad(-8.0), deg_to_rad(12.0))
            _spawn_shell(pid, st, st.turret_yaw, st.gun_pitch)

    for pid in _world.tanks:
        var state = _world.tanks[pid]
        if not state.alive:
            continue
        var inp = _latest_input.get(pid, {"move_forward": 0.0, "move_turn": 0.0, "turret_yaw": 0.0, "gun_pitch": 0.0, "fire_pressed": false, "tick": 0})
        state.last_acked_input_tick = int(inp.get("tick", 0))
        # Humans: trust client-reported pos/yaw (the client is authoritative over
        # its own body now — server-side correction was yanking the tank back on
        # collisions and producing 20Hz shake). AI still runs TankMovement.step.
        if state.is_ai:
            TankMovement.step(state, inp, dt)
            var clamp_result: Dictionary = TankCollision.clamp_to_playable(state.pos, _world.terrain_size)
            state.pos = clamp_result["pos"]
            if clamp_result["clamped"]:
                state.speed = 0.0
            var push: Vector3 = TankCollision.resolve_obstacle_push(state.pos, _world.obstacles, _world.destroyed_obstacle_ids)
            state.pos.x += push.x
            state.pos.z += push.z
            if push.length_squared() > 0.0001:
                state.speed = 0.0
        elif inp.get("has_client_pose", false):
            state.pos = inp["pos"]
            state.yaw = float(inp["yaw"])
        var terrain_h: float = TerrainGenerator.sample_height(_world.heightmap, _world.terrain_size, state.pos.x, state.pos.z)
        state.pos.y = terrain_h
        state.turret_yaw = float(inp.get("turret_yaw", state.turret_yaw))
        state.gun_pitch = clamp(float(inp.get("gun_pitch", state.gun_pitch)), deg_to_rad(-8.0), deg_to_rad(12.0))
        if state.reload_remaining > 0.0:
            state.reload_remaining = max(0.0, state.reload_remaining - dt)
        if state.spawn_invuln_remaining > 0.0:
            state.spawn_invuln_remaining = max(0.0, state.spawn_invuln_remaining - dt)
        if state.shield_invuln_remaining > 0.0:
            state.shield_invuln_remaining = max(0.0, state.shield_invuln_remaining - dt)
        # Part regen: tick each broken part's countdown; when it hits zero,
        # snap the part back to its init max HP so the tank recovers the
        # functional capability (turret → can fire, engine → top speed, etc.).
        if not state.part_regen_remaining.is_empty():
            var finished: Array = []
            for p in state.part_regen_remaining.keys():
                state.part_regen_remaining[p] -= dt
                if state.part_regen_remaining[p] <= 0.0:
                    finished.append(p)
            for p in finished:
                state.parts[p] = state.parts_max.get(p, 0.0)
                state.part_regen_remaining.erase(p)

    _shell_sim.tick(dt)

    # Pickups: step the manager AFTER tank state has been integrated for this
    # tick so collision tests use up-to-date positions; broadcast spawn/consume
    # events before snapshot so clients can apply them in the same tick where
    # the tank's hp/shield_invuln_remaining will reflect the change.
    if _pickups != null:
        var alive: Array = []
        for pid in _world.tanks:
            var t = _world.tanks[pid]
            if t.alive:
                alive.append(t)
        var ev: Dictionary = _pickups.step(dt, alive)
        for s in ev["spawned"]:
            var sp := Messages.PickupSpawned.new()
            sp.pickup_id = int(s["pickup_id"])
            sp.kind = int(s["kind"])
            sp.pos = s["pos"]
            _ws_server.broadcast(MessageType.PICKUP_SPAWNED, sp.encode())
        for c in ev["consumed"]:
            var cm := Messages.PickupConsumed.new()
            cm.pickup_id = int(c["pickup_id"])
            cm.consumer_id = int(c["consumer_id"])
            cm.kind = int(c["kind"])
            _ws_server.broadcast(MessageType.PICKUP_CONSUMED, cm.encode())

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
    # Sim-tick time (strictly TICK_INTERVAL-spaced), NOT wall clock. Stamping
    # with Time.get_ticks_msec() here bakes _process scheduler jitter (~16ms)
    # into every snapshot, which the client then saw as uneven interpolation
    # lerp steps. Using _tick * TICK_INTERVAL_MS guarantees consecutive
    # snapshots are exactly 50ms apart in the client's buffer, regardless of
    # server frame timing or catch-up ticks within a single frame. PONG
    # timestamps share this epoch via world.sim_clock_ms() so the client's
    # offset EMA converges cleanly.
    snap.server_time_ms = _tick * int(Constants.TICK_INTERVAL * 1000.0)
    for pid in _world.tanks:
        var s = _world.tanks[pid]
        if s.alive:
            var turret_regen: float = float(s.part_regen_remaining.get(TankState.Part.TURRET, 0.0))
            snap.add_tank(s.player_id, s.team, s.pos, s.yaw, s.turret_yaw, s.gun_pitch, s.hp, s.last_acked_input_tick, s.ammo, s.reload_remaining, turret_regen, s.display_name, s.shield_invuln_remaining)
    snap.team_kills_0 = int(_team_kills.get(0, 0))
    snap.team_kills_1 = int(_team_kills.get(1, 0))
    _ws_server.broadcast(MessageType.SNAPSHOT, snap.encode())

func _on_client_connected(peer_id: int, connect_msg) -> void:
    var pid: int = _world.allocate_player_id()
    var team: int = connect_msg.preferred_team
    if team != 0 and team != 1:
        team = (pid % 2)
    _ws_server.bind_peer_to_player(peer_id, pid)
    var state = _world.spawn_tank(pid, team)
    state.display_name = NameSanitizer.sanitize(connect_msg.player_name, pid)
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
    if _pickups != null:
        for entry in _pickups.active_pickups():
            var pe := Messages.PickupEntry.new()
            pe.pickup_id = int(entry["pickup_id"])
            pe.kind = int(entry["kind"])
            pe.pos = entry["pos"]
            ack.pickups.append(pe)
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
    _maintain_ai_population()

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
        "pos": input_msg.pos,
        "yaw": input_msg.yaw,
        "has_client_pose": true,
    }

func _on_fire_received(peer_id: int, fire_msg) -> void:
    var pid: int = _ws_server.player_id_for_peer(peer_id)
    if pid == 0 or not _world.tanks.has(pid):
        return
    # No server validation — the client is fully authoritative for shell
    # spawning (origin, velocity, and fire rate). The server just simulates
    # the trajectory and broadcasts the spawn so everyone sees the same shell.
    _broadcast_shell_spawn(pid, fire_msg.origin, fire_msg.velocity)

# AI fire path: still server-authoritative (checks can_fire, applies reload,
# derives origin/velocity from server state). Humans go through
# _on_fire_received which trusts client-supplied data verbatim.
func _spawn_shell(shooter_id: int, state, aim_turret_yaw: float, aim_gun_pitch: float) -> void:
    if not state.can_fire():
        return
    state.reload_remaining = Constants.TANK_RELOAD_S
    var spawn: Dictionary = Ballistics.compute_shell_spawn(state.pos, state.yaw, aim_turret_yaw, aim_gun_pitch)
    _broadcast_shell_spawn(shooter_id, spawn["origin"], spawn["velocity"])

func _broadcast_shell_spawn(shooter_id: int, origin: Vector3, velocity: Vector3) -> void:
    var shell = _shell_sim.spawn(shooter_id, origin, velocity)
    var msg := Messages.ShellSpawned.new()
    msg.shell_id = shell.id
    msg.shooter_id = shooter_id
    msg.origin = origin
    msg.velocity = velocity
    msg.fire_time_ms = Time.get_ticks_msec()
    _ws_server.broadcast(MessageType.SHELL_SPAWNED, msg.encode())

# Keep total tanks at TARGET_TOTAL_TANKS by adding/removing AI, balancing teams.
func _maintain_ai_population() -> void:
    var target_per_team: int = TARGET_TOTAL_TANKS / 2
    var humans: Array = [0, 0]
    var ais: Array = [0, 0]
    for pid in _world.tanks:
        var s = _world.tanks[pid]
        if s.is_ai:
            ais[s.team] += 1
        else:
            humans[s.team] += 1
    # For each team, add AI up to target - humans
    for team in [0, 1]:
        var want_ai: int = max(0, target_per_team - humans[team])
        while ais[team] < want_ai:
            _spawn_ai(team)
            ais[team] += 1
        while ais[team] > want_ai:
            _despawn_ai_in_team(team)
            ais[team] -= 1

func _spawn_ai(team: int) -> void:
    var pid: int = _world.allocate_player_id()
    var st = _world.spawn_tank(pid, team)
    st.is_ai = true
    st.display_name = "P" + str(pid)
    var brain := AIBrain.new()
    brain.setup(pid, _world)
    _ai_brains[pid] = brain

func _despawn_ai_in_team(team: int) -> void:
    for pid in _ai_brains.keys():
        if not _world.tanks.has(pid):
            _ai_brains.erase(pid)
            continue
        var s = _world.tanks[pid]
        if s.is_ai and s.team == team:
            _world.remove_tank(pid)
            _latest_input.erase(pid)
            _respawns.erase(pid)
            _ai_brains.erase(pid)
            return

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
    if victim.is_invulnerable():
        # Damage is ignored during post-spawn grace OR active shield pickup; still
        # broadcast a zero-damage hit so the shell visual gets cleaned up and the
        # shooter sees the impact (and gets the "no damage on shield" feedback).
        var hit_msg_i := Messages.Hit.new()
        hit_msg_i.shell_id = shell.id
        hit_msg_i.shooter_id = shell.shooter_id
        hit_msg_i.victim_id = victim_id
        hit_msg_i.damage = 0
        hit_msg_i.part_id = part_id
        hit_msg_i.hit_point = hit_point
        hit_msg_i.victim_hp_after = victim.hp
        _ws_server.broadcast(MessageType.HIT, hit_msg_i.encode())
        return
    var result = PartDamage.apply(victim, part_id, Constants.TANK_FIRE_DAMAGE)
    var hit_msg := Messages.Hit.new()
    hit_msg.shell_id = shell.id
    hit_msg.shooter_id = shell.shooter_id
    hit_msg.victim_id = victim_id
    hit_msg.damage = int(round(result.actual_damage))
    hit_msg.part_id = part_id
    hit_msg.hit_point = hit_point
    hit_msg.victim_hp_after = victim.hp
    _ws_server.broadcast(MessageType.HIT, hit_msg.encode())
    if result.tank_just_destroyed:
        _respawns[victim_id] = Constants.RESPAWN_COOLDOWN_S
        # Team kill scoring: only credit if the shooter still exists and is on
        # the opposing team (no team-kill credit, no credit for orphan shells).
        var scoring_team: int = -1
        if _world.tanks.has(shell.shooter_id):
            var shooter_team: int = _world.tanks[shell.shooter_id].team
            if shooter_team != victim.team and _team_kills.has(shooter_team):
                _team_kills[shooter_team] += 1
                scoring_team = shooter_team
        var death_msg := Messages.Death.new()
        death_msg.victim_id = victim_id
        death_msg.killer_id = shell.shooter_id
        _ws_server.broadcast(MessageType.DEATH, death_msg.encode())
        if scoring_team >= 0 and _team_kills[scoring_team] >= MATCH_KILL_TARGET:
            _restart_match(scoring_team)

# Hard reset after MATCH_KILL_TARGET: wipe scores, regenerate the world (new
# seed → new terrain + obstacle layout), clear in-flight shells, pending
# respawns, and pickups, then respawn every tank (human + AI).
#
# Order matters. We broadcast PICKUP_CONSUMED for every live pickup *before*
# MATCH_RESTART so clients despawn those nodes while they still have the old
# pickup_ids, then MATCH_RESTART tells them to wipe terrain/obstacles and
# rebuild from the new seed. Respawn packets follow so humans' prediction
# teleports to the new spawn points; AIs just get their new pos in the next
# snapshot.
func _restart_match(winner_team: int) -> void:
    print("[Server] Match restart — team %d reached %d kills" % [winner_team, MATCH_KILL_TARGET])
    _team_kills[0] = 0
    _team_kills[1] = 0
    _respawns.clear()
    if _shell_sim:
        _shell_sim.clear()

    # New seed — XOR with _tick so two restarts in the same wall-clock second
    # still produce distinct worlds.
    var new_seed: int = int(Time.get_unix_time_from_system()) ^ _tick
    _world.regenerate(new_seed)
    if _pickups:
        # Rehook heightmap to the new world and collect a consumed-event per
        # live pickup so clients can despawn them before the terrain swap
        # (client's MATCH_RESTART handler also resets the pickup view, so
        # this is defensive but keeps the PICKUP_CONSUMED contract intact).
        var consumed: Array = _pickups.reset_for_new_world(_world.heightmap, _world.terrain_size)
        for c in consumed:
            var pc := Messages.PickupConsumed.new()
            pc.pickup_id = int(c["pickup_id"])
            pc.consumer_id = int(c["consumer_id"])
            pc.kind = int(c["kind"])
            _ws_server.broadcast(MessageType.PICKUP_CONSUMED, pc.encode())
    var restart_msg := Messages.MatchRestart.new()
    restart_msg.world_seed = new_seed
    _ws_server.broadcast(MessageType.MATCH_RESTART, restart_msg.encode())

    for pid in _world.tanks.keys():
        _respawn_player(pid)

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
    state.spawn_invuln_remaining = Constants.SPAWN_INVULN_S
    state.shield_invuln_remaining = 0.0  # don't carry a leftover shield across deaths
    var peer_id: int = _ws_server.peer_id_for_player(player_id)
    if peer_id != 0:
        var msg := Messages.Respawn.new()
        msg.player_id = player_id
        msg.pos = state.pos
        _ws_server.send_to_peer(peer_id, MessageType.RESPAWN, msg.encode())
