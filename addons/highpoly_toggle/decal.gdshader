shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, specular_schlick_ggx;

// PLACEABLE MESH DECALS: puddles, dirt, road lines, wall staining.
//
// Decals bind a slot family of their own and NONE of the named prop slots, so
// the ordinary material path resolved nothing for them and they drew untextured.
// Two slots carry content and the other three are placeholders on every record
// of every decal on the map (t_grid 134/134, t_debug_r 120/120, t_base_n 22/22),
// so they are simply never read.
//
// THE CHANNEL PACKING, measured off the decoded sheets rather than assumed:
//
//   colour slot (_ca)   RGB = colour, A = coverage. A spans 0..1 on all ten
//                       sheets sampled, so it is the cutout.
//   normal slot         RG  = normal XY. B and A depend on the family:
//     _nms (dirt, walls, road lines)  B is metallic and reads 0.00 on almost
//                       every sheet, A is SMOOTHNESS (dirt 0.10-0.13, concrete
//                       0.09-0.25 - rough, which is right).
//     _nsa (puddles)    B is SMOOTHNESS and spans 0..1, A is coverage.
//
// The two are told apart WITHOUT reading the filename: if the colour sheet is
// real its alpha is the coverage, and the normal sheet's alpha is smoothness. If
// there is no colour sheet, the normal sheet's alpha MUST be the coverage or the
// decal has none at all, which makes B the smoothness. Same rule, both families.
//
// A PUDDLE HAS NO COLOUR TEXTURE. Its colour slot binds t_grey, a flat
// placeholder. That is not a failure to resolve: a puddle is not a painted quad,
// it is a wetness effect - normal, high smoothness and coverage over whatever
// ground is underneath. So it contributes darkening and shine, not pigment.

uniform sampler2D col_tex : source_color, hint_default_white, filter_linear_mipmap;
uniform bool has_col = false;
uniform sampler2D nrm_tex : hint_default_transparent, filter_linear_mipmap;
uniform bool has_nrm = false;
// WHAT A COLOURLESS DECAL DOES TO THE GROUND. Ours, and it is the difference
// between a puddle and a grey patch.
//
// Water is not grey paint. It is nearly black in its own right, it lets what is
// underneath show through, and everything it reads as comes from the SHINE. So
// the albedo is dark rather than mid-grey, and the coverage is scaled down so
// the ground stays visible through it: at full coverage a mid-grey at alpha 1
// simply paints over the surface, which is what it was doing.
uniform vec3 wet_col : source_color = vec3(0.045, 0.050, 0.055);
// How much of the ground a fully-covered puddle hides. Not from the game.
uniform float wet_opacity : hint_range(0.0, 1.0) = 0.62;
// Water is smoother than any authored sheet says, because the sheet describes
// the WETNESS pattern and not a water surface. Floors it so a puddle always
// reflects, without flattening the variation the sheet does carry.
uniform float wet_min_smooth : hint_range(0.0, 1.0) = 0.82;
// WATER IS ITS REFLECTION, AND THE REFLECTION HAS TO BE DRAWN RATHER THAN
// HOPED FOR.
//
// A dark albedo at low roughness is physically a puddle and rendered as one it
// is a dark hole: non-metal F0 is about 0.05, so the sky contributes almost
// nothing, and at roughness 0.12 the sun's highlight collapses to a point too
// small to see. Both renders showed exactly that - the first a single hotspot,
// the second nothing at all.
//
// Godot gives a spatial shader no way to sample the sky, and this plugin cannot
// assume a scene has reflection probes, so the grazing-angle sheen is mixed in
// directly from a colour. It is a cheat, it is ours, and it is the difference
// between water and a stain. Face-on stays dark and see-through.
uniform float wet_fresnel : hint_range(0.0, 1.0) = 0.85;
uniform vec3 wet_sheen : source_color = vec3(0.52, 0.62, 0.78);
uniform float normal_scale : hint_range(-4.0, 4.0) = 1.0;
// OURS. The mesh is 0.00001 m thick and sits ON the surface it marks, so it
// z-fights it. The engine draws decals with a depth bias; Godot has none to set
// on a material, so the geometry is lifted along its own normal instead. Along
// the NORMAL and not along Y, because a facade decal is vertical and lifting
// that upward would slide it along the wall instead of off it.
uniform float lift = 0.012;

void vertex() {
	VERTEX += NORMAL * lift;
}

void fragment() {
	vec4 c = texture(col_tex, UV);
	vec4 n = texture(nrm_tex, UV);
	float cover;
	float smooth_v;
	float spec = 0.5;
	if (has_col) {
		ALBEDO = c.rgb;
		cover = c.a;
		smooth_v = has_nrm ? n.a : 0.5;
	} else {
		ALBEDO = wet_col;
		float wet_mask = has_nrm ? n.a : 1.0;
		cover = wet_mask * wet_opacity;
		smooth_v = max(has_nrm ? n.b : 0.9, wet_min_smooth);
		// Water's reflectance is the whole look of it. Left at the default a
		// dark albedo just reads as a dark hole in the ground.
		spec = 0.85;
		// Grazing angles go bright and opaque, face-on stays dark and
		// see-through. Applied to the COVERAGE as well as the colour, because a
		// puddle seen edge-on hides the ground under it: it is mirroring the sky
		// instead of showing what it sits on.
		//
		// THE SHEEN IS MULTIPLIED BY THE MASK, NOT ADDED TO IT. Added, it
		// brightened the whole quad including the texels where the puddle is not
		// - and since the mesh is a rectangle, that drew a faint rectangle
		// around every puddle. Visible in the render before this line changed.
		float f = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 4.0) * wet_fresnel;
		ALBEDO = mix(wet_col, wet_sheen, f);
		cover = clamp(wet_mask * (wet_opacity + f), 0.0, 1.0);
	}
	if (has_nrm) {
		// Z IS RECONSTRUCTED, NOT READ. B is smoothness or metallic on this
		// family, never the normal's Z, so feeding n.rgb to NORMAL_MAP would
		// tilt every decal by however shiny it is.
		vec2 nxy = (n.rg * 2.0 - 1.0) * normal_scale;
		float nz = sqrt(clamp(1.0 - dot(nxy, nxy), 0.0, 1.0));
		NORMAL_MAP = vec3(nxy * 0.5 + 0.5, nz * 0.5 + 0.5);
	}
	ALPHA = cover;
	ROUGHNESS = clamp(1.0 - smooth_v, 0.02, 1.0);
	METALLIC = 0.0;
	SPECULAR = spec;
}
