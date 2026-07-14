shader_type spatial;
// Subtle foliage wind for the map-context overlay ("Foliage Wind" in
// Configure Shaders). Leaf-card materials get swapped to this at load; with
// wind_strength 0 it renders identically to the baked StandardMaterial
// (albedo x tint, alpha-scissor cutout, double-sided), so the toggle is a
// pure uniform flip — no rebuild, no per-mesh state.
render_mode cull_disabled;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap;
uniform vec4 albedo_mul : source_color = vec4(1.0);
uniform float alpha_cut : hint_range(0.0, 1.0) = 0.5;
uniform float wind_strength = 0.0;   // metres of sway at canopy height; 0 = off
uniform float wind_speed = 1.2;

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
	ROUGHNESS = 1.0;
	SPECULAR = 0.1;
}
