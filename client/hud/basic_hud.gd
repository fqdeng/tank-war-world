# client/hud/basic_hud.gd
extends CanvasLayer

@onready var _status: Label = $StatusLabel
@onready var _hp: Label = $HpLabel
@onready var _id: Label = $IdLabel
@onready var _ammo: Label = $AmmoLabel
@onready var _reload: ProgressBar = $ReloadBar
@onready var _reload_text: Label = $ReloadBar/ReloadText
@onready var radar: Control = $Radar
@onready var _scoreboard: RichTextLabel = $ScoreboardLabel
@onready var _combat_log: VBoxContainer = $CombatLog
@onready var _hit_label: Label = $HitLabel
@onready var _kill_label: Label = $KillLabel
@onready var _respawn_label: Label = $RespawnLabel
@onready var _turret_damage_label: Label = $TurretDamageLabel
@onready var _shield_label: Label = $ShieldLabel
@onready var _net_stats: Label = $NetStatsLabel
var _hit_tween: Tween
var _kill_tween: Tween

func _ready() -> void:
    get_viewport().size_changed.connect(_resize_radar)
    _resize_radar.call_deferred()

func _resize_radar() -> void:
    if radar == null:
        return
    var vp: Vector2 = get_viewport().get_visible_rect().size
    var s: float = clamp(vp.y * 0.56, 480.0, 880.0)
    var margin: float = 16.0
    radar.set_anchors_preset(Control.PRESET_TOP_LEFT)
    radar.position = Vector2(margin, vp.y - s - margin)
    radar.size = Vector2(s, s)
    # Push HP/Player labels above the radar (radar lives bottom-left) so they
    # aren't overlapped by it.
    var labels_bottom_offset: float = -(s + margin + 8.0)
    if _hp:
        _hp.offset_top = labels_bottom_offset - 48.0
        _hp.offset_bottom = labels_bottom_offset - 8.0
    if _id:
        _id.offset_top = labels_bottom_offset
        _id.offset_bottom = labels_bottom_offset + 40.0

func set_status(s: String) -> void:
    if _status:
        _status.text = "STATUS: " + s

# Shown while the local tank's turret is broken. Pass 0 to hide.
func set_turret_damaged(seconds: float) -> void:
    if _turret_damage_label == null:
        return
    if seconds > 0.0:
        _turret_damage_label.text = "炮管损坏 — 重生 %.1fs" % seconds
        _turret_damage_label.visible = true
    else:
        _turret_damage_label.visible = false
        _turret_damage_label.text = ""

# Shown while the local tank has an active shield pickup. Pass 0 to hide.
func set_shield_countdown(seconds: float) -> void:
    if _shield_label == null:
        return
    if seconds > 0.0:
        _shield_label.text = "护盾 %.1fs" % seconds
        _shield_label.visible = true
    else:
        _shield_label.visible = false
        _shield_label.text = ""

# Big center-screen overlay shown during respawn. Pass 0 (or negative) to hide.
func set_respawn_countdown(seconds: float) -> void:
    if _respawn_label == null:
        return
    if seconds > 0.0:
        _respawn_label.text = "阵亡 — 重生 %.1fs" % seconds
        _respawn_label.visible = true
    else:
        _respawn_label.visible = false
        _respawn_label.text = ""

func set_hp(v: int) -> void:
    if _hp:
        _hp.text = "HP: %d" % v

func set_player_id(pid: int) -> void:
    if _id:
        _id.text = "Player: %d" % pid

func set_ammo(_n: int) -> void:
    if _ammo:
        _ammo.text = "AP x ∞"

const MATCH_KILL_TARGET: int = 100

func set_team_kills(blue: int, red: int) -> void:
    if _scoreboard:
        _scoreboard.text = "[center][color=#4db2ff]BLUE %d[/color]  /  %d  /  [color=#ff5050]RED %d[/color][/center]" % [blue, MATCH_KILL_TARGET, red]

const COMBAT_LOG_MAX_LINES: int = 15  # hard cap; overflow fades out FIFO
const COMBAT_LOG_FADE_S: float = 1.0

func add_hit_line(attacker: String, attacker_team: int, victim: String, victim_team: int, damage: int) -> void:
    if _combat_log == null:
        return
    var atk_color: String = "#4db2ff" if attacker_team == 0 else "#ff5050"
    var vic_color: String = "#4db2ff" if victim_team == 0 else "#ff5050"
    var lbl := RichTextLabel.new()
    lbl.bbcode_enabled = true
    lbl.fit_content = true
    lbl.scroll_active = false
    lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
    lbl.custom_minimum_size = Vector2(0, 44)
    lbl.add_theme_font_size_override("normal_font_size", 32)
    lbl.add_theme_font_size_override("bold_font_size", 32)
    lbl.text = "[color=%s]%s[/color] 击中了 [color=%s]%s[/color]  [color=#ffd070]-%d HP[/color]" % [atk_color, attacker, vic_color, victim, damage]
    _combat_log.add_child(lbl)
    _combat_log.move_child(lbl, 0)  # newest on top
    # FIFO overflow: only start fading out the oldest entries once we exceed the cap.
    while _combat_log.get_child_count() > COMBAT_LOG_MAX_LINES:
        var tail: Node = _combat_log.get_child(_combat_log.get_child_count() - 1)
        if tail.has_meta("fading"):
            # Already scheduled for removal but still in the tree — hard-drop so we
            # don't double-tween. Safer to just free now.
            _combat_log.remove_child(tail)
            tail.queue_free()
            continue
        tail.set_meta("fading", true)
        var tw := tail.create_tween()
        tw.tween_property(tail, "modulate:a", 0.0, COMBAT_LOG_FADE_S)
        tw.tween_callback(Callable(tail, "queue_free"))

func show_hit(damage: int) -> void:
    if _hit_label == null:
        return
    if _hit_tween and _hit_tween.is_valid():
        _hit_tween.kill()
    _hit_label.text = "HIT  -%d HP" % damage
    _hit_label.modulate.a = 1.0
    _hit_tween = create_tween()
    _hit_tween.tween_interval(0.6)
    _hit_tween.tween_property(_hit_label, "modulate:a", 0.0, 0.4)

func show_kill(victim_id: int) -> void:
    if _kill_label == null:
        return
    if _kill_tween and _kill_tween.is_valid():
        _kill_tween.kill()
    _kill_label.text = "KILL  P%d" % victim_id
    _kill_label.modulate.a = 1.0
    _kill_tween = create_tween()
    _kill_tween.tween_interval(1.2)
    _kill_tween.tween_property(_kill_label, "modulate:a", 0.0, 0.6)

# remaining_s: seconds left on reload; total_s: reload duration. 0 remaining = full bar.
func set_reload(remaining_s: float, total_s: float) -> void:
    if _reload == null or total_s <= 0.0:
        return
    var frac: float = 1.0 - clamp(remaining_s / total_s, 0.0, 1.0)
    _reload.value = frac
    if _reload_text:
        if remaining_s > 0.0:
            _reload_text.text = "装填 %.1fs" % remaining_s
        else:
            _reload_text.text = "就绪"

# Bottom-right network overlay. ping_ms comes from the RTT EMA (RFC6298-style);
# up/down are payload byte counts over a rolling 1 s window (WebSocket frame
# overhead isn't counted — treat as a lower bound).
func set_net_stats(ping_ms: float, up_bps: int, down_bps: int) -> void:
    if _net_stats == null:
        return
    # ASCII only — the web font subset (build.sh) excludes arrow
    # glyphs, so avoid ↑/↓ here or they render as tofu on the browser build.
    var ping_str: String = "--" if ping_ms <= 0.0 else "%d ms" % int(round(ping_ms))
    _net_stats.text = "PING %s\nTX  %s\nRX  %s" % [ping_str, _fmt_bps(up_bps), _fmt_bps(down_bps)]

func _fmt_bps(b: int) -> String:
    if b >= 1024:
        return "%.1f KB/s" % (float(b) / 1024.0)
    return "%d B/s" % b
