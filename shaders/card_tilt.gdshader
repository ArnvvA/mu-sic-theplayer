shader_type canvas_item;

// ── Player-slot 3D card effect ────────────────────────────────────────────────
// Fakes a real 3D card spinning around its vertical axis. card.gd works out the
// rotation angle and feeds it in through `spin`; this shader turns the flat
// sprite into a perspective-correct spinning quad and shows a darkened back face
// when the card is turned away from you.
//
//   spin = 0       → front, facing you
//   spin = PI/2    → edge-on (a thin sliver)
//   spin = PI      → the same album art, mirrored left-to-right (the back)
//   spin = 2*PI    → front again
// card.gd sets `spin` every frame with material.set_shader_parameter("spin", ...).

uniform float spin = 0.0;            // rotation around the vertical axis (radians)
uniform float cam_dist = 2.5;        // camera distance (smaller = stronger perspective)
uniform float float_amp = 5.0;       // idle bob height (texture pixels)
uniform float bob_phase = 0.0;       // bob position, advanced by card.gd (slows when paused)
uniform float glare_strength = 0.30; // sliding sheen brightness
uniform float corner_radius = 0.05;  // matches the plain card's rounded corners
uniform float scrim = 0.0;           // bottom darkening for title text (see card_round)

// These carry data from the vertex stage to the fragment stage. We use them to do
// perspective-correct texturing by hand (see the notes below).
varying vec2  v_uvw;   // UV multiplied by the perspective weight
varying float v_w;     // the perspective weight itself

void vertex() {
	// Corner direction from the card's centre, in the range [-0.5, 0.5].
	vec2 c = UV - 0.5;
	// Recover the sprite's pixel size. A Sprite2D is centred, so VERTEX = c * size,
	// and its four corners always have c = +/-0.5 (never zero), so this is safe.
	vec2 size = VERTEX / c;

	// Rotate this corner around the vertical (Y) axis by `spin`.
	float cs = cos(spin);
	float sn = sin(spin);
	float x = c.x * cs;          // width shrinks to zero as the card turns edge-on
	float z = c.x * sn;          // depth: one side swings toward you, the other away
	float y = c.y;

	// Perspective: corners nearer the camera (z > 0) look bigger, farther ones
	// (z < 0) look smaller. `w` is this corner's perspective weight.
	float w = cam_dist / (cam_dist - z);
	vec2 projected = vec2(x, y) * w;

	// Write the new corner position (in pixels), then add the gentle idle bob.
	// card.gd drives `bob_phase` — it advances quickly while the song plays and
	// slowly when it's paused, so the float eases down instead of running forever.
	VERTEX = projected * size;
	VERTEX.y += sin(bob_phase) * float_amp;

	// A 2-triangle quad would smear the texture at steep angles. To fix that we
	// pass UV*w and w through, then divide them back in fragment() — that recovers
	// the correct ("perspective-correct") texture coordinate per pixel.
	v_uvw = UV * w;
	v_w   = w;
}

void fragment() {
	// Undo the perspective weighting to get the true texture coordinate.
	vec2 uv = v_uvw / v_w;

	// Sampling the same texture works for both faces. Once the card turns past
	// edge-on, the geometry has already flipped the corners, so the back shows the
	// same album art mirrored left-to-right — no extra work needed here.
	COLOR = texture(TEXTURE, uv);

	// Gradient scrim at the bottom, matching the flat card, so the slot card's
	// title stays readable while it spins.
	float g = smoothstep(0.55, 1.0, uv.y);
	COLOR.rgb *= 1.0 - g * scrim;

	// Sliding sheen that tracks the spin, like light glinting off the surface.
	vec2 spot = (uv - 0.5) + vec2(sin(spin), 0.0) * 0.4;
	float sheen = smoothstep(0.6, 0.0, length(spot));
	COLOR.rgb += sheen * glare_strength * COLOR.a;

	// Round the corners, same as the plain card, so the look is consistent while
	// it spins in the slot. (Same rounded-rectangle alpha mask as card_round.)
	vec2 p = abs(uv - 0.5);
	vec2 d = p - (vec2(0.5) - vec2(corner_radius));
	float dist = length(max(d, vec2(0.0))) - corner_radius;
	COLOR.a *= 1.0 - smoothstep(-0.004, 0.004, dist);
}
