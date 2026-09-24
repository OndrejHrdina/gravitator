extends Node2D
## Gravitator — wires the simulation to rendering, audio, input and game flow.
##
## The simulation runs at a fixed 60 Hz (with render interpolation) inside
## _process so that time can be dilated for hit-stop and slow motion.
##
## Command line (after `--`): --seed=N  --stars=N  --autoplay  --debug
##   --mass=N (start heavier)  --zoom=N (extra zoom-out)  --gallery (shader line-up)

const DT := 1.0 / 60.0
const MAX_STEPS_PER_FRAME := 3
const PLAYER_VIEW_RADII := 62.0  # view height in player radii
const TRAJECTORY_STEPS := 90

var universe: Universe
var camera: Camera2D
var bodies: BodyRenderer
var fx: FX
var overlay: WorldOverlay
var hud: Hud
var sfx: Sfx

var zoom := 3.0
var user_zoom := 1.0
var time_scale := 1.0
var paused := false
var show_trajectory := true
var show_debug := false
var autopilot := false

# Game flow / session stats.
var dead := false
var candidate_uid := -1
var peak_mass := 0.0
var best_mass := 0.0
var eaten := 0
var lives := 1

var _bg_mat: ShaderMaterial
var _post_mat: ShaderMaterial
var _acc := 0.0
var _slow_scale := 1.0
var _slow_hold := 0.0
var _shake := 0.0
var _zoom_punch := 0.0
var _flash := 0.0
var _flash_color := Color.WHITE
var _aberration := 0.0
var _desaturate := 0.0
var _waves: Array[Dictionary] = []
var _thrust_cd := 0.0
var _maintain_t := 0.0
var _real_time := 0.0
var _render_time := 0.0
var _view_rect := Rect2()
var _view_radius := 500.0
var _cam_target := Vector2.ZERO
var _dead_t := 0.0
var _life_start := 0.0
var _last_rank := 0
var _seed := 0
var _stars := 8
var _v_ref := Vector2.ZERO
var _ref_uid := -1
var _indicator_t := 0.0
var _warned_small := false
var _gallery := false
var _start_mass := 0.0


func _ready() -> void:
	_parse_args()
	_setup_input()
	_build_scene()
	_new_universe()


func _parse_args() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seed="):
			_seed = int(a.get_slice("=", 1))
		elif a.begins_with("--stars="):
			_stars = clampi(int(a.get_slice("=", 1)), 1, 24)
		elif a == "--autoplay":
			autopilot = true
		elif a == "--debug":
			show_debug = true
		elif a.begins_with("--mass="):
			_start_mass = maxf(0.3, float(a.get_slice("=", 1)))
		elif a == "--gallery":
			_gallery = true
		elif a.begins_with("--zoom="):
			user_zoom = clampf(float(a.get_slice("=", 1)), 0.3, 400.0)


func _setup_input() -> void:
	_bind("thrust", [KEY_SPACE])
	var mb := InputEventMouseButton.new()
	mb.button_index = MOUSE_BUTTON_LEFT
	InputMap.action_add_event("thrust", mb)
	_bind("toggle_trajectory", [KEY_T])
	_bind("pause", [KEY_P, KEY_ESCAPE])
	_bind("restart", [KEY_R])
	_bind("help", [KEY_H, KEY_F1])
	_bind("debug", [KEY_F3])
	_bind("autopilot", [KEY_F8])
	_bind("zoom_in", [KEY_EQUAL, KEY_KP_ADD])
	_bind("zoom_out", [KEY_MINUS, KEY_KP_SUBTRACT])


func _bind(action: StringName, keys: Array) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	for k in keys:
		var ev := InputEventKey.new()
		ev.physical_keycode = k
		InputMap.action_add_event(action, ev)


func _build_scene() -> void:
	var bg_layer := CanvasLayer.new()
	bg_layer.layer = -10
	add_child(bg_layer)
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bg_mat = ShaderMaterial.new()
	_bg_mat.shader = preload("res://shaders/background.gdshader")
	bg.material = _bg_mat
	bg_layer.add_child(bg)

	bodies = BodyRenderer.new()
	add_child(bodies)
	fx = FX.new()
	add_child(fx)
	overlay = WorldOverlay.new()
	add_child(overlay)

	camera = Camera2D.new()
	add_child(camera)
	camera.make_current()

	# HDR bloom makes everything above 1.0 glow.
	var env := Environment.new()
	env.background_mode = Environment.BG_CANVAS
	env.glow_enabled = true
	env.glow_intensity = 0.75
	env.glow_strength = 1.0
	env.glow_bloom = 0.0
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	env.glow_hdr_threshold = 1.0
	env.glow_hdr_scale = 2.0
	for lvl in 7:
		env.set_glow_level(lvl, [0.4, 0.8, 0.9, 0.6, 0.3, 0.12, 0.0][lvl])
	# Linear keeps colours saturated; highlights clip to white-hot and bloom.
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var post_layer := CanvasLayer.new()
	post_layer.layer = 5
	add_child(post_layer)
	var post := ColorRect.new()
	post.set_anchors_preset(Control.PRESET_FULL_RECT)
	post.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_post_mat = ShaderMaterial.new()
	_post_mat.shader = preload("res://shaders/post.gdshader")
	post.material = _post_mat
	post_layer.add_child(post)

	var hud_layer := CanvasLayer.new()
	hud_layer.layer = 10
	add_child(hud_layer)
	hud = Hud.new()
	hud_layer.add_child(hud)
	hud.debug_label.visible = show_debug

	sfx = Sfx.new()
	add_child(sfx)


func _new_universe() -> void:
	universe = Universe.new(_seed)
	_seed = 0  # restarts get a fresh universe
	if _gallery:
		_make_gallery()
	else:
		UniverseGenerator.generate(universe, _stars)
	if _start_mass > 0.0:
		# Debug: skip ahead to a bigger player.
		universe.mass[universe.player] = _start_mass
		universe.rad[universe.player] = Phys.radius(_start_mass)
	dead = false
	candidate_uid = -1
	hud.hide_game_over()
	var p := universe.player
	peak_mass = universe.mass[p]
	eaten = 0
	lives = 1
	_life_start = 0.0
	_last_rank = Phys.rank_index(peak_mass)
	_cam_target = universe.player_pos()
	zoom = _target_zoom(universe.rad[p])
	time_scale = 1.0
	_slow_hold = 0.0
	_acc = 0.0
	_ref_uid = -1
	overlay.clear_trail()
	hud.reset_mass(peak_mass)
	hud.show_hints()
	hud.notice("EAT  ·  GROW  ·  IGNITE", Color(0.6, 1.0, 1.0), 2.5)


## Debug line-up of bodies across the mass and heat range (--gallery).
func _make_gallery() -> void:
	var u := universe
	u.add_body(Vector2(-3000, -2600), Vector2.ZERO, 3.0e7, Color(1.0, 0.55, 0.2), 3.0)
	u.add_body(Vector2(4200, -2600), Vector2.ZERO, 1.2e8, Color(0.4, 0.6, 1.0), 4.5)
	var masses := [1.0, 20.0, 400.0, 8000.0, 1.5e5, 1.0e6]
	var x := -1200.0
	for k in masses.size():
		var m: float = masses[k]
		var r := Phys.radius(m)
		x += r * 2.2
		for row in 3:
			var c := Color.from_hsv(float(k) / 6.0 + row * 0.3, 0.75, 0.9)
			u.add_body(Vector2(x, float(row) * 700.0 - 400.0), Vector2.ZERO, m, c, [0.0, 0.9, 2.5][row])
		x += r * 2.2 + 80.0
	u.set_player(u.add_body(Vector2(-1500, -400), Vector2.ZERO, 3.0, UniverseGenerator.PLAYER_COLOR), 1e9)


# --- Frame loop -----------------------------------------------------------------------

func _process(delta: float) -> void:
	delta = minf(delta, 0.1)
	_real_time += delta
	if not paused:
		_update_time_scale(delta)
		_player_input(delta)
		_acc += delta * time_scale
		var steps := 0
		while _acc >= DT and steps < MAX_STEPS_PER_FRAME:
			# Precision is centred on the player and scales with its size (not
			# with how far you zoom out).
			if universe.player >= 0:
				universe.focus = universe.player_pos()
				universe.focus_radius = maxf(universe.rad[universe.player] * 32.0, 150.0)
			else:
				universe.focus = _cam_target
				universe.focus_radius = 200.0
			universe.step(DT)
			_handle_events()
			_acc -= DT
			steps += 1
		if _acc > DT:
			_acc = DT  # can't keep up: let time dilate rather than spiral
		_maintain_t += delta * time_scale
		if _maintain_t > 2.0:
			_maintain_t = 0.0
			universe.maintain(_view_radius)
		if dead:
			_dead_t += delta
	var alpha := clampf(_acc / DT, 0.0, 1.0)
	_render_time = universe.time - DT + _acc
	_update_camera(delta, alpha)
	_update_render(delta, alpha)
	_update_hud(delta)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		var mbe := event as InputEventMouseButton
		if mbe.button_index == MOUSE_BUTTON_WHEEL_UP:
			user_zoom = clampf(user_zoom / 1.15, 0.3, 200.0)
		elif mbe.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			user_zoom = clampf(user_zoom * 1.15, 0.3, 200.0)
	if event.is_action_pressed("zoom_in"):
		user_zoom = clampf(user_zoom / 1.3, 0.3, 200.0)
	elif event.is_action_pressed("zoom_out"):
		user_zoom = clampf(user_zoom * 1.3, 0.3, 200.0)
	elif event.is_action_pressed("toggle_trajectory"):
		show_trajectory = not show_trajectory
	elif event.is_action_pressed("pause"):
		paused = not paused
		hud.notice("PAUSED" if paused else "", Color(0.8, 0.9, 1.0), 9999.0 if paused else 0.1)
	elif event.is_action_pressed("restart"):
		_new_universe()
	elif event.is_action_pressed("help"):
		hud.show_hints()
	elif event.is_action_pressed("debug"):
		show_debug = not show_debug
		hud.debug_label.visible = show_debug
	elif event.is_action_pressed("autopilot"):
		autopilot = not autopilot
		hud.notice("AUTOPILOT " + ("ON" if autopilot else "OFF"), Color(0.7, 0.9, 1.0), 0.8)


func _update_time_scale(delta: float) -> void:
	if _slow_hold > 0.0:
		_slow_hold -= delta
		time_scale = lerpf(time_scale, _slow_scale, 1.0 - exp(-delta * 25.0))
	else:
		time_scale = lerpf(time_scale, 1.0, 1.0 - exp(-delta * 3.5))
		if time_scale > 0.995:
			time_scale = 1.0


## Hit-stop / slow motion: drop to `factor` for `hold` real seconds.
func _dip_time(factor: float, hold: float) -> void:
	if factor <= _slow_scale or _slow_hold <= 0.0:
		_slow_scale = factor
	_slow_hold = maxf(_slow_hold, hold)


func _player_input(delta: float) -> void:
	_thrust_cd -= delta * time_scale
	if dead:
		if _dead_t > 1.2 and (Input.is_action_just_pressed("thrust") or (autopilot and _dead_t > 3.0)):
			_respawn()
		return
	var p := universe.player
	if p < 0:
		return
	var ppos := _interp(p, clampf(_acc / DT, 0.0, 1.0))
	var aim := get_global_mouse_position() - ppos
	var want := Input.is_action_pressed("thrust")
	var just := Input.is_action_just_pressed("thrust")
	if autopilot:
		var ap := _autopilot_decide()
		aim = ap[0]
		want = ap[1]
		just = false
	if aim.length_squared() < 1e-6:
		aim = Vector2.RIGHT
	aim = aim.normalized()
	overlay.aim = aim
	overlay.can_thrust = universe.mass[p] >= Phys.MIN_THRUST_MASS
	if (want and _thrust_cd <= 0.0) or (just and _thrust_cd <= Phys.THRUST_INTERVAL * 0.5):
		if universe.thrust(aim):
			# The autopilot paces itself: every burst costs mass.
			_thrust_cd = Phys.THRUST_INTERVAL * (2.5 if autopilot else 1.0)
			overlay.thrust_flash = 1.0
			_handle_events()
		elif not _warned_small:
			_warned_small = true
			hud.notice("TOO SMALL TO THRUST — EAT SOMETHING", Color(1.0, 0.5, 0.4), 1.5)


func _interp(i: int, alpha: float) -> Vector2:
	return Vector2(lerpf(universe.ppx[i], universe.px[i], alpha), lerpf(universe.ppy[i], universe.py[i], alpha))


func _target_zoom(player_r: float) -> float:
	var vh := get_viewport_rect().size.y
	var view_h := clampf(player_r * PLAYER_VIEW_RADII, 180.0, 6.0e5) * user_zoom
	return vh / view_h


func _update_camera(delta: float, alpha: float) -> void:
	var pr := 4.0
	if not dead and universe.player >= 0:
		var p := universe.player
		_cam_target = _interp(p, alpha)
		pr = universe.rad[p]
	elif dead:
		var ci := universe.find_by_uid(candidate_uid)
		if ci >= 0:
			pr = maxf(universe.rad[ci], 3.0)
			if _dead_t > 0.5:
				var k := 1.0 - exp(-delta * 4.0)
				_cam_target = _cam_target.lerp(_interp(ci, alpha), k)
		else:
			pr = 6.0
	var tz := _target_zoom(pr)
	# Ease out slowly so you get to see yourself swell after a big meal.
	var rate := (1.1 if tz < zoom else 2.5) if not dead else 1.2
	zoom = exp(lerpf(log(zoom), log(tz), 1.0 - exp(-delta * rate)))
	_zoom_punch = lerpf(_zoom_punch, 0.0, 1.0 - exp(-delta * 7.0))
	camera.zoom = Vector2.ONE * zoom * (1.0 + _zoom_punch)
	_shake = maxf(0.0, _shake - delta * 1.6)
	var s := _shake * _shake * 26.0
	var t := _real_time
	var off := Vector2(sin(t * 47.0) + sin(t * 31.0 + 1.3), cos(t * 43.0) + sin(t * 29.0 + 0.7)) * 0.5 * s
	camera.position = _cam_target + off / camera.zoom.x
	var vs := get_viewport_rect().size / camera.zoom
	_view_rect = Rect2(camera.position - vs * 0.5, vs)
	_view_radius = vs.length() * 0.5


func _update_render(delta: float, alpha: float) -> void:
	var z := camera.zoom.x
	bodies.refresh(universe, alpha, _view_rect.grow(_view_radius * 0.05), z, _render_time)
	fx.set_time(_render_time, z)

	# Reference frame for trail & trajectory (what you move relative to).
	overlay.zoom = z
	overlay.time = _real_time
	var p := universe.player
	overlay.player_visible = p >= 0 and not dead
	overlay.candidate_visible = false
	if p >= 0 and not dead:
		var pp := _interp(p, alpha)
		overlay.player_pos = pp
		overlay.player_r = universe.rad[p]
		overlay.trail_color = universe.col[p]
		overlay.trail_width = universe.rad[p] * 0.8
		_update_reference(p, delta, alpha)
		# The trail lives in the reference frame: old points ride along with it.
		overlay.shift_trail(_v_ref * delta * time_scale)
		overlay.push_trail(pp)
		if show_trajectory:
			_predict_trajectory(p, alpha)
		else:
			overlay.trajectory = PackedVector2Array()
	else:
		overlay.trajectory = PackedVector2Array()
		overlay.clear_trail()
		if dead and _dead_t > 0.4:
			var ci := universe.find_by_uid(candidate_uid)
			if ci >= 0:
				overlay.candidate_visible = true
				overlay.candidate_pos = _interp(ci, alpha)
				overlay.candidate_r = universe.rad[ci]
	overlay.tick(delta, time_scale)

	var vp := get_viewport_rect().size
	_bg_mat.set_shader_parameter("u_cam", camera.position)
	_bg_mat.set_shader_parameter("u_zoom", z)
	_bg_mat.set_shader_parameter("u_time", _real_time)
	_bg_mat.set_shader_parameter("u_view", vp)

	# Post-processing juice.
	_flash = maxf(0.0, _flash - delta * 3.0)
	_aberration = maxf(0.0, _aberration - delta * 2.5)
	_desaturate = lerpf(_desaturate, 0.55 if dead and _dead_t < 1.4 else 0.0, 1.0 - exp(-delta * 4.0))
	var waves := PackedVector4Array()
	var keep: Array[Dictionary] = []
	for w in _waves:
		w["t"] = float(w["t"]) + delta
		var wt: float = w["t"]
		var life: float = w["life"]
		if wt >= life:
			continue
		keep.append(w)
		var wp: Vector2 = w["pos"]
		var uv := ((wp - camera.position) * z + vp * 0.5) / vp
		var radius := wt * float(w["speed"])
		waves.append(Vector4(uv.x, uv.y, radius, float(w["s"]) * pow(1.0 - wt / life, 1.5)))
	_waves = keep
	_post_mat.set_shader_parameter("u_wave_count", waves.size())
	if waves.size() > 0:
		while waves.size() < 8:
			waves.append(Vector4.ZERO)
		_post_mat.set_shader_parameter("u_waves", waves)
	_post_mat.set_shader_parameter("u_aberration", _aberration)
	_post_mat.set_shader_parameter("u_flash", _flash)
	_post_mat.set_shader_parameter("u_flash_color", Vector3(_flash_color.r, _flash_color.g, _flash_color.b))
	_post_mat.set_shader_parameter("u_desaturate", _desaturate)


## Picks the frame the player cares about: the dominant attractor when one is
## close by (orbiting a planet), otherwise the local flow of nearby rocks.
func _update_reference(p: int, delta: float, _alpha: float) -> void:
	var u := universe
	var x := u.px[p]
	var y := u.py[p]
	var pm := u.mass[p]
	var best := -1
	var best_a := 0.0
	var flow := Vector2.ZERO
	var wsum := 0.0
	var r2 := _view_radius * _view_radius * 2.25
	for i in u.n:
		if i == p:
			continue
		var dx := u.px[i] - x
		var dy := u.py[i] - y
		var d2 := dx * dx + dy * dy + 1.0
		var m := u.mass[i]
		if m > pm:
			var a := m / d2
			if a > best_a:
				best_a = a
				best = i
		if d2 < r2 and (u.flags[i] & Universe.FLAG_EXHAUST) == 0:
			var w := sqrt(m)
			flow += Vector2(u.vx[i], u.vy[i]) * w
			wsum += w
	var target := Vector2(u.vx[p], u.vy[p])
	var uid_ref := -1
	if best >= 0:
		var d := Vector2(u.px[best] - x, u.py[best] - y).length()
		if d < _view_radius * 3.0 or wsum <= 0.0:
			target = Vector2(u.vx[best], u.vy[best])
			uid_ref = u.uid[best]
	if uid_ref < 0 and wsum > 0.0:
		target = flow / wsum
	if uid_ref != _ref_uid:
		_ref_uid = uid_ref
	_v_ref = _v_ref.lerp(target, 1.0 - exp(-delta * 5.0))


func _predict_trajectory(p: int, alpha: float) -> void:
	var u := universe
	var pts := PackedVector2Array()
	var pos := _interp(p, alpha)
	var vel := Vector2(u.vx[p], u.vy[p])
	var ref := u.find_by_uid(_ref_uid) if _ref_uid >= 0 else -1
	overlay.trajectory_hit = false
	overlay.trajectory_color = u.col[p].lerp(Color(0.7, 1.0, 1.0), 0.5)
	if ref < 0:
		# Drift relative to the local swarm: a straight line.
		var rv := vel - _v_ref
		var horizon := clampf(_view_radius * 0.9 / maxf(rv.length(), 1.0), 1.0, 8.0)
		for k in TRAJECTORY_STEPS:
			pts.append(pos + rv * horizon * float(k) / float(TRAJECTORY_STEPS - 1))
		overlay.trajectory = pts
		return
	# Orbit around the dominant body, including the next strongest attractors.
	var rpos := _interp(ref, alpha)
	var rvel := Vector2(u.vx[ref], u.vy[ref])
	var srcs: Array[Vector4] = []   # rel pos xy, rel vel xy
	var sm := PackedFloat64Array()
	var sr := PackedFloat64Array()
	srcs.append(Vector4.ZERO)
	sm.append(u.mass[ref])
	sr.append(u.rad[ref])
	# The three next-strongest pulls (linear scan, no sorting).
	var top := [-1, -1, -1]
	var top_a := [0.0, 0.0, 0.0]
	var pm := u.mass[p]
	for i in u.n:
		if i == p or i == ref or u.mass[i] < pm:
			continue
		var a := u.mass[i] / ((u.px[i] - pos.x) ** 2 + (u.py[i] - pos.y) ** 2 + 1.0)
		if a <= top_a[2]:
			continue
		var slot := 2
		while slot > 0 and a > top_a[slot - 1]:
			top_a[slot] = top_a[slot - 1]
			top[slot] = top[slot - 1]
			slot -= 1
		top_a[slot] = a
		top[slot] = i
	for k in 3:
		var i: int = top[k]
		if i < 0:
			break
		srcs.append(Vector4(u.px[i] - rpos.x, u.py[i] - rpos.y, u.vx[i] - rvel.x, u.vy[i] - rvel.y))
		sm.append(u.mass[i])
		sr.append(u.rad[i])
	var rp := pos - rpos
	var rv := vel - rvel
	var d0 := rp.length()
	var period := TAU * sqrt(d0 * d0 * d0 / (Phys.G * u.mass[ref]))
	var horizon := clampf(period * 0.3, 2.0, 60.0)
	var h := horizon / float(TRAJECTORY_STEPS)
	var pr := u.rad[p]
	var t := 0.0
	for k in TRAJECTORY_STEPS:
		var acc := Vector2.ZERO
		for s in srcs.size():
			var sp := Vector2(srcs[s].x + srcs[s].z * t, srcs[s].y + srcs[s].w * t)
			var dd := sp - rp
			var dl2 := dd.length_squared()
			if dl2 < (sr[s] + pr) * (sr[s] + pr):
				overlay.trajectory_hit = true
				break
			acc += dd * (Phys.G * sm[s] / (dl2 * sqrt(dl2)))
			if s > 0:
				# The reference body is pulled too: subtract to stay in its frame.
				var ds2 := sp.length_squared() + 1.0
				acc -= sp * (Phys.G * sm[s] / (ds2 * sqrt(ds2)))
		if overlay.trajectory_hit:
			break
		rv += acc * h
		rp += rv * h
		t += h
		pts.append(rpos + rp)
	overlay.trajectory = pts


# --- Events → juice --------------------------------------------------------------------

## 0 when far off-screen, 1 when on screen.
func _vis(pos: Vector2, r: float) -> float:
	var d := pos.distance_to(camera.position) - r
	return clampf(1.6 - d / _view_radius, 0.0, 1.0)


func _vol(pos: Vector2, base_db: float) -> float:
	var d := pos.distance_to(camera.position) / maxf(_view_radius, 1.0)
	return base_db - 14.0 * maxf(0.0, d - 0.7)


func _add_wave(pos: Vector2, strength: float, speed := 0.9, life := 0.9) -> void:
	if _waves.size() >= 8:
		_waves.pop_front()
	_waves.append({"pos": pos, "t": 0.0, "s": strength, "speed": speed, "life": life})


## How big an event is on screen (radius in screen heights).
func _screen_size(r: float) -> float:
	return r * camera.zoom.x / get_viewport_rect().size.y


func _handle_events() -> void:
	for ev in universe.events:
		match int(ev["type"]):
			Universe.Ev.MERGE:
				_fx_merge(ev)
			Universe.Ev.SHATTER:
				_fx_shatter(ev)
			Universe.Ev.CATASTROPHE:
				_fx_catastrophe(ev)
			Universe.Ev.IGNITE:
				_fx_ignite(ev)
			Universe.Ev.THRUST:
				_fx_thrust(ev)
			Universe.Ev.DEATH:
				_on_death(ev)
			Universe.Ev.EVAPORATE:
				_fx_evaporate(ev)
	universe.events.clear()


func _fx_merge(ev: Dictionary) -> void:
	var pos := Vector2(ev["x"], ev["y"])
	var rb: float = ev["r_big"]
	var vis := _vis(pos, rb)
	var role: int = ev["role"]
	if vis <= 0.0 and role == 0:
		return
	var rs: float = ev["r_small"]
	var ms: float = ev["m_small"]
	var m: float = ev["m"]
	var ratio := ms / m
	var carrier := Vector2(ev["vx"], ev["vy"])
	var nrm := Vector2(ev["nx"], ev["ny"])
	var cs: Color = ev["color"]
	var cb: Color = ev["color_big"]
	var vrel: float = ev["vrel"]
	var tang := nrm.orthogonal()
	var count := int(clampf(8.0 + ratio * 120.0 + vrel * 0.1, 8.0, 70.0))
	var spd := rs * 4.0 + vrel * 0.35
	fx.burst(pos, carrier, cs, count / 3.0, spd * 0.4, spd, rs * 0.35, 0.55, tang, 0.45, 3.0, 1.3)
	fx.burst(pos, carrier, cs, count / 3.0, spd * 0.4, spd, rs * 0.35, 0.55, -tang, 0.45, 3.0, 1.3)
	fx.burst(pos, carrier, cs.lerp(Color.WHITE, 0.3), count / 3.0, spd * 0.3, spd * 0.8, rs * 0.3, 0.4, nrm, 0.8, 3.5, 1.6)
	fx.ring(pos, carrier, rs * 2.5, cs, 0.3, FX.Ring.FLASH, 0.1, 0.4 + ratio * 1.5)
	var bpos := Vector2(ev["bx"], ev["by"])
	if role == 1:
		eaten += 1
		fx.ring(bpos, carrier, rb * 2.0, cs, 0.45, FX.Ring.IMPLODE, 0.07, 1.4 + ratio * 4.0)
		fx.ring(bpos, carrier, rb * (2.2 + ratio * 4.0), cb, 0.55, FX.Ring.SHOCKWAVE, 0.05, 0.5 + ratio * 4.0)
		var txt_col := Color(cs.r * 0.8 + 0.35, cs.g * 0.8 + 0.35, cs.b * 0.8 + 0.35)
		var above := bpos + Vector2(0.0, -rb * 1.6 - 14.0 / camera.zoom.x)
		overlay.float_text(above, carrier, "+" + Phys.format_mass(ms), txt_col, 0.75 + minf(ratio * 2.0, 0.7))
		sfx.play("pop", clampf(-9.0 + sqrt(ratio) * 16.0, -9.0, 3.0), clampf(1.65 - ratio * 2.6, 0.55, 1.65), 15)
		if ratio > 0.08:
			sfx.play("gulp", clampf(-8.0 + ratio * 20.0, -8.0, 2.0), clampf(1.3 - ratio, 0.6, 1.3))
			_add_wave(bpos, clampf(ratio * 2.0, 0.1, 0.8), 0.7, 0.6)
		_zoom_punch += 0.015 + ratio * 0.3
		_shake = minf(1.0, _shake + ratio * 0.9)
		if ratio > 0.25:
			_dip_time(0.3, 0.12)
	elif role == 0:
		var loud := clampf(-22.0 + log(1.0 + float(ev["e"])) * 1.2, -30.0, -4.0)
		sfx.play("thud", _vol(pos, loud), clampf(2.0 - log(rb + 1.0) * 0.3, 0.4, 1.8), 60)


func _fx_shatter(ev: Dictionary) -> void:
	var pos := Vector2(ev["x"], ev["y"])
	var rs: float = ev["r_small"]
	var rb: float = ev["r_big"]
	var vis := _vis(pos, rb)
	var role: int = ev["role"]
	if vis <= 0.0 and role == 0:
		return
	var carrier := Vector2(ev["vx"], ev["vy"])
	var nrm := Vector2(ev["nx"], ev["ny"])
	var cs: Color = ev["color"]
	var vrel: float = ev["vrel"]
	var nf: int = ev["n_frag"]
	var count := int(clampf(24.0 + nf * 10.0 + vrel * 0.1, 24.0, 160.0))
	fx.burst(pos, carrier, cs, count, vrel * 0.2 + rs * 3.0, vrel * 0.8 + rs * 10.0, rs * 0.4, 0.8, nrm, 1.3, 2.2, 1.1, rs)
	fx.burst(pos, carrier, cs.darkened(0.2), count / 3.0, vrel * 0.1, vrel * 0.4 + rs * 4.0, rs * 0.7, 1.4, nrm, 1.1, 1.2, 0.6)
	fx.ring(pos, carrier, rs * 4.0, Color(1.0, 0.8, 0.5), 0.3, FX.Ring.FLASH, 0.1, 1.1)
	fx.ring(pos, carrier, rs * 9.0 + rb * 0.4, cs, 0.6, FX.Ring.SHOCKWAVE, 0.05, 1.3)
	var ss := _screen_size(rs * 6.0)
	sfx.play("crack", _vol(pos, clampf(-14.0 + ss * 60.0 + (6.0 if role != 0 else 0.0), -18.0, 2.0)), clampf(1.6 - log(rs + 1.0) * 0.3, 0.5, 1.6), 40)
	if ss > 0.02 or role != 0:
		_add_wave(pos, clampf(ss * 6.0, 0.15, 0.9))
		_shake = minf(1.0, _shake + clampf(ss * 4.0, 0.05, 0.5) * vis)
		_aberration = minf(1.0, _aberration + 0.3 * vis)
	if role == 1:
		eaten += 1
		var gain: float = ev["absorbed"]
		var above := Vector2(ev["bx"], ev["by"]) + Vector2(0.0, -rb * 1.6 - 14.0 / camera.zoom.x)
		overlay.float_text(above, carrier, "+" + Phys.format_mass(gain), Color(1.0, 0.85, 0.55), 0.9)
		overlay.float_text(above + Vector2(0.0, -26.0 / camera.zoom.x), carrier, "CRUNCH!", Color(1.0, 0.55, 0.3), 0.7)
		_dip_time(0.35, 0.1)


func _fx_catastrophe(ev: Dictionary) -> void:
	var pos := Vector2(ev["x"], ev["y"])
	var r: float = ev["r"]
	var vis := _vis(pos, r * 3.0)
	var role: int = ev["role"]
	if vis <= 0.0 and role == 0:
		return
	var carrier := Vector2(ev["vx"], ev["vy"])
	var ca: Color = ev["color_a"]
	var cb: Color = ev["color_b"]
	var count := int(clampf(80.0 + float(ev["n_frag"]) * 12.0, 80.0, 300.0))
	fx.burst(pos, carrier, ca, count / 2.0, r * 2.0, r * 14.0, r * 0.25, 1.1, Vector2.ZERO, PI, 1.5, 1.4, r)
	fx.burst(pos, carrier, cb, count / 2.0, r * 2.0, r * 14.0, r * 0.25, 1.1, Vector2.ZERO, PI, 1.5, 1.4, r)
	fx.burst(pos, carrier, Color(1.0, 0.9, 0.7), count / 3.0, r * 6.0, r * 22.0, r * 0.15, 0.6, Vector2.ZERO, PI, 2.5, 1.5)
	fx.ring(pos, carrier, r * 4.0, Color(1.0, 0.9, 0.75), 0.45, FX.Ring.FLASH, 0.1, 1.3)
	fx.ring(pos, carrier, r * 14.0, ca, 1.0, FX.Ring.SHOCKWAVE, 0.04, 2.0)
	fx.ring(pos, carrier, r * 22.0, cb, 1.5, FX.Ring.SHOCKWAVE, 0.03, 1.2)
	var ss := _screen_size(r)
	sfx.play("boom", _vol(pos, clampf(-10.0 + ss * 80.0, -14.0, 4.0)), clampf(1.3 - log(r + 1.0) * 0.12, 0.5, 1.3), 80)
	sfx.play("crack", _vol(pos, -6.0), 0.8, 40)
	_add_wave(pos, clampf(ss * 10.0, 0.3, 1.2) * vis, 1.0, 1.1)
	_shake = minf(1.0, _shake + clampf(ss * 8.0, 0.2, 0.9) * vis)
	_aberration = minf(1.2, _aberration + 0.8 * vis)
	_flash = minf(0.6, _flash + clampf(ss * 2.0, 0.05, 0.4) * vis)
	_flash_color = Color(1.0, 0.8, 0.6)
	if vis > 0.3 and ss > 0.01:
		_dip_time(0.3, 0.3)


func _fx_ignite(ev: Dictionary) -> void:
	var pos := Vector2(ev["x"], ev["y"])
	var r: float = ev["r"]
	var carrier := Vector2(ev["vx"], ev["vy"])
	var c: Color = ev["color"]
	var is_player: bool = ev["is_player"]
	var vis := _vis(pos, r * 6.0)
	if vis > 0.0 or is_player:
		fx.ring(pos, carrier, r * 5.0, Color(1.0, 0.9, 0.6), 2.5, FX.Ring.IGNITE, 0.05, 3.0)
		fx.ring(pos, carrier, r * 3.0, Color.WHITE, 0.8, FX.Ring.FLASH, 0.1, 4.0)
		fx.ring(pos, carrier, r * 12.0, c, 2.0, FX.Ring.SHOCKWAVE, 0.03, 2.5)
		fx.burst(pos, carrier, Color(1.0, 0.85, 0.5), 200, r * 1.0, r * 8.0, r * 0.08, 1.8, Vector2.ZERO, PI, 1.0, 2.5)
		sfx.play("ignite", 0.0, 1.0, 500)
		_add_wave(pos, 1.2, 0.8, 1.6)
		_flash = 0.3
		_flash_color = Color(1.0, 0.85, 0.55)
		_shake = 1.0
		_dip_time(0.25, 0.6)
	if is_player:
		# This *is* the rank-up; don't let the generic notice overwrite it.
		_last_rank = Phys.rank_index(float(ev["m"]))
		hud.notice("IGNITION!  YOU ARE A STAR", Color(1.0, 0.9, 0.5), 3.0)
	elif vis > 0.0:
		hud.notice("A STAR IS BORN", Color(1.0, 0.9, 0.6), 2.0)


func _fx_thrust(ev: Dictionary) -> void:
	var pos := Vector2(ev["x"], ev["y"])
	var dir := Vector2(ev["dx"], ev["dy"])
	var r: float = ev["r"]
	var c: Color = ev["color"]
	var carrier := Vector2(ev["vx"], ev["vy"])
	var hot := c.lerp(Color(1.0, 0.7, 0.3), 0.5)
	fx.burst(pos, carrier, hot, 22, Phys.EXHAUST_SPEED * 0.25, Phys.EXHAUST_SPEED * 0.8, r * 0.28, 0.45, dir, 0.32, 3.5, 1.8)
	fx.burst(pos, carrier, c, 10, Phys.EXHAUST_SPEED * 0.05, Phys.EXHAUST_SPEED * 0.3, r * 0.45, 0.7, dir, 0.7, 2.5, 0.8)
	fx.ring(pos, carrier, r * 2.2, hot, 0.22, FX.Ring.FLASH, 0.1, 1.2)
	fx.ring(pos - dir * r, carrier, r * 3.5, c, 0.35, FX.Ring.SHOCKWAVE, 0.06, 0.6)
	sfx.play("whoosh", -7.0, clampf(1.5 - log(r + 1.0) * 0.12, 0.6, 1.5), 30)
	_shake = minf(1.0, _shake + 0.08)
	_aberration = minf(1.0, _aberration + 0.12)
	_zoom_punch -= 0.012


func _fx_evaporate(ev: Dictionary) -> void:
	var pos := Vector2(ev["x"], ev["y"])
	var r: float = ev["r"]
	if _vis(pos, r) <= 0.0:
		return
	fx.burst(pos, Vector2(ev["vx"], ev["vy"]), ev["color"], 6, r * 2.0, r * 6.0, r * 0.4, 0.6, Vector2.ZERO, PI, 2.0, 0.8)


# --- Death & rebirth ----------------------------------------------------------------------

func _on_death(ev: Dictionary) -> void:
	dead = true
	_dead_t = 0.0
	candidate_uid = int(ev["candidate_uid"])
	var pos := Vector2(ev["x"], ev["y"])
	best_mass = maxf(best_mass, peak_mass)
	_dip_time(0.12, 1.3)
	_shake = 1.0
	_flash = 0.55
	_flash_color = Color(1.0, 0.35, 0.15)
	_aberration = 1.5
	_add_wave(pos, 1.3, 0.8, 1.4)
	sfx.play("boom", -3.0, 0.9, 0)
	sfx.play("crack", -6.0, 0.7, 0)
	var vel := Vector2(ev["vx"], ev["vy"])
	var r: float = ev["r"]
	var c: Color = ev["color"]
	fx.burst(pos, vel, c, 60, r * 8.0, r * 45.0, r * 0.3, 1.3, Vector2.ZERO, PI, 1.6, 0.9, r * 1.5)
	fx.burst(pos, vel, Color(1.0, 0.55, 0.3), 30, r * 5.0, r * 25.0, r * 0.2, 0.9, Vector2.ZERO, PI, 2.0, 0.8, r)
	fx.ring(pos, vel, r * 14.0, c, 1.2, FX.Ring.SHOCKWAVE, 0.04, 1.6)
	var cause: String = ev["cause"]
	var title := "SHATTERED" if cause == "SHATTERED" else "CONSUMED"
	var why := "The impact overcame your structural integrity." if cause == "SHATTERED" else "You touched something bigger (%s) and it swallowed you." % Phys.format_mass(float(ev["killer_mass"]))
	var survived := universe.time - _life_start
	var body := "%s\n\nPeak mass  %s  (%s)\nRocks eaten  %d     Survived  %d:%02d\nBest ever  %s" % [
		why, Phys.format_mass(peak_mass), Phys.rank_name(peak_mass), eaten,
		floori(survived / 60.0), int(survived) % 60, Phys.format_mass(best_mass)]
	hud.show_game_over(title, body)


func _respawn() -> void:
	var idx := universe.find_by_uid(candidate_uid)
	if idx < 0:
		idx = _nearest_small_body(_cam_target)
	if idx < 0:
		idx = universe.add_body(_cam_target, _v_ref, 1.0, UniverseGenerator.PLAYER_COLOR)
	if idx < 0:
		return
	universe.set_player(idx, Phys.RESPAWN_GRACE)
	_thrust_cd = 0.35  # the key press that brought you back shouldn't fire
	dead = false
	candidate_uid = -1
	lives += 1
	eaten = 0
	peak_mass = universe.mass[idx]
	_life_start = universe.time
	_last_rank = Phys.rank_index(peak_mass)
	_warned_small = false
	hud.hide_game_over()
	hud.reset_mass(peak_mass)
	hud.notice("REBORN AS A FRAGMENT", Color(0.5, 1.0, 1.0), 1.5)
	var pos := universe.player_pos()
	var vel := Vector2(universe.vx[idx], universe.vy[idx])
	fx.ring(pos, vel, universe.rad[idx] * 8.0, Color(0.5, 1.0, 1.0), 0.8, FX.Ring.SHOCKWAVE, 0.05, 2.0)
	fx.ring(pos, vel, universe.rad[idx] * 4.0, Color(0.5, 1.0, 1.0), 0.5, FX.Ring.FLASH, 0.1, 2.0)
	sfx.play("rankup", -4.0, 0.8, 0)
	overlay.clear_trail()


func _nearest_small_body(pos: Vector2) -> int:
	var best := -1
	var bd := INF
	for i in universe.n:
		if universe.mass[i] > 20.0 or universe.mass[i] < 0.3:
			continue
		var d := pos.distance_squared_to(Vector2(universe.px[i], universe.py[i]))
		if d < bd:
			bd = d
			best = i
	return best


# --- HUD ------------------------------------------------------------------------------------

func _update_hud(delta: float) -> void:
	var p := universe.player
	var alive := p >= 0 and not dead
	if alive:
		var m := universe.mass[p]
		peak_mass = maxf(peak_mass, m)
		best_mass = maxf(best_mass, peak_mass)
		hud.set_mass(m, true, delta)
		var rank := Phys.rank_index(m)
		if rank > _last_rank:
			_last_rank = rank
			hud.notice("RANK UP  ·  " + Phys.rank_name(m).to_upper(), Hud.RANK_COLORS[mini(rank, Hud.RANK_COLORS.size() - 1)], 1.8)
			sfx.play("rankup", -3.0, 1.0, 0)
			fx.ring(universe.player_pos(), Vector2(universe.vx[p], universe.vy[p]), universe.rad[p] * 10.0, hud.rank_color, 1.0, FX.Ring.SHOCKWAVE, 0.04, 2.0)
		var rel := Vector2(universe.vx[p], universe.vy[p]) - _v_ref
		var heat := universe.temp[p]
		var ghost := "   ·   GHOST" if universe.time < universe.player_grace_until else ""
		hud.stats_label.text = "radius %s   ·   drift %.0f u/s   ·   heat %d%%   ·   eaten %d%s" % [
			_fmt_len(universe.rad[p]), rel.length(), int(minf(heat / 2.5, 1.0) * 100.0), eaten, ghost]
	if dead and _dead_t > 1.2:
		hud.over_hint.text = "Press SPACE to be reborn as one of the fragments" if universe.find_by_uid(candidate_uid) >= 0 else "Press SPACE to be reborn"
	hud.info_label.text = "best %s\nlife %d%s" % [Phys.format_mass(best_mass), lives, "\nAUTOPILOT" if autopilot else ""]
	if show_debug:
		var bh := universe.bh
		hud.debug_label.text = "%d fps   bodies %d   drawn %d\nstep %.2f ms   tree %.2f   gravity %.2f\nforces this step %d   nodes %d   time x%.2f" % [
			Engine.get_frames_per_second(), universe.n, bodies.visible_count,
			universe.step_usec / 1000.0, bh.build_usec / 1000.0, bh.force_usec / 1000.0,
			bh.active_count, bh.node_count, time_scale]
	_indicator_t -= delta
	if _indicator_t <= 0.0:
		_indicator_t = 0.1
		_update_indicators()
	hud.tick(delta)


func _fmt_len(r: float) -> String:
	return "%.1f" % r if r < 100.0 else "%.0f" % r


## Arrows at the screen edge pointing at off-screen prey (and incoming threats).
func _update_indicators() -> void:
	hud.indicators.clear()
	var p := universe.player
	if p < 0 or dead:
		return
	var u := universe
	var pm := u.mass[p]
	var ppos := u.player_pos()
	var pv := Vector2(u.vx[p], u.vy[p])
	var vp := get_viewport_rect().size
	var z := camera.zoom.x
	var prey: Array = []
	var threats: Array = []
	var max_d := _view_radius * 14.0
	for i in u.n:
		if i == p or (u.flags[i] & Universe.FLAG_EXHAUST) != 0:
			continue
		var pos := Vector2(u.px[i], u.py[i])
		if _view_rect.grow(u.rad[i]).has_point(pos):
			continue
		var d := pos.distance_to(ppos)
		if d > max_d:
			continue
		var m := u.mass[i]
		if m < pm * 0.95 and m > pm * 0.04:
			prey.append([d / sqrt(m / pm), i, d])
		elif m > pm and d < _view_radius * 2.5:
			var closing := (pv - Vector2(u.vx[i], u.vy[i])).dot((pos - ppos).normalized())
			if closing > 5.0:
				threats.append([d / closing, i, d])
	prey.sort_custom(func(a, b): return a[0] < b[0])
	threats.sort_custom(func(a, b): return a[0] < b[0])
	var center := vp * 0.5
	var inset := vp * 0.5 - Vector2(34, 34)
	for k in mini(5, prey.size()):
		var i: int = prey[k][1]
		_edge_arrow(center, inset, (Vector2(u.px[i], u.py[i]) - camera.position) * z,
			Color(0.45, 1.0, 0.75, clampf(1.2 - float(prey[k][2]) / max_d, 0.25, 0.9)), 9.0 + 6.0 * sqrt(u.mass[i] / pm))
	for k in mini(3, threats.size()):
		var i: int = threats[k][1]
		_edge_arrow(center, inset, (Vector2(u.px[i], u.py[i]) - camera.position) * z,
			Color(1.0, 0.25, 0.2, 0.9), 15.0)


func _edge_arrow(center: Vector2, inset: Vector2, rel: Vector2, color: Color, size: float) -> void:
	if rel.length_squared() < 1.0:
		return
	var sx := inset.x / maxf(absf(rel.x), 1e-6)
	var sy := inset.y / maxf(absf(rel.y), 1e-6)
	var s := minf(sx, sy)
	hud.indicators.append({"pos": center + rel * s, "angle": rel.angle(), "color": color, "size": size})


# --- Autopilot (attract mode / testing) -------------------------------------------------

## Returns [aim: Vector2, thrust: bool]: chase the most appetising nearby prey,
## dodge anything bigger that is closing in.
func _autopilot_decide() -> Array:
	var u := universe
	var p := u.player
	var pm := u.mass[p]
	var ppos := u.player_pos()
	var pv := Vector2(u.vx[p], u.vy[p])
	var burst := Phys.EXHAUST_SPEED * Phys.THRUST_FRACTION
	var best := -1
	var best_score := 0.0
	var threat := -1
	var threat_t := INF
	for i in u.n:
		if i == p or (u.flags[i] & Universe.FLAG_EXHAUST) != 0:
			continue
		var rel := Vector2(u.px[i], u.py[i]) - ppos
		var d := rel.length()
		var m := u.mass[i]
		if m < pm * 0.9:
			if d < _view_radius * 9.0 and m > pm * 0.02:
				# Worth it only if the meal outweighs the mass burnt matching
				# its velocity.
				var dv := (pv - Vector2(u.vx[i], u.vy[i])).length() + 30.0
				var cost := pm * (1.0 - pow(1.0 - Phys.THRUST_FRACTION, dv / burst))
				var score := (m - cost) / (d + u.rad[p] * 10.0)
				if m > cost * 1.5 and score > best_score:
					best_score = score
					best = i
		else:
			var closing := (pv - Vector2(u.vx[i], u.vy[i])).dot(rel / maxf(d, 1e-6))
			var gap := d - u.rad[i] - u.rad[p]
			if closing > 0.0 and gap < u.rad[p] * 30.0 + closing * 1.5:
				var tt := gap / closing
				if tt < threat_t:
					threat_t = tt
					threat = i
	if threat >= 0 and threat_t < 2.0:
		var away := ppos - Vector2(u.px[threat], u.py[threat])
		return [away.normalized().rotated(0.6), true]
	if best < 0:
		return [pv.normalized() if pv != Vector2.ZERO else Vector2.RIGHT, false]
	var rel := Vector2(u.px[best], u.py[best]) - ppos
	var dist := rel.length()
	var dir := rel / maxf(dist, 1e-6)
	var va := pv - Vector2(u.vx[best], u.vy[best])  # our velocity relative to the prey
	var closing := va.dot(dir)
	# Already on an intercept course? Coast — every burst costs mass.
	var t_ca := rel.dot(va) / maxf(va.length_squared(), 1e-6)
	var miss := (rel - va * t_ca).length()
	var reach := (u.rad[p] + u.rad[best]) * 0.7
	if closing > 8.0 and closing < 90.0 and t_ca > 0.0 and t_ca < 25.0 and miss < reach:
		return [dir, false]
	# Otherwise steer: close in briskly, but slowly enough to swallow rather
	# than shatter the prey.
	var desired := dir * clampf(dist * 0.25, burst * 1.3, 70.0)
	var need := desired - va
	return [need.normalized(), need.length() > burst * 0.6]
