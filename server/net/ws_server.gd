# server/net/ws_server.gd
extends Node

const Messages = preload("res://common/protocol/messages.gd")
const Codec = preload("res://common/protocol/codec.gd")
const MessageType = preload("res://common/protocol/message_types.gd")

signal client_connected(peer_id: int, connect_msg)
signal client_disconnected(peer_id: int)
signal input_received(peer_id: int, input_msg)
signal fire_received(peer_id: int, fire_msg)

var _peer: WebSocketMultiplayerPeer
var _world
# Godot multiplayer peer_id → our player_id
var _peer_to_player: Dictionary = {}
# Peers that have been observed as connected (so we can emit disconnect once)
var _known_peers: Dictionary = {}

func set_world(world) -> void:
    _world = world

func listen(port: int) -> void:
    _peer = WebSocketMultiplayerPeer.new()
    var err := _peer.create_server(port)
    assert(err == OK, "Failed to listen on port %d (err=%d)" % [port, err])
    _peer.peer_connected.connect(_on_peer_connected)
    _peer.peer_disconnected.connect(_on_peer_disconnected)
    print("[WSServer] Listening on port %d" % port)

func _on_peer_connected(peer_id: int) -> void:
    _known_peers[peer_id] = true
    print("[WSServer] Peer %d connected (awaiting CONNECT msg)" % peer_id)

func _on_peer_disconnected(peer_id: int) -> void:
    _known_peers.erase(peer_id)
    emit_signal("client_disconnected", peer_id)

func _process(_delta: float) -> void:
    if _peer == null:
        return
    _peer.poll()
    while _peer.get_available_packet_count() > 0:
        var peer_id := _peer.get_packet_peer()
        var packet := _peer.get_packet()
        _handle_packet(peer_id, packet)

func _handle_packet(peer_id: int, packet: PackedByteArray) -> void:
    if packet.size() < 1:
        return
    var env := Codec.read_envelope(packet)
    match env.msg_type:
        MessageType.CONNECT:
            var msg := Messages.Connect.decode(env.payload)
            emit_signal("client_connected", peer_id, msg)
        MessageType.INPUT:
            var msg := Messages.InputMsg.decode(env.payload)
            emit_signal("input_received", peer_id, msg)
        MessageType.FIRE:
            var msg := Messages.Fire.decode(env.payload)
            emit_signal("fire_received", peer_id, msg)
        MessageType.PING:
            # Reply immediately on the poll thread so PONG latency isn't delayed
            # by tick-loop gating. Echoes client_time_ms + stamps server_time_ms
            # so the client can compute RTT and refine its server-clock estimate.
            var ping := Messages.Ping.decode(env.payload)
            var pong := Messages.Pong.new()
            pong.client_time_ms = ping.client_time_ms
            # Use the shared sim clock (wall-ms since tick loop started), not
            # raw Time.get_ticks_msec(). SNAPSHOT stamps use the same epoch via
            # _tick * 50, so both arrival paths feed the client offset EMA on
            # the same timeline; otherwise snapshot and PONG updates fight
            # each other and the estimate never settles.
            pong.server_time_ms = _world.sim_clock_ms() if _world != null else Time.get_ticks_msec()
            send_to_peer(peer_id, MessageType.PONG, pong.encode())
        MessageType.DISCONNECT:
            emit_signal("client_disconnected", peer_id)
        _:
            push_warning("[WSServer] Unknown msg_type %d from peer %d" % [env.msg_type, peer_id])

func send_to_peer(peer_id: int, msg_type: int, payload: PackedByteArray) -> void:
    if _peer == null:
        return
    var framed := Codec.write_envelope_auto(msg_type, payload)
    _peer.set_target_peer(peer_id)
    _peer.put_packet(framed)

func broadcast(msg_type: int, payload: PackedByteArray) -> void:
    if _peer == null:
        return
    # WebSocketMultiplayerPeer reports CONNECTION_DISCONNECTED while no clients
    # are attached; put_packet errors out as ERR_UNCONFIGURED in that state, and
    # tick_loop broadcasts every tick → error spam. Skip until someone joins.
    if _peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
        return
    var framed := Codec.write_envelope_auto(msg_type, payload)
    _peer.set_target_peer(MultiplayerPeer.TARGET_PEER_BROADCAST)
    _peer.put_packet(framed)

func bind_peer_to_player(peer_id: int, player_id: int) -> void:
    _peer_to_player[peer_id] = player_id

func player_id_for_peer(peer_id: int) -> int:
    return _peer_to_player.get(peer_id, 0)

func peer_id_for_player(player_id: int) -> int:
    for peer_id in _peer_to_player:
        if _peer_to_player[peer_id] == player_id:
            return peer_id
    return 0

func unbind_peer(peer_id: int) -> void:
    _peer_to_player.erase(peer_id)
