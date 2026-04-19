# client/audio/sound_bank.gd
# Procedural sound effects so we don't need to ship WAV/OGG assets.
# All generators return AudioStreamWAV resources that the scene can hand to an
# AudioStreamPlayer / AudioStreamPlayer3D. Engine sound is seamlessly loopable;
# fire and hit are one-shots.
class_name SoundBank

const SAMPLE_RATE: int = 22050

# Looping engine rumble: stacked low-frequency saw harmonics + slow LFO rasp.
# Callers modulate AudioStreamPlayer3D.pitch_scale at runtime based on tank
# speed, so the base frequency here should be on the low end.
static func make_engine_loop() -> AudioStreamWAV:
    var dur: float = 0.25  # shorter loop = cheaper; pitch modulation hides it
    var n: int = int(SAMPLE_RATE * dur)
    var base_hz: float = 70.0
    var frames := PackedFloat32Array()
    frames.resize(n)
    for i in n:
        var t: float = float(i) / SAMPLE_RATE
        var phase: float = fmod(t * base_hz, 1.0)
        var saw1: float = 2.0 * phase - 1.0
        var phase2: float = fmod(t * base_hz * 2.01, 1.0)
        var saw2: float = 2.0 * phase2 - 1.0
        var rasp: float = 0.15 * sin(TAU * 12.0 * t)
        frames[i] = (0.55 * saw1 + 0.35 * saw2 + rasp) * 0.35
    return _build_wav(frames, true)

# Short deep thump + noise burst for cannon fire.
static func make_fire_shot() -> AudioStreamWAV:
    var dur: float = 0.35
    var n: int = int(SAMPLE_RATE * dur)
    var frames := PackedFloat32Array()
    frames.resize(n)
    var rng := RandomNumberGenerator.new()
    rng.seed = 0xB007
    for i in n:
        var t: float = float(i) / SAMPLE_RATE
        var env: float = exp(-t * 6.0)
        var thump: float = sin(TAU * 55.0 * t) + 0.6 * sin(TAU * 82.0 * t)
        var noise: float = rng.randf_range(-1.0, 1.0) * exp(-t * 18.0)
        frames[i] = (0.7 * thump + 0.8 * noise) * env * 0.85
    return _build_wav(frames, false)

# Metallic clang when a shell strikes armor.
static func make_hit_clang() -> AudioStreamWAV:
    var dur: float = 0.25
    var n: int = int(SAMPLE_RATE * dur)
    var frames := PackedFloat32Array()
    frames.resize(n)
    var rng := RandomNumberGenerator.new()
    rng.seed = 0xC1A7
    for i in n:
        var t: float = float(i) / SAMPLE_RATE
        var env: float = exp(-t * 12.0)
        var ping: float = sin(TAU * 640.0 * t) + 0.55 * sin(TAU * 930.0 * t) + 0.3 * sin(TAU * 1480.0 * t)
        var scratch: float = rng.randf_range(-1.0, 1.0) * exp(-t * 30.0)
        frames[i] = (0.7 * ping + 0.35 * scratch) * env * 0.8
    return _build_wav(frames, false)

# Pack float frames (-1..1) into a 16-bit PCM mono AudioStreamWAV.
static func _build_wav(frames: PackedFloat32Array, looping: bool) -> AudioStreamWAV:
    var n: int = frames.size()
    var bytes := PackedByteArray()
    bytes.resize(n * 2)
    for i in n:
        var s: float = clamp(frames[i], -1.0, 1.0)
        var iv: int = int(s * 32767.0)
        bytes.encode_s16(i * 2, iv)
    var stream := AudioStreamWAV.new()
    stream.format = AudioStreamWAV.FORMAT_16_BITS
    stream.stereo = false
    stream.mix_rate = SAMPLE_RATE
    stream.data = bytes
    if looping:
        stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
        stream.loop_begin = 0
        stream.loop_end = n
    return stream
