shader_type spatial;
// Subtle foliage wind for the map-context overlay ("Foliage Wind" in
// Configure Shaders). Leaf-card materials are swapped to this by
// _wind_swap_materials(), and ONLY while the wind pref is on.
//
// THIS SHADER MUST REPRODUCE THE MATERIAL IT REPLACES. The first version
// carried albedo, a tint and an alpha cutoff and nothing else, hard-setting
// ROUGHNESS to 1.0 — so every tree, hedge, ivy and planter (157 props on
// Dumbo, matched by WIND_MAT_PAT) lost its normal map, roughness, metallic and
// AO the moment it loaded, and read flat next to the correctly shaded trunk
// beside it. The comment that used to sit here claimed it "renders identically
// to the baked StandardMaterial" at zero wind. It did not, and the swap ran
// even with wind switched OFF, so the downgrade was paid for a disabled
// feature.
//
// Samplers are paired with use_* flags rather than leaning on default
// textures: an unbound sampler reads white in Godot, which is harmless for
// roughness or AO but yields a broken (1,1,1) normal rather than a flat one.
render_mode cull_disabled;   // leaf cards are double-sided by construction

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap;
uniform vec4 albedo_mul : source_color = vec4(1.0);
uniform float alpha_cut : hint_range(0.0, 1.0) = 0.5;

uniform float wind_strength = 0.0;   // metres of sway at canopy height; 0 = off
uniform float wind_speed = 1.2;

uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap;
uniform bool use_normal = false;
uniform float normal_scale : hint_range(-16.0, 16.0) = 1.0;

uniform sampler2D rough_tex : hint_default_white, filter_linear_mipmap;
uniform bool use_rough_tex = false;
uniform int rough_channel : hint_range(0, 3) = 1;
uniform float roughness_mul : hint_range(0.0, 1.0) = 1.0;

uniform sampler2D metal_tex : hint_default_white, filter_linear_mipmap;
uniform bool use_metal_tex = false;
uniform int metal_channel : hint_range(0, 3) = 2;
uniform float metallic_mul : hint_range(0.0, 1.0) = 0.0;

uniform sampler2D ao_tex : hint_default_white, filter_linear_mipmap;
uniform bool use_ao = false;
uniform int ao_channel : hint_range(0, 3) = 0;
uniform float ao_affect : hint_range(0.0, 1.0) = 0.0;

uniform float specular_amount : hint_range(0.0, 1.0) = 0.5;

// GLSL has no dynamic swizzle, and BaseMaterial3D stores roughness / metallic /
// AO in an author-chosen channel of a packed texture.
float pick(vec4 v, int ch) {
	if (ch == 0) { return v.r; }
	if (ch == 1) { return v.g; }
	if (ch == 2) { return v.b; }
	return v.a;
}

void vertex() {
	if (wind_strength > 0.0) {
		vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
		// per-instance phase from world position; two detuned sines so the
		// whole map never sways in lockstep (minecraft-shader feel, subtler)
		float ph = dot(wp.xz, vec2(0.31, 0.17)) + TIME * wind_speed;
		float sway = sin(ph) * 0.6 + sin(ph * 2.33 + 1.3) * 0.4;
		float mask = clamp(VERTEX.y * 0.25, 0.0, 1.0);   // higher foliage sways more
		VERTEX.x += sway * wind_strength * mask;
		VERTEX.z += cos(ph * 0.77) * 0.6 * wind_strength * mask;
	}
}

void fragment() {
	vec4 c = texture(albedo_tex, UV) * albedo_mul;
	ALBEDO = c.rgb;
	ALPHA = c.a;
	ALPHA_SCISSOR_THRESHOLD = alpha_cut;

	float r = roughness_mul;
	if (use_rough_tex) { r *= pick(texture(rough_tex, UV), rough_channel); }
	ROUGHNESS = r;

	float mt = metallic_mul;
	if (use_metal_tex) { mt *= pick(texture(metal_tex, UV), metal_channel); }
	METALLIC = mt;

	SPECULAR = specular_amount;

	if (use_normal) {
		NORMAL_MAP = texture(normal_tex, UV).rgb;
		NORMAL_MAP_DEPTH = normal_scale;
	}
	if (use_ao) {
		AO = pick(texture(ao_tex, UV), ao_channel);
		AO_LIGHT_AFFECT = ao_affect;
	}
}
