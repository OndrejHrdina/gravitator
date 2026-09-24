shader_type canvas_item;
// GPU-driven one-shot effects around a point: shockwave rings, flashes,
// implosions ("gulp") and ignition bursts.
//
// Per instance:
//   MODEL_MATRIX[3].xy – centre at birth
//   MODEL_MATRIX[0].xy – (max radius, lifetime)
//   MODEL_MATRIX[1].xy – carrier velocity (the effect drifts with its body)
//   INSTANCE_CUSTOM    – (birth time, thickness, kind, seed)
//   COLOR              – rgb colour, a: intensity
// kind: 0 shockwave, 1 flash, 2 implosion, 3 ignition burst
render_mode blend_add, skip_vertex_transform, unshaded;

uniform float u_now = 0.0;

varying vec2 v_p;
varying vec4 v_col;
varying vec4 v_prm;

void vertex() {
	vec2 c = MODEL_MATRIX[3].xy;
	float rmax = MODEL_MATRIX[0].x;
	float life = MODEL_MATRIX[0].y;
	vec2 vc = MODEL_MATRIX[1].xy;
	float age = u_now - INSTANCE_CUSTOM.x;
	float f = life > 0.0 ? age / life : 2.0;
	vec2 lv = VERTEX;
	v_p = lv * 2.4;
	v_col = COLOR;
	v_prm = vec4(f, INSTANCE_CUSTOM.y, INSTANCE_CUSTOM.z, INSTANCE_CUSTOM.w);
	if (f < 0.0 || f > 1.0) {
		VERTEX = c;
	} else {
		VERTEX = c + vc * age + lv * rmax * 2.4;
	}
}

void fragment() {
	float f = clamp(v_prm.x, 0.0, 1.0);
	float thick = max(v_prm.y, 0.01);
	int kind = int(v_prm.z + 0.5);
	float seedv = v_prm.w;
	float d = length(v_p);
	vec3 c = vec3(0.0);
	if (kind == 0) {
		float r = 1.0 - pow(1.0 - f, 3.0);
		float w = thick * (1.0 - 0.6 * f) + 0.01;
		float ring = exp(-pow((d - r) / w, 2.0));
		float inner = exp(-pow((d - r * 0.85) / (w * 2.5), 2.0)) * 0.25;
		c = v_col.rgb * (ring + inner) * pow(1.0 - f, 1.5);
	} else if (kind == 1) {
		float s = 0.08 + 0.5 * f;
		float g = exp(-d * d / s) + 0.35 * exp(-d * d / (s * 6.0));
		c = mix(vec3(1.0), v_col.rgb, 0.35 + 0.5 * f) * g * pow(1.0 - f, 2.5) * 2.0;
	} else if (kind == 2) {
		float r = pow(1.0 - f, 1.6);
		float w = thick * (0.5 + 0.5 * r) + 0.01;
		float ring = exp(-pow((d - r) / w, 2.0));
		c = v_col.rgb * ring * smoothstep(0.0, 0.25, f) * (1.0 - f) * 1.5;
	} else {
		float ang = atan(v_p.y, v_p.x);
		float rays = pow(abs(sin(ang * 6.0 + seedv)), 18.0) + pow(abs(sin(ang * 11.0 - seedv * 2.0)), 30.0) * 0.7;
		float r = 1.0 - pow(1.0 - f, 2.0);
		float beam = rays * smoothstep(r + 0.05, r - 0.4, d) * smoothstep(0.0, 0.15, d);
		float ring = exp(-pow((d - r) / (thick + 0.02), 2.0));
		float core = exp(-d * d / (0.05 + 0.2 * f));
		c = v_col.rgb * (beam * 1.5 + ring + core * 2.0) * pow(1.0 - f, 1.3);
	}
	// Fade out before the quad's edge so its square never shows.
	c *= 1.0 - smoothstep(1.0, 1.18, d);
	COLOR = vec4(c * v_col.a, 1.0);
}
