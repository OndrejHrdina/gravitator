extends SceneTree
## Headless smoke test for the simulation core.
##   godot --headless --path . -s tests/sim_smoke.gd [-- --steps=600 --stars=8]

func _init() -> void:
	var steps := 600
	var stars := 8
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--steps="):
			steps = int(a.get_slice("=", 1))
		elif a.begins_with("--stars="):
			stars = int(a.get_slice("=", 1))
	var u := Universe.new(12345)
	var t0 := Time.get_ticks_usec()
	UniverseGenerator.generate(u, stars)
	print("generated %d bodies in %d ms, total mass %.1f" % [u.n, (Time.get_ticks_usec() - t0) / 1000, u.total_mass()])
	var m0 := u.total_mass()
	var counts := {}
	var sum_step := 0
	var sum_build := 0
	var sum_force := 0
	var worst := 0
	for s in steps:
		if u.player >= 0:
			u.focus = u.player_pos()
		u.focus_radius = 400.0
		if s % 20 == 0 and u.player >= 0:
			u.thrust(Vector2.RIGHT.rotated(s * 0.1))
		u.step(1.0 / 60.0)
		sum_step += u.step_usec
		sum_build += u.bh.build_usec
		sum_force += u.bh.force_usec
		worst = maxi(worst, u.step_usec)
		for ev in u.events:
			var t: int = ev["type"]
			counts[t] = counts.get(t, 0) + 1
		u.events.clear()
	var bad := 0
	for i in u.n:
		if is_nan(u.px[i]) or is_nan(u.vx[i]) or is_nan(u.mass[i]) or u.mass[i] <= 0.0:
			bad += 1
	var names := {}
	for k in Universe.Ev.keys():
		names[Universe.Ev[k]] = k
	var ev_str := ""
	for k in counts:
		ev_str += "%s=%d " % [names[k], counts[k]]
	print("after %d steps: %d bodies, player=%d, mass drift %.6f" % [steps, u.n, u.player, (u.total_mass() - m0) / m0])
	print("avg step %.2f ms (build %.2f, force %.2f), worst %.2f ms" % [sum_step / 1000.0 / steps, sum_build / 1000.0 / steps, sum_force / 1000.0 / steps, worst / 1000.0])
	print("events: ", ev_str)
	print("NaN/invalid bodies: ", bad)
	quit(1 if bad > 0 else 0)
