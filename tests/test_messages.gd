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
    msg.server_time_ms = 9876543
    msg.add_tank(1, 0, Vector3(10, 0, 20), 0.5, 0.1, 0.0, 850, 777, 24, 0.0, 0.0, "Wolf")
    msg.add_tank(2, 1, Vector3(-30, 2, 40), 1.5, 0.2, 0.3, 600, 888, 12, 1.75, 6.3, "P42")
    var bytes := msg.encode()
    var decoded := Messages.Snapshot.decode(bytes)
    assert_eq(decoded.tick, 1234)
    assert_eq(decoded.server_time_ms, 9876543)
    assert_eq(decoded.tanks.size(), 2)
    assert_eq(decoded.tanks[0].player_id, 1)
    assert_eq(decoded.tanks[0].hp, 850)
    assert_eq(decoded.tanks[0].last_input_tick, 777)
    assert_eq(decoded.tanks[0].ammo, 24)
    assert_almost_eq(decoded.tanks[0].reload_remaining, 0.0, 0.001)
    assert_eq(decoded.tanks[1].ammo, 12)
    assert_almost_eq(decoded.tanks[1].reload_remaining, 1.75, 0.001)
    assert_almost_eq(decoded.tanks[0].turret_regen_remaining, 0.0, 0.001)
    assert_almost_eq(decoded.tanks[1].turret_regen_remaining, 6.3, 0.001)
    assert_eq(decoded.tanks[0].display_name, "Wolf")
    assert_eq(decoded.tanks[1].display_name, "P42")

func test_snapshot_roundtrip_default_display_name_is_empty() -> void:
    # add_tank's display_name parameter defaults to "" — verifies callers that
    # don't pass it (none expected post-rollout, but the default is part of
    # the contract) get an empty string back, not crash on encode/decode.
    var msg := Messages.Snapshot.new()
    msg.tick = 1
    msg.server_time_ms = 0
    msg.add_tank(1, 0, Vector3.ZERO, 0.0, 0.0, 0.0, 1000, 0, 0, 0.0, 0.0)
    var bytes := msg.encode()
    var decoded := Messages.Snapshot.decode(bytes)
    assert_eq(decoded.tanks[0].display_name, "")

func test_ping_roundtrip() -> void:
    var msg := Messages.Ping.new()
    msg.client_time_ms = 123456
    var bytes := msg.encode()
    var decoded := Messages.Ping.decode(bytes)
    assert_eq(decoded.client_time_ms, 123456)

func test_pong_roundtrip() -> void:
    var msg := Messages.Pong.new()
    msg.client_time_ms = 123456
    msg.server_time_ms = 789012
    var bytes := msg.encode()
    var decoded := Messages.Pong.decode(bytes)
    assert_eq(decoded.client_time_ms, 123456)
    assert_eq(decoded.server_time_ms, 789012)

func test_fire_roundtrip() -> void:
    var msg := Messages.Fire.new()
    msg.tick = 100
    msg.origin = Vector3(10, 2, -5)
    msg.velocity = Vector3(0, 5, -160)
    var bytes := msg.encode()
    var decoded := Messages.Fire.decode(bytes)
    assert_eq(decoded.tick, 100)
    assert_almost_eq(decoded.origin.x, 10.0, 0.001)
    assert_almost_eq(decoded.origin.z, -5.0, 0.001)
    assert_almost_eq(decoded.velocity.z, -160.0, 0.001)

func test_hit_roundtrip() -> void:
    var msg := Messages.Hit.new()
    msg.shell_id = 99
    msg.shooter_id = 3
    msg.victim_id = 5
    msg.damage = 260
    msg.part_id = 2
    msg.hit_point = Vector3(1, 2, 3)
    msg.victim_hp_after = 1740
    var bytes := msg.encode()
    var decoded := Messages.Hit.decode(bytes)
    assert_eq(decoded.shell_id, 99)
    assert_eq(decoded.shooter_id, 3)
    assert_eq(decoded.victim_id, 5)
    assert_eq(decoded.damage, 260)
    assert_eq(decoded.part_id, 2)
    assert_eq(decoded.victim_hp_after, 1740)

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

func test_pickup_spawned_roundtrip() -> void:
    var msg := Messages.PickupSpawned.new()
    msg.pickup_id = 17
    msg.kind = Constants.PICKUP_KIND_SHIELD
    msg.pos = Vector3(123.5, 2.0, 456.5)
    var bytes := msg.encode()
    var decoded := Messages.PickupSpawned.decode(bytes)
    assert_eq(decoded.pickup_id, 17)
    assert_eq(decoded.kind, Constants.PICKUP_KIND_SHIELD)
    assert_almost_eq(decoded.pos.x, 123.5, 0.001)
    assert_almost_eq(decoded.pos.z, 456.5, 0.001)

func test_pickup_consumed_roundtrip() -> void:
    var msg := Messages.PickupConsumed.new()
    msg.pickup_id = 17
    msg.consumer_id = 42
    msg.kind = Constants.PICKUP_KIND_HEART
    var bytes := msg.encode()
    var decoded := Messages.PickupConsumed.decode(bytes)
    assert_eq(decoded.pickup_id, 17)
    assert_eq(decoded.consumer_id, 42)
    assert_eq(decoded.kind, Constants.PICKUP_KIND_HEART)

func test_connect_ack_roundtrip_with_pickups() -> void:
    var msg := Messages.ConnectAck.new()
    msg.player_id = 3
    msg.team = 1
    msg.world_seed = 999
    msg.spawn_pos = Vector3.ZERO
    var p1 := Messages.PickupEntry.new()
    p1.pickup_id = 1
    p1.kind = Constants.PICKUP_KIND_HEART
    p1.pos = Vector3(100, 1, 200)
    var p2 := Messages.PickupEntry.new()
    p2.pickup_id = 2
    p2.kind = Constants.PICKUP_KIND_SHIELD
    p2.pos = Vector3(300, 2, 400)
    msg.pickups = [p1, p2]
    var bytes := msg.encode()
    var decoded := Messages.ConnectAck.decode(bytes)
    assert_eq(decoded.pickups.size(), 2)
    assert_eq(decoded.pickups[0].pickup_id, 1)
    assert_eq(decoded.pickups[0].kind, Constants.PICKUP_KIND_HEART)
    assert_almost_eq(decoded.pickups[0].pos.x, 100.0, 0.001)
    assert_eq(decoded.pickups[1].kind, Constants.PICKUP_KIND_SHIELD)
    assert_almost_eq(decoded.pickups[1].pos.z, 400.0, 0.001)

func test_snapshot_carries_shield_invuln() -> void:
    var msg := Messages.Snapshot.new()
    msg.tick = 1
    msg.server_time_ms = 0
    msg.add_tank(1, 0, Vector3.ZERO, 0.0, 0.0, 0.0, 1000, 0, 24, 0.0, 0.0, "Wolf", 12.5)
    var bytes := msg.encode()
    var decoded := Messages.Snapshot.decode(bytes)
    assert_almost_eq(decoded.tanks[0].shield_invuln_remaining, 12.5, 0.001)

func test_scoreboard_roundtrip() -> void:
    var msg := Messages.Scoreboard.new()
    var e1 := Messages.ScoreboardEntry.new()
    e1.player_id = 7
    e1.team = 0
    e1.is_ai = false
    e1.display_name = "Alice"
    e1.kills = 12
    e1.deaths = 5
    e1.assists = 3
    e1.hits = 27
    e1.damage = 6540
    var e2 := Messages.ScoreboardEntry.new()
    e2.player_id = 42
    e2.team = 1
    e2.is_ai = true
    e2.display_name = "P42"
    e2.kills = 4
    e2.deaths = 9
    e2.assists = 1
    e2.hits = 11
    e2.damage = 2410
    msg.entries = [e1, e2]
    var bytes := msg.encode()
    var decoded := Messages.Scoreboard.decode(bytes)
    assert_eq(decoded.entries.size(), 2)
    assert_eq(decoded.entries[0].player_id, 7)
    assert_eq(decoded.entries[0].team, 0)
    assert_eq(decoded.entries[0].is_ai, false)
    assert_eq(decoded.entries[0].display_name, "Alice")
    assert_eq(decoded.entries[0].kills, 12)
    assert_eq(decoded.entries[0].damage, 6540)
    assert_eq(decoded.entries[1].is_ai, true)
    assert_eq(decoded.entries[1].display_name, "P42")
    assert_eq(decoded.entries[1].damage, 2410)

func test_scoreboard_roundtrip_empty() -> void:
    var msg := Messages.Scoreboard.new()
    var bytes := msg.encode()
    var decoded := Messages.Scoreboard.decode(bytes)
    assert_eq(decoded.entries.size(), 0)
