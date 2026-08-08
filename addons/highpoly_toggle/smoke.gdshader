shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, unshaded, shadows_disabled;

// BACKDROP SMOKE PLUMES: the columns of smoke standing over the skyline.
//
// The meshes were being placed all along - 23 of them on mp_aftermath - and
// drawn WHITE, because the record binds no named basecolor slot. It binds a
// family of its own, the same way the decals did:
//
//   0x48B69B15  t_bd_smokeplumes_02_ca   RGB the smoke, A its shape
//   0xBA5B7844  t_tilingnoise_01_rgbm    the sheet the motion comes from
//
// WHAT IS THE GAME'S, read from the record:
//
//   0xD021807F  (1.000, 0.920, 0.776)   the tint. The only non-neutral float3
//                                       in the record; 0xE347A831 beside it is
//                                       (1,1,1) and says nothing.
//   0xC4C39A0C  (0.000, 0.100)          scroll A
//   0xC4C39A0D  (0.000, 0.500)          scroll B
//
// The two scrolls are consecutive hashes holding Vec2s whose x is ZERO and
// whose y differs by 5x - a slow layer and a fast one, both purely vertical.
// That is what rising smoke is, and a sibling sheet in the same directory is
// named t_bd_smokeplume_05_rising_unpremult, which says the same thing in words.
//
// WHAT IS OURS, and stated rather than smuggled: that scroll B drives a
// DISTORTION of the smoke's own lookup rather than a second visible layer, and
// how strong that distortion is. The record carries 0.020, 0.080 and 0.100 as
// bare scalars and nothing in it says which is which, so distort_amount starts
// at the 0.080 sitting in there and is a uniform anyone can turn.
//
// Also ours: unshaded. A plume this far out is lit by the sky and nothing else,
// and letting the editor's directional light rake across it makes it read as a
// solid object rather than as smoke.

uniform sampler2D smoke_tex : source_color, filter_linear_mipmap;
uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform bool has_noise = false;
uniform vec3 tint : source_color = vec3(1.0, 0.92, 0.776);
uniform vec2 scroll_a = vec2(0.0, 0.10);
uniform vec2 scroll_b = vec2(0.0, 0.50);
uniform float distort_amount : hint_range(0.0, 0.5) = 0.08;
uniform float noise_scale = 0.35;
// The plume fades out where it meets its own top and bottom edges rather than
// ending on a hard line. Ours: the sheet has the shape, not the falloff.
uniform float edge_fade : hint_range(0.0, 0.5) = 0.12;

void fragment() {
	vec2 uv = UV;
	if (has_noise) {
		// The noise is what MOVES. Sampled at its own rate and used to push the
		// smoke's lookup around, so the plume boils and drifts instead of
		// sliding as one rigid image - which is what a single scroll looks like
		// and is the giveaway that smoke is a texture.
		vec2 nuv = UV * noise_scale + scroll_b * TIME;
		vec2 d = (texture(noise_tex, nuv).rg - 0.5) * 2.0 * distort_amount;
		uv += d;
	}
	uv += scroll_a * TIME;
	vec4 s = texture(smoke_tex, uv);
	ALBEDO = s.rgb * tint;
	// Fade at the top and bottom of the card so the plume dissolves rather than
	// ending on the mesh edge.
	float fade = smoothstep(0.0, edge_fade, UV.y) * smoothstep(0.0, edge_fade, 1.0 - UV.y);
	ALPHA = s.a * fade;
}
