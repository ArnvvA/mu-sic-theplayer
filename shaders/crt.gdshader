shader_type canvas_item;

// Sample the already-composited scene (background + cards + button).
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear;
uniform float millis = 0.0;
uniform vec2 resolution = vec2(1920.0, 1080.0);

vec2 curve(vec2 uv) {
	uv = (uv - 0.5) * 2.0;
	uv *= 1.1;
	uv.x *= 1.0 + pow(abs(uv.y) / 5.0, 2.0);
	uv.y *= 1.0 + pow(abs(uv.x) / 4.0, 2.0);
	uv = (uv / 2.0) + 0.5;
	uv = uv * 0.92 + 0.04;
	return uv;
}

void fragment() {
	vec2 uv = UV;
	uv = curve(uv);

	float x = sin(0.3 * millis + uv.y * 21.0)
	        * sin(0.7 * millis + uv.y * 29.0)
	        * sin(0.3 + 0.33 * millis + uv.y * 31.0) * 0.0017;

	vec3 col;
	col.r = texture(screen_texture, vec2(x + uv.x + 0.001, uv.y + 0.001)).r + 0.05;
	col.g = texture(screen_texture, vec2(x + uv.x + 0.000, uv.y - 0.002)).g + 0.05;
	col.b = texture(screen_texture, vec2(x + uv.x - 0.002, uv.y + 0.000)).b + 0.05;
	col.r += 0.08 * texture(screen_texture, 0.75 * vec2(x + 0.025,  -0.027) + vec2(uv.x + 0.001, uv.y + 0.001)).r;
	col.g += 0.05 * texture(screen_texture, 0.75 * vec2(x - 0.022,  -0.020) + vec2(uv.x + 0.000, uv.y - 0.002)).g;
	col.b += 0.08 * texture(screen_texture, 0.75 * vec2(x - 0.020,  -0.018) + vec2(uv.x - 0.002, uv.y + 0.000)).b;

	col = clamp(col * 0.6 + 0.4 * col * col * 1.0, 0.0, 1.0);

	float vig = 1.0 * 16.0 * uv.x * uv.y * (1.0 - uv.x) * (1.0 - uv.y);
	col *= vec3(pow(vig, 0.3));

	col *= vec3(0.95, 1.05, 0.95);
	col *= 2.8;

	float scans = clamp(0.35 + 0.35 * sin(3.5 * millis + uv.y * resolution.y * 1.5), 0.0, 1.0);
	float s = pow(scans, 5.7);
	col = col * vec3(0.4 + 0.7 * s);

	col *= 1.0 + 0.01 * sin(10.0 * millis);

	if (uv.x < 0.0 || uv.x > 1.0) col *= 0.0;
	if (uv.y < 0.0 || uv.y > 1.0) col *= 0.0;

	col *= 1.0 - 0.65 * vec3(clamp((mod(FRAGCOORD.x, 2.0) - 1.0) * 2.0, 0.0, 1.0));

	COLOR = vec4(col, 1.0);
}
