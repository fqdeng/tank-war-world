# client/tank/tank_view.gd
extends Node3D

var player_id: int = 0
var team: int = 0
var is_local: bool = false

var _body_mesh: MeshInstance3D
var _turret: Node3D
var _barrel: Node3D
var _hp: int = 0

func setup(pid: int, t: int, local: bool) -> void:
    player_id = pid
    team = t
    is_local = local
    _build_mesh()

func _build_mesh() -> void:
    _body_mesh = MeshInstance3D.new()
    var body := BoxMesh.new()
    body.size = Vector3(3.0, 1.2, 5.0)
    _body_mesh.mesh = body
    var mat := StandardMaterial3D.new()
    mat.albedo_color = Color(0.2, 0.45, 0.8) if team == 0 else Color(0.8, 0.2, 0.2)
    _body_mesh.material_override = mat
    _body_mesh.position.y = 0.8
    add_child(_body_mesh)

    _turret = Node3D.new()
    _turret.position = Vector3(0, 1.6, 0)
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

func apply_snapshot(pos: Vector3, yaw: float, turret_yaw: float, gun_pitch: float, hp: int) -> void:
    position = pos
    rotation.y = yaw
    if _turret:
        _turret.rotation.y = turret_yaw
    if _barrel:
        _barrel.rotation.x = gun_pitch
    _hp = hp

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
