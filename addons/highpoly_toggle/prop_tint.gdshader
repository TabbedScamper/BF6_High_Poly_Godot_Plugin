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

// UNBOUND READS WHITE, which is what the tile-paint records need: they carry no
// colour sheet at all and their paint is the whole of their colour. Spelled as
// the absence of a hint rather than hint_default_white, so the declaration stays
// inside the same idiom foliage_wind.gdshader is already known to compile in.
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap;
// The `_nmt` sheet: RGB is the normal, A is the paint mask. One texture, two
// jobs, which is why the mask costs no extra memory.
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap;
uniform sampler2D emission_tex : source_color, filter_linear_mipmap;
uniform bool use_normal = false;
// SEPARATE FROM use_normal ON PURPOSE. A tile-painted body binds a normal map
// too, and its alpha is not a paint mask — masking the tile paint by it would
// wash a bus out wherever that channel happened to dip. Only the tint path,
// which measured this sheet's alpha and found it varying, turns the mask on.
uniform bool use_paint_mask = false;
uniform bool use_emission = false;
// LINEAR, AND DELIBERATELY NOT source_color. Every Godot material colour is a
// source_color and gets srgb_to_linear applied before the shader sees it, so a
// linear value handed over as a Color is linearised twice — and this one is a
// MULTIPLIER that routinely exceeds 1.0 (a playground frame is 1.92 on red),
// which a Color channel cannot carry at all. A plain vec3 takes the depot's
// number as it stands.
uniform vec3 tint = vec3(1.0);
uniform float normal_scale : hint_range(-16.0, 16.0) = 1.0;

// TILE PAINT — the second job this shader does.
//
// A bus, a semi trailer and a delivery van do not ship a colour sheet at all
// (impl/notes/material-recipes.md, recipe 1): their paint is two eight-entry
// palettes, one clean and one aged, and a greyscale "tilebreaker" sheet that
// says how far each texel has weathered:
//
//     paint[zone] = lerp(A[zone], B[zone], tilebreaker(uv))
//
// The zone is the same per-vertex selector the colour table uses, resolved on
// the CPU, so what arrives here is one A and one B. This is the recipe the
// research repo validated numerically against in-game photographs of the bus —
// the strongest-evidenced recipe in it — and the result is bounded by two
// authored paint colours whatever the breaker does, which is the important
// property while its UV scale is still a guess.
uniform vec3 tint_b = vec3(1.0);
uniform sampler2D breaker_tex : filter_linear_mipmap;
uniform bool use_breaker = false;
uniform float breaker_scale = 1.0;

// PER-TEXEL SMOOTHNESS, OUT OF THE COLOUR SHEET'S OWN ALPHA.
//
// _cs is colour+smoothness, on the same naming the decal sheets use (_ca is
// colour+alpha, _nsa is normal-smoothness-alpha), and its alpha channel is the
// smoothness map. Surveyed over 502 distinct basecolor sheets on mp_dumbo: 460
// continuous and mid-range, 7 constant, and the 35 that pile at 0 and 1 are
// almost all _cu VEGETATION, which never reaches this shader. The direction is
// confirmed by materials that cannot be confused - a concrete wall reads
// 0.06-0.10 and painted metal 0.745-0.875.
//
// IT IS NOT OPACITY, which matters because reading it as opacity is inviting
// and destructive: cutting this channel at 0.5 would erase 91% of an ammo crate
// and 99% of an electrical box surface. The corpus says the same thing from the
// other end (veg-cu-alpha-is-not-the-cutout).
//
// Free: the sheet is already sampled for ALBEDO, so this is one subtract and no
// extra fetch. Everything drew at a flat ROUGHNESS = 1 before, which is why
// props read uniformly matte whatever they are made of.
uniform bool use_smooth = false;
// PROP LIGHTING. 1.0 is the sheet as authored, which reads as a lamp that is not
// switched on; the panel raises it so a bulb, a screen or a lit sign reads as
// POWERED. The sheet is the level's; the multiplier is the switch and is ours.
uniform float emission_energy = 1.0;

void fragment() {
	vec4 c = texture(albedo_tex, UV);
	vec4 n = texture(normal_tex, UV);
	float paint = use_paint_mask ? n.a : 1.0;
	vec3 t = tint;
	if (use_breaker) {
		t = mix(tint, tint_b, texture(breaker_tex, UV * breaker_scale).r);
	}
	ALBEDO = c.rgb * mix(vec3(1.0), t, paint);
	if (use_normal) {
		NORMAL_MAP = n.rgb;
		NORMAL_MAP_DEPTH = normal_scale;
	}
	if (use_emission) {
		EMISSION = texture(emission_tex, UV).rgb * emission_energy;
	}
	ROUGHNESS = use_smooth ? clamp(1.0 - c.a, 0.02, 1.0) : 1.0;
	METALLIC = 0.0;
}
