class_name Phys
extends RefCounted
## Physical constants, gameplay tuning and small helpers shared by the
## simulation, the renderers and the UI.
##
## Units are arbitrary "game" units: distance ~ pixels at zoom 1, time in
## seconds, mass in "rock" units. Nothing here is meant to be realistic —
## everything is tuned for feel.

# --- Gravity & matter --------------------------------------------------------

const G := 10.0

## Standard density of the universe's single non-descript material. Every
## object is a sphere, so its radius follows from its volume:
##   V = m / ρ,   r = cbrt(3V / 4π)
const DENSITY := 0.0153
static var RADIUS_K: float = pow(3.0 / (4.0 * PI * DENSITY), 1.0 / 3.0)

## Structural integrity. The energy needed to shatter a body of mass m is
##   B(m) = m · (STRENGTH · m^STRENGTH_EXP + SELF_GRAVITY · m^(2/3))
## The first term is material strength (bigger rocks are a bit tougher), the
## second is gravitational binding (uniform sphere: 3/5 · G m² / r), which
## dominates for planets and stars.
const STRENGTH := 7000.0
const STRENGTH_EXP := 0.12
static var SELF_GRAVITY: float = 1.5 * 3.0 * G / (5.0 * RADIUS_K)

## Fraction of the collision energy that turns into heat (per unit mass).
const HEAT_PER_ENERGY := 2.4e-4
## Above this mass a body ignites and sustains its own heat as a star.
const FUSION_MASS := 6.0e6
## Temperature ceiling, purely to keep the visuals sane.
const MAX_TEMP := 7.0

## Smallest fragment worth simulating as a body.
const FRAG_MIN_MASS := 0.12
## Bodies lighter than this slowly evaporate (keeps exhaust/dust in check).
const DUST_MASS := 0.25
const DUST_LIFETIME := 35.0
const MAX_BODIES := 2600

# --- Player ------------------------------------------------------------------

const PLAYER_START_MASS := 3.0
## Fraction of the current mass released on each thrust burst.
const THRUST_FRACTION := 0.03
## Speed of the ejected mass relative to the rock.
const EXHAUST_SPEED := 650.0
## Auto-repeat interval while the thrust key is held.
const THRUST_INTERVAL := 0.14
## Rocks lighter than this cannot afford to thrust any more.
const MIN_THRUST_MASS := 0.3
## Seconds of "ghosting" after being reborn as a fragment.
const RESPAWN_GRACE := 2.5

# --- Barnes-Hut precision ------------------------------------------------------

## Opening angle for the player itself (smaller = more precise).
const THETA_PLAYER := 0.25
## Opening angle for bodies within the player's neighbourhood.
const THETA_NEAR := 0.4
## Opening angle far away from the player.
const THETA_FAR := 1.0
const THETA_SLOPE := 0.22

# --- Ranks ---------------------------------------------------------------------

const RANKS := [
	[0.0, "Dust"],
	[1.0, "Pebble"],
	[6.0, "Rock"],
	[40.0, "Boulder"],
	[300.0, "Asteroid"],
	[2500.0, "Planetesimal"],
	[20000.0, "Moonlet"],
	[100000.0, "Moon"],
	[500000.0, "Planet"],
	[2000000.0, "Giant"],
	[FUSION_MASS, "Star"],
	[5.0e7, "Giant Star"],
	[2.5e8, "Hypergiant"],
]


static func radius(m: float) -> float:
	return RADIUS_K * pow(maxf(m, 0.0), 1.0 / 3.0)


static func binding_energy(m: float) -> float:
	return m * (STRENGTH * pow(m, STRENGTH_EXP) + SELF_GRAVITY * pow(m, 2.0 / 3.0))


static func escape_speed(m: float, r: float) -> float:
	return sqrt(2.0 * G * m / maxf(r, 0.001))


static func circular_speed(m: float, d: float) -> float:
	return sqrt(G * m / maxf(d, 0.001))


## Equilibrium temperature of a fusing body — heavier stars burn hotter/bluer.
static func fusion_temp(m: float) -> float:
	return clampf(2.4 + 1.3 * log(m / FUSION_MASS) / log(10.0), 2.4, MAX_TEMP - 0.5)


## Mass-weighted colour blend that keeps things vibrant: RGB is averaged for the
## hue, then saturation and value are restored to the weighted averages so that
## mixing does not wash everything out to grey-brown.
static func mix_color(a: Color, ma: float, b: Color, mb: float) -> Color:
	var w := mb / maxf(ma + mb, 1e-9)
	if w <= 0.0005:
		return a
	var c := a.lerp(b, w)
	var s := lerpf(a.s, b.s, w)
	var v := lerpf(a.v, b.v, w)
	if c.s < 0.02:
		# Complementary colours cancelled out: keep the dominant hue.
		return Color.from_hsv(a.h if w < 0.5 else b.h, s, v)
	return Color.from_hsv(c.h, s, v)


static func vivid_color(rng: RandomNumberGenerator, hue: float, hue_jitter := 0.08) -> Color:
	var h := fposmod(hue + rng.randf_range(-hue_jitter, hue_jitter), 1.0)
	return Color.from_hsv(h, rng.randf_range(0.55, 0.92), rng.randf_range(0.62, 0.95))


static func rank_index(m: float) -> int:
	var idx := 0
	for k in RANKS.size():
		if m >= float(RANKS[k][0]):
			idx = k
	return idx


static func rank_name(m: float) -> String:
	return String(RANKS[rank_index(m)][1])


## Splits `total` into `count` masses following a steep power law (a few big
## chunks, many small ones), sorted largest first.
static func split_masses(total: float, count: int, rng: RandomNumberGenerator) -> PackedFloat64Array:
	var w := PackedFloat64Array()
	w.resize(count)
	var sum := 0.0
	for k in count:
		var x := pow(rng.randf(), 2.2) + 0.04
		w[k] = x
		sum += x
	for k in count:
		w[k] = w[k] / sum * total
	w.sort()
	w.reverse()
	return w


static func format_mass(m: float) -> String:
	if m < 10.0:
		return "%.2f" % m
	if m < 1000.0:
		return "%.1f" % m
	if m < 1.0e6:
		return "%.1fk" % (m / 1000.0)
	if m < 1.0e9:
		return "%.2fM" % (m / 1.0e6)
	return "%.2fG" % (m / 1.0e9)
