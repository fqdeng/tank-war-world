extends GutTest

const Messages = preload("res://common/protocol/messages.gd")

func test_connect_roundtrip() -> void:
    var msg := Messages.Connect.new()
    msg.player_name = "Alice"
    msg.preferred_team = 1
    var bytes := msg.encode()
    var decoded := Messages.Connect.decode(bytes)
    assert_eq(decoded.player_name, "Alice")
    assert_eq(decoded.preferred_team, 1)

func test_connect_ack_roundtrip() -> void:
    var msg := Messages.ConnectAck.new()
    msg.player_id = 7
    msg.team = 0
    msg.world_seed = 123456789
    msg.spawn_pos = Vector3(100, 5, 200)
    msg.destroyed_obstacle_ids = PackedInt32Array([1, 42, 999])
    var bytes := msg.encode()
    var decoded := Messages.ConnectAck.decode(bytes)
    assert_eq(decoded.player_id, 7)
    assert_eq(decoded.team, 0)
    assert_eq(decoded.world_seed, 123456789)
    assert_almost_eq(decoded.spawn_pos.x, 100.0, 0.001)
    assert_eq(decoded.destroyed_obstacle_ids.size(), 3)
    assert_eq(decoded.destroyed_obstacle_ids[2], 999)

func test_obstacle_destroyed_roundtrip() -> void:
    var msg := Messages.ObstacleDestroyed.new()
    msg.obstacle_id = 4242
    var bytes := msg.encode()
    var decoded := Messages.ObstacleDestroyed.decode(bytes)
    assert_eq(decoded.obstacle_id, 4242)

func test_input_roundtrip() -> void:
    var msg := Messages.InputMsg.new()
    msg.tick = 500
    msg.move_forward = 1.0
    msg.move_turn = -0.5
    msg.turret_yaw = 1.57
    msg.gun_pitch = 0.2
    msg.fire_pressed = true
    var bytes := msg.encode()
    var decoded := Messages.InputMsg.decode(bytes)
    assert_eq(decoded.tick, 500)
    assert_almost_eq(decoded.move_forward, 1.0, 0.001)
    assert_almost_eq(decoded.move_turn, -0.5, 0.001)
    assert_almost_eq(decoded.turret_yaw, 1.57, 0.001)
    assert_almost_eq(decoded.gun_pitch, 0.2, 0.001)
    assert_eq(decoded.fire_pressed, true)

func test_snapshot_roundtrip_multiple_tanks() -> void:
    var msg := Messages.Snapshot.new()
    msg.tick = 1234
    msg.add_tank(1, 0, Vector3(10, 0, 20), 0.5, 0.1, 0.0, 850, 777)
    msg.add_tank(2, 1, Vector3(-30, 2, 40), 1.5, 0.2, 0.3, 600, 888)
    var bytes := msg.encode()
    var decoded := Messages.Snapshot.decode(bytes)
    assert_eq(decoded.tick, 1234)
    assert_eq(decoded.tanks.size(), 2)
    assert_eq(decoded.tanks[0].player_id, 1)
    assert_eq(decoded.tanks[0].team, 0)
    assert_eq(decoded.tanks[0].hp, 850)
    assert_eq(decoded.tanks[0].last_input_tick, 777)
    assert_eq(decoded.tanks[1].player_id, 2)
    assert_eq(decoded.tanks[1].hp, 600)
    assert_eq(decoded.tanks[1].last_input_tick, 888)

func test_fire_roundtrip() -> void:
    var msg := Messages.Fire.new()
    msg.tick = 100
    var bytes := msg.encode()
    var decoded := Messages.Fire.decode(bytes)
    assert_eq(decoded.tick, 100)

func test_hit_roundtrip() -> void:
    var msg := Messages.Hit.new()
    msg.shell_id = 99
    msg.shooter_id = 3
    msg.victim_id = 5
    msg.damage = 260
    msg.part_id = 2
    msg.hit_point = Vector3(1, 2, 3)
    var bytes := msg.encode()
    var decoded := Messages.Hit.decode(bytes)
    assert_eq(decoded.shell_id, 99)
    assert_eq(decoded.shooter_id, 3)
    assert_eq(decoded.victim_id, 5)
    assert_eq(decoded.damage, 260)
    assert_eq(decoded.part_id, 2)

func test_shell_spawned_roundtrip() -> void:
    var msg := Messages.ShellSpawned.new()
    msg.shell_id = 42
    msg.shooter_id = 3
    msg.origin = Vector3(10, 20, 30)
    msg.velocity = Vector3(100, 50, -200)
    msg.fire_time_ms = 123456789
    var bytes := msg.encode()
    var decoded := Messages.ShellSpawned.decode(bytes)
    assert_eq(decoded.shell_id, 42)
    assert_eq(decoded.shooter_id, 3)
    assert_almost_eq(decoded.velocity.z, -200.0, 0.001)
    assert_eq(decoded.fire_time_ms, 123456789)

func test_death_roundtrip() -> void:
    var msg := Messages.Death.new()
    msg.victim_id = 2
    msg.killer_id = 4
    var bytes := msg.encode()
    var decoded := Messages.Death.decode(bytes)
    assert_eq(decoded.victim_id, 2)
    assert_eq(decoded.killer_id, 4)

func test_respawn_roundtrip() -> void:
    var msg := Messages.Respawn.new()
    msg.player_id = 2
    msg.pos = Vector3(50, 5, 60)
    var bytes := msg.encode()
    var decoded := Messages.Respawn.decode(bytes)
    assert_eq(decoded.player_id, 2)
    assert_almost_eq(decoded.pos.x, 50.0, 0.001)
