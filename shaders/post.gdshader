shader_type canvas_item;
// Screen-space impact juice: shockwave distortion, chromatic aberration,
// a white/coloured flash and a vignette.
render_mode unshaded;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
// xy: centre in screen UV, z: radius (in screen heights), w: strength
uniform vec4 u_waves[8];
uniform int u_wave_count = 0;
uniform float u_aberration = 0.0;
uniform float u_flash = 0.0;
uniform vec3 u_flash_color = vec3(1.0);
uniform float u_vignette = 0.3;
uniform float u_desaturate = 0.0;

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 px = SCREEN_PIXEL_SIZE;
	float aspect = px.y / px.x;  // width / height
	vec2 offset = vec2(0.0);
	for (int i = 0; i < 8; i++) {
		if (i >= u_wave_count) {
			break;
		}
		vec4 w = u_waves[i];
		vec2 d = uv - w.xy;
		d.x *= aspect;
		float dist = length(d);
		float x = (dist - w.z) / 0.035;
		float prof = x * exp(-x * x) * w.w;
		if (dist > 1e-4) {
			vec2 dir = d / dist;
			dir.x /= aspect;
			offset -= dir * prof * 0.03;
		}
	}
	vec2 duv = uv + offset;
	vec2 fromc = duv - 0.5;
	float ab = u_aberration + length(offset) * 2.0;
	vec3 col;
	col.r = texture(screen_tex, duv + fromc * ab * 0.03).r;
	col.g = texture(screen_tex, duv).g;
	col.b = texture(screen_tex, duv - fromc * ab * 0.03).b;
	float grey = dot(col, vec3(0.299, 0.587, 0.114));
	col = mix(col, vec3(grey), u_desaturate);
	col += u_flash_color * u_flash;
	float vig = smoothstep(1.25, 0.25, length(fromc * vec2(aspect * 0.8, 1.0)));
	col *= mix(1.0, vig, u_vignette);
	// Triangular dither of ±1 LSB in sRGB space: kills banding in the dark
	// gradients of space before the final 8-bit output.
	vec2 fc = FRAGCOORD.xy;
	float n = fract(sin(dot(fc, vec2(12.9898, 78.233))) * 43758.5453)
			+ fract(sin(dot(fc, vec2(39.3468, 11.1353))) * 24634.6345) - 1.0;
	vec3 srgb = pow(max(col, vec3(0.0)), vec3(1.0 / 2.2));
	srgb += n / 255.0;
	col = pow(max(srgb, vec3(0.0)), vec3(2.2));
	COLOR = vec4(col, 1.0);
}
