extends SceneTree
## Plays the real main scene on autopilot and reports how the session went.
##   godot --headless --path . --fixed-fps 60 -s tests/play_test.gd -- --autoplay [--frames=N]

var main: Node
var frames := 0
var max_frames := 10800
var deaths := 0
var was_dead := false
var t0 := 0


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--frames="):
			max_frames = int(a.get_slice("=", 1))
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	t0 = Time.get_ticks_msec()


func _process(_delta: float) -> bool:
	frames += 1
	var dead: bool = main.dead
	if dead and not was_dead:
		deaths += 1
		print("  [t=%.1f] DEATH #%d  peak %.2f" % [main.universe.time, deaths, main.peak_mass])
	was_dead = dead
	if frames % 900 == 0 or frames >= max_frames:
		var u: Universe = main.universe
		var m := u.mass[u.player] if u.player >= 0 else -1.0
		print("t=%6.1f  mass %8.2f  peak %8.2f  eaten %3d  lives %d  bodies %d  step %.2f ms  fps(real) %.0f" % [
			u.time, m, main.peak_mass, main.eaten, main.lives, u.n, u.step_usec / 1000.0,
			frames * 1000.0 / maxf(1.0, Time.get_ticks_msec() - t0)])
	return frames >= max_frames
