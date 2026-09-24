extends SceneTree
## Visual check of stellar ignition: the player is just under the fusion
## threshold and swallows one last moon.
##   godot --path . --write-movie out.png --fixed-fps 30 -s tests/ignite_demo.gd

var main: Node
var frames := 0


func _initialize() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)


func _process(_delta: float) -> bool:
	frames += 1
	var u: Universe = main.universe
	if frames == 2:
		var p := u.player
		u.mass[p] = Phys.FUSION_MASS * 0.985
		u.rad[p] = Phys.radius(u.mass[p])
	if frames == 30:
		var p := u.player
		var dir := Vector2.RIGHT
		var m := Phys.FUSION_MASS * 0.03
		var pos := u.player_pos() + dir * (u.rad[p] + Phys.radius(m) + 60.0)
		u.add_body(pos, Vector2(u.vx[p], u.vy[p]) - dir * 25.0, m, Color(0.3, 0.6, 1.0))
	return frames >= 150
