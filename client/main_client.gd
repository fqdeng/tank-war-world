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

@export var server_url: String = "ws://localhost:8910"

var _ws
var _terrain_builder
var _obstacle_builder
var _camera
var _input
var _hud
var _tanks: Dictionary = {}  # player_id → TankView
var _my_player_id: int = 0

func _ready() -> void:
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

    _input = TankInput.new()
    add_child(_input)

    _hud = BasicHUD.instantiate()
    add_child(_hud)

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
        MessageType.SHELL_FIRED:
            _handle_shell_fired(Messages.ShellFired.decode(payload))
        MessageType.HIT:
            _handle_hit(Messages.Hit.decode(payload))
        MessageType.DEATH:
            _handle_death(Messages.Death.decode(payload))
        MessageType.RESPAWN:
            _handle_respawn(Messages.Respawn.decode(payload))

func _handle_connect_ack(msg) -> void:
    _my_player_id = msg.player_id
    print("[Client] CONNECT_ACK: player_id=%d team=%d seed=%d spawn=%s" % [msg.player_id, msg.team, msg.world_seed, msg.spawn_pos])
    _terrain_builder.build(msg.world_seed)
    _obstacle_builder.build(msg.world_seed, _terrain_builder.heightmap, _terrain_builder.terrain_size)
    _input.set_enabled(true)
    _hud.set_status("CONNECTED")
    _hud.set_player_id(msg.player_id)

func _handle_snapshot(msg) -> void:
    var seen: Dictionary = {}
    for t in msg.tanks:
        seen[t.player_id] = true
        var view = _tanks.get(t.player_id)
        if view == null:
            view = TankView.new()
            add_child(view)
            _tanks[t.player_id] = view
            view.setup(t.player_id, t.team, t.player_id == _my_player_id)
        view.apply_snapshot(t.pos, t.yaw, t.turret_yaw, t.gun_pitch, t.hp)
        if t.player_id == _my_player_id:
            _camera.set_target(view)
            _hud.set_hp(t.hp)
    for pid in _tanks.keys():
        if not seen.has(pid):
            _tanks[pid].queue_free()
            _tanks.erase(pid)

func _handle_shell_fired(msg) -> void:
    _spawn_tracer(msg.origin, msg.direction)

func _handle_hit(msg) -> void:
    if _tanks.has(msg.victim_id):
        _tanks[msg.victim_id].flash_hit()

func _handle_death(msg) -> void:
    if _tanks.has(msg.victim_id):
        _tanks[msg.victim_id].set_dead(true)
    if msg.victim_id == _my_player_id:
        _hud.set_status("DEAD — respawning")

func _handle_respawn(msg) -> void:
    if msg.player_id == _my_player_id:
        _hud.set_status("CONNECTED")
    if _tanks.has(msg.player_id):
        _tanks[msg.player_id].set_dead(false)

func _physics_process(_delta: float) -> void:
    if _my_player_id == 0:
        return
    if _ws == null or not _ws.is_open():
        return
    var inp = _input.build_input_message()
    inp.tick = Engine.get_physics_frames()
    _ws.send(MessageType.INPUT, inp.encode())
    if _input.consume_fire():
        var fire := Messages.Fire.new()
        fire.tick = inp.tick
        _ws.send(MessageType.FIRE, fire.encode())

func _spawn_tracer(origin: Vector3, direction: Vector3) -> void:
    var mesh := MeshInstance3D.new()
    var cyl := CylinderMesh.new()
    cyl.top_radius = 0.08
    cyl.bottom_radius = 0.08
    cyl.height = 40.0
    mesh.mesh = cyl
    mesh.position = origin + direction * 20.0
    mesh.look_at(mesh.position + direction, Vector3.UP)
    mesh.rotate_object_local(Vector3.RIGHT, PI/2)
    var mat := StandardMaterial3D.new()
    mat.albedo_color = Color(1.0, 0.7, 0.2)
    mat.emission_enabled = true
    mat.emission = Color(1.0, 0.5, 0.0)
    mesh.material_override = mat
    add_child(mesh)
    get_tree().create_timer(0.12).timeout.connect(func(): mesh.queue_free())
