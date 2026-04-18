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
