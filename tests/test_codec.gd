extends GutTest

const Codec = preload("res://common/protocol/codec.gd")

func test_u8_roundtrip() -> void:
    var buf := PackedByteArray()
    Codec.write_u8(buf, 200)
    var cursor := [0]
    assert_eq(Codec.read_u8(buf, cursor), 200)
    assert_eq(cursor[0], 1)

func test_u16_roundtrip() -> void:
    var buf := PackedByteArray()
    Codec.write_u16(buf, 60000)
    var cursor := [0]
    assert_eq(Codec.read_u16(buf, cursor), 60000)
    assert_eq(cursor[0], 2)

func test_u32_roundtrip() -> void:
    var buf := PackedByteArray()
    Codec.write_u32(buf, 4000000000)
    var cursor := [0]
    assert_eq(Codec.read_u32(buf, cursor), 4000000000)
    assert_eq(cursor[0], 4)

func test_f32_roundtrip() -> void:
    var buf := PackedByteArray()
    Codec.write_f32(buf, 3.14159)
    var cursor := [0]
    assert_almost_eq(Codec.read_f32(buf, cursor), 3.14159, 0.0001)
    assert_eq(cursor[0], 4)

func test_vec3_roundtrip() -> void:
    var buf := PackedByteArray()
    Codec.write_vec3(buf, Vector3(10.5, -20.25, 100.0))
    var cursor := [0]
    var v: Vector3 = Codec.read_vec3(buf, cursor)
    assert_almost_eq(v.x, 10.5, 0.0001)
    assert_almost_eq(v.y, -20.25, 0.0001)
    assert_almost_eq(v.z, 100.0, 0.0001)
    assert_eq(cursor[0], 12)

func test_string_roundtrip() -> void:
    var buf := PackedByteArray()
    Codec.write_string(buf, "Hello, 坦克 🚀")
    var cursor := [0]
    assert_eq(Codec.read_string(buf, cursor), "Hello, 坦克 🚀")

func test_multi_value_sequence() -> void:
    var buf := PackedByteArray()
    Codec.write_u8(buf, 1)
    Codec.write_u16(buf, 500)
    Codec.write_f32(buf, 2.5)
    Codec.write_string(buf, "tank")
    var cursor := [0]
    assert_eq(Codec.read_u8(buf, cursor), 1)
    assert_eq(Codec.read_u16(buf, cursor), 500)
    assert_almost_eq(Codec.read_f32(buf, cursor), 2.5, 0.0001)
    assert_eq(Codec.read_string(buf, cursor), "tank")

func test_envelope_roundtrip() -> void:
    var payload := PackedByteArray()
    Codec.write_u32(payload, 12345)
    var framed := Codec.write_envelope(3, payload)
    var parsed := Codec.read_envelope(framed)
    assert_eq(parsed.msg_type, 3)
    var c := [0]
    assert_eq(Codec.read_u32(parsed.payload, c), 12345)

func test_envelope_auto_small_passthrough() -> void:
    # Under the threshold: auto-path must produce identical bytes to the
    # uncompressed path so existing wire behavior doesn't regress.
    var payload := PackedByteArray()
    for i in 100:
        Codec.write_u8(payload, i)
    var framed_auto := Codec.write_envelope_auto(3, payload)
    var framed_raw := Codec.write_envelope(3, payload)
    assert_eq(framed_auto, framed_raw)
    assert_eq(framed_auto[0] & Codec.COMPRESS_FLAG, 0)
    var parsed := Codec.read_envelope(framed_auto)
    assert_eq(parsed.msg_type, 3)
    assert_eq(parsed.payload, payload)

func test_envelope_auto_large_compressed() -> void:
    # Highly repetitive 1 KB payload — ZSTD must shrink it and set bit 7.
    var payload := PackedByteArray()
    for i in 1024:
        Codec.write_u8(payload, 0x42)
    var framed := Codec.write_envelope_auto(3, payload)
    assert_true(framed.size() < payload.size() + 1, "compressed framed should be smaller than raw envelope")
    assert_eq(framed[0] & Codec.COMPRESS_FLAG, Codec.COMPRESS_FLAG)
    assert_eq(framed[0] & 0x7F, 3)
    var parsed := Codec.read_envelope(framed)
    assert_eq(parsed.msg_type, 3)
    assert_eq(parsed.payload, payload)

func test_envelope_auto_incompressible_skip() -> void:
    # Pseudo-random bytes don't compress; the auto-path should detect inflation
    # and fall back to the uncompressed encoding.
    var rng := RandomNumberGenerator.new()
    rng.seed = 0xC0FFEE
    var payload := PackedByteArray()
    for i in 1024:
        Codec.write_u8(payload, rng.randi() & 0xFF)
    var framed := Codec.write_envelope_auto(3, payload)
    assert_eq(framed[0] & Codec.COMPRESS_FLAG, 0)
    var parsed := Codec.read_envelope(framed)
    assert_eq(parsed.msg_type, 3)
    assert_eq(parsed.payload, payload)

func test_envelope_auto_msg_type_masking() -> void:
    # msg_type 3 (SNAPSHOT) compressed → raw byte 0x83; read must strip bit 7.
    var payload := PackedByteArray()
    for i in 500:
        Codec.write_u8(payload, 0xAB)
    var framed := Codec.write_envelope_auto(MessageType.SNAPSHOT, payload)
    assert_eq(framed[0], MessageType.SNAPSHOT | Codec.COMPRESS_FLAG)
    var parsed := Codec.read_envelope(framed)
    assert_eq(parsed.msg_type, MessageType.SNAPSHOT)
