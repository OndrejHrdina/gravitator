class_name BarnesHut
extends RefCounted
## Barnes-Hut N-body gravity on a hierarchical space-partitioning tree.
##
## The universe is 2D, so the octree collapses to its 2D form — a quadtree
## (each cell splits into 2^dims = 4 children). The tree is rebuilt every step:
##
##   1. every body gets a 32-bit Morton code (interleaved quantised x/y bits),
##   2. codes are sorted natively (PackedInt64Array.sort),
##   3. cells are carved out of contiguous runs of equal code prefixes,
##   4. mass, centre of mass and a bounding radius are accumulated bottom-up.
##
## Forces are then evaluated per body by walking the tree. A cell is treated as
## a single point mass when it looks small from the body (bmax criterion:
## R_cell < θ · d). θ is chosen *per receiving body*, so the player and its
## surroundings get a tight θ (near-exact forces) while distant bodies use a
## coarse one — precision where it matters, speed everywhere else.
##
## The same walk doubles as the broad phase for collisions: a cell whose
## bounding radius (which includes each body's radius plus its motion over the
## step) overlaps the receiver is always opened, so every potentially touching
## pair is reported.
##
## The walk is embarrassingly parallel and runs on WorkerThreadPool.

const LEAF_SIZE := 8
const MIN_CHUNK := 48

var G := Phys.G
## Plummer softening (units²) for body-body interactions.
var eps2 := 4.0
var use_threads := true

# Timing (microseconds), for the debug overlay.
var build_usec := 0
var force_usec := 0

# Inputs for the current step (shared references, never copied).
var _n := 0
var _px: PackedFloat64Array
var _py: PackedFloat64Array
var _m: PackedFloat64Array
var _reff: PackedFloat64Array
var _th2: PackedFloat64Array
var _due: PackedByteArray
var _ax: PackedFloat64Array
var _ay: PackedFloat64Array

# Sorted body order and their Morton codes.
var order := PackedInt32Array()
## Bodies whose forces are evaluated this step, in Morton order.
var active := PackedInt32Array()
var active_count := 0
var _codes := PackedInt64Array()
var _keys := PackedInt64Array()

# Node storage (structure of arrays).
var node_count := 0
var _node_cap := 0
var n_lo := PackedInt32Array()      # first index into `order`
var n_hi := PackedInt32Array()      # one past the last index into `order`
var n_shift := PackedInt32Array()   # Morton bit position used to split this node
var n_child := PackedInt32Array()   # first child node, -1 for leaves
var n_cnt := PackedInt32Array()     # number of (contiguous) children
var n_skip := PackedInt32Array()    # next node when this one is not opened (-1 = done)
var n_mass := PackedFloat64Array()
var n_gm := PackedFloat64Array()    # G · mass
var n_cx := PackedFloat64Array()
var n_cy := PackedFloat64Array()
var n_r := PackedFloat64Array()     # bounding radius around the centre of mass
var n_r2 := PackedFloat64Array()

# Per-chunk collision candidate lists: flat [i0, j0, i1, j1, ...].
var pair_lists: Array[PackedInt32Array] = []
var _chunk_len := 0
var _chunks := 0


func _ensure_nodes(count: int) -> void:
	if count <= _node_cap:
		return
	var cap := maxi(count, _node_cap * 2 + 256)
	n_lo.resize(cap)
	n_hi.resize(cap)
	n_shift.resize(cap)
	n_child.resize(cap)
	n_cnt.resize(cap)
	n_skip.resize(cap)
	n_mass.resize(cap)
	n_gm.resize(cap)
	n_cx.resize(cap)
	n_cy.resize(cap)
	n_r.resize(cap)
	n_r2.resize(cap)
	_node_cap = cap


## Builds the tree over bodies [0, n). `reff` is each body's radius inflated by
## its motion over the step; it feeds the collision-aware opening test.
func build(n: int, px: PackedFloat64Array, py: PackedFloat64Array, mass: PackedFloat64Array, reff: PackedFloat64Array) -> void:
	var t0 := Time.get_ticks_usec()
	_n = n
	_px = px
	_py = py
	_m = mass
	_reff = reff
	node_count = 0
	if n == 0:
		build_usec = 0
		return

	# Bounding square.
	var minx := px[0]
	var maxx := minx
	var miny := py[0]
	var maxy := miny
	for i in range(1, n):
		var x := px[i]
		var y := py[i]
		if x < minx:
			minx = x
		elif x > maxx:
			maxx = x
		if y < miny:
			miny = y
		elif y > maxy:
			maxy = y
	var size := maxf(maxx - minx, maxy - miny)
	if size <= 0.0:
		size = 1.0
	var scale := 65535.0 / (size * 1.000001)

	# Morton keys: (code << 21) | body_index, sorted natively.
	_keys.resize(n)
	for i in n:
		var qx := int((px[i] - minx) * scale)
		var qy := int((py[i] - miny) * scale)
		qx = (qx | (qx << 8)) & 0x00FF00FF
		qx = (qx | (qx << 4)) & 0x0F0F0F0F
		qx = (qx | (qx << 2)) & 0x33333333
		qx = (qx | (qx << 1)) & 0x55555555
		qy = (qy | (qy << 8)) & 0x00FF00FF
		qy = (qy | (qy << 4)) & 0x0F0F0F0F
		qy = (qy | (qy << 2)) & 0x33333333
		qy = (qy | (qy << 1)) & 0x55555555
		_keys[i] = ((qx | (qy << 1)) << 21) | i
	_keys.sort()
	order.resize(n)
	_codes.resize(n)
	var codes := _codes
	for k in n:
		var key := _keys[k]
		order[k] = key & 0x1FFFFF
		codes[k] = key >> 21

	# Carve cells out of the sorted codes. Children are appended after their
	# parent, so a forward sweep visits parents first and a reverse sweep
	# visits children first.
	_ensure_nodes(maxi(64, n))
	n_lo[0] = 0
	n_hi[0] = n
	n_shift[0] = 30
	node_count = 1
	var q := 0
	while q < node_count:
		var lo := n_lo[q]
		var hi := n_hi[q]
		n_child[q] = -1
		n_cnt[q] = 0
		if hi - lo <= LEAF_SIZE:
			q += 1
			continue
		var sh := n_shift[q]
		var c_last := codes[hi - 1]
		var c_first := codes[lo]
		# Skip levels where every body falls into the same quadrant.
		while sh >= 0 and ((c_first >> sh) & 3) == ((c_last >> sh) & 3):
			sh -= 2
		if sh < 0:
			q += 1  # identical codes: oversized leaf
			continue
		_ensure_nodes(node_count + 4)
		var first := node_count
		var start := lo
		var q_hi := (c_last >> sh) & 3
		var cur := (c_first >> sh) & 3
		while cur < q_hi:
			# First index whose quadrant is beyond `cur` (codes are sorted).
			var a := start
			var b := hi
			while a < b:
				var mid := (a + b) >> 1
				if ((codes[mid] >> sh) & 3) <= cur:
					a = mid + 1
				else:
					b = mid
			n_lo[node_count] = start
			n_hi[node_count] = a
			n_shift[node_count] = sh - 2
			node_count += 1
			start = a
			cur = (codes[a] >> sh) & 3
		n_lo[node_count] = start
		n_hi[node_count] = hi
		n_shift[node_count] = sh - 2
		node_count += 1
		n_child[q] = first
		n_cnt[q] = node_count - first
		q += 1

	# Bottom-up moments.
	q = node_count - 1
	while q >= 0:
		var ch := n_child[q]
		var m := 0.0
		var sx := 0.0
		var sy := 0.0
		var r := 0.0
		if ch < 0:
			var lo := n_lo[q]
			var hi := n_hi[q]
			for k in range(lo, hi):
				var j := order[k]
				var mj := mass[j]
				m += mj
				sx += mj * px[j]
				sy += mj * py[j]
			var cx := sx / m
			var cy := sy / m
			for k in range(lo, hi):
				var j := order[k]
				var dx := px[j] - cx
				var dy := py[j] - cy
				var rr := sqrt(dx * dx + dy * dy) + reff[j]
				if rr > r:
					r = rr
			n_cx[q] = cx
			n_cy[q] = cy
		else:
			var ce := ch + n_cnt[q]
			for c in range(ch, ce):
				var mc := n_mass[c]
				m += mc
				sx += mc * n_cx[c]
				sy += mc * n_cy[c]
			var cx := sx / m
			var cy := sy / m
			for c in range(ch, ce):
				var dx := n_cx[c] - cx
				var dy := n_cy[c] - cy
				var rr := sqrt(dx * dx + dy * dy) + n_r[c]
				if rr > r:
					r = rr
			n_cx[q] = cx
			n_cy[q] = cy
		n_mass[q] = m
		n_gm[q] = G * m
		n_r[q] = r
		n_r2[q] = r * r
		q -= 1

	# Skip pointers turn the walk into a stackless loop: "open" goes to the
	# first child, "accept" jumps to the next sibling (or an ancestor's).
	n_skip[0] = -1
	for p in node_count:
		var ch := n_child[p]
		if ch < 0:
			continue
		var last := ch + n_cnt[p] - 1
		for c in range(ch, last):
			n_skip[c] = c + 1
		n_skip[last] = n_skip[p]
	build_usec = Time.get_ticks_usec() - t0


## Computes gravitational accelerations into `ax`/`ay` for every body with
## `due[i] != 0`, and gathers collision candidates into `pair_lists`.
## `th2` holds θ² per body.
func compute(due: PackedByteArray, th2: PackedFloat64Array, ax: PackedFloat64Array, ay: PackedFloat64Array) -> void:
	var t0 := Time.get_ticks_usec()
	_th2 = th2
	_due = due
	_ax = ax
	_ay = ay
	active.resize(_n)
	var na := 0
	for k in _n:
		var i := order[k]
		if due[i] != 0:
			active[na] = i
			na += 1
	active_count = na
	for c in pair_lists.size():
		pair_lists[c].clear()
	if na == 0:
		force_usec = 0
		return
	var workers := maxi(1, OS.get_processor_count())
	_chunks = clampi(na / MIN_CHUNK, 1, workers * 4) if use_threads else 1
	_chunk_len = int(ceil(float(na) / float(_chunks)))
	_chunks = int(ceil(float(na) / float(_chunk_len)))
	while pair_lists.size() < _chunks:
		pair_lists.append(PackedInt32Array())
	if _chunks == 1:
		_force_chunk(0)
	else:
		var id := WorkerThreadPool.add_group_task(_force_chunk, _chunks, -1, true, "barnes_hut")
		WorkerThreadPool.wait_for_group_task_completion(id)
	force_usec = Time.get_ticks_usec() - t0


## Walks the tree for one contiguous chunk of the active bodies (Morton order
## keeps each chunk spatially coherent, so its bodies open similar cells).
func _force_chunk(c: int) -> void:
	var start := c * _chunk_len
	var end := mini(start + _chunk_len, active_count)
	if start >= end:
		return
	var order_ := order
	var act := active
	var px := _px
	var py := _py
	var m := _m
	var reff := _reff
	var th2 := _th2
	var ax := _ax
	var ay := _ay
	var cgm := n_gm
	var ccx := n_cx
	var ccy := n_cy
	var cr := n_r
	var cr2 := n_r2
	var cchild := n_child
	var cskip := n_skip
	var clo := n_lo
	var chi := n_hi
	var pairs: PackedInt32Array = pair_lists[c]
	var due := _due
	var g := G
	var e2 := eps2

	for k in range(start, end):
		var i := act[k]
		var xi := px[i]
		var yi := py[i]
		var ri := reff[i]
		var t2 := th2[i]
		var fx := 0.0
		var fy := 0.0
		var nd := 0
		while nd >= 0:
			var dx := ccx[nd] - xi
			var dy := ccy[nd] - yi
			var d2 := dx * dx + dy * dy
			var rr := cr[nd] + ri
			if d2 * t2 > cr2[nd] and d2 > rr * rr:
				# Far enough: the whole cell acts as one point mass.
				var f := cgm[nd] / (d2 * sqrt(d2))
				fx += f * dx
				fy += f * dy
				nd = cskip[nd]
				continue
			var ch := cchild[nd]
			if ch >= 0:
				nd = ch
				continue
			# Leaf: exact pairwise interactions + collision candidates.
			var kk := clo[nd]
			var ke := chi[nd]
			while kk < ke:
				var j := order_[kk]
				kk += 1
				if j == i:
					continue
				var ddx := px[j] - xi
				var ddy := py[j] - yi
				var dd2 := ddx * ddx + ddy * ddy
				var rs := ri + reff[j]
				if dd2 < rs * rs and (i < j or due[j] == 0):
					pairs.append(i)
					pairs.append(j)
				var e := dd2 + e2
				var f := g * m[j] / (e * sqrt(e))
				fx += f * ddx
				fy += f * ddy
			nd = cskip[nd]
		ax[i] = fx
		ay[i] = fy
