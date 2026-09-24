class_name Hud
extends Control
## Screen-space interface: mass counter with rank progress, notifications,
## off-screen prey indicators, help and the game-over panel.

const RANK_COLORS := [
	Color(0.6, 0.6, 0.7), Color(0.7, 0.8, 0.9), Color(0.5, 0.9, 1.0), Color(0.4, 1.0, 0.7),
	Color(0.7, 1.0, 0.4), Color(1.0, 0.9, 0.3), Color(1.0, 0.65, 0.25), Color(1.0, 0.45, 0.35),
	Color(1.0, 0.35, 0.6), Color(0.85, 0.4, 1.0), Color(1.0, 0.95, 0.6), Color(0.7, 0.85, 1.0),
	Color(1.0, 1.0, 1.0),
]

var mass_label: Label
var rank_label: Label
var stats_label: Label
var info_label: Label
var debug_label: Label
var hint_label: Label
var notice_label: Label
var over_root: Control
var over_title: Label
var over_body: Label
var over_hint: Label

## Filled by main each frame: [{pos: Vector2 (screen), color: Color, size: float}]
var indicators: Array[Dictionary] = []
var progress := 0.0
var rank_color := Color.WHITE

var _shown_mass := 0.0
var _bump := 0.0
var _notice_tween: Tween
var _hint_time := 0.0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	mass_label = _label(46, Color(1, 1, 1), 8)
	mass_label.position = Vector2(28, 18)
	rank_label = _label(22, Color(0.7, 0.9, 1.0), 6)
	rank_label.position = Vector2(30, 78)
	stats_label = _label(15, Color(0.75, 0.8, 0.95, 0.85), 4)
	stats_label.position = Vector2(30, 128)

	info_label = _label(15, Color(0.8, 0.85, 1.0, 0.8), 4)
	info_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_place(info_label, Control.PRESET_TOP_RIGHT, -330, 20, -28, 100)

	debug_label = _label(13, Color(0.6, 1.0, 0.7, 0.9), 4)
	debug_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_place(debug_label, Control.PRESET_TOP_RIGHT, -460, 100, -28, 260)
	debug_label.visible = false

	hint_label = _label(16, Color(0.85, 0.9, 1.0, 0.85), 5)
	hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_place(hint_label, Control.PRESET_CENTER_BOTTOM, -560, -70, 560, -16)
	hint_label.text = "Aim with the mouse  ·  SPACE / left click: blast mass away to thrust towards the cursor\nEat anything smaller  ·  avoid anything bigger (red rim)  ·  wheel: zoom  ·  T: trajectory  ·  H: help"

	notice_label = _label(40, Color(1, 1, 1), 10)
	notice_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_place(notice_label, Control.PRESET_CENTER_TOP, -600, 150, 600, 210)
	notice_label.pivot_offset = Vector2(600, 30)
	notice_label.modulate.a = 0.0

	over_root = Control.new()
	add_child(over_root)
	over_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	over_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	over_root.visible = false
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.03, 0.01, 0.08, 0.72)
	sb.border_color = Color(1.0, 0.45, 0.2, 0.8)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(14)
	sb.set_content_margin_all(26)
	sb.shadow_color = Color(1.0, 0.3, 0.1, 0.25)
	sb.shadow_size = 24
	panel.add_theme_stylebox_override("panel", sb)
	panel.custom_minimum_size = Vector2(620, 0)
	_place(panel, Control.PRESET_CENTER, -310, -170, 310, 170)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	over_root.add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	panel.add_child(vb)
	over_title = _label(56, Color(1.0, 0.55, 0.25), 10, vb)
	over_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	over_body = _label(18, Color(0.9, 0.9, 1.0), 4, vb)
	over_body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	over_hint = _label(20, Color(0.5, 1.0, 1.0), 5, vb)
	over_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER


func _place(c: Control, preset: int, left: float, top: float, right: float, bottom: float) -> void:
	c.set_anchors_preset(preset)
	c.offset_left = left
	c.offset_top = top
	c.offset_right = right
	c.offset_bottom = bottom


func _label(font_size: int, color: Color, outline: int, parent: Control = null) -> Label:
	var l := Label.new()
	var ls := LabelSettings.new()
	ls.font_size = font_size
	ls.font_color = color
	ls.outline_size = outline
	ls.outline_color = Color(0.0, 0.0, 0.05, 0.75)
	ls.shadow_size = 6
	ls.shadow_color = Color(0.0, 0.0, 0.0, 0.35)
	ls.shadow_offset = Vector2(0, 2)
	l.label_settings = ls
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	(parent if parent != null else self).add_child(l)
	return l


func set_mass(m: float, alive: bool, delta: float) -> void:
	if not alive:
		return
	if m > _shown_mass * 1.0001:
		_bump = minf(1.0, _bump + 0.35)
	# Count up/down smoothly for a satisfying tally.
	_shown_mass = lerpf(_shown_mass, m, 1.0 - exp(-delta * 10.0))
	if absf(_shown_mass - m) < m * 0.001:
		_shown_mass = m
	mass_label.text = Phys.format_mass(_shown_mass)
	var idx := Phys.rank_index(m)
	rank_color = RANK_COLORS[mini(idx, RANK_COLORS.size() - 1)]
	rank_label.text = String(Phys.RANKS[idx][1]).to_upper()
	rank_label.label_settings.font_color = rank_color
	if idx + 1 < Phys.RANKS.size():
		var lo := float(Phys.RANKS[idx][0])
		var hi := float(Phys.RANKS[idx + 1][0])
		progress = clampf(log(maxf(m, 0.01) / maxf(lo, 0.01)) / log(hi / maxf(lo, 0.01)), 0.0, 1.0) if lo > 0.0 else clampf(m / hi, 0.0, 1.0)
	else:
		progress = 1.0


func reset_mass(m: float) -> void:
	_shown_mass = m


func notice(text: String, color := Color.WHITE, hold := 1.6) -> void:
	notice_label.text = text
	notice_label.label_settings.font_color = color
	if _notice_tween:
		_notice_tween.kill()
	notice_label.scale = Vector2(1.6, 1.6)
	notice_label.modulate.a = 1.0
	_notice_tween = create_tween()
	_notice_tween.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_notice_tween.tween_property(notice_label, "scale", Vector2.ONE, 0.35)
	_notice_tween.tween_interval(hold)
	_notice_tween.tween_property(notice_label, "modulate:a", 0.0, 0.6)


func show_game_over(title: String, body: String) -> void:
	over_title.text = title
	over_body.text = body
	over_hint.text = ""
	over_root.visible = true
	over_root.modulate.a = 0.0
	# Let the explosion play out before the panel fades in.
	var tw := create_tween()
	tw.tween_interval(0.7)
	tw.tween_property(over_root, "modulate:a", 1.0, 0.6)


func hide_game_over() -> void:
	over_root.visible = false


func tick(delta: float) -> void:
	_bump = maxf(0.0, _bump - delta * 3.0)
	mass_label.scale = Vector2.ONE * (1.0 + 0.18 * _bump)
	mass_label.label_settings.font_color = Color(1, 1, 1).lerp(Color(0.6, 1.4, 1.2), _bump)
	_hint_time += delta
	hint_label.modulate.a = clampf(1.0 - (_hint_time - 25.0) / 3.0, 0.0, 1.0)
	queue_redraw()


func show_hints() -> void:
	_hint_time = 0.0


func _draw() -> void:
	# Rank progress bar.
	var bar := Rect2(Vector2(30, 112), Vector2(240, 7))
	draw_rect(bar, Color(1, 1, 1, 0.12))
	var fill := bar
	fill.size.x *= progress
	draw_rect(fill, Color(rank_color.r * 1.3, rank_color.g * 1.3, rank_color.b * 1.3, 0.9))
	# Off-screen indicators.
	for ind in indicators:
		var p: Vector2 = ind["pos"]
		var c: Color = ind["color"]
		var s: float = ind["size"]
		var ang: float = ind["angle"]
		var fwd := Vector2.from_angle(ang)
		var side := fwd.orthogonal()
		var pts := PackedVector2Array([p + fwd * s, p - fwd * s * 0.6 + side * s * 0.7, p - fwd * s * 0.2, p - fwd * s * 0.6 - side * s * 0.7])
		draw_colored_polygon(pts, c)
