class_name UniverseGenerator
extends RefCounted
## Builds a fresh universe: a slowly rotating field of star systems. Every star
## has planets, planets have moons (and sometimes rings), and asteroid belts
## full of snack-sized rocks thread between the orbits. The player starts in a
## calm "nursery" swarm inside the home star's first belt.

const PLAYER_COLOR := Color(0.35, 0.95, 1.0)


static func generate(u: Universe, star_count := 8) -> void:
	var rng := u.rng
	star_count = maxi(1, star_count)

	# --- Star placement (rejection sampling in a disc) ---
	var positions: Array[Vector2] = []
	# Systems reach out to ~14k units; keep neighbours far enough apart that
	# their tides only nudge each other's planets.
	var r_gal := 72000.0 * sqrt(float(star_count) / 8.0)
	var min_sep := 44000.0
	var tries := 0
	while positions.size() < star_count and tries < 20000:
		tries += 1
		var p := Vector2.from_angle(rng.randf() * TAU) * sqrt(rng.randf()) * r_gal
		var ok := true
		for q in positions:
			if q.distance_to(p) < min_sep:
				ok = false
				break
		if ok:
			positions.append(p)
		elif tries % 2000 == 0:
			r_gal *= 1.15
	var masses := PackedFloat64Array()
	for k in positions.size():
		masses.append(exp(rng.randf_range(log(2.5e7), log(8.0e7))))
	masses[0] = 4.0e7  # a friendly, medium home star

	# --- Slow galactic rotation so the systems don't just fall together ---
	var com := Vector2.ZERO
	var mtot := 0.0
	for k in positions.size():
		com += positions[k] * masses[k]
		mtot += masses[k]
	com /= mtot
	var vels: Array[Vector2] = []
	for k in positions.size():
		var r := positions[k] - com
		var d := r.length()
		var enclosed := masses[k] * 0.5
		for j in positions.size():
			if j != k and (positions[j] - com).length() < d:
				enclosed += masses[j]
		var v := Vector2.ZERO
		if d > 1.0:
			v = Vector2(-r.y, r.x) / d * sqrt(Phys.G * enclosed / d) * 0.7
		vels.append(v)

	var home_start := Vector2.ZERO
	var home_vel := Vector2.ZERO
	var home_hue := 0.0
	for k in positions.size():
		var info := _make_system(u, rng, positions[k], vels[k], masses[k], k == 0)
		if k == 0:
			home_start = info["start"]
			home_vel = info["start_vel"]
			home_hue = info["hue"]

	# --- Interstellar drifters ---
	var drifters := 140
	var placed := 0
	tries = 0
	while placed < drifters and tries < 5000:
		tries += 1
		var p := com + Vector2.from_angle(rng.randf() * TAU) * sqrt(rng.randf()) * r_gal * 1.25
		var near_star := false
		for q in positions:
			if q.distance_to(p) < 17000.0:
				near_star = true
				break
		if near_star:
			continue
		var m := minf(250.0, 0.3 * pow(1.0 - rng.randf(), -1.0 / 1.05))
		var vel := Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(5.0, 35.0)
		u.add_body(p, vel, m, Phys.vivid_color(rng, rng.randf(), 0.0))
		placed += 1

	# --- The player: a little rock in a calm swarm of edible pebbles ---
	var pl := u.add_body(home_start, home_vel, Phys.PLAYER_START_MASS, PLAYER_COLOR)
	u.set_player(pl, 1.0)
	for k in 22:
		var off := Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(45.0, 330.0)
		var m := rng.randf_range(0.25, 2.2)
		var jitter := Vector2(rng.randf_range(-3.0, 3.0), rng.randf_range(-3.0, 3.0))
		u.add_body(home_start + off, home_vel + jitter, m, Phys.vivid_color(rng, home_hue if rng.randf() < 0.7 else rng.randf(), 0.1))
	for k in 4:
		var off := Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(380.0, 560.0)
		var jitter := Vector2(rng.randf_range(-2.0, 2.0), rng.randf_range(-2.0, 2.0))
		u.add_body(home_start + off, home_vel + jitter, rng.randf_range(4.0, 10.0), Phys.vivid_color(rng, rng.randf(), 0.0))

	var small := 0
	for i in u.n:
		if u.mass[i] < 40.0:
			small += 1
	u.target_small = int(small * 0.85)


static func _make_system(u: Universe, rng: RandomNumberGenerator, pos: Vector2, vel: Vector2, m_star: float, home: bool) -> Dictionary:
	var hue := rng.randf()
	var star_col := Color.from_hsv(rng.randf(), rng.randf_range(0.5, 0.85), 1.0)
	var s := u.add_body(pos, vel, m_star, star_col, Phys.fusion_temp(m_star))
	var rs := Phys.radius(m_star)
	var a := rs * 3.2 + rng.randf_range(400.0, 900.0)
	var a_max := rs * 3.2 + 11000.0
	var result := {"hue": hue, "start": pos, "start_vel": vel}
	# Orbital slots, spaced geometrically; each holds a planet or a belt.
	var slot := 0
	var belts := 0
	var home_belt_slot := 1 if home else -1
	while a < a_max:
		var is_belt := slot == home_belt_slot or (slot > 0 and belts < 2 and rng.randf() < 0.38)
		if is_belt:
			var start_angle := -1.0
			if slot == home_belt_slot:
				start_angle = rng.randf() * TAU
				var sp := pos + Vector2.from_angle(start_angle) * a
				result["start"] = sp
				result["start_vel"] = vel + Vector2.from_angle(start_angle + PI * 0.5) * Phys.circular_speed(m_star, a)
			_make_belt(u, rng, s, a, hue, start_angle)
			belts += 1
		else:
			_make_planet(u, rng, pos, vel, m_star, a)
		slot += 1
		a *= rng.randf_range(1.38, 1.6)
	return result


## Places one planet (with moons and maybe a ring) at orbital radius `a`.
static func _make_planet(u: Universe, rng: RandomNumberGenerator, spos: Vector2, svel: Vector2, m_star: float, a: float) -> void:
	var rs := Phys.radius(m_star)
	var mp := exp(rng.randf_range(log(1.5e4), log(4.0e5)))
	if a > rs * 7.0 and rng.randf() < 0.2:
		mp = exp(rng.randf_range(log(4.0e5), log(1.5e6)))  # a giant
	var rp := Phys.radius(mp)
	var ang := rng.randf() * TAU
	var ppos := spos + Vector2.from_angle(ang) * a
	var pvel := svel + Vector2.from_angle(ang + PI * 0.5) * Phys.circular_speed(m_star, a)
	var pcol := Color.from_hsv(rng.randf(), rng.randf_range(0.45, 0.85), rng.randf_range(0.7, 0.95))
	u.add_body(ppos, pvel, mp, pcol)
	# Moons are only stable well inside the Hill sphere.
	var hill := a * pow(mp / (3.0 * m_star), 1.0 / 3.0)
	var stable := hill * 0.5

	var am := rp * 2.0 + rng.randf_range(10.0, 40.0)
	# A ring of tiny rocks — tasty but dangerously close to the planet.
	var ring_r := rp * 1.7
	if mp > 8.0e4 and rng.randf() < 0.45 and ring_r < stable:
		var count := rng.randi_range(10, 18)
		var ring_hue := fposmod(pcol.h + rng.randf_range(-0.15, 0.15), 1.0)
		for k in count:
			var rr := ring_r * rng.randf_range(0.93, 1.12)
			var ra := (float(k) + rng.randf_range(-0.3, 0.3)) / float(count) * TAU
			var rpos := ppos + Vector2.from_angle(ra) * rr
			var rvel := pvel + Vector2.from_angle(ra + PI * 0.5) * Phys.circular_speed(mp, rr)
			u.add_body(rpos, rvel, rng.randf_range(0.3, 4.0), Phys.vivid_color(rng, ring_hue, 0.06))
		am = maxf(am, ring_r * 1.3)

	var n_moons := rng.randi_range(1, 3)
	for k in n_moons:
		var mm := mp * exp(rng.randf_range(log(0.003), log(0.03)))
		var rm := Phys.radius(mm)
		am += rm
		if am > stable:
			break
		var ma := rng.randf() * TAU
		var mpos := ppos + Vector2.from_angle(ma) * am
		var mvel := pvel + Vector2.from_angle(ma + PI * 0.5) * Phys.circular_speed(mp, am)
		var mcol := Color.from_hsv(rng.randf(), rng.randf_range(0.35, 0.8), rng.randf_range(0.65, 0.95))
		u.add_body(mpos, mvel, mm, mcol)
		am = am * rng.randf_range(1.35, 1.6) + rm


## A belt of clumpy rock swarms on a circular orbit of radius `a`.
## `skip_angle` (>= 0) leaves a gap there for the player's nursery.
static func _make_belt(u: Universe, rng: RandomNumberGenerator, star: int, a: float, hue: float, skip_angle: float) -> void:
	var spos := Vector2(u.px[star], u.py[star])
	var svel := Vector2(u.vx[star], u.vy[star])
	var m_star := u.mass[star]
	var n_clumps := rng.randi_range(9, 13)
	for c in n_clumps:
		var ang := (float(c) + rng.randf_range(-0.3, 0.3)) / float(n_clumps) * TAU
		if skip_angle >= 0.0 and absf(angle_difference(ang, skip_angle)) < 0.13:
			continue
		var count := rng.randi_range(7, 14)
		var spread := rng.randf_range(70.0, 170.0)
		var center := spos + Vector2.from_angle(ang) * a * rng.randf_range(0.97, 1.03)
		for k in count:
			var p := center + Vector2.from_angle(rng.randf() * TAU) * spread * sqrt(rng.randf())
			_add_belt_rock(u, rng, spos, svel, m_star, p, hue, 900.0)
	# Loose rocks strewn along the belt, plus a few big asteroids.
	for k in 26:
		var ang := rng.randf() * TAU
		if skip_angle >= 0.0 and absf(angle_difference(ang, skip_angle)) < 0.08:
			continue
		var p := spos + Vector2.from_angle(ang) * a * rng.randf_range(0.93, 1.07)
		_add_belt_rock(u, rng, spos, svel, m_star, p, hue, 1500.0 if k < 3 else 200.0)
	u.belts.append({"star_uid": u.uid[star], "radius": a, "hue": hue})


static func _add_belt_rock(u: Universe, rng: RandomNumberGenerator, spos: Vector2, svel: Vector2, m_star: float, p: Vector2, hue: float, max_mass: float) -> void:
	var rel := p - spos
	var d := rel.length()
	var vc := Phys.circular_speed(m_star, d) * rng.randf_range(0.995, 1.005)
	var vel := svel + Vector2(-rel.y, rel.x) / d * vc + Vector2(rng.randf_range(-2.0, 2.0), rng.randf_range(-2.0, 2.0))
	var m := minf(max_mass, 0.3 * pow(1.0 - rng.randf(), -1.0 / 1.1))
	var c := Phys.vivid_color(rng, hue if rng.randf() < 0.8 else rng.randf(), 0.09)
	u.add_body(p, vel, m, c)
