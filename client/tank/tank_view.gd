# client/tank/tank_view.gd
extends Node3D

const TerrainGenerator = preload("res://shared/world/terrain_generator.gd")
const SoundBank = preload("res://client/audio/sound_bank.gd")

var player_id: int = 0
var team: int = 0
var is_local: bool = false

# Shared heightmap for local Y resolution (avoids per-tick Y jitter from server)
var _heightmap: PackedFloat32Array
var _terrain_size: int = 0

var _body_mesh: MeshInstance3D
var _turret: Node3D
var _barrel: Node3D
var _hp: int = 0
var _max_hp: int = Constants.TANK_MAX_HP
var _hp_bar_root: Node3D
var _hp_bar_fill_anchor: Node3D
var _hp_bar_fill_mat: StandardMaterial3D
var _dust: CPUParticles3D
var _engine: AudioStreamPlayer3D
var _prev_pos: Vector3 = Vector3.ZERO
var _has_prev_pos: bool = false
var _engine_speed: float = 0.0  # smoothed horizontal speed for pitch/volume

# Smoothing targets — snapshot updates these; _process lerps visuals toward them.
# Plan 03 will replace this with proper buffered interpolation.
var _target_pos: Vector3 = Vector3.ZERO
var _target_yaw: float = 0.0
var _target_turret_yaw: float = 0.0
var _target_gun_pitch: float = 0.0
var _first_snapshot: bool = true
const SMOOTH_POS: float = 14.0
const SMOOTH_ROT: float = 18.0

func setup(pid: int, t: int, local: bool) -> void:
    player_id = pid
    team = t
    is_local = local
    _build_mesh()

func set_terrain(hm: PackedFloat32Array, size: int) -> void:
    _heightmap = hm
    _terrain_size = size

func _build_mesh() -> void:
    _body_mesh = MeshInstance3D.new()
    var body := BoxMesh.new()
    body.size = Vector3(3.0, 1.2, 5.0)
    _body_mesh.mesh = body
    var mat := StandardMaterial3D.new()
    mat.albedo_color = Color(0.2, 0.45, 0.8) if team == 0 else Color(0.8, 0.2, 0.2)
    _body_mesh.material_override = mat
    # Body center at 0.6 → body spans 0.0 to 1.2 so the bottom sits on the ground.
    _body_mesh.position.y = 0.6
    add_child(_body_mesh)

    # Rear fuel drum — mounted horizontally on the rear deck. Front of the tank
    # is -Z, so this tells the viewer which way is back at a glance.
    var fuel := MeshInstance3D.new()
    var fuel_cyl := CylinderMesh.new()
    fuel_cyl.top_radius = 0.28
    fuel_cyl.bottom_radius = 0.28
    fuel_cyl.height = 1.6
    fuel.mesh = fuel_cyl
    fuel.rotation = Vector3(0, 0, PI / 2)  # cylinder axis Y → X (drum lies across the back)
    fuel.position = Vector3(0, 1.48, 2.0)  # just above hull top (1.2), near rear face (+2.5)
    var fuel_mat := StandardMaterial3D.new()
    fuel_mat.albedo_color = Color(0.32, 0.34, 0.22)  # olive drab — reads as a drum, not body
    fuel_mat.roughness = 0.8
    fuel.material_override = fuel_mat
    add_child(fuel)

    _turret = Node3D.new()
    _turret.position = Vector3(0, 1.4, 0)  # turret sits on top of body (1.2)
    add_child(_turret)
    var turret_mesh := MeshInstance3D.new()
    var tm := BoxMesh.new()
    tm.size = Vector3(2.0, 0.8, 2.2)
    turret_mesh.mesh = tm
    turret_mesh.material_override = mat
    _turret.add_child(turret_mesh)

    _barrel = Node3D.new()
    _barrel.position = Vector3(0, 0, -1.1)
    _turret.add_child(_barrel)
    var barrel_mesh := MeshInstance3D.new()
    var bm := CylinderMesh.new()
    bm.top_radius = 0.12
    bm.bottom_radius = 0.12
    bm.height = 2.5
    barrel_mesh.mesh = bm
    barrel_mesh.rotation = Vector3(PI / 2, 0, 0)
    barrel_mesh.position = Vector3(0, 0, -1.25)
    var barrel_mat := StandardMaterial3D.new()
    barrel_mat.albedo_color = Color(0.15, 0.15, 0.15)
    barrel_mesh.material_override = barrel_mat
    _barrel.add_child(barrel_mesh)

    _dust = CPUParticles3D.new()
    _dust.position = Vector3(0, 0.15, 2.6)  # behind tank at ground level
    _dust.emitting = false
    _dust.amount = 30
    _dust.lifetime = 0.9
    _dust.direction = Vector3(0, 0.4, 1)
    _dust.spread = 30.0
    _dust.initial_velocity_min = 1.2
    _dust.initial_velocity_max = 3.0
    _dust.gravity = Vector3(0, -1.2, 0)
    _dust.scale_amount_min = 0.35
    _dust.scale_amount_max = 0.9
    var gradient := Gradient.new()
    gradient.add_point(0.0, Color(0.65, 0.56, 0.42, 0.75))
    gradient.add_point(1.0, Color(0.65, 0.56, 0.42, 0.0))
    _dust.color_ramp = gradient
    var dust_mesh := SphereMesh.new()
    dust_mesh.radius = 0.28
    dust_mesh.height = 0.56
    _dust.mesh = dust_mesh
    add_child(_dust)

    # Godot 4.6 Web AudioWorklet mangles AudioStreamWAV LOOP_FORWARD +
    # pitch_scale into overlapping-playback artifacts that read as ghost
    # "volume ramp-up". Skip the engine loop on web entirely; modulation below
    # stays guarded by `if _engine`.
    if not OS.has_feature("web"):
        _engine = AudioStreamPlayer3D.new()
        _engine.stream = SoundBank.make_engine_loop()
        _engine.unit_size = 14.0
        _engine.max_distance = 120.0
        _engine.autoplay = true
        _engine.volume_db = -12.0
        _engine.pitch_scale = 0.9
        add_child(_engine)

    _build_hp_bar()

# HP bar floating above the turret. Two coplanar quads (dark backing + colored
# fill) rotated as a single rigid group to face the camera each frame — we
# can't use per-material BILLBOARD_ENABLED because the fill pivot is offset
# from the bg pivot, so independent per-quad billboarding would make the fill
# drift in/out of the bg as the camera rotates.
func _build_hp_bar() -> void:
    _hp_bar_root = Node3D.new()
    _hp_bar_root.position = Vector3(0, 3.6, 0)
    add_child(_hp_bar_root)

    var bg_mi := MeshInstance3D.new()
    var bg_quad := QuadMesh.new()
    bg_quad.size = Vector2(2.2, 0.28)
    bg_mi.mesh = bg_quad
    var bg_mat := StandardMaterial3D.new()
    bg_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    bg_mat.albedo_color = Color(0.08, 0.08, 0.08, 0.85)
    bg_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    bg_mi.material_override = bg_mat
    _hp_bar_root.add_child(bg_mi)

    _hp_bar_fill_anchor = Node3D.new()
    _hp_bar_fill_anchor.position = Vector3(-1.0, 0, 0.01)  # left edge of bg, tiny z so it sits in front
    _hp_bar_root.add_child(_hp_bar_fill_anchor)

    var fill_mi := MeshInstance3D.new()
    var fill_quad := QuadMesh.new()
    fill_quad.size = Vector2(2.0, 0.2)
    fill_mi.mesh = fill_quad
    fill_mi.position = Vector3(1.0, 0, 0)  # mesh center sits at +width/2 so left edge = anchor origin
    _hp_bar_fill_mat = StandardMaterial3D.new()
    _hp_bar_fill_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    _hp_bar_fill_mat.albedo_color = Color(0.2, 0.9, 0.3)
    fill_mi.material_override = _hp_bar_fill_mat
    _hp_bar_fill_anchor.add_child(fill_mi)

    _update_hp_bar()

func _face_hp_bar_to_camera() -> void:
    if _hp_bar_root == null:
        return
    var cam := get_viewport().get_camera_3d()
    if cam == null:
        return
    var root_pos: Vector3 = _hp_bar_root.global_position
    var to_cam: Vector3 = cam.global_position - root_pos
    if to_cam.length_squared() < 0.0001:
        return
    # Quad's front face is +Z local, so we align the root's +Z with the
    # to-camera direction. Build an orthonormal basis keeping world UP, which
    # keeps the bar horizontal regardless of camera pitch.
    var forward: Vector3 = to_cam.normalized()
    var up_hint: Vector3 = Vector3.UP
    if absf(forward.dot(up_hint)) > 0.99:
        up_hint = Vector3.FORWARD
    var right: Vector3 = up_hint.cross(forward).normalized()
    var up: Vector3 = forward.cross(right).normalized()
    _hp_bar_root.global_transform = Transform3D(Basis(right, up, forward), root_pos)

func _update_hp_bar() -> void:
    if _hp_bar_fill_anchor == null or _max_hp <= 0:
        return
    var r: float = clamp(float(_hp) / float(_max_hp), 0.0, 1.0)
    _hp_bar_fill_anchor.scale.x = max(r, 0.0001)
    if _hp_bar_fill_mat:
        # green → yellow → red
        var c: Color
        if r > 0.5:
            var k: float = (r - 0.5) * 2.0
            c = Color(1.0 - k, 0.85, 0.25).lerp(Color(0.2, 0.9, 0.3), k)
        else:
            var k: float = r * 2.0
            c = Color(0.95, 0.2, 0.2).lerp(Color(1.0, 0.85, 0.25), k)
        _hp_bar_fill_mat.albedo_color = c

func apply_snapshot(pos: Vector3, yaw: float, turret_yaw: float, gun_pitch: float, hp: int) -> void:
    _target_pos = pos
    _target_yaw = yaw
    _target_turret_yaw = turret_yaw
    _target_gun_pitch = gun_pitch
    if hp != _hp:
        _hp = hp
        _update_hp_bar()
    if _first_snapshot:
        # First snapshot: snap directly so we don't lerp from origin to spawn.
        _first_snapshot = false
        position = pos
        rotation.y = yaw
        if _turret:
            _turret.rotation.y = turret_yaw
        if _barrel:
            _barrel.rotation.x = gun_pitch

func _process(delta: float) -> void:
    # HP bar faces the camera as a rigid unit — run for all tanks (local + remote).
    _face_hp_bar_to_camera()
    # Local tank is driven by apply_predicted each frame — skip the remote-smoothing lerp.
    if is_local:
        return
    if _first_snapshot:
        return
    var tp: float = clamp(SMOOTH_POS * delta, 0.0, 1.0)
    var tr: float = clamp(SMOOTH_ROT * delta, 0.0, 1.0)
    var lerped: Vector3 = position.lerp(_target_pos, tp)
    if _heightmap.size() > 0:
        lerped.y = TerrainGenerator.sample_height(_heightmap, _terrain_size, lerped.x, lerped.z)
    _update_dust(lerped)
    position = lerped
    rotation.y = lerp_angle(rotation.y, _target_yaw, tr)
    if _turret:
        _turret.rotation.y = lerp_angle(_turret.rotation.y, _target_turret_yaw, tr)
    if _barrel:
        _barrel.rotation.x = lerp(_barrel.rotation.x, _target_gun_pitch, tr)

func barrel_node() -> Node3D:
    return _barrel

func turret_local_yaw() -> float:
    return _turret.rotation.y if _turret else 0.0

func apply_predicted(pos: Vector3, yaw: float, turret_yaw: float, gun_pitch: float, hp: int) -> void:
    # Used for local tank: skip lerp/interp, render prediction result directly.
    _update_dust(pos)
    position = pos
    rotation.y = yaw
    if _turret:
        _turret.rotation.y = turret_yaw
    if _barrel:
        _barrel.rotation.x = gun_pitch
    if hp != _hp:
        _hp = hp
        _update_hp_bar()
    _first_snapshot = false

func _update_dust(new_pos: Vector3) -> void:
    if _dust == null:
        return
    if not _has_prev_pos:
        _has_prev_pos = true
        _prev_pos = new_pos
        return
    var dt: float = get_process_delta_time()
    if dt <= 0.0:
        return
    var dx: float = new_pos.x - _prev_pos.x
    var dz: float = new_pos.z - _prev_pos.z
    var horiz_speed: float = sqrt(dx * dx + dz * dz) / dt
    _prev_pos = new_pos
    _dust.emitting = horiz_speed > 1.0
    # Low-pass to keep pitch/volume from flickering with per-frame jitter.
    _engine_speed = lerp(_engine_speed, horiz_speed, clamp(dt * 8.0, 0.0, 1.0))
    if _engine:
        var s: float = clamp(_engine_speed / 18.0, 0.0, 1.2)
        _engine.pitch_scale = 0.75 + s * 0.85
        _engine.volume_db = lerp(-18.0, -3.0, clamp(s, 0.0, 1.0))

func set_hp(hp: int) -> void:
    if hp == _hp:
        return
    _hp = hp
    _update_hp_bar()

func flash_hit() -> void:
    if _body_mesh == null:
        return
    var m: StandardMaterial3D = _body_mesh.material_override
    var orig := m.albedo_color
    m.albedo_color = Color(1, 1, 1)
    get_tree().create_timer(0.1).timeout.connect(func():
        if is_instance_valid(m):
            m.albedo_color = orig
    )

func set_dead(dead: bool) -> void:
    visible = not dead
