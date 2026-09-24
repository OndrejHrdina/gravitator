class_name Universe
extends RefCounted
## The whole simulated universe, stored as a structure of packed arrays.
##
## Each step (kick-drift-kick leapfrog):
##   1. half-kick velocities, drift positions,
##   2. rebuild the Barnes-Hut tree and evaluate gravity (threaded); the same
##      tree walk reports every pair that may be touching,
##   3. second half-kick,
##   4. resolve collisions — absorb, shatter or catastrophically disrupt,
##   5. heat transport: impacts heat bodies up, everything radiates heat away
##      except bodies massive enough to sustain fusion,
##   6. compact the arrays (swap-remove dead bodies).
##
## Anything interesting that happened is appended to `events` for the
## renderers, audio and UI to react to; the consumer clears it.

enum Ev { MERGE, SHATTER, CATASTROPHE, IGNITE, THRUST, DEATH, EVAPORATE }

const FLAG_FUSION := 1
const FLAG_EXHAUST := 2

var rng := RandomNumberGenerator.new()
var bh := BarnesHut.new()
var time := 0.0
var n := 0
var _cap := 0

# --- Body data (structure of arrays) ------------------------------------------
var px := PackedFloat64Array()
var py := PackedFloat64Array()
var ppx := PackedFloat64Array()   # positions at the previous step, for render interpolation
var ppy := PackedFloat64Array()
var vx := PackedFloat64Array()
var vy := PackedFloat64Array()
var ax := PackedFloat64Array()
var ay := PackedFloat64Array()
var mass := PackedFloat64Array()
var rad := PackedFloat64Array()
var temp := PackedFloat64Array()
var ripple := PackedFloat64Array()   # 0..1, surface wobble after absorbing something
var born := PackedFloat64Array()
var group_until := PackedFloat64Array()
var t_eval := PackedFloat64Array()   # when this body's forces were last evaluated
var reff := PackedFloat64Array()     # radius + motion this step (tree scratch)
var th2 := PackedFloat64Array()      # Barnes-Hut θ² per body (tree scratch)
var col := PackedColorArray()
var seeds := PackedFloat32Array()
var uid := PackedInt64Array()
var group := PackedInt32Array()      # bodies sharing a live group do not collide
var flags := PackedInt32Array()
var lvl := PackedInt32Array()        # force update interval in steps (LOD)
var due := PackedByteArray()         # forces evaluated this step
var alive := PackedByteArray()

# --- Player ----------------------------------------------------------------------
var player := -1
var player_uid := -1
var player_grace_until := -1.0

## Where precision matters (the player) and how large "near" is.
var focus := Vector2.ZERO
var focus_radius := 600.0

## Bodies further than this many focus radii away only get fresh forces every
## FAR_INTERVAL steps (they still move every step). Symplectic multi-rate
## leapfrog: precision near the player, economy far away.
const FAR_Q := 3.0
const FAR_INTERVAL := 3

var events: Array[Dictionary] = []
## Asteroid belts, used to replenish small rocks: {star_uid, radius, hue}.
var belts: Array[Dictionary] = []
var target_small := 0
var step_usec := 0

var _next_uid := 1
var _next_group := 1


func _init(seed_value: int = 0) -> void:
	if seed_value != 0:
		rng.seed = seed_value
	else:
		rng.randomize()


# --- Body management ------------------------------------------------------------

func _ensure_cap(k: int) -> void:
	if k <= _cap:
		return
	var c := maxi(k, _cap * 2 + 128)
	px.resize(c)
	py.resize(c)
	ppx.resize(c)
	ppy.resize(c)
	vx.resize(c)
	vy.resize(c)
	ax.resize(c)
	ay.resize(c)
	mass.resize(c)
	rad.resize(c)
	temp.resize(c)
	ripple.resize(c)
	born.resize(c)
	group_until.resize(c)
	t_eval.resize(c)
	reff.resize(c)
	th2.resize(c)
	col.resize(c)
	seeds.resize(c)
	uid.resize(c)
	group.resize(c)
	flags.resize(c)
	lvl.resize(c)
	due.resize(c)
	alive.resize(c)
	_cap = c


## Adds a body and returns its index, or -1 when the universe is full.
func add_body(pos: Vector2, vel: Vector2, m: float, c: Color, t := 0.0, f := 0) -> int:
	if n >= Phys.MAX_BODIES or m <= 0.0:
		return -1
	_ensure_cap(n + 1)
	var i := n
	n += 1
	px[i] = pos.x
	py[i] = pos.y
	ppx[i] = pos.x
	ppy[i] = pos.y
	vx[i] = vel.x
	vy[i] = vel.y
	ax[i] = 0.0
	ay[i] = 0.0
	mass[i] = m
	rad[i] = Phys.radius(m)
	temp[i] = t
	ripple[i] = 0.0
	born[i] = time
	group_until[i] = 0.0
	# Random phase so far-away bodies spread their updates over the steps.
	t_eval[i] = time - float(_next_uid % FAR_INTERVAL) * (1.0 / 60.0)
	reff[i] = rad[i]
	th2[i] = 1.0
	col[i] = c
	seeds[i] = float(rng.randi_range(0, 255))
	uid[i] = _next_uid
	_next_uid += 1
	group[i] = 0
	if m >= Phys.FUSION_MASS:
		f |= FLAG_FUSION
	flags[i] = f
	lvl[i] = 1
	due[i] = 0
	alive[i] = 1
	return i


func find_by_uid(u: int) -> int:
	if u < 0:
		return -1
	for i in n:
		if uid[i] == u:
			return i
	return -1


func set_player(i: int, grace := 0.0) -> void:
	player = i
	player_uid = uid[i] if i >= 0 else -1
	player_grace_until = time + grace


func player_pos() -> Vector2:
	if player < 0:
		return Vector2.ZERO
	return Vector2(px[player], py[player])


func total_mass() -> float:
	var s := 0.0
	for i in n:
		s += mass[i]
	return s


func _new_group() -> int:
	_next_group += 1
	return _next_group


func _move(from: int, to: int) -> void:
	px[to] = px[from]
	py[to] = py[from]
	ppx[to] = ppx[from]
	ppy[to] = ppy[from]
	vx[to] = vx[from]
	vy[to] = vy[from]
	ax[to] = ax[from]
	ay[to] = ay[from]
	mass[to] = mass[from]
	rad[to] = rad[from]
	temp[to] = temp[from]
	ripple[to] = ripple[from]
	born[to] = born[from]
	group_until[to] = group_until[from]
	t_eval[to] = t_eval[from]
	reff[to] = reff[from]
	th2[to] = th2[from]
	col[to] = col[from]
	seeds[to] = seeds[from]
	uid[to] = uid[from]
	group[to] = group[from]
	flags[to] = flags[from]
	lvl[to] = lvl[from]
	due[to] = due[from]
	alive[to] = alive[from]


func _compact() -> void:
	var i := 0
	while i < n:
		if alive[i] != 0:
			i += 1
			continue
		if i == player:
			player = -1
		var last := n - 1
		if i != last:
			_move(last, i)
			if player == last:
				player = i
		n -= 1


# --- Simulation step ----------------------------------------------------------------

func step(dt: float) -> void:
	var t_start := Time.get_ticks_usec()
	time += dt
	var cnt := n
	ppx = px.duplicate()
	ppy = py.duplicate()

	# Drift every body (velocities live at half steps), decide who gets fresh
	# forces this step, and set per-body tree parameters.
	var fx := focus.x
	var fy := focus.y
	var inv_fr := 1.0 / maxf(focus_radius, 1.0)
	var th_near := Phys.THETA_NEAR
	var th_far := Phys.THETA_FAR
	var th_slope := Phys.THETA_SLOPE
	var now := time - 1e-6
	var far_dt := float(FAR_INTERVAL) * dt
	for i in cnt:
		var vxi := vx[i]
		var vyi := vy[i]
		var x := px[i] + vxi * dt
		var y := py[i] + vyi * dt
		px[i] = x
		py[i] = y
		var ddx := x - fx
		var ddy := y - fy
		var q := sqrt(ddx * ddx + ddy * ddy) * inv_fr
		var th := th_near
		var window := dt
		if q > 1.0:
			th = minf(th_far, th_near + th_slope * log(q))
			if q > FAR_Q:
				window = far_dt
		lvl[i] = 1 if window == dt else FAR_INTERVAL
		due[i] = 1 if now - t_eval[i] >= window - dt * 0.5 else 0
		reff[i] = rad[i] + sqrt(vxi * vxi + vyi * vyi) * far_dt + 0.25
		th2[i] = th * th
	if player >= 0:
		th2[player] = Phys.THETA_PLAYER * Phys.THETA_PLAYER
		lvl[player] = 1
		due[player] = 1

	bh.build(cnt, px, py, mass, reff)
	bh.compute(due, th2, ax, ay)

	# Kick: close the elapsed interval and open the next one in one go.
	var act := bh.active
	for k in bh.active_count:
		var i := act[k]
		var h := (time - t_eval[i]) + float(lvl[i]) * dt
		vx[i] += ax[i] * h * 0.5
		vy[i] += ay[i] * h * 0.5
		t_eval[i] = time

	_resolve_collisions(dt)
	_thermal(dt)
	_compact()
	step_usec = Time.get_ticks_usec() - t_start


func _resolve_collisions(dt: float) -> void:
	for pl: PackedInt32Array in bh.pair_lists:
		var k := 0
		var cnt := pl.size()
		while k < cnt:
			var i := pl[k]
			var j := pl[k + 1]
			k += 2
			if alive[i] == 0 or alive[j] == 0:
				continue
			var gi := group[i]
			if gi != 0 and gi == group[j] and time < group_until[i] and time < group_until[j]:
				continue
			var dx := px[j] - px[i]
			var dy := py[j] - py[i]
			var rs := rad[i] + rad[j]
			var d2 := dx * dx + dy * dy
			if d2 >= rs * rs:
				# Not overlapping now — did they pass through each other during
				# the step? (closest approach over the last dt)
				var dvx := vx[j] - vx[i]
				var dvy := vy[j] - vy[i]
				var dv2 := dvx * dvx + dvy * dvy
				if dv2 < 1e-12:
					continue
				var window := dt * float(maxi(lvl[i], lvl[j]))
				var s := clampf(-(dx * dvx + dy * dvy) / dv2, -window, 0.0)
				dx += dvx * s
				dy += dvy * s
				if dx * dx + dy * dy >= rs * rs:
					continue
			_collide(i, j, dx, dy)


func _thermal(dt: float) -> void:
	for i in n:
		if alive[i] == 0:
			continue
		var t := temp[i]
		if (flags[i] & FLAG_FUSION) != 0:
			var target := Phys.fusion_temp(mass[i])
			t += (target - t) * minf(1.0, dt * 0.7)
		elif t > 0.0005:
			# Small things cool fast, big things hold their heat for a long time.
			t -= t * dt / (0.9 + 0.09 * rad[i]) + 0.04 * t * t * dt
			if t < 0.0:
				t = 0.0
		else:
			t = 0.0
		temp[i] = t
		var rp := ripple[i]
		if rp > 0.0:
			ripple[i] = maxf(0.0, rp - dt * 1.1)
		if mass[i] < Phys.DUST_MASS and i != player and time - born[i] > Phys.DUST_LIFETIME:
			alive[i] = 0
			events.append({"type": Ev.EVAPORATE, "x": px[i], "y": py[i], "vx": vx[i], "vy": vy[i],
				"r": rad[i], "color": col[i]})


# --- Collisions --------------------------------------------------------------------

## `dxij, dyij` points from i to j at (or near) the moment of contact.
func _collide(i: int, j: int, dxij: float, dyij: float) -> void:
	var big := i
	var small := j
	var sgn := 1.0
	# Ties go to the player: equal-sized rocks are food, not death.
	if mass[j] > mass[i] or (mass[j] == mass[i] and j == player):
		big = j
		small = i
		sgn = -1.0
	var d := sqrt(dxij * dxij + dyij * dyij)
	var nx := 1.0
	var ny := 0.0
	if d > 1e-9:
		nx = dxij / d * sgn
		ny = dyij / d * sgn
	var mb := mass[big]
	var ms := mass[small]
	var rvx := vx[small] - vx[big]
	var rvy := vy[small] - vy[big]
	var e := 0.5 * (mb * ms / (mb + ms)) * (rvx * rvx + rvy * rvy)

	var role := 0
	if big == player:
		role = 1
	elif small == player:
		role = 2
	var grace := time < player_grace_until
	if grace and role == 2:
		return  # freshly reborn: ghost through bigger bodies

	if (flags[big] & FLAG_FUSION) != 0 or e <= Phys.binding_energy(ms):
		if role == 2:
			_consume_player(big, small, e, nx, ny)
		else:
			_merge(big, small, e, nx, ny, role)
		return
	if e <= Phys.binding_energy(mb) or (grace and role == 1):
		_shatter_small(big, small, e, nx, ny, rvx, rvy, role)
		return
	_catastrophe(big, small, e, nx, ny, role)


## Perfectly inelastic absorption of `small` into `big`.
func _merge(big: int, small: int, e: float, nx: float, ny: float, role: int) -> void:
	var mb := mass[big]
	var ms := mass[small]
	var m := mb + ms
	var cx := px[big] + nx * rad[big]
	var cy := py[big] + ny * rad[big]
	var rvx := vx[small] - vx[big]
	var rvy := vy[small] - vy[big]
	var c_small := col[small]
	var old_x := px[big]
	var old_y := py[big]
	vx[big] = (mb * vx[big] + ms * vx[small]) / m
	vy[big] = (mb * vy[big] + ms * vy[small]) / m
	px[big] = (mb * px[big] + ms * px[small]) / m
	py[big] = (mb * py[big] + ms * py[small]) / m
	ppx[big] += px[big] - old_x
	ppy[big] += py[big] - old_y
	temp[big] = minf(Phys.MAX_TEMP, (mb * temp[big] + ms * temp[small]) / m + e * Phys.HEAT_PER_ENERGY / m)
	col[big] = Phys.mix_color(col[big], mb, c_small, ms)
	var r_small := rad[small]
	mass[big] = m
	rad[big] = Phys.radius(m)
	ripple[big] = minf(1.0, ripple[big] + 0.3 + 5.0 * ms / m)
	alive[small] = 0
	events.append({"type": Ev.MERGE, "x": cx, "y": cy, "nx": nx, "ny": ny, "e": e,
		"m_small": ms, "m": m, "r_small": r_small, "r_big": rad[big], "color": c_small,
		"color_big": col[big], "role": role, "vrel": sqrt(rvx * rvx + rvy * rvy),
		"vx": vx[big], "vy": vy[big], "bx": px[big], "by": py[big]})
	_check_fusion(big)


## The player gently touched something bigger and got swallowed. A little of it
## splashes back out — that splinter becomes the next player rock.
func _consume_player(big: int, small: int, e: float, nx: float, ny: float) -> void:
	var ms := mass[small]
	var splash := clampf(ms * 0.2, minf(ms, Phys.FRAG_MIN_MASS * 2.0), ms)
	var keep := ms - splash
	var c_small := col[small]
	var old_v := Vector2(vx[small], vy[small])
	var t_small := temp[small]
	if keep > 1e-6:
		mass[small] = keep
		_merge(big, small, e, nx, ny, 2)
	else:
		alive[small] = 0
	var vesc := Phys.escape_speed(mass[big], rad[big])
	var dir := Vector2(nx, ny).rotated(rng.randf_range(-0.6, 0.6))
	var spd := vesc * 1.12 + rng.randf_range(15.0, 45.0)
	var rf := Phys.radius(splash)
	var pos := Vector2(px[big], py[big]) + dir * (rad[big] + rf + 2.0)
	var vel := Vector2(vx[big], vy[big]) + dir * spd
	# Recoil so momentum stays roughly conserved.
	vx[big] -= splash * (vel.x - old_v.x) / mass[big]
	vy[big] -= splash * (vel.y - old_v.y) / mass[big]
	var f := _spawn_fragment(pos, vel, splash, c_small, maxf(t_small, 1.2), big, _new_group())
	_player_died("CONSUMED", f, big, ms)


## `small` breaks apart on impact; part of it sticks to `big`, the rest sprays
## off as fragments (those too slow to escape `big` fall back and are absorbed).
func _shatter_small(big: int, small: int, e: float, nx: float, ny: float, rvx: float, rvy: float, role: int) -> void:
	var mb := mass[big]
	var ms := mass[small]
	var x := e / Phys.binding_energy(ms)
	var f_acc := 1.0 / (1.0 + 0.6 * (x - 1.0))
	var rest := ms * (1.0 - f_acc)
	var nf := clampi(int(2.0 + 1.5 * log(x) / log(2.0)), 2, 7)
	nf = mini(nf, int(rest / Phys.FRAG_MIN_MASS))
	if role == 2:
		nf = maxi(nf, 1)
	nf = maxi(0, mini(nf, Phys.MAX_BODIES - n))
	var vrel := sqrt(rvx * rvx + rvy * rvy)
	var nrm := Vector2(nx, ny)
	# Debris leaves roughly like a reflection off the surface.
	var rd := Vector2(rvx, rvy) / maxf(vrel, 1e-6)
	var refl := rd - 2.0 * rd.dot(nrm) * nrm
	var base_dir := (refl * 0.5 + nrm * 0.9).normalized()

	var c_small := col[small]
	var t_small := temp[small]
	var old_vb := Vector2(vx[big], vy[big])
	var ptot := old_vb * mb + Vector2(vx[small], vy[small]) * ms
	var small_pos := Vector2(px[small], py[small])
	var cx := px[big] + nx * rad[big]
	var cy := py[big] + ny * rad[big]
	var r_small := rad[small]

	var absorbed := ms - rest
	var masses := Phys.split_masses(rest, nf, rng) if nf > 0 else PackedFloat64Array()
	if nf == 0:
		absorbed = ms
	var vesc := Phys.escape_speed(mb + absorbed, rad[big])
	var launch: Array = []
	for k in nf:
		var mf := masses[k]
		var spd := vrel * rng.randf_range(0.25, 0.7)
		if spd < vesc * 1.05:
			if role == 2 and k == 0:
				spd = vesc * 1.1 + rng.randf_range(10.0, 30.0)
			else:
				absorbed += mf
				continue
		var dir := base_dir.rotated(rng.randf_range(-0.9, 0.9))
		if dir.dot(nrm) < 0.15:
			dir = (dir + nrm).normalized()
		launch.append([mf, dir, spd])

	var new_mb := mb + absorbed
	var r_new := Phys.radius(new_mb)
	var gid := _new_group()
	var frag_t := minf(Phys.MAX_TEMP, t_small + e * Phys.HEAT_PER_ENERGY * 1.3 / ms)
	var survivor := -1
	var bpos := Vector2(px[big], py[big]).lerp(small_pos, absorbed / new_mb)
	for L in launch:
		var mf: float = L[0]
		var dir: Vector2 = L[1]
		var spd: float = L[2]
		var pos := bpos + dir * (r_new + Phys.radius(mf) + 1.0)
		var vel := old_vb + dir * spd
		var f := _spawn_fragment(pos, vel, mf, c_small, frag_t, big, gid)
		if f < 0:
			new_mb += mf
			absorbed += mf
			continue
		ptot -= vel * mf
		if survivor < 0:
			survivor = f

	var old_x := px[big]
	var old_y := py[big]
	px[big] = bpos.x
	py[big] = bpos.y
	ppx[big] += bpos.x - old_x
	ppy[big] += bpos.y - old_y
	vx[big] = ptot.x / new_mb
	vy[big] = ptot.y / new_mb
	temp[big] = minf(Phys.MAX_TEMP, (mb * temp[big] + absorbed * t_small) / new_mb + e * Phys.HEAT_PER_ENERGY * 0.7 / new_mb)
	col[big] = Phys.mix_color(col[big], mb, c_small, absorbed)
	mass[big] = new_mb
	rad[big] = Phys.radius(new_mb)
	ripple[big] = minf(1.0, ripple[big] + 0.3 + 5.0 * absorbed / new_mb)
	group[big] = gid
	group_until[big] = time + 0.4
	alive[small] = 0
	events.append({"type": Ev.SHATTER, "x": cx, "y": cy, "nx": nx, "ny": ny, "e": e,
		"m_small": ms, "absorbed": absorbed, "m": new_mb, "r_small": r_small, "r_big": rad[big],
		"color": c_small, "color_big": col[big], "role": role, "vrel": vrel,
		"n_frag": launch.size(), "vx": vx[big], "vy": vy[big], "bx": px[big], "by": py[big]})
	if role == 2:
		_player_died("SHATTERED", survivor, big, ms)
	_check_fusion(big)


## Both bodies are torn apart. The largest remnant keeps `big`'s identity; the
## rest of the mass is flung out as a spray of fragments.
func _catastrophe(big: int, small: int, e: float, nx: float, ny: float, role: int) -> void:
	var mb := mass[big]
	var ms := mass[small]
	var m := mb + ms
	var cpos := (Vector2(px[big], py[big]) * mb + Vector2(px[small], py[small]) * ms) / m
	var cvel := (Vector2(vx[big], vy[big]) * mb + Vector2(vx[small], vy[small]) * ms) / m
	var q := e / Phys.binding_energy(m)
	var m_lr := m * clampf(1.0 - 0.5 * q, 0.1, 0.85)
	var rest := m - m_lr
	var nf := clampi(int(3.0 + 3.0 * log(1.0 + q) / log(2.0)), 3, 12)
	nf = mini(nf, int(rest / Phys.FRAG_MIN_MASS))
	if role != 0:
		nf = maxi(nf, 1)
	nf = maxi(0, mini(nf, Phys.MAX_BODIES - n))
	var c_big := col[big]
	var c_small := col[small]
	var c_mix := Phys.mix_color(c_big, mb, c_small, ms)
	var heat := minf(Phys.MAX_TEMP, (mb * temp[big] + ms * temp[small]) / m + e * Phys.HEAT_PER_ENERGY * 1.5 / m)
	var e_kin := maxf(e - 0.5 * Phys.binding_energy(mb), e * 0.25)
	var v_base := sqrt(2.0 * e_kin / maxf(rest, 1e-6))
	var r_lr := Phys.radius(m_lr)
	var vesc := Phys.escape_speed(m_lr, r_lr)
	var masses := Phys.split_masses(rest, nf, rng) if nf > 0 else PackedFloat64Array()
	var absorbed := 0.0 if nf > 0 else rest
	var ptot := cvel * m
	var gid := _new_group()
	# The player continues as one of the mid-sized pieces, not the big remnant.
	var forced := mini(1, nf - 1)
	var survivor := -1
	var axis := Vector2(-ny, nx)
	for k in nf:
		var mf := masses[k]
		var spd := v_base * rng.randf_range(0.35, 1.0)
		var is_forced := role != 0 and k == forced
		if spd < vesc * 1.05:
			if is_forced:
				spd = vesc * 1.15 + rng.randf_range(10.0, 30.0)
			else:
				absorbed += mf
				continue
		# Ejecta fan out mostly perpendicular to the impact axis.
		var side := 1.0 if rng.randf() < 0.5 else -1.0
		var dir := (axis * side).rotated(rng.randf_range(-1.2, 1.2))
		var rf := Phys.radius(mf)
		var pos := cpos + dir * (r_lr * 1.05 + rf + 1.0 + rng.randf() * rf * 2.0)
		var vel := cvel + dir * spd
		var fc := c_big.lerp(c_small, rng.randf())
		var f := _spawn_fragment(pos, vel, mf, fc, heat, big, gid)
		if f < 0:
			absorbed += mf
			continue
		ptot -= vel * mf
		if is_forced or (role != 0 and survivor < 0):
			survivor = f

	var m_rem := m_lr + absorbed
	ppx[big] += cpos.x - px[big]
	ppy[big] += cpos.y - py[big]
	px[big] = cpos.x
	py[big] = cpos.y
	vx[big] = ptot.x / m_rem
	vy[big] = ptot.y / m_rem
	mass[big] = m_rem
	rad[big] = Phys.radius(m_rem)
	temp[big] = heat
	col[big] = c_mix
	ripple[big] = 1.0
	group[big] = gid
	group_until[big] = time + 0.5
	alive[small] = 0
	events.append({"type": Ev.CATASTROPHE, "x": cpos.x, "y": cpos.y, "nx": nx, "ny": ny, "e": e,
		"m": m, "m_rem": m_rem, "r": Phys.radius(m), "color": c_mix, "color_a": c_big,
		"color_b": c_small, "role": role, "n_frag": nf, "vx": cvel.x, "vy": cvel.y})
	if role != 0:
		_player_died("SHATTERED", survivor, big, mb if role == 1 else ms)
	_check_fusion(big)


func _spawn_fragment(pos: Vector2, vel: Vector2, m: float, c: Color, t: float, parent: int, gid: int) -> int:
	var f := add_body(pos, vel, m, c, t)
	if f < 0:
		return -1
	group[f] = gid
	group_until[f] = time + 0.45
	ax[f] = ax[parent]
	ay[f] = ay[parent]
	t_eval[f] = time - 1.0 / 60.0
	ripple[f] = 0.6
	return f


func _check_fusion(i: int) -> void:
	var f := flags[i]
	if mass[i] >= Phys.FUSION_MASS:
		if (f & FLAG_FUSION) == 0:
			flags[i] = f | FLAG_FUSION
			events.append({"type": Ev.IGNITE, "x": px[i], "y": py[i], "m": mass[i], "r": rad[i],
				"color": col[i], "is_player": i == player, "vx": vx[i], "vy": vy[i]})
	elif (f & FLAG_FUSION) != 0:
		flags[i] = f & ~FLAG_FUSION


func _player_died(cause: String, candidate: int, killer: int, player_mass: float) -> void:
	# The piece you are reborn as coalesces a little debris so it is a fair
	# restart rather than a speck — the mass comes out of whatever killed you.
	if candidate >= 0:
		var target := minf(player_mass, clampf(player_mass * 0.45, 1.2, 4.0))
		var delta := target - mass[candidate]
		if delta > 0.0 and killer >= 0 and mass[killer] > delta * 4.0:
			mass[killer] -= delta
			rad[killer] = Phys.radius(mass[killer])
			mass[candidate] = target
			rad[candidate] = Phys.radius(target)
	events.append({"type": Ev.DEATH, "cause": cause, "x": px[player], "y": py[player],
		"candidate_uid": uid[candidate] if candidate >= 0 else -1,
		"killer_uid": uid[killer] if killer >= 0 else -1,
		"killer_mass": mass[killer] if killer >= 0 else 0.0})
	player = -1
	player_uid = -1


# --- Player actions ----------------------------------------------------------------

## Ejects a slug of the player's mass away from `dir`; the recoil pushes the
## player towards `dir`. Momentum is conserved exactly.
func thrust(dir: Vector2) -> bool:
	if player < 0:
		return false
	var p := player
	var m := mass[p]
	if m < Phys.MIN_THRUST_MASS:
		return false
	var d := dir.normalized()
	if d == Vector2.ZERO:
		return false
	var dm := m * Phys.THRUST_FRACTION
	var m2 := m - dm
	var u := Phys.EXHAUST_SPEED
	var ov := Vector2(vx[p], vy[p])
	vx[p] = ov.x + d.x * u * dm / m
	vy[p] = ov.y + d.y * u * dm / m
	mass[p] = m2
	rad[p] = Phys.radius(m2)
	var re := Phys.radius(dm)
	var epos := Vector2(px[p], py[p]) - d * (rad[p] + re + 0.6)
	var evel := ov - d * u * m2 / m
	var gid := _new_group()
	group[p] = gid
	group_until[p] = time + 0.35
	var hot := col[p].lerp(Color(1.0, 0.75, 0.35), 0.3)
	var e := add_body(epos, evel, dm, hot, 1.6, FLAG_EXHAUST)
	if e >= 0:
		group[e] = gid
		group_until[e] = time + 0.35
		ax[e] = ax[p]
		ay[e] = ay[p]
	events.append({"type": Ev.THRUST, "x": epos.x, "y": epos.y, "dx": -d.x, "dy": -d.y,
		"m": dm, "r": rad[p], "color": col[p], "vx": vx[p], "vy": vy[p], "evx": evel.x, "evy": evel.y})
	return true


# --- Population upkeep -----------------------------------------------------------

## Scatters a loose swarm of small rocks around `center`, all drifting with
## `vel` plus a little jitter.
func spawn_clump(center: Vector2, vel: Vector2, count: int, spread: float, hue: float, max_mass := 60.0) -> void:
	for k in count:
		var off := Vector2.from_angle(rng.randf() * TAU) * spread * sqrt(rng.randf())
		var m := minf(max_mass, 0.3 * pow(1.0 - rng.randf(), -1.0 / 1.15))
		var c := Phys.vivid_color(rng, hue if rng.randf() < 0.85 else rng.randf(), 0.09)
		var jitter := Vector2(rng.randf_range(-2.0, 2.0), rng.randf_range(-2.0, 2.0))
		add_body(center + off, vel + jitter, m, c)


## Keeps the belts stocked with snacks, spawning new swarms out of sight.
func maintain(view_radius: float) -> void:
	if belts.is_empty() or target_small <= 0:
		return
	var small := 0
	for i in n:
		if mass[i] < 40.0:
			small += 1
	if small >= target_small:
		return
	var b: Dictionary = belts[rng.randi() % belts.size()]
	var s := find_by_uid(int(b["star_uid"]))
	if s < 0 or (flags[s] & FLAG_FUSION) == 0:
		return
	var ms := mass[s]
	var spos := Vector2(px[s], py[s])
	var svel := Vector2(vx[s], vy[s])
	for _attempt in 8:
		var a: float = float(b["radius"]) * rng.randf_range(0.94, 1.06)
		var ang := rng.randf() * TAU
		var c := spos + Vector2.from_angle(ang) * a
		if player >= 0 and c.distance_to(player_pos()) < view_radius * 1.8:
			continue
		var vel := svel + Vector2.from_angle(ang + PI * 0.5) * Phys.circular_speed(ms, a)
		spawn_clump(c, vel, rng.randi_range(7, 13), rng.randf_range(70.0, 150.0), float(b["hue"]))
		return
