class_name Sfx
extends Node
## Procedurally synthesised sound effects (no audio assets). Every sound is
## rendered once into an AudioStreamWAV at startup and played through a small
## voice pool with pitch/volume variation.

const RATE := 22050
const VOICES := 20

var _streams := {}
var _players: Array[AudioStreamPlayer] = []
var _next := 0
var _last_play := {}
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	_streams["pop"] = _wav(_pop())
	_streams["gulp"] = _wav(_gulp())
	_streams["thud"] = _wav(_thud())
	_streams["crack"] = _wav(_crack())
	_streams["whoosh"] = _wav(_whoosh())
	_streams["boom"] = _wav(_boom())
	_streams["ignite"] = _wav(_ignite())
	_streams["rankup"] = _wav(_rankup())
	for k in VOICES:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_players.append(p)
	var drone := AudioStreamPlayer.new()
	drone.stream = _wav(_drone(), true)
	drone.volume_db = -17.0
	add_child(drone)
	drone.play()


## Plays `name`. Rapid repeats of the same sound are rate-limited so a swarm of
## collisions doesn't turn into noise.
func play(sound: String, volume_db := 0.0, pitch := 1.0, min_gap_ms := 25) -> void:
	if not _streams.has(sound) or volume_db < -40.0:
		return
	var now := Time.get_ticks_msec()
	if now - int(_last_play.get(sound, -100000)) < min_gap_ms:
		return
	_last_play[sound] = now
	var p: AudioStreamPlayer = null
	for k in VOICES:
		var cand := _players[(_next + k) % VOICES]
		if not cand.playing:
			p = cand
			_next = (_next + k + 1) % VOICES
			break
	if p == null:
		p = _players[_next]
		_next = (_next + 1) % VOICES
	p.stream = _streams[sound]
	p.volume_db = volume_db
	p.pitch_scale = clampf(pitch * _rng.randf_range(0.94, 1.06), 0.2, 4.0)
	p.play()


# --- Synthesis --------------------------------------------------------------------

func _wav(s: PackedFloat32Array, loop := false) -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(s.size() * 2)
	for i in s.size():
		data.encode_s16(i * 2, int(clampf(s[i], -1.0, 1.0) * 32000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = data
	if loop:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = s.size()
	return w


func _buf(seconds: float) -> PackedFloat32Array:
	var s := PackedFloat32Array()
	s.resize(int(seconds * RATE))
	return s


## Bubbly "bloop" for swallowing a rock: a fast upward chirp.
func _pop() -> PackedFloat32Array:
	var s := _buf(0.2)
	var ph := 0.0
	for i in s.size():
		var t := float(i) / RATE
		var f := 330.0 + 700.0 * (1.0 - exp(-t * 38.0))
		ph += TAU * f / RATE
		var env := (1.0 - exp(-t * 700.0)) * exp(-t * 20.0)
		var thump := sin(TAU * 95.0 * t) * exp(-t * 30.0) * 0.5
		s[i] = (sin(ph) * 0.65 + sin(ph * 2.0) * 0.12) * env + thump
	return s


## Deeper, wetter swallow for big meals.
func _gulp() -> PackedFloat32Array:
	var s := _buf(0.45)
	var ph := 0.0
	var lp := 0.0
	for i in s.size():
		var t := float(i) / RATE
		var f := 110.0 + 160.0 * exp(-t * 9.0) + 60.0 * sin(t * 40.0) * exp(-t * 6.0)
		ph += TAU * f / RATE
		var env := (1.0 - exp(-t * 300.0)) * exp(-t * 7.0)
		lp += (_rng.randf_range(-1.0, 1.0) - lp) * 0.06
		s[i] = tanh((sin(ph) * 0.9 + lp * 1.5 * exp(-t * 14.0)) * env * 1.6) * 0.8
	return s


func _thud() -> PackedFloat32Array:
	var s := _buf(0.8)
	var ph := 0.0
	var lp := 0.0
	for i in s.size():
		var t := float(i) / RATE
		var f := 36.0 + 80.0 * exp(-t * 11.0)
		ph += TAU * f / RATE
		lp += (_rng.randf_range(-1.0, 1.0) - lp) * 0.1
		var v := sin(ph) * exp(-t * 5.0) + lp * 2.2 * exp(-t * 16.0)
		s[i] = tanh(v * 1.4) * 0.85
	return s


func _crack() -> PackedFloat32Array:
	var s := _buf(0.9)
	var ph := 0.0
	var hp_prev := 0.0
	var lp := 0.0
	for i in s.size():
		var t := float(i) / RATE
		var nz := _rng.randf_range(-1.0, 1.0)
		var hp := nz - hp_prev
		hp_prev = nz
		var crackle := 0.0
		if _rng.randf() < 0.012 * exp(-t * 4.0):
			crackle = _rng.randf_range(-1.0, 1.0) * 3.0
		lp += (nz - lp) * 0.08
		ph += TAU * (48.0 + 50.0 * exp(-t * 8.0)) / RATE
		var v := hp * 0.6 * exp(-t * 20.0) + crackle * exp(-t * 3.0) + lp * 1.4 * exp(-t * 6.0) + sin(ph) * 0.7 * exp(-t * 5.0)
		s[i] = tanh(v) * 0.8
	return s


func _whoosh() -> PackedFloat32Array:
	var s := _buf(0.38)
	var lp := 0.0
	var lp2 := 0.0
	for i in s.size():
		var t := float(i) / RATE
		var cut := 0.04 + 0.3 * exp(-t * 10.0)
		lp += (_rng.randf_range(-1.0, 1.0) - lp) * cut
		lp2 += (lp - lp2) * cut
		var env := (1.0 - exp(-t * 120.0)) * exp(-t * 9.0)
		s[i] = (lp - lp2 * 0.5) * env * 2.2
	return s


func _boom() -> PackedFloat32Array:
	var s := _buf(2.2)
	var ph := 0.0
	var lp := 0.0
	var lp2 := 0.0
	for i in s.size():
		var t := float(i) / RATE
		ph += TAU * (28.0 + 55.0 * exp(-t * 4.0)) / RATE
		var nz := _rng.randf_range(-1.0, 1.0)
		lp += (nz - lp) * 0.05
		lp2 += (lp - lp2) * 0.05
		var v := sin(ph) * exp(-t * 2.4) * 1.2 + lp2 * 7.0 * exp(-t * 1.6) + nz * 0.5 * exp(-t * 35.0)
		s[i] = tanh(v * 1.3) * 0.9
	return s


func _ignite() -> PackedFloat32Array:
	var s := _buf(3.4)
	var lp := 0.0
	var ph1 := 0.0
	var ph2 := 0.0
	var ph3 := 0.0
	var ph_b := 0.0
	for i in s.size():
		var t := float(i) / RATE
		var nz := _rng.randf_range(-1.0, 1.0)
		var swell_t := clampf(t / 1.3, 0.0, 1.0)
		lp += (nz - lp) * (0.01 + 0.25 * swell_t * swell_t)
		var swell := lp * swell_t * swell_t * (1.0 if t < 1.3 else exp(-(t - 1.3) * 3.0)) * 1.6
		var bt := maxf(t - 1.3, 0.0)
		ph_b += TAU * (30.0 + 60.0 * exp(-bt * 5.0)) / RATE
		var boom := 0.0 if t < 1.3 else sin(ph_b) * exp(-bt * 1.8) * 1.3
		ph1 += TAU * 220.0 / RATE
		ph2 += TAU * 277.2 / RATE
		ph3 += TAU * 329.6 / RATE
		var chord := (sin(ph1) + sin(ph2) * 0.8 + sin(ph3) * 0.7) * 0.18 * (0.0 if t < 1.3 else (1.0 - exp(-bt * 8.0)) * exp(-bt * 0.9))
		s[i] = tanh((swell + boom + chord) * 1.2) * 0.9
	return s


func _rankup() -> PackedFloat32Array:
	var s := _buf(0.9)
	var notes := [523.25, 659.25, 783.99, 1046.5]
	for i in s.size():
		var t := float(i) / RATE
		var v := 0.0
		for k in notes.size():
			var st := k * 0.07
			if t >= st:
				var tt := t - st
				v += sin(TAU * float(notes[k]) * tt) * exp(-tt * 4.0) * (1.0 - exp(-tt * 300.0)) * 0.22
		s[i] = v
	return s


## Seamless 8-second ambient pad (all frequencies complete whole cycles).
func _drone() -> PackedFloat32Array:
	var seconds := 8.0
	var s := _buf(seconds)
	var n := s.size()
	var freqs := [55.0, 82.5, 110.0, 164.875, 220.125]
	var amps := [0.35, 0.22, 0.18, 0.08, 0.05]
	# Filtered noise "wind", generated a little longer than the loop so the
	# start can be cross-faded with the overhang: no click at the loop point.
	var fade := RATE / 2
	var lp := 0.0
	var noise := PackedFloat32Array()
	noise.resize(n + fade)
	for i in n + fade:
		lp += (_rng.randf_range(-1.0, 1.0) - lp) * 0.02
		noise[i] = lp
	for i in n:
		var t := float(i) / RATE
		var v := 0.0
		for k in freqs.size():
			var lfo := 0.6 + 0.4 * sin(TAU * t * float(k + 1) / seconds + k)
			v += sin(TAU * float(freqs[k]) * t) * float(amps[k]) * lfo
		var nz := noise[i]
		if i < fade:
			var xf := float(i) / fade
			nz = noise[i] * xf + noise[n + i] * (1.0 - xf)
		s[i] = v * 0.5 + nz * 1.8 * (0.6 + 0.4 * sin(TAU * t / seconds))
	return s
