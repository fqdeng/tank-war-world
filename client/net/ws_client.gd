# client/net/ws_client.gd
extends Node

const Codec = preload("res://common/protocol/codec.gd")

signal connected
signal disconnected
signal message(msg_type: int, payload: PackedByteArray)

var _peer: WebSocketPeer
var _was_open: bool = false

func connect_to_url(url: String) -> void:
    _peer = WebSocketPeer.new()
    var err := _peer.connect_to_url(url)
    assert(err == OK, "WS connect_to_url failed (err=%d)" % err)

func is_open() -> bool:
    return _peer != null and _peer.get_ready_state() == WebSocketPeer.STATE_OPEN

func send(msg_type: int, payload: PackedByteArray) -> void:
    if not is_open():
        return
    var framed := Codec.write_envelope(msg_type, payload)
    _peer.put_packet(framed)

func _process(_delta: float) -> void:
    if _peer == null:
        return
    _peer.poll()
    var st := _peer.get_ready_state()
    match st:
        WebSocketPeer.STATE_OPEN:
            if not _was_open:
                _was_open = true
                emit_signal("connected")
            while _peer.get_available_packet_count() > 0:
                var packet := _peer.get_packet()
                if packet.size() < 1:
                    continue
                var env := Codec.read_envelope(packet)
                emit_signal("message", env.msg_type, env.payload)
        WebSocketPeer.STATE_CLOSED:
            if _was_open:
                _was_open = false
                emit_signal("disconnected")
