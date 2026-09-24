class_name FX
extends Node2D
## Visual-only particles and one-shot effects, animated entirely on the GPU.
## Each effect is written once into a ring buffer slot of a MultiMesh; the
## shaders (spark.gdshader, ring.gdshader) animate it from its birth time.

const SPARK_MAX := 8192
const RING_MAX := 512

enum Ring { SHOCKWAVE, FLASH, IMPLODE, IGNITE }

var now := 0.0

var _sparks: MultiMesh
var _rings: MultiMesh
var _spark_mat: ShaderMaterial
var _ring_mat: ShaderMaterial
var _spark_head := 0
var _ring_head := 0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	# Rings sit under the sparks.
	var r := _make(RING_MAX, preload("res://shaders/ring.gdshader"))
	_rings = r[0]
	_ring_mat = r[1]
	var s := _make(SPARK_MAX, preload("res://shaders/spark.gdshader"))
	_sparks = s[0]
	_spark_mat = s[1]


func _make(count: int, shader: Shader) -> Array:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = QuadMesh.new()
	mm.instance_count = count
	mm.custom_aabb = AABB(Vector3(-1e9, -1e9, -1.0), Vector3(2e9, 2e9, 2.0))
	# Start every slot as long dead.
	var buf := PackedFloat32Array()
	buf.resize(count * 16)
	for i in count:
		buf[i * 16 + 12] = -1.0e6
	mm.buffer = buf
	var mmi := MultiMeshInstance2D.new()
	mmi.multimesh = mm
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mmi.material = mat
	add_child(mmi)
	return [mm, mat]


func set_time(t: float, zoom: float) -> void:
	now = t
	_spark_mat.set_shader_parameter("u_now", t)
	_spark_mat.set_shader_parameter("u_min_size", 0.9 / maxf(zoom, 1e-6))
	_ring_mat.set_shader_parameter("u_now", t)


## One spark. `vel` is the burst velocity (decays with `drag`), `carrier` the
## velocity of whatever it came off (kept constant).
func spark(pos: Vector2, vel: Vector2, carrier: Vector2, color: Color, size: float, life: float, drag := 2.0, brightness := 1.0) -> void:
	var i := _spark_head
	_spark_head = (i + 1) % SPARK_MAX
	_sparks.set_instance_transform_2d(i, Transform2D(vel, carrier, pos))
	_sparks.set_instance_color(i, Color(color.r, color.g, color.b, brightness))
	_sparks.set_instance_custom_data(i, Color(now, life, size, drag))


## A spray of sparks. `dir` = Vector2.ZERO means all directions.
## `origin_radius` scatters the birth points so a big burst doesn't start as
## one blinding dot.
func burst(pos: Vector2, carrier: Vector2, color: Color, count: float, speed_min: float, speed_max: float,
		size: float, life: float, dir := Vector2.ZERO, spread := PI, drag := 2.0, brightness := 1.0,
		origin_radius := 0.0) -> void:
	var n := mini(int(count), 400)
	var base_ang := dir.angle() if dir != Vector2.ZERO else 0.0
	for k in n:
		var a := base_ang + (_rng.randf_range(-spread, spread) if dir != Vector2.ZERO else _rng.randf() * TAU)
		var spd := _rng.randf_range(speed_min, speed_max)
		var c := color
		if _rng.randf() < 0.3:
			c = c.lerp(Color(1.0, 0.8, 0.4), 0.5)
		var dv := Vector2.from_angle(a)
		spark(pos + dv * origin_radius * _rng.randf(), dv * spd, carrier, c, size * _rng.randf_range(0.5, 1.4),
			life * _rng.randf_range(0.6, 1.3), drag, brightness * _rng.randf_range(0.7, 1.3))


func ring(pos: Vector2, carrier: Vector2, radius: float, color: Color, life: float, kind: int = Ring.SHOCKWAVE,
		thickness := 0.06, intensity := 1.0) -> void:
	var i := _ring_head
	_ring_head = (i + 1) % RING_MAX
	_rings.set_instance_transform_2d(i, Transform2D(Vector2(radius, life), carrier, pos))
	_rings.set_instance_color(i, Color(color.r, color.g, color.b, intensity))
	_rings.set_instance_custom_data(i, Color(now, thickness, float(kind), _rng.randf() * TAU))
