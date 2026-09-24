class_name WorldOverlay
extends Node2D
## World-space UI drawn with the canvas API: the player's comet trail, aim
## chevron, predicted trajectory, floating "+mass" numbers and the marker for
## the fragment you will be reborn as.

const TRAIL_LEN := 48

var zoom := 1.0
var time := 0.0

var trail: PackedVector2Array = PackedVector2Array()
var trail_color := Color(0.4, 1.0, 1.0)
var trail_width := 2.0

var player_visible := false
var player_pos := Vector2.ZERO
var player_r := 1.0
var aim := Vector2.RIGHT
var thrust_flash := 0.0
var can_thrust := true

var trajectory := PackedVector2Array()
var trajectory_hit := false
var trajectory_color := Color(0.5, 0.9, 1.0)

var candidate_visible := false
var candidate_pos := Vector2.ZERO
var candidate_r := 1.0

var _texts: Array[Dictionary] = []
var _font: Font


func _ready() -> void:
	_font = ThemeDB.fallback_font


func push_trail(p: Vector2) -> void:
	trail.append(p)
	if trail.size() > TRAIL_LEN:
		trail.remove_at(0)


func shift_trail(d: Vector2) -> void:
	for k in trail.size():
		trail[k] += d


func clear_trail() -> void:
	trail.clear()


## Floating number that rises and fades; `vel` lets it drift with its body.
func float_text(pos: Vector2, vel: Vector2, text: String, color: Color, scale := 1.0) -> void:
	_texts.append({"pos": pos, "vel": vel, "text": text, "color": color, "t": 0.0, "scale": scale})
	if _texts.size() > 40:
		_texts.pop_front()


## `time_scale` keeps floating texts glued to their bodies during slow motion.
func tick(delta: float, time_scale := 1.0) -> void:
	thrust_flash = maxf(0.0, thrust_flash - delta * 6.0)
	var keep: Array[Dictionary] = []
	for t in _texts:
		t["t"] = float(t["t"]) + delta
		var v: Vector2 = t["vel"]
		t["pos"] = (t["pos"] as Vector2) + v * delta * time_scale
		if float(t["t"]) < 1.4:
			keep.append(t)
	_texts = keep
	queue_redraw()


func _draw() -> void:
	var px := 1.0 / maxf(zoom, 1e-6)  # one screen pixel in world units

	# Comet trail.
	var nt := trail.size()
	if nt >= 2:
		var cols := PackedColorArray()
		cols.resize(nt)
		for k in nt:
			var f := float(k) / float(nt - 1)
			cols[k] = Color(trail_color.r * 1.6, trail_color.g * 1.6, trail_color.b * 1.6, f * f * 0.55)
		draw_polyline_colors(trail, cols, maxf(trail_width, 2.0 * px), true)

	# Predicted trajectory as fading dots.
	var ntr := trajectory.size()
	if ntr >= 2:
		for k in ntr:
			if k % 2 == 1:
				continue
			var f := 1.0 - float(k) / float(ntr)
			var c := trajectory_color
			c.a = 0.55 * f
			draw_circle(trajectory[k], 1.6 * px * (0.6 + f), c)
		if trajectory_hit:
			var e := trajectory[ntr - 1]
			var s := 7.0 * px
			var red := Color(1.0, 0.25, 0.2, 0.9)
			draw_line(e + Vector2(-s, -s), e + Vector2(s, s), red, 2.0 * px)
			draw_line(e + Vector2(-s, s), e + Vector2(s, -s), red, 2.0 * px)

	# Aim chevron around the player.
	if player_visible:
		var dist := player_r * 1.9 + 10.0 * px
		var tip := player_pos + aim * (dist + 9.0 * px)
		var side := aim.orthogonal() * 6.0 * px
		var back := player_pos + aim * dist
		var c := Color(0.7, 1.0, 1.0, 0.75) if can_thrust else Color(1.0, 0.4, 0.3, 0.6)
		c = c.lerp(Color(3.0, 2.4, 1.2, 1.0), thrust_flash)
		draw_polyline(PackedVector2Array([back + side, tip, back - side]), c, 2.0 * px, true)

	# Pulsing marker on the fragment you'll be reborn as.
	if candidate_visible:
		var pulse := 0.5 + 0.5 * sin(time * 6.0)
		var rr := candidate_r * 2.2 + (14.0 + 6.0 * pulse) * px
		draw_arc(candidate_pos, rr, 0.0, TAU, 48, Color(0.5, 1.0, 1.0, 0.5 + 0.4 * pulse), 2.0 * px, true)
		draw_arc(candidate_pos, rr * 1.6, time * 2.0, time * 2.0 + 1.2, 16, Color(0.5, 1.0, 1.0, 0.35), 1.5 * px, true)
		draw_arc(candidate_pos, rr * 1.6, time * 2.0 + PI, time * 2.0 + PI + 1.2, 16, Color(0.5, 1.0, 1.0, 0.35), 1.5 * px, true)

	# Floating texts (constant screen size).
	for t in _texts:
		var age: float = t["t"]
		var a := clampf(1.4 - age, 0.0, 1.0)
		var pop := 1.0 + 0.6 * exp(-age * 10.0)
		var sc: float = float(t["scale"]) * pop
		var pos: Vector2 = t["pos"]
		pos.y -= age * 40.0 * px
		var col: Color = t["color"]
		col.a = a
		draw_set_transform(pos, 0.0, Vector2(px, px) * sc)
		var text: String = t["text"]
		var fs := 22
		var w := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		draw_string_outline(_font, Vector2(-w * 0.5, 0.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 5, Color(0.0, 0.0, 0.0, a * 0.7))
		draw_string(_font, Vector2(-w * 0.5, 0.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
