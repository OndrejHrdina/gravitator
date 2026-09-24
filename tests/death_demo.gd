extends SceneTree
## Visual check of the death flow: after a moment, a big rock is flung at the
## player at high speed. Run with Movie Maker to capture frames:
##   godot --path . --write-movie out.png --fixed-fps 30 -s tests/death_demo.gd

var main: Node
var frames := 0


func _initialize() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)


func _process(_delta: float) -> bool:
	frames += 1
	if frames in [4, 9, 14]:
		Input.action_press("thrust")
	elif frames in [5, 10, 15]:
		Input.action_release("thrust")
	if frames == 20:
		var u: Universe = main.universe
		var p := u.player
		var pos := u.player_pos() + Vector2(160.0, -40.0)
		var vel := Vector2(u.vx[p], u.vy[p]) + Vector2(-260.0, 65.0)
		u.add_body(pos, vel, 30.0, Color(1.0, 0.4, 0.2))
	if frames == 140 and main.dead:
		Input.action_press("thrust")
	if frames == 142:
		Input.action_release("thrust")
	return frames >= 200
