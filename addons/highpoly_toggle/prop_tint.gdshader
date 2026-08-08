shader_type spatial;
// A PAINTED PROP WHERE ONLY PART OF IT IS PAINTED.
//
// BF6 authors most props in grey and colours them with a shader constant, and
// DESTRUCTION.md 9.5 says that constant is masked per texel by the ALPHA of the
// prop's `_nmt` normal map. A StandardMaterial3D cannot express that: its
// albedo_color multiplies the whole surface, so a brick wall whose paint should
// stop at the mortar gets the paint over the mortar too.
//
// THE POLARITY IS MEASURED, not assumed. The claim is falsifiable against the
// textures themselves: if high alpha marks the paintable part, the basecolour
// must be GREYER there, because that is the part the constant is going to
// colour. Over 90 matched _nmt/_cs pairs on mp_dumbo the mean basecolour
// saturation is 0.0295 where alpha >= 0.7 against 0.0904 where alpha <= 0.3 —
// 3.07x — and 76 of the 90 sheets separate that way individually. Two controls
// on the same texels return nothing: splitting by the normal map's RED channel
// gives 1.05x and splitting the sheet left-half against right-half gives 0.99x.
// So the alpha channel specifically names the grey, paintable texels, and the
// tint belongs where the alpha is HIGH.
//
// This shader is used ONLY where that alpha actually varies. A sheet whose
// alpha is a constant says nothing per texel, and those keep the plain
// StandardMaterial3D with a uniform tint (identical result at alpha 1.0, and no
// guess where a whole sheet reads 0.0).
//
// It reproduces exactly what the standard path builds and no more: albedo,
// normal, emission, roughness 1, metallic 0, double-sided. Anything else would
// be this material quietly shading differently from its neighbour.
render_mode cull_disabled;

uniform sampler2D albedo_tex : source_color, hint_default_white, filter_linear_mipmap;
// The `_nmt` sheet: RGB is the normal, A is the paint mask. One texture, two
// jobs, which is why the mask costs no extra memory.
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap;
uniform sampler2D emission_tex : source_color, hint_default_black, filter_linear_mipmap;
uniform bool use_normal = false;
uniform bool use_emission = false;
// LINEAR, AND DELIBERATELY NOT source_color. Every Godot material colour is a
// source_color and gets srgb_to_linear applied before the shader sees it, so a
// linear value handed over as a Color is linearised twice — and this one is a
// MULTIPLIER that routinely exceeds 1.0 (a playground frame is 1.92 on red),
// which a Color channel cannot carry at all. A plain vec3 takes the depot's
// number as it stands.
uniform vec3 tint = vec3(1.0);
uniform float normal_scale : hint_range(-16.0, 16.0) = 1.0;

void fragment() {
	vec4 c = texture(albedo_tex, UV);
	vec4 n = texture(normal_tex, UV);
	float paint = use_normal ? n.a : 1.0;
	ALBEDO = c.rgb * mix(vec3(1.0), tint, paint);
	if (use_normal) {
		NORMAL_MAP = n.rgb;
		NORMAL_MAP_DEPTH = normal_scale;
	}
	if (use_emission) {
		EMISSION = texture(emission_tex, UV).rgb;
	}
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
}
