# client/main_client.gd
extends Node3D

const WSClient = preload("res://client/net/ws_client.gd")
const TerrainBuilder = preload("res://client/world/terrain_builder.gd")
const ObstacleBuilder = preload("res://client/world/obstacle_builder.gd")
const TankView = preload("res://client/tank/tank_view.gd")
const ThirdPersonCam = preload("res://client/camera/third_person_cam.gd")
const TankInput = preload("res://client/input/tank_input.gd")
const BasicHUD = preload("res://client/hud/basic_hud.tscn")
const Messages = preload("res://common/protocol/messages.gd")
const MessageType = preload("res://common/protocol/message_types.gd")
const Ballistics = preload("res://shared/combat/ballistics.gd")
const Prediction = preload("res://client/tank/prediction.gd")
const Interpolation = preload("res://client/tank/interpolation.gd")
const TankState = preload("res://shared/tank/tank_state.gd")
const ScopeCam = preload("res://client/camera/scope_cam.gd")
const ScopeOverlay = preload("res://client/hud/scope_overlay.tscn")
const TerrainGenerator = preload("res://shared/world/terrain_generator.gd")
const SoundBank = preload("res://client/audio/sound_bank.gd")

@export var server_url: String = "ws://cn.flz.cc:8910"

var _ws
var _terrain_builder
var _obstacle_builder
var _camera
var _input
var _hud
var _tanks: Dictionary = {}  # player_id → TankView
var _shells: Dictionary = {}  # shell_id → Node3D (visual shell)
var _my_player_id: int = 0
var _prediction  # Prediction for local tank
var _remote_interp: Dictionary = {}  # player_id → Interpolation
var _scope_cam
var _scope_overlay
var _in_scope: bool = false
# Wall-clock deadline (ms) for local respawn; 0 when alive. Used for the
# on-screen countdown — server doesn't echo a duration, but RESPAWN_COOLDOWN_S
# is the contract so we derive it locally at death.
var _respawn_deadline_ms: int = 0
# Shared AudioStreamWAVs so we don't regenerate per-shot.
var _fire_stream: AudioStreamWAV
var _hit_stream: AudioStreamWAV
var _tank_hit_stream: AudioStreamWAV

func _ready() -> void:
    if OS.has_feature("web"):
        server_url = _derive_web_server_url()
    print("[Client] Connecting to %s" % server_url)

    # Environment
    var light := DirectionalLight3D.new()
    light.rotation = Vector3(-PI/4, PI/4, 0)
    add_child(light)
    var env := WorldEnvironment.new()
    var e := Environment.new()
    e.background_mode = Environment.BG_SKY
    e.sky = Sky.new()
    e.sky.sky_material = ProceduralSkyMaterial.new()
    env.environment = e
    add_child(env)

    _ws = WSClient.new()
    add_child(_ws)
    _ws.connected.connect(_on_connected)
    _ws.message.connect(_on_message)
    _ws.disconnected.connect(_on_disconnected)
    _ws.connect_to_url(server_url)

    _terrain_builder = TerrainBuilder.new()
    add_child(_terrain_builder)
    _obstacle_builder = ObstacleBuilder.new()
    add_child(_obstacle_builder)

    _camera = ThirdPersonCam.new()
    add_child(_camera)
    _camera.current = true
    # Keep the audio listener pinned to the third-person camera. Without this,
    # Godot uses whichever Camera3D is .current, so entering scope (barrel-
    # mounted cam) slams every sound source right against the ear.
    var listener := AudioListener3D.new()
    _camera.add_child(listener)
    listener.make_current()

    _input = TankInput.new()
    add_child(_input)
    _input.scope_changed.connect(_on_scope_changed)
    _input.zoom_cycled.connect(_on_zoom_cycled)

    _hud = BasicHUD.instantiate()
    add_child(_hud)
    _scope_overlay = ScopeOverlay.instantiate()
    add_child(_scope_overlay)

    _fire_stream = SoundBank.make_fire_shot()
    _hit_stream = SoundBank.make_hit_clang()
    _tank_hit_stream = SoundBank.make_tank_hit_thud()

# Under HTML5 the server endpoint is fixed to cn.flz.cc:8910. `wss` is required
# when the page is served over https (browser mixed-content rule); assume the
# deploy has a TLS-terminating proxy in that case.
func _derive_web_server_url() -> String:
    var proto: String = str(JavaScriptBridge.eval("location.protocol"))
    var scheme: String = "wss" if proto == "https:" else "ws"
    return "%s://cn.flz.cc:8910" % scheme

func _on_connected() -> void:
    print("[Client] WebSocket connected. Sending CONNECT.")
    var msg := Messages.Connect.new()
    msg.player_name = "Player"
    msg.preferred_team = -1
    _ws.send(MessageType.CONNECT, msg.encode())

func _on_disconnected() -> void:
    print("[Client] Disconnected.")
    _hud.set_status("DISCONNECTED")

func _on_message(msg_type: int, payload: PackedByteArray) -> void:
    match msg_type:
        MessageType.CONNECT_ACK:
            _handle_connect_ack(Messages.ConnectAck.decode(payload))
        MessageType.SNAPSHOT:
            _handle_snapshot(Messages.Snapshot.decode(payload))
        MessageType.SHELL_SPAWNED:
            _handle_shell_spawned(Messages.ShellSpawned.decode(payload))
        MessageType.HIT:
            _handle_hit(Messages.Hit.decode(payload))
        MessageType.DEATH:
            _handle_death(Messages.Death.decode(payload))
        MessageType.RESPAWN:
            _handle_respawn(Messages.Respawn.decode(payload))
        MessageType.OBSTACLE_DESTROYED:
            var od = Messages.ObstacleDestroyed.decode(payload)
            _obstacle_builder.destroy_obstacle(od.obstacle_id)
            if _prediction:
                _prediction.mark_obstacle_destroyed(od.obstacle_id)

func _handle_connect_ack(msg) -> void:
    _my_player_id = msg.player_id
    print("[Client] CONNECT_ACK: player_id=%d team=%d seed=%d spawn=%s" % [msg.player_id, msg.team, msg.world_seed, msg.spawn_pos])
    _terrain_builder.build(msg.world_seed)
    _obstacle_builder.build(msg.world_seed, _terrain_builder.heightmap, _terrain_builder.terrain_size, msg.destroyed_obstacle_ids)
    _camera.set_heightmap(_terrain_builder.heightmap, _terrain_builder.terrain_size)
    # Initialize client-side prediction for own tank.
    var ls := TankState.new()
    ls.player_id = msg.player_id
    ls.team = msg.team
    ls.pos = msg.spawn_pos
    ls.yaw = PI if msg.team == 1 else 0.0
    ls.initialize_parts(Constants.TANK_MAX_HP)
    ls.ammo = Constants.TANK_AMMO_CAPACITY
    ls.alive = true
    _prediction = Prediction.new()
    add_child(_prediction)
    _prediction.initialize(ls, _terrain_builder.heightmap, _terrain_builder.terrain_size)
    _prediction.set_obstacles(_obstacle_builder.obstacles, _obstacle_builder.destroyed_ids)
    _input.set_enabled(true)
    _hud.set_status("CONNECTED")
    _hud.set_player_id(msg.player_id)
    _hud.radar.set_my_team(msg.team)

func _handle_snapshot(msg) -> void:
    if _hud != null:
        _hud.set_team_kills(msg.team_kills_0, msg.team_kills_1)
    var now_ms: int = Time.get_ticks_msec()
    var seen: Dictionary = {}
    for t in msg.tanks:
        seen[t.player_id] = true
        if t.player_id == _my_player_id:
            _ensure_view(t.player_id, t.team, true)
            if _prediction:
                _prediction.reconcile(t.pos, t.yaw, t.turret_yaw, t.gun_pitch, t.hp, t.last_input_tick, t.ammo, t.reload_remaining)
            _camera.set_target(_tanks[t.player_id])
            _hud.set_hp(t.hp)
            if _hud:
                _hud.set_turret_damaged(t.turret_regen_remaining)
            if _scope_overlay and _scope_overlay.has_node("Reticle"):
                _scope_overlay.get_node("Reticle").set_turret_damaged(t.turret_regen_remaining)
        else:
            _ensure_view(t.player_id, t.team, false)
            if not _remote_interp.has(t.player_id):
                _remote_interp[t.player_id] = Interpolation.new()
            _remote_interp[t.player_id].push_snapshot(now_ms, t.pos, t.yaw, t.turret_yaw, t.gun_pitch, t.hp)
    for pid in _tanks.keys():
        if not seen.has(pid):
            _tanks[pid].queue_free()
            _tanks.erase(pid)
            _remote_interp.erase(pid)

func _on_scope_changed(active: bool) -> void:
    if active:
        _enter_scope()
    else:
        _exit_scope()

func _enter_scope() -> void:
    if _in_scope:
        return
    if _scope_cam == null:
        _ensure_scope_cam()
    if _scope_cam == null:
        return
    _in_scope = true
    _scope_cam.current = true
    _scope_overlay.visible = true
    _hud.visible = false
    if _tanks.has(_my_player_id):
        _tanks[_my_player_id].visible = false
    _input.set_scope_zoom(float(_scope_cam.current_zoom()))

func _exit_scope() -> void:
    if not _in_scope:
        return
    _in_scope = false
    _camera.current = true
    _scope_overlay.visible = false
    _hud.visible = true
    if _tanks.has(_my_player_id):
        _tanks[_my_player_id].visible = true
    _input.set_scope_zoom(1.0)

func _on_zoom_cycled(dir: int) -> void:
    if _scope_cam == null or not _in_scope:
        return
    _scope_cam.cycle_zoom(dir)
    _scope_overlay.get_node("Reticle").set_zoom(_scope_cam.current_zoom())
    _input.set_scope_zoom(float(_scope_cam.current_zoom()))

func _ensure_scope_cam() -> void:
    if _scope_cam != null:
        return
    if not _tanks.has(_my_player_id):
        return
    var view = _tanks[_my_player_id]
    var barrel = view.barrel_node()
    if barrel == null:
        return
    _scope_cam = ScopeCam.new()
    # Place the scope cam along the barrel's line-of-fire, slightly behind the shell
    # spawn point so the shell emerges centered on the crosshair.
    # Shell origin in tank space = (0, 1.6, -2.5) at rest; _barrel origin in tank
    # space = (0, 1.4, -1.1). So cam local (relative to _barrel) = (0, 0.2, -1.0)
    # lands at tank (0, 1.6, -2.1), 0.4 m behind shell origin on the same axis.
    _scope_cam.position = Vector3(0, 0.2, -1.0)
    barrel.add_child(_scope_cam)
    _scope_overlay.get_node("Reticle").set_zoom(_scope_cam.current_zoom())

func _raycast_terrain_distance(origin: Vector3, dir: Vector3) -> float:
    if _terrain_builder == null or _terrain_builder.heightmap.size() == 0:
        return -1.0
    var max_d: float = 1500.0
    var steps: int = 60
    var step_len: float = max_d / float(steps)
    for i in range(1, steps + 1):
        var t: float = i * step_len
        var p: Vector3 = origin + dir * t
        var th: float = TerrainGenerator.sample_height(_terrain_builder.heightmap, _terrain_builder.terrain_size, p.x, p.z)
        if p.y <= th:
            return t
    return -1.0

func _ensure_view(pid: int, team: int, is_local: bool) -> void:
    if _tanks.has(pid):
        return
    var v = TankView.new()
    add_child(v)
    v.setup(pid, team, is_local)
    v.set_terrain(_terrain_builder.heightmap, _terrain_builder.terrain_size)
    _tanks[pid] = v

func _handle_shell_spawned(msg) -> void:
    # Radar ping: show the shooter's tank pos for 5s
    if _hud != null and _tanks.has(msg.shooter_id):
        var shooter = _tanks[msg.shooter_id]
        _hud.radar.ping_shot(msg.shooter_id, shooter.position, shooter.team)
    var mesh := MeshInstance3D.new()
    var sm := SphereMesh.new()
    sm.radius = 0.2
    sm.height = 0.4
    mesh.mesh = sm
    var mat := StandardMaterial3D.new()
    mat.albedo_color = Color(1, 0.6, 0.15)
    mat.emission_enabled = true
    mat.emission = Color(1, 0.4, 0.0)
    mesh.material_override = mat
    var holder := Node3D.new()
    holder.add_child(mesh)
    holder.set_meta("origin", msg.origin)
    holder.set_meta("velocity", msg.velocity)
    holder.set_meta("start_ms", Time.get_ticks_msec())
    add_child(holder)
    _shells[msg.shell_id] = holder
    _play_oneshot_3d(_fire_stream, msg.origin, 4.0, 280.0)

func _handle_hit(msg) -> void:
    var tank_hit: bool = msg.victim_id != 0 and _tanks.has(msg.victim_id)
    if tank_hit:
        _tanks[msg.victim_id].flash_hit()
        # Apply authoritative post-hit HP to the 3D bar so fatal hits visibly
        # drain the bar before the tank is removed from subsequent snapshots.
        _tanks[msg.victim_id].set_hp(int(msg.victim_hp_after))
        if msg.victim_id == _my_player_id:
            if _prediction != null:
                _prediction.state().hp = int(msg.victim_hp_after)
            _hud.set_hp(int(msg.victim_hp_after))
    if _shells.has(msg.shell_id):
        _shells[msg.shell_id].queue_free()
        _shells.erase(msg.shell_id)
    _spawn_impact_puff(msg.hit_point)
    # Distinct audio: heavy thud for shell-vs-tank, lighter clang for everything else.
    # unit_size is generous so impacts are clearly audible even when the camera
    # is ~10 m behind the tank (previous unit_size=2 made hits on own tank only
    # ~20% volume, which read as "no sound" in practice).
    var impact_stream: AudioStreamWAV = _tank_hit_stream if tank_hit else _hit_stream
    _play_oneshot_3d(impact_stream, msg.hit_point, 6.0, 300.0)
    # Crosshair feedback for the local shooter.
    if msg.shooter_id == _my_player_id and tank_hit and msg.damage > 0:
        if _scope_overlay and _scope_overlay.has_node("Reticle"):
            _scope_overlay.get_node("Reticle").show_hit(int(msg.damage))
        if _hud:
            _hud.show_hit(int(msg.damage))
    # Combat log: only tank-vs-tank with real damage (skip obstacle/terrain and
    # zero-damage spawn-invuln hits).
    if msg.victim_id != 0 and msg.damage > 0 and _hud != null:
        var atk_team: int = -1
        var vic_team: int = -1
        if _tanks.has(msg.shooter_id):
            atk_team = _tanks[msg.shooter_id].team
        if _tanks.has(msg.victim_id):
            vic_team = _tanks[msg.victim_id].team
        _hud.add_hit_line("P%d" % msg.shooter_id, atk_team, "P%d" % msg.victim_id, vic_team, msg.damage)

# Spawns a temporary AudioStreamPlayer3D at `pos`, plays once, frees itself.
func _play_oneshot_3d(stream: AudioStreamWAV, pos: Vector3, unit_size: float, max_dist: float) -> void:
    if stream == null:
        return
    var p := AudioStreamPlayer3D.new()
    p.stream = stream
    p.unit_size = unit_size
    p.max_distance = max_dist
    p.position = pos
    add_child(p)
    p.play()
    p.finished.connect(p.queue_free)

func _handle_death(msg) -> void:
    if _tanks.has(msg.victim_id):
        _tanks[msg.victim_id].set_dead(true)
    if msg.victim_id == _my_player_id:
        _respawn_deadline_ms = Time.get_ticks_msec() + int(Constants.RESPAWN_COOLDOWN_S * 1000.0)
        # Force exit scope so the center-screen respawn countdown is actually visible
        # (scope view hides the full HUD).
        if _in_scope:
            _exit_scope()
        # While dead, our tank is excluded from snapshots — explicitly clear the
        # turret-damage prompt so it doesn't freeze on the last reported value.
        if _hud:
            _hud.set_turret_damaged(0.0)
        if _scope_overlay and _scope_overlay.has_node("Reticle"):
            _scope_overlay.get_node("Reticle").set_turret_damaged(0.0)
    if msg.killer_id == _my_player_id and msg.victim_id != _my_player_id:
        if _scope_overlay and _scope_overlay.has_node("Reticle"):
            _scope_overlay.get_node("Reticle").show_kill(int(msg.victim_id))
        if _hud:
            _hud.show_kill(int(msg.victim_id))

func _handle_respawn(msg) -> void:
    if msg.player_id == _my_player_id:
        _respawn_deadline_ms = 0
        if _hud:
            _hud.set_respawn_countdown(0.0)
        _hud.set_status("CONNECTED")
        if _prediction != null:
            _prediction.teleport(msg.pos)
    if _tanks.has(msg.player_id):
        _tanks[msg.player_id].set_dead(false)

func _physics_process(delta: float) -> void:
    if _my_player_id == 0 or _ws == null or not _ws.is_open():
        return
    var inp = _input.build_input_message()
    var tick: int = Engine.get_physics_frames()
    inp.tick = tick
    # Step prediction BEFORE packing the message so the server gets this tick's
    # authoritative pos/yaw, not last tick's.
    if _prediction != null:
        var d := {
            "move_forward": inp.move_forward,
            "move_turn": inp.move_turn,
            "turret_yaw": inp.turret_yaw,
            "gun_pitch": inp.gun_pitch,
            "fire_pressed": inp.fire_pressed,
        }
        _prediction.apply_local(d, tick, delta)
        var ps = _prediction.state()
        inp.pos = ps.pos
        inp.yaw = ps.yaw
    _ws.send(MessageType.INPUT, inp.encode())
    if _input.consume_fire():
        var fire := Messages.Fire.new()
        fire.tick = tick
        _ws.send(MessageType.FIRE, fire.encode())

func _spawn_impact_puff(pos: Vector3) -> void:
    var mesh := MeshInstance3D.new()
    var sm := SphereMesh.new()
    sm.radius = 1.2
    sm.height = 2.4
    mesh.mesh = sm
    var mat := StandardMaterial3D.new()
    mat.albedo_color = Color(1, 0.8, 0.2, 0.8)
    mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    mat.emission_enabled = true
    mat.emission = Color(1, 0.5, 0.0)
    mesh.material_override = mat
    mesh.position = pos
    add_child(mesh)
    get_tree().create_timer(0.3).timeout.connect(func(): mesh.queue_free())

func _process(_delta: float) -> void:
    if _respawn_deadline_ms > 0 and _hud != null:
        var remaining_ms: int = _respawn_deadline_ms - Time.get_ticks_msec()
        var remaining_s: float = max(0.0, float(remaining_ms) / 1000.0)
        _hud.set_respawn_countdown(remaining_s)
    # Apply predicted state at render rate (no physics-interpolation stack).
    if _prediction != null and _tanks.has(_my_player_id):
        var s = _prediction.state()
        _tanks[_my_player_id].apply_predicted(s.pos, s.yaw, s.turret_yaw, s.gun_pitch, s.hp)
        _hud.set_ammo(s.ammo)
        _hud.set_reload(s.reload_remaining, Constants.TANK_RELOAD_S)
        _hud.radar.set_self_pose(s.pos, s.yaw)
        if _in_scope and _scope_cam != null:
            var reticle = _scope_overlay.get_node("Reticle")
            reticle.set_ammo(s.ammo)
            reticle.set_pitch(rad_to_deg(s.gun_pitch))
            reticle.set_reload(s.reload_remaining, Constants.TANK_RELOAD_S)
            var origin: Vector3 = _scope_cam.global_position
            var fwd: Vector3 = -_scope_cam.global_transform.basis.z
            reticle.set_distance(_raycast_terrain_distance(origin, fwd))
    # Remote tanks: sample interp buffer at now - 100ms and update view
    var now_ms: int = Time.get_ticks_msec()
    for pid in _remote_interp:
        var r = _remote_interp[pid].sample(now_ms)
        if r == null:
            continue
        var view = _tanks.get(pid)
        if view == null:
            continue
        view.apply_snapshot(r["pos"], r["yaw"], r["turret_yaw"], r["gun_pitch"], int(r["hp"]))
    # Advance visual shells along parabolic path
    for shell_id in _shells.keys():
        var h: Node3D = _shells[shell_id]
        var start_ms: int = int(h.get_meta("start_ms"))
        var elapsed: float = float(Time.get_ticks_msec() - start_ms) / 1000.0
        if elapsed > Constants.SHELL_MAX_LIFETIME_S:
            h.queue_free()
            _shells.erase(shell_id)
            continue
        var origin: Vector3 = h.get_meta("origin")
        var vel: Vector3 = h.get_meta("velocity")
        h.position = Ballistics.position_at(origin, vel, elapsed)
