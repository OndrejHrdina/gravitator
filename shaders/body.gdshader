shader_type canvas_item;
// Every celestial body is one instance of a quad in a MultiMesh.
//
// Per instance:
//   transform  – rotation points local +x at the dominant star (light), scale
//                is the quad size (radius * halo * 2)
//   COLOR      – rgb: base material colour, a: flag bits
//                (1 fusion, 2 player, 4 edible, 8 danger)
//   CUSTOM     – x: temperature, y: mass glow, z: seed + ripple (fract),
//                w: halo extent in radii
//
// Premultiplied alpha lets one shader draw an opaque sphere (alpha = 1) with
// an additive halo around it (alpha = 0, rgb > 0).
render_mode blend_premul_alpha, unshaded;

uniform float u_time = 0.0;

varying vec2 v_local;
varying vec4 v_col;
varying vec4 v_data;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash12(i);
	float b = hash12(i + vec2(1.0, 0.0));
	float c = hash12(i + vec2(0.0, 1.0));
	float d = hash12(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(vec2 p) {
	float s = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		s += a * vnoise(p);
		p = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8)) * p * 2.03 + vec2(1.7, 9.2);
		a *= 0.5;
	}
	return s;
}

// Stylised black-body ramp: dull red → orange → yellow → white → blue-white.
vec3 heat_color(float t) {
	vec3 c = vec3(1.0, 0.06, 0.01);
	c = mix(c, vec3(1.0, 0.42, 0.04), smoothstep(0.35, 1.0, t));
	c = mix(c, vec3(1.0, 0.82, 0.38), smoothstep(0.9, 1.8, t));
	c = mix(c, vec3(1.0, 0.97, 0.92), smoothstep(1.7, 2.8, t));
	c = mix(c, vec3(0.62, 0.78, 1.0), smoothstep(3.0, 5.5, t));
	return c;
}

float heat_intensity(float t) {
	return smoothstep(0.03, 0.6, t) * (0.5 + 0.6 * t);
}

void vertex() {
	float halo = INSTANCE_CUSTOM.w;
	v_local = VERTEX * 2.0 * halo;
	v_col = COLOR;
	v_data = INSTANCE_CUSTOM;
}

void fragment() {
	vec2 p = v_local;
	float d = length(p);
	float temp = v_data.x;
	float glow = v_data.y;
	float seedv = floor(v_data.z);
	float ripple = fract(v_data.z);
	float halo = v_data.w;
	int flags = int(v_col.a + 0.5);
	bool fusion = (flags & 1) != 0;
	bool is_player = (flags & 2) != 0;
	bool edible = (flags & 4) != 0;
	bool danger = (flags & 8) != 0;
	vec3 base = v_col.rgb;
	float aa = max(fwidth(d), 0.0005) * 1.25;

	// Absorbing something sends ripples across the surface.
	float wob = ripple * sin(d * 15.0 - u_time * 18.0 + seedv) * 0.05;
	float edge = 1.0 + wob * smoothstep(0.0, 1.0, d);
	float body_a = 1.0 - smoothstep(edge - aa, edge + aa, d);

	float hi = heat_intensity(temp);
	vec3 hc = heat_color(temp);
	vec3 col = vec3(0.0);
	if (body_a > 0.0) {
		float dd = min(d / edge, 1.0);
		float z = sqrt(max(1.0 - dd * dd, 0.0));
		vec3 n = vec3(p / edge, z);
		float spin = u_time * (0.03 + fract(seedv * 0.137) * 0.07) * (fract(seedv * 0.31) > 0.5 ? 1.0 : -1.0);
		float cs = cos(spin);
		float sn = sin(spin);
		vec2 q = vec2(cs * n.x - sn * n.y, sn * n.x + cs * n.y);
		vec2 suv = q / (0.45 + 0.55 * z) * 2.4 + vec2(seedv * 1.37, seedv * 0.73);
		if (fusion) {
			// Churning plasma with bright granulation and limb darkening.
			float g1 = fbm(suv * 1.6 + vec2(u_time * 0.21, -u_time * 0.15));
			float g2 = fbm(suv * 3.4 - vec2(u_time * 0.33, u_time * 0.09));
			float gran = g1 * 0.65 + g2 * 0.35;
			float limb = 0.55 + 0.45 * pow(z, 0.6);
			vec3 star = mix(base, hc, 0.25);
			col = star * (0.55 + 1.0 * gran) * limb;
			col += mix(hc, base, 0.5) * pow(gran, 4.0) * 1.4 * limb;
			col *= 1.0 + 0.25 * glow + ripple * 0.6;
		} else {
			float h = fbm(suv);
			float h2 = fbm(suv * 3.3 + 4.1);
			float blot = smoothstep(0.6, 0.72, vnoise(suv * 1.8 + 9.0));
			vec3 albedo = base * (0.45 + 0.8 * h + 0.25 * h2 - blot * 0.25);
			vec3 L = normalize(vec3(1.0, 0.0, 0.55));
			float ndl = dot(n, L);
			float lam = max(ndl, 0.0);
			vec3 lit = albedo * (0.13 + 1.2 * lam * smoothstep(-0.05, 0.3, ndl));
			float fres = pow(1.0 - z, 2.5);
			lit += base * fres * (0.25 + 1.3 * glow);
			lit += base * glow * (0.25 + 0.7 * h);
			// Heat: glowing fissures first, then a fully molten surface.
			float fis = 1.0 - smoothstep(0.0, 0.05 + 0.1 * clamp(temp, 0.0, 2.0), abs(fbm(suv * 1.3 + 17.0) - 0.5));
			float molten = smoothstep(1.0, 2.6, temp);
			float mask = mix(fis * (0.6 + 0.5 * h2), 0.55 + 0.45 * h, molten);
			lit *= 1.0 - 0.55 * smoothstep(0.3, 2.0, temp);
			lit += hc * min(hi, 1.5) * mask * 0.85 * (0.9 + 0.2 * sin(u_time * 4.0 + h * 12.0));
			lit += base * ripple * 0.6 * (0.5 + 0.5 * sin(d * 15.0 - u_time * 18.0));
			if (edible) {
				lit += base * fres * 1.4 * (0.55 + 0.45 * sin(u_time * 4.0 + seedv));
			}
			col = lit;
		}
	}

	// Halo: heavier bodies glow more, hot bodies glow in their heat colour.
	float outer = max(d - 1.0, 0.0);
	float span = max(halo - 1.0, 0.05);
	float fall = pow(clamp(1.0 - outer / span, 0.0, 1.0), 2.0);
	vec3 halo_rgb;
	// Fade to exactly zero before the quad's edge so it never shows.
	float win = 1.0 - smoothstep(halo * 0.75, halo * 0.98, d);
	if (fusion) {
		float ang = atan(p.y, p.x);
		float rays = 0.75 + 0.25 * sin(ang * 7.0 + u_time * 0.5 + seedv) * sin(ang * 13.0 - u_time * 0.8);
		float core = exp(-outer * 5.0 / span);
		float corona = exp(-outer * 2.2 / span) * rays;
		halo_rgb = mix(base, hc, 0.25) * (0.9 * core + 0.4 * corona) * (1.0 + 0.2 * glow);
	} else {
		float core = exp(-outer * 4.0 / span);
		float strength = glow * 1.0 + min(hi, 1.6) * 0.35;
		halo_rgb = mix(base, hc, clamp(hi, 0.0, 1.0)) * strength * (0.5 * core + 0.5 * fall);
	}
	halo_rgb *= win;
	if (is_player) {
		float ring = exp(-pow((d - 1.4) / 0.07, 2.0));
		halo_rgb += vec3(0.55, 1.0, 1.0) * ring * (0.7 + 0.3 * sin(u_time * 3.0));
	}
	if (danger) {
		float ring = exp(-pow((d - 1.18) / 0.04, 2.0));
		halo_rgb += vec3(1.0, 0.12, 0.08) * ring * (0.45 + 0.3 * sin(u_time * 6.0));
	}

	COLOR = vec4(col * body_a + halo_rgb * (1.0 - body_a), body_a);
}
