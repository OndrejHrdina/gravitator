shader_type canvas_item;
// GPU-driven sparks: the CPU writes each spark exactly once when it is born and
// the vertex shader animates it from its birth time, so thousands of sparks
// cost nothing per frame on the CPU.
//
// Per instance (the node itself sits at the origin with an identity transform):
//   MODEL_MATRIX[3].xy – birth position
//   MODEL_MATRIX[0].xy – burst velocity (slowed by drag)
//   MODEL_MATRIX[1].xy – carrier velocity (constant, e.g. the body it came off)
//   INSTANCE_CUSTOM    – (birth time, lifetime, size, drag)
//   COLOR              – rgb colour, a: brightness
render_mode blend_add, skip_vertex_transform, unshaded;

uniform float u_now = 0.0;
uniform float u_min_size = 0.5;
uniform float u_streak = 0.035;

varying vec2 v_uv;
varying vec4 v_col;
varying float v_f;

void vertex() {
	vec2 p0 = MODEL_MATRIX[3].xy;
	vec2 vb = MODEL_MATRIX[0].xy;
	vec2 vc = MODEL_MATRIX[1].xy;
	float t0 = INSTANCE_CUSTOM.x;
	float life = INSTANCE_CUSTOM.y;
	float size = INSTANCE_CUSTOM.z;
	float drag = INSTANCE_CUSTOM.w;
	float age = u_now - t0;
	float f = life > 0.0 ? age / life : 2.0;
	vec2 lv = VERTEX;
	v_uv = lv * 2.0;
	v_col = COLOR;
	v_f = f;
	if (f < 0.0 || f > 1.0) {
		VERTEX = p0;
	} else {
		float decay = exp(-drag * age);
		float k = drag > 0.001 ? (1.0 - decay) / drag : age;
		vec2 pos = p0 + vb * k + vc * age;
		vec2 cv = vb * decay;
		float spd = length(cv);
		vec2 dir = spd > 0.001 ? cv / spd : vec2(1.0, 0.0);
		vec2 perp = vec2(-dir.y, dir.x);
		float sz = max(size * (1.0 - 0.55 * f), u_min_size);
		float len = sz + spd * u_streak;
		VERTEX = pos + dir * lv.x * 2.0 * len + perp * lv.y * 2.0 * sz;
	}
}

void fragment() {
	float d = length(v_uv);
	float a = smoothstep(1.0, 0.15, d);
	float f = clamp(v_f, 0.0, 1.0);
	// White-hot at birth, the material colour mid-life, embers at the end.
	vec3 c = mix(vec3(1.0, 0.92, 0.75) * 3.0, v_col.rgb * 2.2, smoothstep(0.0, 0.3, f));
	c = mix(c, v_col.rgb * 0.5 + vec3(0.45, 0.05, 0.0), smoothstep(0.55, 1.0, f));
	float fade = (1.0 - f) * (1.0 - f);
	COLOR = vec4(c * v_col.a * fade, a);
}
