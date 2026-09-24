class_name BodyRenderer
extends MultiMeshInstance2D
## Draws every visible body as one instanced quad (see shaders/body.gdshader).
## Each frame: cull against the view, sort heavy-first (so small rocks draw on
## top of big glowing things), pick the dominant star as the light source and
## upload one packed buffer.

const FLOATS := 16  # 8 transform + 4 colour + 4 custom

var visible_count := 0

var _buf := PackedFloat32Array()
var _keys := PackedInt64Array()
var _mat: ShaderMaterial
var _capacity := 0


func _ready() -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = QuadMesh.new()
	_capacity = Phys.MAX_BODIES + 64
	mm.instance_count = _capacity
	mm.visible_instance_count = 0
	# Everything is culled on the CPU; never let the engine cull the batch.
	mm.custom_aabb = AABB(Vector3(-1e9, -1e9, -1.0), Vector3(2e9, 2e9, 2.0))
	multimesh = mm
	_mat = ShaderMaterial.new()
	_mat.shader = preload("res://shaders/body.gdshader")
	material = _mat
	_buf.resize(_capacity * FLOATS)


## "The heavier something is, the more it glows": a faint base glow for
## pebbles rising steeply to blazing for giants and stars.
static func glow_for(m: float) -> float:
	return 0.1 + pow(clampf(log(m + 1.0) / log(10.0) / 8.0, 0.0, 1.0), 1.4) * 1.2


static func halo_for(glow: float, t: float, fusion: bool) -> float:
	if fusion:
		return 3.4
	return 1.45 + glow * 1.1 + minf(t, 3.0) * 0.35


## `alpha` interpolates between the previous and current simulation step.
func refresh(u: Universe, alpha: float, view: Rect2, zoom: float, time: float) -> void:
	_mat.set_shader_parameter("u_time", time)
	var n := u.n
	# Stars light everything else.
	var stars := PackedInt32Array()
	for i in n:
		if (u.flags[i] & Universe.FLAG_FUSION) != 0:
			stars.append(i)
	var ns := stars.size()
	var spx := PackedFloat64Array()
	var spy := PackedFloat64Array()
	var sm := PackedFloat64Array()
	spx.resize(ns)
	spy.resize(ns)
	sm.resize(ns)
	for k in ns:
		var s := stars[k]
		spx[k] = u.px[s]
		spy[k] = u.py[s]
		sm[k] = u.mass[s]

	var px := u.px
	var py := u.py
	var ppx := u.ppx
	var ppy := u.ppy
	var rad := u.rad
	var mass := u.mass
	var min_r := 1.3 / maxf(zoom, 1e-6)
	var x0 := view.position.x
	var y0 := view.position.y
	var x1 := view.end.x
	var y1 := view.end.y
	var pl := u.player
	var pl_mass := u.mass[pl] if pl >= 0 else -1.0

	# Cull, then sort by mass (ascending key; filled from the end = heaviest first).
	_keys.resize(n)
	var cnt := 0
	for i in n:
		var x := ppx[i] + (px[i] - ppx[i]) * alpha
		var y := ppy[i] + (py[i] - ppy[i]) * alpha
		var ext := maxf(rad[i], min_r) * 3.5
		if x + ext < x0 or x - ext > x1 or y + ext < y0 or y - ext > y1:
			continue
		var lm := int(log(mass[i] + 1.0) * 64.0) + 1
		_keys[cnt] = (lm << 24) | i
		cnt += 1
	_keys.resize(cnt)
	_keys.sort()
	cnt = mini(cnt, _capacity)

	var buf := _buf
	var w := 0
	var k := _keys.size() - 1
	while k >= 0 and w < cnt:
		var i := _keys[k] & 0xFFFFFF
		k -= 1
		var x := ppx[i] + (px[i] - ppx[i]) * alpha
		var y := ppy[i] + (py[i] - ppy[i]) * alpha
		var m := mass[i]
		var f := u.flags[i]
		var fusion := (f & Universe.FLAG_FUSION) != 0
		var t := u.temp[i]
		var glow := glow_for(m)
		var halo := halo_for(glow, t, fusion)
		var r := maxf(rad[i], min_r)
		# Dominant light: the star with the strongest apparent brightness.
		var ang := -2.35
		if not fusion:
			var best := 0.0
			for s in ns:
				var dx := spx[s] - x
				var dy := spy[s] - y
				var b := sm[s] / (dx * dx + dy * dy + 1.0)
				if b > best:
					best = b
					ang = atan2(dy, dx)
		var size := 2.0 * r * halo
		var ca := cos(ang) * size
		var sa := sin(ang) * size
		var bits := 0
		if fusion:
			bits |= 1
		if i == pl:
			bits |= 2
		elif pl_mass > 0.0:
			if m < pl_mass:
				bits |= 4
			else:
				bits |= 8
		var c := u.col[i]
		var o := w * FLOATS
		buf[o] = ca
		buf[o + 1] = -sa
		buf[o + 2] = 0.0
		buf[o + 3] = x
		buf[o + 4] = sa
		buf[o + 5] = ca
		buf[o + 6] = 0.0
		buf[o + 7] = y
		buf[o + 8] = c.r
		buf[o + 9] = c.g
		buf[o + 10] = c.b
		buf[o + 11] = float(bits)
		buf[o + 12] = t
		buf[o + 13] = glow
		buf[o + 14] = u.seeds[i] + minf(u.ripple[i], 0.99)
		buf[o + 15] = halo
		w += 1
	multimesh.buffer = buf
	multimesh.visible_instance_count = w
	visible_count = w
