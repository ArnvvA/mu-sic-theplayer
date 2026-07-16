shader_type canvas_item;

// Default skin for every card. The album art is already in COLOR (canvas_item
// shaders sample TEXTURE for you); all we do is round the corners by carving a
// little alpha out of them, so the square gets a soft edge.
//
//   corner_radius = 0.0  → hard square corners
//   corner_radius = 0.05 → a tiny, tasteful round (the default)

uniform float corner_radius : hint_range(0.0, 0.5) = 0.05;

// Gradient scrim: darkens the bottom of the card so the title text is readable.
// main.gd sets `scrim` to 0 on cards with no visible label, and up to its full
// strength on the ones that show a name. 0 = untouched art, 1 = fully dark base.
uniform float scrim : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	// Soft top-to-bottom darkening. `g` is 0 across the upper ~55% of the card,
	// then eases to 1 at the very bottom — a smooth fade with no hard edge.
	float g = smoothstep(0.55, 1.0, UV.y);
	COLOR.rgb *= 1.0 - g * scrim;

	// Distance from this pixel to the rounded-rectangle edge, in UV units.
	// Positive outside the shape, negative inside.
	vec2 p = abs(UV - 0.5);                       // 0 at centre, 0.5 at edges
	vec2 d = p - (vec2(0.5) - vec2(corner_radius));
	float dist = length(max(d, vec2(0.0))) - corner_radius;

	// Fade the last sliver to nothing for a smooth (anti-aliased) edge.
	COLOR.a *= 1.0 - smoothstep(-0.004, 0.004, dist);
}
