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
// What a colourless decal tints the ground by. Wet ground is darker and shinier
// than dry, and this is the darkening; the shine comes from the sheet.
uniform vec3 wet_col = vec3(0.30, 0.30, 0.31);
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
	if (has_col) {
		ALBEDO = c.rgb;
		cover = c.a;
		smooth_v = has_nrm ? n.a : 0.5;
	} else {
		ALBEDO = wet_col;
		cover = has_nrm ? n.a : 1.0;
		smooth_v = has_nrm ? n.b : 0.9;
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
}
