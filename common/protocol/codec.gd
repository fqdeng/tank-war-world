# common/protocol/codec.gd
class_name Codec

# Primitive encoders append to a PackedByteArray.
# Readers take a cursor (1-elem int array so we can mutate by reference).

static func write_u8(buf: PackedByteArray, v: int) -> void:
    var off := buf.size()
    buf.resize(off + 1)
    buf.encode_u8(off, v & 0xFF)

static func read_u8(buf: PackedByteArray, cursor: Array) -> int:
    var v := buf[cursor[0]]
    cursor[0] += 1
    return v

static func write_u16(buf: PackedByteArray, v: int) -> void:
    var off := buf.size()
    buf.resize(off + 2)
    buf.encode_u16(off, v & 0xFFFF)

static func read_u16(buf: PackedByteArray, cursor: Array) -> int:
    var lo := buf[cursor[0]]
    var hi := buf[cursor[0] + 1]
    cursor[0] += 2
    return lo | (hi << 8)

static func write_u32(buf: PackedByteArray, v: int) -> void:
    var off := buf.size()
    buf.resize(off + 4)
    buf.encode_u32(off, v)

static func read_u32(buf: PackedByteArray, cursor: Array) -> int:
    var b0 := buf[cursor[0]]
    var b1 := buf[cursor[0] + 1]
    var b2 := buf[cursor[0] + 2]
    var b3 := buf[cursor[0] + 3]
    cursor[0] += 4
    return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)

static func write_f32(buf: PackedByteArray, v: float) -> void:
    var off := buf.size()
    buf.resize(off + 4)
    buf.encode_float(off, v)

static func read_f32(buf: PackedByteArray, cursor: Array) -> float:
    var v := buf.decode_float(cursor[0])
    cursor[0] += 4
    return v

static func write_vec3(buf: PackedByteArray, v: Vector3) -> void:
    write_f32(buf, v.x)
    write_f32(buf, v.y)
    write_f32(buf, v.z)

static func read_vec3(buf: PackedByteArray, cursor: Array) -> Vector3:
    return Vector3(read_f32(buf, cursor), read_f32(buf, cursor), read_f32(buf, cursor))

static func write_string(buf: PackedByteArray, s: String) -> void:
    var utf8 := s.to_utf8_buffer()
    write_u16(buf, utf8.size())
    buf.append_array(utf8)

static func read_string(buf: PackedByteArray, cursor: Array) -> String:
    var n := read_u16(buf, cursor)
    var slice := buf.slice(cursor[0], cursor[0] + n)
    cursor[0] += n
    return slice.get_string_from_utf8()

# ---- Envelope ----
# Uncompressed frame: [u8 msg_type][payload]
# Compressed frame:   [u8 msg_type|0x80][u32 original_size][zstd(payload)]
# msg_type bit 7 signals compression. Enum values are 0-15 so bit 7 is free.

const COMPRESS_FLAG := 0x80
const COMPRESS_THRESHOLD := 128
const COMPRESSION_MODE := FileAccess.COMPRESSION_ZSTD

class Envelope:
    var msg_type: int = 0
    var payload: PackedByteArray = PackedByteArray()

static func write_envelope(msg_type: int, payload: PackedByteArray) -> PackedByteArray:
    var buf := PackedByteArray()
    buf.append(msg_type & 0xFF)
    buf.append_array(payload)
    return buf

# Same contract as write_envelope but opportunistically ZSTD-compresses payloads
# above COMPRESS_THRESHOLD. Falls back to the uncompressed path if compression
# inflates (pathological input).
static func write_envelope_auto(msg_type: int, payload: PackedByteArray) -> PackedByteArray:
    if payload.size() < COMPRESS_THRESHOLD:
        return write_envelope(msg_type, payload)
    var compressed := payload.compress(COMPRESSION_MODE)
    # 5 = 1 byte tag + 4 byte original size header; if that exceeds the raw
    # payload, skip compression.
    if compressed.size() + 5 >= payload.size() + 1:
        return write_envelope(msg_type, payload)
    var buf := PackedByteArray()
    buf.append((msg_type & 0x7F) | COMPRESS_FLAG)
    write_u32(buf, payload.size())
    buf.append_array(compressed)
    return buf

static func read_envelope(buf: PackedByteArray) -> Envelope:
    var e := Envelope.new()
    var raw_type := buf[0]
    if raw_type & COMPRESS_FLAG == 0:
        e.msg_type = raw_type
        e.payload = buf.slice(1)
        return e
    e.msg_type = raw_type & 0x7F
    var cursor := [1]
    var original_size := read_u32(buf, cursor)
    var compressed := buf.slice(cursor[0])
    e.payload = compressed.decompress(original_size, COMPRESSION_MODE)
    return e
