# Plan 04: Destructible Obstacles — Implementation Plan

**Goal:** Shells can damage and destroy rocks + trees. Each obstacle has HP; when reduced to 0, it plays a brief "destroyed" animation on clients and no longer exists in the world (neither visually nor as tank-collision). Destruction state is server-authoritative and survives across reconnects / new client joins within the same world.

**Out of scope:** Fancy destruction physics / debris. Obstacles come back on world reset (already the case — server regenerates from seed).

---

## File Structure

```
common/constants.gd                    # modify: obstacle max HP per kind
common/protocol/message_types.gd       # modify: add OBSTACLE_DESTROYED (value 12)
common/protocol/messages.gd            # modify: add ObstacleDestroyed msg; ConnectAck adds destroyed_ids list
server/world/world_instance.gd         # modify: obstacle_hp dict + max_hp helper
server/combat/shell_sim.gd             # modify: also test against obstacles, return obstacle hit info
server/sim/tick_loop.gd                # modify: apply damage to obstacles, broadcast destruction; update tank collision to skip destroyed
server/net/ws_server.gd                # unchanged
client/world/obstacle_builder.gd       # modify: keep dict of obstacle_id → node
client/main_client.gd                  # modify: on OBSTACLE_DESTROYED, play effect + remove; handle destroyed_ids in CONNECT_ACK
shared/world/obstacle_placer.gd        # unchanged
```

---

## Task 1: Obstacle constants + HP helper

- [ ] Append to `common/constants.gd`:

```gdscript

# --- Obstacle HP (Plan 04) ---
const OBSTACLE_HP_SMALL_ROCK: int = 100
const OBSTACLE_HP_LARGE_ROCK: int = 400
const OBSTACLE_HP_TREE: int = 150
```

- [ ] Commit.

---

## Task 2: Messages — add OBSTACLE_DESTROYED + CONNECT_ACK carries destroyed list

- [ ] Modify `common/protocol/message_types.gd`:

```gdscript
    OBSTACLE_DESTROYED = 12,  # server → all clients
```

- [ ] Modify `common/protocol/messages.gd` — add ConnectAck field and new ObstacleDestroyed class.

Replace ConnectAck class:

```gdscript
class ConnectAck:
    var player_id: int = 0
    var team: int = 0
    var world_seed: int = 0
    var spawn_pos: Vector3 = Vector3.ZERO
    var destroyed_obstacle_ids: PackedInt32Array = PackedInt32Array()

    func encode() -> PackedByteArray:
        var buf := PackedByteArray()
        Codec.write_u16(buf, player_id)
        Codec.write_u8(buf, team)
        Codec.write_u32(buf, world_seed)
        Codec.write_vec3(buf, spawn_pos)
        Codec.write_u16(buf, destroyed_obstacle_ids.size())
        for oid in destroyed_obstacle_ids:
            Codec.write_u32(buf, oid)
        return buf

    static func decode(buf: PackedByteArray) -> ConnectAck:
        var m := ConnectAck.new()
        var c := [0]
        m.player_id = Codec.read_u16(buf, c)
        m.team = Codec.read_u8(buf, c)
        m.world_seed = Codec.read_u32(buf, c)
        m.spawn_pos = Codec.read_vec3(buf, c)
        var n := Codec.read_u16(buf, c)
        var arr := PackedInt32Array()
        for i in n:
            arr.append(Codec.read_u32(buf, c))
        m.destroyed_obstacle_ids = arr
        return m
```

Add at the end:

```gdscript
# ---- ObstacleDestroyed (server → all clients) ----
class ObstacleDestroyed:
    var obstacle_id: int = 0

    func encode() -> PackedByteArray:
        var buf := PackedByteArray()
        Codec.write_u32(buf, obstacle_id)
        return buf

    static func decode(buf: PackedByteArray) -> ObstacleDestroyed:
        var m := ObstacleDestroyed.new()
        var c := [0]
        m.obstacle_id = Codec.read_u32(buf, c)
        return m
```

- [ ] Update existing `test_connect_ack_roundtrip` to include destroyed_obstacle_ids. Add a new test for ObstacleDestroyed:

```gdscript
func test_connect_ack_with_destroyed_ids() -> void:
    var msg := Messages.ConnectAck.new()
    msg.player_id = 7
    msg.team = 0
    msg.world_seed = 123456789
    msg.spawn_pos = Vector3(100, 5, 200)
    msg.destroyed_obstacle_ids = PackedInt32Array([1, 42, 999])
    var bytes := msg.encode()
    var decoded := Messages.ConnectAck.decode(bytes)
    assert_eq(decoded.destroyed_obstacle_ids.size(), 3)
    assert_eq(decoded.destroyed_obstacle_ids[0], 1)
    assert_eq(decoded.destroyed_obstacle_ids[2], 999)

func test_obstacle_destroyed_roundtrip() -> void:
    var msg := Messages.ObstacleDestroyed.new()
    msg.obstacle_id = 4242
    var bytes := msg.encode()
    var decoded := Messages.ObstacleDestroyed.decode(bytes)
    assert_eq(decoded.obstacle_id, 4242)
```

Run tests. Commit.

---

## Task 3: Server — obstacle HP tracking + max helper

- [ ] Modify `server/world/world_instance.gd`:

Add fields:

```gdscript
# obstacle_id → current HP (absent = intact at max)
var obstacle_hp: Dictionary = {}
# Set of destroyed obstacle ids (for fast "is destroyed" lookup + connect_ack snapshot)
var destroyed_obstacle_ids: Dictionary = {}
```

Add helper:

```gdscript
func obstacle_max_hp(kind: int) -> int:
    match kind:
        0: return Constants.OBSTACLE_HP_SMALL_ROCK
        1: return Constants.OBSTACLE_HP_LARGE_ROCK
        2: return Constants.OBSTACLE_HP_TREE
    return 100

func obstacle_current_hp(id: int, kind: int) -> int:
    return obstacle_hp.get(id, obstacle_max_hp(kind))

# Returns true if this hit destroyed the obstacle.
func apply_obstacle_damage(id: int, kind: int, damage: int) -> bool:
    if destroyed_obstacle_ids.has(id):
        return false
    var current: int = obstacle_current_hp(id, kind)
    current -= damage
    if current <= 0:
        destroyed_obstacle_ids[id] = true
        obstacle_hp.erase(id)
        return true
    obstacle_hp[id] = current
    return false

func is_obstacle_destroyed(id: int) -> bool:
    return destroyed_obstacle_ids.has(id)
```

- [ ] Commit.

---

## Task 4: Shell sim tests obstacles, returns obstacle hit

- [ ] Modify `server/combat/shell_sim.gd` — after the per-tank loop inside `_swept_collide`, add obstacle check:

```gdscript
        # Obstacles
        for o in _world.obstacles:
            if _world.is_obstacle_destroyed(o.id):
                continue
            var o_r: float = _obstacle_collision_radius(o.kind)
            # The tank collides with a cylinder of radius o_r; shell is a point.
            # Treat obstacle as a sphere of radius o_r centered at (o.pos.x, o.pos.y + approx_half_height, o.pos.z).
            var half_h: float = _obstacle_half_height(o.kind)
            var center: Vector3 = o.pos + Vector3(0, half_h, 0)
            var seg_dir: Vector3 = pos - prev_pos
            var seg_len: float = seg_dir.length()
            if seg_len < 0.001:
                continue
            var seg_norm: Vector3 = seg_dir / seg_len
            var to_center: Vector3 = center - prev_pos
            var proj: float = to_center.dot(seg_norm)
            proj = clamp(proj, 0.0, seg_len)
            var closest: Vector3 = prev_pos + seg_norm * proj
            if closest.distance_to(center) <= o_r:
                return {"hit": true, "victim_id": 0, "point": closest, "part_id": 0, "obstacle_id": o.id, "obstacle_kind": o.kind}
```

Include `obstacle_id` and `obstacle_kind` in the default return (0). Also add the helpers:

```gdscript
func _obstacle_collision_radius(kind: int) -> float:
    match kind:
        0: return Constants.OBSTACLE_RADIUS_SMALL_ROCK
        1: return Constants.OBSTACLE_RADIUS_LARGE_ROCK
        2: return Constants.OBSTACLE_RADIUS_TREE
    return 1.0

func _obstacle_half_height(kind: int) -> float:
    match kind:
        0: return 1.2   # small rock half-height
        1: return 2.5   # large rock
        2: return 4.0   # tree (crown + trunk center)
    return 1.0
```

Update the default hit return elsewhere to include `obstacle_id: 0, obstacle_kind: 0`:

```gdscript
    return {"hit": false, "victim_id": 0, "point": Vector3.ZERO, "part_id": 0, "obstacle_id": 0, "obstacle_kind": 0}
```

Same for terrain hit return:

```gdscript
                return {"hit": true, "victim_id": 0, "point": Vector3(pos.x, terrain_h, pos.z), "part_id": 0, "obstacle_id": 0, "obstacle_kind": 0}
```

Same for tank hit:

```gdscript
                return {"hit": true, "victim_id": pid, "point": closest, "part_id": part, "obstacle_id": 0, "obstacle_kind": 0}
```

- [ ] Commit.

---

## Task 5: TickLoop — apply obstacle damage, broadcast destruction, send destroyed_ids in ACK

- [ ] Modify `server/sim/tick_loop.gd`:

Update `_on_shell_hit` to handle obstacles:

```gdscript
func _on_shell_hit(shell, victim_id: int, hit_point: Vector3, part_id: int, obstacle_id: int = 0, obstacle_kind: int = 0) -> void:
    # Obstacle hit?
    if obstacle_id != 0:
        var destroyed: bool = _world.apply_obstacle_damage(obstacle_id, obstacle_kind, Constants.TANK_FIRE_DAMAGE)
        # Always broadcast impact to all for puff visual
        var hit_msg := Messages.Hit.new()
        hit_msg.shell_id = shell.id
        hit_msg.shooter_id = shell.shooter_id
        hit_msg.victim_id = 0
        hit_msg.damage = Constants.TANK_FIRE_DAMAGE
        hit_msg.part_id = 0
        hit_msg.hit_point = hit_point
        _ws_server.broadcast(MessageType.HIT, hit_msg.encode())
        if destroyed:
            var msg := Messages.ObstacleDestroyed.new()
            msg.obstacle_id = obstacle_id
            _ws_server.broadcast(MessageType.OBSTACLE_DESTROYED, msg.encode())
        return
    if victim_id == 0:
        # Terrain miss — puff
        var hit_msg := Messages.Hit.new()
        hit_msg.shell_id = shell.id
        hit_msg.shooter_id = shell.shooter_id
        hit_msg.victim_id = 0
        hit_msg.damage = 0
        hit_msg.part_id = 0
        hit_msg.hit_point = hit_point
        _ws_server.broadcast(MessageType.HIT, hit_msg.encode())
        return
    # (existing tank hit logic unchanged)
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
```

Also change shell_sim's `set_hit_callback` usage site — `_hit_callback.call(...)` now passes 4 values; update tick_loop's receiver signature to accept the 2 extra optional values. Already handled by default args in the signature above.

In `set_world`:

```gdscript
    _shell_sim.set_hit_callback(func(shell, victim_id, point, part_id, obstacle_id, obstacle_kind):
        _on_shell_hit(shell, victim_id, point, part_id, obstacle_id, obstacle_kind))
```

(Replace the existing `_shell_sim.set_hit_callback(_on_shell_hit)` with a lambda that explicitly maps 6 args.)

Update shell_sim's hit_callback call:

```gdscript
        if _hit_callback.is_valid():
            _hit_callback.call(s, hit_info["victim_id"], hit_info["point"], hit_info["part_id"], hit_info.get("obstacle_id", 0), hit_info.get("obstacle_kind", 0))
```

Update `_on_client_connected` to include destroyed_obstacle_ids:

```gdscript
    ack.spawn_pos = state.pos
    var arr := PackedInt32Array()
    for oid in _world.destroyed_obstacle_ids.keys():
        arr.append(oid)
    ack.destroyed_obstacle_ids = arr
    _ws_server.send_to_peer(peer_id, MessageType.CONNECT_ACK, ack.encode())
```

Update `_resolve_obstacle_collision` in tick_loop to skip destroyed obstacles:

```gdscript
    for o in _world.obstacles:
        if _world.is_obstacle_destroyed(o.id):
            continue
        ...
```

- [ ] Boot server, verify no errors. Commit.

---

## Task 6: Client — track obstacles by id, handle destruction

- [ ] Modify `client/world/obstacle_builder.gd`:

```gdscript
extends Node3D

const ObstaclePlacer = preload("res://shared/world/obstacle_placer.gd")

# obstacle_id → Node3D
var _nodes: Dictionary = {}

func build(world_seed: int, heightmap: PackedFloat32Array, terrain_size: int, already_destroyed: PackedInt32Array = PackedInt32Array()) -> void:
    var destroyed: Dictionary = {}
    for oid in already_destroyed:
        destroyed[oid] = true
    var obs := ObstaclePlacer.place(
        world_seed, heightmap, terrain_size,
        Constants.SMALL_ROCK_COUNT,
        Constants.LARGE_ROCK_COUNT,
        Constants.TREE_COUNT,
    )
    for o in obs:
        if destroyed.has(o.id):
            continue
        var node := _make_node(o)
        node.position = o.pos
        node.rotation.y = o.yaw
        add_child(node)
        _nodes[o.id] = node

func destroy_obstacle(id: int) -> void:
    if not _nodes.has(id):
        return
    var node: Node3D = _nodes[id]
    _nodes.erase(id)
    _play_destruction(node)

func _play_destruction(node: Node3D) -> void:
    # Simple shrink-and-fall animation
    var tw := node.create_tween()
    tw.set_parallel(true)
    tw.tween_property(node, "scale", Vector3(0.1, 0.1, 0.1), 0.4)
    tw.tween_property(node, "position:y", node.position.y - 1.0, 0.4)
    tw.chain().tween_callback(node.queue_free)
```

(Preserve `_make_node` from the existing file.)

- [ ] Modify `client/main_client.gd`:

In `_handle_connect_ack`, pass destroyed ids:

```gdscript
    _obstacle_builder.build(msg.world_seed, _terrain_builder.heightmap, _terrain_builder.terrain_size, msg.destroyed_obstacle_ids)
```

Handle new message type:

```gdscript
        MessageType.OBSTACLE_DESTROYED:
            var m = Messages.ObstacleDestroyed.decode(payload)
            _obstacle_builder.destroy_obstacle(m.obstacle_id)
```

- [ ] Boot both, fire a shot at a tree, verify it disappears. Commit.

---

## Task 7: Verification + tag

- [ ] Full test suite: expect 63+ passing.
- [ ] Live test: shoot rocks + trees, confirm destruction broadcasts + tank can drive through the freshly cleared spot.
- [ ] Tag `plan-04-destructible-obstacles-complete`.
- [ ] Completion notes.

---

## Self-Review

**Spec coverage:**
- Obstacles have HP → Task 3
- Shells damage obstacles → Task 4
- Destroyed obstacles disappear with animation → Task 6
- Destruction state persists for late joiners → Tasks 2, 5 (destroyed_ids in ConnectAck)
- Tank collision ignores destroyed obstacles → Task 5

**Placeholder scan:** none.
