# client/net/ws_client.gd
extends Node

const Codec = preload("res://common/protocol/codec.gd")

signal connected
signal disconnected
signal message(msg_type: int, payload: PackedByteArray)

var _peer: WebSocketPeer
var _was_open: bool = false

# Rolling 1-second byte windows (payload only — WebSocket frame overhead isn't
# observable from WebSocketPeer). HUD reads these per ~0.25 s for display.
var _sent_window: Array = []  # [{t_ms: int, bytes: int}, …]
var _recv_window: Array = []

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
    _record_window(_sent_window, framed.size())

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
                _record_window(_recv_window, packet.size())
                if packet.size() < 1:
                    continue
                var env := Codec.read_envelope(packet)
                emit_signal("message", env.msg_type, env.payload)
        WebSocketPeer.STATE_CLOSED:
            if _was_open:
                _was_open = false
                emit_signal("disconnected")

func _record_window(w: Array, n: int) -> void:
    var now: int = Time.get_ticks_msec()
    w.append({"t_ms": now, "bytes": n})
    _trim_window(w, now)

func _trim_window(w: Array, now: int) -> void:
    # Drop entries older than 1 s. Called on every write and read; Array.pop_front
    # is O(n), but n is bounded by ~40 (20 Hz send + ~20 Hz recv), so cheap.
    while w.size() > 0 and now - int(w[0]["t_ms"]) > 1000:
        w.pop_front()

func bytes_sent_per_sec() -> int:
    _trim_window(_sent_window, Time.get_ticks_msec())
    var total: int = 0
    for e in _sent_window:
        total += int(e["bytes"])
    return total

func bytes_recv_per_sec() -> int:
    _trim_window(_recv_window, Time.get_ticks_msec())
    var total: int = 0
    for e in _recv_window:
        total += int(e["bytes"])
    return total
