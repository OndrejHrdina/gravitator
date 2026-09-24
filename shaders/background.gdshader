shader_type canvas_item;
// Deep-space backdrop: vivid nebulae and three parallax star layers that react
// gently to camera movement and zoom.
render_mode unshaded;

uniform vec2 u_cam = vec2(0.0);
uniform float u_zoom = 1.0;
uniform float u_time = 0.0;
uniform vec2 u_view = vec2(1600.0, 900.0);

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), u.x),
			mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), u.x), u.y);
}

float fbm(vec2 p) {
	float s = 0.0;
	float a = 0.5;
	for (int i = 0; i < 5; i++) {
		s += a * vnoise(p);
		p = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8)) * p * 2.02 + vec2(3.1, 1.7);
		a *= 0.5;
	}
	return s;
}

// One star per grid cell (in screen pixels), a crisp 1-2 px point plus a
// faint glint, twinkling slowly.
vec3 stars(vec2 p, float cell, float density, float radius, float seedv) {
	vec2 g = floor(p / cell);
	float h = hash21(g + seedv);
	if (h > density) {
		return vec3(0.0);
	}
	vec2 o = (vec2(hash21(g + seedv + 1.3), hash21(g + seedv + 7.1)) - 0.5) * cell * 0.7;
	float d = length(p - (g + 0.5) * cell - o);
	float tw = 0.6 + 0.4 * sin(u_time * (0.6 + h * 3.0) + h * 60.0);
	float r = radius * (0.6 + 0.8 * hash21(g + seedv + 5.9));
	float core = smoothstep(r + 0.8, r - 0.4, d);
	float glint = exp(-d * d / (r * r * 9.0)) * 0.18;
	float hue = hash21(g + seedv + 3.3);
	vec3 c = mix(vec3(0.65, 0.78, 1.0), vec3(1.0, 0.8, 0.6), hue);
	c = mix(c, vec3(1.0, 0.55, 0.95), step(0.92, hue));
	return c * (core + glint) * tw;
}

void fragment() {
	vec2 frag = (SCREEN_UV - 0.5) * u_view;
	float zs = pow(clamp(u_zoom, 1e-4, 100.0), 0.18);
	vec2 cam = u_cam * zs;

	// Base: a deep indigo gradient.
	vec3 col = mix(vec3(0.012, 0.004, 0.032), vec3(0.002, 0.008, 0.022), SCREEN_UV.y);

	// Nebulae (very slow parallax): domain-warped noise for organic wisps.
	vec2 nuv = (frag / zs + cam * 0.02) * 0.0011;
	vec2 q = vec2(fbm(nuv + vec2(0.0, u_time * 0.003)), fbm(nuv + vec2(5.2, 1.3)));
	vec2 r = vec2(fbm(nuv + 3.0 * q + vec2(1.7, 9.2)), fbm(nuv + 3.0 * q + vec2(8.3, 2.8) - u_time * 0.002));
	float n1 = fbm(nuv + 2.5 * r);
	vec3 magenta = vec3(0.62, 0.05, 0.55);
	vec3 teal = vec3(0.0, 0.48, 0.62);
	vec3 amber = vec3(0.8, 0.28, 0.03);
	vec3 neb = mix(magenta, teal, smoothstep(0.3, 0.7, q.x));
	neb = mix(neb, amber, smoothstep(0.55, 0.85, r.y) * 0.75);
	float dens = pow(smoothstep(0.35, 0.95, n1), 2.4);
	col += neb * dens * 0.55;
	// Dark dust lanes.
	col *= 1.0 - 0.55 * smoothstep(0.55, 0.8, fbm(nuv * 3.0 + 4.0 * r)) * dens;

	// Parallax star layers (pixel-sized points).
	vec2 sp = frag / zs;
	col += stars(sp + cam * 0.004, 26.0, 0.35, 0.55, 1.0) * 0.35;
	col += stars(sp + cam * 0.015, 48.0, 0.28, 0.8, 17.0) * 0.55;
	col += stars(sp + cam * 0.05, 90.0, 0.22, 1.1, 41.0) * 0.8;

	COLOR = vec4(col, 1.0);
}
