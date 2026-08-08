shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, unshaded, shadows_disabled;

// BACKDROP SMOKE PLUMES, both families.
//
// The meshes were always placed - 13 horizontal and 10 vertical on
// mp_aftermath - and drawn WHITE, because the record binds no named basecolor.
// It binds a family of its own, the way the decals do:
//
//   0x48B69B15  the smoke sheet, RGB and A
//   0xBA5B7844  t_tilingnoise_01_rgbm        (horizontal family)
//   0xD0182167  t_tilingnoises_curly_01_d    (vertical family)
//   0x42EC27B9  box_softedge_02              a soft-edge mask
//   0x0127E78C  t_blackbodyramps_01_m        temperature -> colour
//
// TWO RECIPES ON ONE SLOT, which is why one shader with one look was wrong:
//
//   horizontal   19.6 x 10 x 2.6 m card, t_bd_smokeplumes_02_ca, flat warm tint
//                (1.000, 0.920, 0.776), scrolls (0, 0.1) and (0, 0.5)
//   vertical     1.0 x 0.9 x 0.0 card in TWO surfaces, the rising sheet, a
//                NEUTRAL tint, scrolls (1, 0) and (0, 0.1) - crossed rather
//                than parallel - and a blackbody ramp on the second surface
//
// FROM THE RECORD, per material: the tint 0xD021807F, both scrolls
// 0xC4C39A0C / 0xC4C39A0D, the distortion 0x4315DC37 (SIGNED: 0.080 horizontal,
// -0.030 and -0.100 vertical) and a strength 0x3B6C99D6.
//
// OURS, and stated: that the second scroll drives a distortion of the smoke's
// lookup rather than a second visible layer; that the ramp is indexed by the
// sheet's own luminance; the noise tiling; and unshaded, because a plume this
// far out is lit by the sky and a directional light raking it makes it read as
// a solid object.
//
// The sheets are STRAIGHT alpha, measured: t_bd_smokeplumes_02_ca has RGB > A on
// 91% of its texels. The `_unpremult` in a sibling filename suggested otherwise
// and was a red herring.

uniform sampler2D smoke_tex : source_color, filter_linear_mipmap;
uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform sampler2D edge_tex : filter_linear;
uniform sampler2D ramp_tex : source_color, filter_linear;
uniform bool has_noise = false;
uniform bool has_edge = false;
uniform bool has_ramp = false;
uniform vec3 tint : source_color = vec3(1.0, 0.92, 0.776);
uniform vec2 scroll_a = vec2(0.0, 0.10);
uniform vec2 scroll_b = vec2(0.0, 0.50);
// Signed, and the record's own number.
uniform float distort_amount : hint_range(-0.5, 0.5) = 0.08;
uniform float gain : hint_range(0.0, 4.0) = 1.0;
uniform float noise_scale = 0.35;
// Only used when the record binds no soft-edge mask of its own.
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

	if (has_ramp) {
		// BLACKBODY: a temperature-to-colour strip, which is what gives a
		// vertical column a lit base instead of a uniform warm grey. Indexed by
		// the sheet's own luminance - that mapping is OURS; the strip is the
		// level's.
		float temp = clamp(dot(s.rgb, vec3(0.299, 0.587, 0.114)), 0.0, 1.0);
		ALBEDO = texture(ramp_tex, vec2(temp, 0.5)).rgb * tint * gain;
	} else {
		ALBEDO = s.rgb * tint;
	}

	float cover = s.a;
	if (has_edge) {
		// The card's own soft edge, from the game. Its alpha is a constant 1.0,
		// so the shape is in the colour channels.
		cover *= texture(edge_tex, UV).r;
	} else {
		cover *= smoothstep(0.0, edge_fade, UV.y)
			* smoothstep(0.0, edge_fade, 1.0 - UV.y);
	}
	ALPHA = cover;
}
