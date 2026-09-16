shader_type spatial;
// One road-paint or ground-decal draw from the shared core
// (bf6_level_decal_draws). A port of the Unreal add-on's "Road" parent
// material (BF6HighPoly.cpp EnsureParentMaterial, EKind::Road):
//   base colour = albedo sheet (white when absent) * tint, with mip bias
//   normal      = sheet RG * 2 - 1, Z derived; roughness = 1 - sheet A
//                 (absent: RG 0.5, A 1)
//   opacity     = dot(opacity sheet, mask_select) * vertex alpha * opacity_scale
// Translucent and lit per pixel; the node casts no shadow. The core's normal
// sheets are DirectX-handed, Godot reads OpenGL, so green is flipped.
render_mode blend_mix, depth_draw_never, cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_sheet : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_sheet : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D opacity_sheet : filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool has_albedo = false;
uniform bool has_normal = false;
uniform bool has_opacity = false;
uniform vec3 tint = vec3(1.0);
uniform float opacity_scale = 1.0;
uniform vec4 mask_select = vec4(1.0, 0.0, 0.0, 0.0);
uniform float mip_bias = 0.0;
// NUDGED TOWARD THE CAMERA, because Godot has no depth bias to ask for.
//
// The paint sits 6 cm above a terrain mesh the CORE builds, while this plugin
// draws a terrain it tessellates differently. Wherever the two cross, the
// ground wins the depth test and the marking vanishes - worst looking straight
// down, where decal and ground are most nearly coplanar. That is the "invisible
// from top down" report, and it reads as a normals fault because the same decal
// draws fine from a low angle.
//
// The plugin's older road path has carried this for the same reason and at the
// same value; this shader, the one the shared-core draws use, never had it.
uniform float view_bias = 0.04;

void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	VERTEX += normalize(CAMERA_POSITION_WORLD - world) * view_bias;
}

void fragment() {
	vec4 base = has_albedo ? texture(albedo_sheet, UV, mip_bias) : vec4(1.0);
	ALBEDO = base.rgb * tint;
	vec4 n = has_normal ? texture(normal_sheet, UV, mip_bias) : vec4(0.5, 0.5, 1.0, 1.0);
	NORMAL_MAP = vec3(n.r, 1.0 - n.g, 1.0);
	ROUGHNESS = 1.0 - n.a;
	vec4 cov = has_opacity ? texture(opacity_sheet, UV, mip_bias) : vec4(1.0);
	ALPHA = clamp(dot(cov, mask_select) * COLOR.a * opacity_scale, 0.0, 1.0);
}
