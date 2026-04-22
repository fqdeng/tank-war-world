# client/main_client.gd
extends Node3D

const WSClient = preload("res://client/net/ws_client.gd")
const TerrainBuilder = preload("res://client/world/terrain_builder.gd")
const ObstacleBuilder = preload("res://client/world/obstacle_builder.gd")
const PickupView = preload("res://client/world/pickup_view.gd")
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

@export var server_url: String = "wss://tank.fqdeng.com"

var _ws
var _pending_player_name: String = ""
var _terrain_builder
var _obstacle_builder
var _pickup_view
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
# Throttled counter for [Scope] diagnostics; prints every N render frames while in scope.
var _scope_log_counter: int = 0
# Wall-clock deadline (ms) for local respawn; 0 when alive. Used for the
# on-screen countdown — server doesn't echo a duration, but RESPAWN_COOLDOWN_S
# is the contract so we derive it locally at death.
var _respawn_deadline_ms: int = 0
# Shared AudioStreamWAVs so we don't regenerate per-shot.
var _fire_stream: AudioStreamWAV
var _hit_stream: AudioStreamWAV
var _tank_hit_stream: AudioStreamWAV

# --- Network timing ---------------------------------------------------------
# Throttle INPUT sending to the server's tick rate. Local prediction keeps
# running every physics frame; this only gates the uplink + encode/send cost.
var _input_send_accum: float = 0.0
# Client-side estimate of the server clock: server_ms ≈ client_ms + offset.
# Refined by both SNAPSHOT.server_time_ms (coarse) and PONG (precise, since we
# know the outbound leg is ~rtt/2).
var _srv_clock_offset_ms: int = 0
var _srv_clock_initialized: bool = false
# PING/PONG + RTT smoothing (TCP RFC6298-style).
var _last_ping_ms: int = 0
var _rtt_ms: float = 0.0
var _rtt_var_ms: float = 0.0
const _PING_INTERVAL_MS: int = 1000
# HUD net-stats refresh cadence (seconds). 4 Hz is responsive but doesn't
# thrash the label on every render frame.
var _hud_stats_accum: float = 0.0
const _HUD_STATS_INTERVAL_S: float = 0.25

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

    var menu = preload("res://client/menu/name_entry.tscn").instantiate()
    menu.joined.connect(_on_name_chosen)
    add_child(menu)

    _terrain_builder = TerrainBuilder.new()
    add_child(_terrain_builder)
    _obstacle_builder = ObstacleBuilder.new()
    add_child(_obstacle_builder)
    _pickup_view = PickupView.new()
    add_child(_pickup_view)

    _camera = ThirdPersonCam.new()
    add_child(_camera)
    _camera.current = true
    # The cam writes its transform in _physics_process at a stable dt and leaves
    # physics_interpolation on (INHERIT, the project default). Godot then
    # interpolates the rendered cam pose between physics ticks the same way it
    # does for the locally-predicted tank body. Forcing interp=OFF here made the
    # cam step once per physics tick while the tracked tank kept moving
    # smoothly between ticks, which read as per-tick stutter locked to the
    # local tank (remote tanks aren't rigidly cam-tracked, so they hid it).
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

    # HUD + scope overlay are built after the player joins so the name-entry
    # screen shows nothing but its own opaque backdrop — BasicHUD is a
    # CanvasLayer (layer=1) and would otherwise render the radar/status/
    # scoreboard labels *above* the name_entry Control.

    _fire_stream = SoundBank.make_fire_shot()
    _hit_stream = SoundBank.make_hit_clang()
    _tank_hit_stream = SoundBank.make_tank_hit_thud()

# Under HTML5 the server endpoint is fixed to tank.fqdeng.com over wss.
func _derive_web_server_url() -> String:
    return "wss://tank.fqdeng.com"

func _on_name_chosen(player_name: String) -> void:
    _pending_player_name = player_name
    _hud = BasicHUD.instantiate()
    add_child(_hud)
    _scope_overlay = ScopeOverlay.instantiate()
    add_child(_scope_overlay)
    _ws = WSClient.new()
    add_child(_ws)
    _ws.connected.connect(_on_connected)
    _ws.message.connect(_on_message)
    _ws.disconnected.connect(_on_disconnected)
    _ws.connect_to_url(server_url)

func _on_connected() -> void:
    print("[Client] WebSocket connected. Sending CONNECT.")
    var msg := Messages.Connect.new()
    msg.player_name = _pending_player_name
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
        MessageType.PICKUP_SPAWNED:
            var ps = Messages.PickupSpawned.decode(payload)
            if _pickup_view:
                _pickup_view.spawn(ps.pickup_id, ps.kind, ps.pos)
        MessageType.PICKUP_CONSUMED:
            var pc = Messages.PickupConsumed.decode(payload)
            if _pickup_view:
                _pickup_view.consume(pc.pickup_id)
        MessageType.MATCH_RESTART:
            _handle_match_restart(Messages.MatchRestart.decode(payload))
        MessageType.PONG:
            _handle_pong(Messages.Pong.decode(payload))

func _handle_connect_ack(msg) -> void:
    _my_player_id = msg.player_id
    print("[Client] CONNECT_ACK: player_id=%d team=%d seed=%d spawn=%s" % [msg.player_id, msg.team, msg.world_seed, msg.spawn_pos])
    _terrain_builder.build(msg.world_seed)
    _obstacle_builder.build(msg.world_seed, _terrain_builder.heightmap, _terrain_builder.terrain_size, msg.destroyed_obstacle_ids)
    _camera.set_heightmap(_terrain_builder.heightmap, _terrain_builder.terrain_size)
    if _pickup_view:
        _pickup_view.set_terrain(_terrain_builder.heightmap, _terrain_builder.terrain_size)
        for entry in msg.pickups:
            _pickup_view.spawn(entry.pickup_id, entry.kind, entry.pos)
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
    # Prediction pushes the local tank out of other tanks' radii each physics
    # tick. Sample the interp buffer at the current render time so the push
    # matches what TankView is drawing (interp-delayed), not the freshest
    # snapshot — otherwise the bump would fire before the player sees contact.
    _prediction.set_other_tanks_provider(func() -> Array:
        var out: Array = []
        var now_ms: int = _estimated_server_now_ms()
        for pid in _remote_interp:
            var r = _remote_interp[pid].sample(now_ms)
            if r == null:
                continue
            out.append({"id": pid, "pos": r["pos"], "alive": int(r["hp"]) > 0})
        return out
    )
    _input.set_enabled(true)
    _hud.set_status("CONNECTED")
    _hud.set_player_id(msg.player_id)
    _hud.radar.set_my_team(msg.team)

# Server broadcast after a team reaches MATCH_KILL_TARGET. Wipe the world
# and rebuild from the new seed. Pickup nodes are already despawned by the
# PICKUP_CONSUMED bursts that preceded this, but we reset the view
# defensively. Tanks keep their identity; the trailing RESPAWN packet will
# teleport prediction to the new spawn and remote tanks follow snapshots.
# Shell visuals are cleared because their server authority (_shell_sim) was
# just wiped, so no HIT will ever arrive to free them.
func _handle_match_restart(msg) -> void:
    print("[Client] MATCH_RESTART: seed=%d" % msg.world_seed)
    for shell_id in _shells.keys():
        var h: Node3D = _shells[shell_id]
        if is_instance_valid(h):
            h.queue_free()
    _shells.clear()
    if _pickup_view:
        _pickup_view.reset()
    _obstacle_builder.reset()
    _terrain_builder.reset()
    _terrain_builder.build(msg.world_seed)
    _obstacle_builder.build(msg.world_seed, _terrain_builder.heightmap, _terrain_builder.terrain_size)
    _camera.set_heightmap(_terrain_builder.heightmap, _terrain_builder.terrain_size)
    if _pickup_view:
        _pickup_view.set_terrain(_terrain_builder.heightmap, _terrain_builder.terrain_size)
    if _prediction:
        _prediction.set_heightmap(_terrain_builder.heightmap, _terrain_builder.terrain_size)
        _prediction.set_obstacles(_obstacle_builder.obstacles, _obstacle_builder.destroyed_ids)
    for pid in _tanks.keys():
        var v = _tanks[pid]
        if v and v.has_method("set_terrain"):
            v.set_terrain(_terrain_builder.heightmap, _terrain_builder.terrain_size)

func _handle_snapshot(msg) -> void:
    if _hud != null:
        _hud.set_team_kills(msg.team_kills_0, msg.team_kills_1)
    # Refine the server-clock estimate from the snapshot's send timestamp.
    # PONG gives a more accurate correction (below); snapshots are the fallback
    # so the clock is usable immediately on first SNAPSHOT, before the first PONG.
    _update_server_clock_offset(int(msg.server_time_ms))
    var seen: Dictionary = {}
    for t in msg.tanks:
        seen[t.player_id] = true
        if t.player_id == _my_player_id:
            _ensure_view(t.player_id, t.team, true)
            _tanks[t.player_id].set_display_name(t.display_name)
            _tanks[t.player_id].set_shield_active(t.shield_invuln_remaining > 0.0)
            if _hud:
                _hud.set_shield_countdown(t.shield_invuln_remaining)
            if _prediction:
                _prediction.reconcile(t.pos, t.yaw, t.turret_yaw, t.gun_pitch, t.hp, t.last_input_tick, t.ammo, t.reload_remaining)
                # Sync turret destruction from the snapshot so can_fire() gates the
                # client-authoritative fire path. turret_regen_remaining > 0 == broken.
                var ps_local = _prediction.state()
                if t.turret_regen_remaining > 0.0:
                    ps_local.parts[TankState.Part.TURRET] = 0.0
                else:
                    ps_local.parts[TankState.Part.TURRET] = ps_local.parts_max.get(TankState.Part.TURRET, 0.0)
            _camera.set_target(_tanks[t.player_id])
            _hud.set_hp(t.hp)
            if _hud:
                _hud.set_turret_damaged(t.turret_regen_remaining)
            if _scope_overlay and _scope_overlay.has_node("Reticle"):
                _scope_overlay.get_node("Reticle").set_turret_damaged(t.turret_regen_remaining)
        else:
            _ensure_view(t.player_id, t.team, false)
            _tanks[t.player_id].set_display_name(t.display_name)
            _tanks[t.player_id].set_shield_active(t.shield_invuln_remaining > 0.0)
            if not _remote_interp.has(t.player_id):
                _remote_interp[t.player_id] = Interpolation.new()
            # Push using the server's send time, not our receive time. Network
            # jitter moves packet arrivals around, but server spacing is a strict
            # 50 ms — keying the buffer on server time makes lerp steps constant.
            _remote_interp[t.player_id].push_snapshot(int(msg.server_time_ms), t.pos, t.yaw, t.turret_yaw, t.gun_pitch, t.hp)
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
    _scope_log_counter = 0
    var ps = _prediction.state() if _prediction != null else null
    print("[Scope] ENTER turret_yaw=%.3f gun_pitch=%.3f cam_current=%s" % [
        ps.turret_yaw if ps else 0.0,
        ps.gun_pitch if ps else 0.0,
        str(_scope_cam.current)
    ])

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
    # Skip Godot's physics_interpolation on the scope cam: its world transform
    # is fully determined by the (interpolated) barrel parent, and a freshly-
    # added child starts with an uninitialized prev-frame cache that freezes
    # the rendered view for a tick. See fix for "mouse unresponsive in FPV".
    _scope_cam.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
    barrel.add_child(_scope_cam)
    _scope_overlay.get_node("Reticle").set_zoom(_scope_cam.current_zoom())
    print("[Scope] cam attached to barrel, interp_mode=OFF parent=%s" % barrel.name)

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
        # Tell the view to discard its physics_interpolation "previous" pose on
        # the next apply_predicted, so we don't see a visible lerp from the
        # death spot to the new spawn.
        if _tanks.has(msg.player_id):
            _tanks[msg.player_id].mark_teleport()
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
        # Push the local tank's transform inside the physics frame (not _process)
        # so Godot's physics_interpolation captures it and can smoothly interpolate
        # between physics ticks when rendering. Without this, on web (60 Hz physics,
        # 60 Hz render w/ vsync jitter) render frames alias against physics ticks
        # and the tank appears to microstutter.
        if _tanks.has(_my_player_id):
            _tanks[_my_player_id].apply_predicted(ps.pos, ps.yaw, ps.turret_yaw, ps.gun_pitch, ps.hp)
    # Throttle INPUT to 20 Hz (= server tick). Web physics runs at 60 Hz and
    # native at 120 Hz, so we were sending 3–6× more INPUT packets than the
    # server actually consumes — pure uplink + encode + GC waste on Web.
    # Prediction above still runs every physics frame so local motion stays
    # smooth. fire_pressed on INPUT is unused for humans (FIRE is the path).
    _input_send_accum += delta
    if _input_send_accum >= Constants.TICK_INTERVAL:
        _input_send_accum -= Constants.TICK_INTERVAL
        # On a big frame hitch (e.g. GC pause), don't try to replay a backlog of
        # INPUTs — drop to current.
        if _input_send_accum > Constants.TICK_INTERVAL:
            _input_send_accum = 0.0
        _ws.send(MessageType.INPUT, inp.encode())
    _maybe_send_ping()
    if _input.consume_fire():
        # Reload + turret-damage are both enforced on the client now that firing is
        # client-authoritative; the server no longer gates FIRE for humans. Drop the
        # shot silently (reload, broken turret, or dead) so rapid-click can't sneak
        # past the gate.
        if _prediction != null and not _prediction.state().can_fire():
            pass
        else:
            var fire := Messages.Fire.new()
            fire.tick = tick
            if _prediction != null:
                var ps = _prediction.state()
                var spawn: Dictionary = Ballistics.compute_shell_spawn(ps.pos, ps.yaw, ps.turret_yaw, ps.gun_pitch)
                fire.origin = spawn["origin"]
                fire.velocity = spawn["velocity"]
                _prediction.state().reload_remaining = Constants.TANK_RELOAD_S
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
    # Update bottom-right net-stats overlay (ping/up/down) a few times per second.
    if _hud != null and _ws != null:
        _hud_stats_accum += _delta
        if _hud_stats_accum >= _HUD_STATS_INTERVAL_S:
            _hud_stats_accum = 0.0
            _hud.set_net_stats(_rtt_ms, _ws.bytes_sent_per_sec(), _ws.bytes_recv_per_sec())
    # Local tank transform is pushed in _physics_process so physics_interpolation
    # can smooth between physics ticks. Here we only mirror the latest prediction
    # state into the HUD — reads, not transform writes.
    if _prediction != null and _tanks.has(_my_player_id):
        var s = _prediction.state()
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
            # Every ~30 render frames (~0.5s @ 60Hz): log state → input → cam
            # so we can see whether the scope cam is actually following the
            # barrel when the mouse moves. If turret_yaw/gun_pitch change but
            # fwd doesn't, the cam's transform is stale (physics_interp cache).
            _scope_log_counter += 1
            if _scope_log_counter % 30 == 0:
                print("[Scope] tick #%d turret_yaw=%.3f gun_pitch=%.3f cam_fwd=(%.3f,%.3f,%.3f)" % [
                    _scope_log_counter,
                    s.turret_yaw, s.gun_pitch,
                    fwd.x, fwd.y, fwd.z
                ])
    # Remote tanks: sample interp buffer using the estimated server clock.
    # Matching the buffer's time base (server send-time) means lerp steps are
    # driven by the server's strict 20 Hz spacing, not by arrival jitter.
    var now_server_ms: int = _estimated_server_now_ms()
    for pid in _remote_interp:
        var r = _remote_interp[pid].sample(now_server_ms)
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

# --- Server-clock estimate & PING/PONG -------------------------------------

func _estimated_server_now_ms() -> int:
    return Time.get_ticks_msec() + _srv_clock_offset_ms

func _update_server_clock_offset(server_now_ms: int) -> void:
    var client_ms: int = Time.get_ticks_msec()
    var instant_offset: int = server_now_ms - client_ms
    if not _srv_clock_initialized:
        _srv_clock_offset_ms = instant_offset
        _srv_clock_initialized = true
        return
    # 7:1 EMA — a single-packet jitter spike of ±50 ms only shifts the estimate
    # by ~6 ms, so interp target_t stays stable across that spike.
    _srv_clock_offset_ms = (_srv_clock_offset_ms * 7 + instant_offset) / 8

func _maybe_send_ping() -> void:
    if _ws == null or not _ws.is_open():
        return
    var now: int = Time.get_ticks_msec()
    if now - _last_ping_ms < _PING_INTERVAL_MS:
        return
    _last_ping_ms = now
    var p := Messages.Ping.new()
    p.client_time_ms = now
    _ws.send(MessageType.PING, p.encode())

func _handle_pong(msg) -> void:
    var now: int = Time.get_ticks_msec()
    var rtt: float = float(now - msg.client_time_ms)
    if rtt < 0.0 or rtt > 10000.0:
        # Clock skew or truly broken network — don't poison the estimator.
        return
    if _rtt_ms == 0.0:
        _rtt_ms = rtt
        _rtt_var_ms = rtt * 0.5
    else:
        # RFC6298-style smoothing: RTTVAR first (uses old RTT), then RTT.
        _rtt_var_ms = 0.75 * _rtt_var_ms + 0.25 * absf(rtt - _rtt_ms)
        _rtt_ms = 0.875 * _rtt_ms + 0.125 * rtt
    # Server stamped server_time_ms roughly rtt/2 after we sent client_time_ms.
    # So offset = server_time_ms - (client_time_ms + rtt/2). More accurate than
    # the SNAPSHOT-based estimate (which can't separate one-way delay from jitter).
    var inferred_offset: int = int(msg.server_time_ms) - (int(msg.client_time_ms) + int(rtt * 0.5))
    _srv_clock_offset_ms = (_srv_clock_offset_ms * 7 + inferred_offset) / 8
    _srv_clock_initialized = true
    # Adapt interp delay. Base 2.5 × TICK_INTERVAL = 125 ms survives a skipped
    # snapshot; jitter_var × 2.5 covers ~99% of packet-arrival variance.
    # interpolation.gd clamps to [60, 300] internally.
    var delay: int = int(2.5 * Constants.TICK_INTERVAL * 1000.0 + 2.5 * _rtt_var_ms)
    for pid in _remote_interp:
        _remote_interp[pid].set_delay_ms(delay)
