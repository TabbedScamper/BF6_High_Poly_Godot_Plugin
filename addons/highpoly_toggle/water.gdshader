shader_type spatial;
// BF6 map-context water surface (editor preview).
// Cheap, plausible BF6-style water: depth-tinted transparency (reads the depth
// buffer to see how much water sits over the ground), fresnel edge boost,
// procedural animated ripples (3-octave sine field, no textures), and a low-
// roughness specular response so the scene's DirectionalLight gives a sun glint.
// Applied by HighpolyWater.material() to the flat planes extracted from each
// map's WaterEntityData / placed water quads (see _add_water_plane).
render_mode blend_mix, cull_disabled, specular_schlick_ggx;

uniform vec3 shallow_color : source_color = vec3(0.11, 0.34, 0.36);
uniform vec3 deep_color : source_color = vec3(0.012, 0.074, 0.135);
uniform float depth_fade = 14.0;      // metres of water depth to reach deep_color
uniform float min_alpha = 0.45;       // shoreline opacity
uniform float max_alpha = 0.94;       // deep-water opacity
uniform float fresnel_boost = 0.25;   // extra opacity/brightness at grazing angles
uniform float ripple_scale = 22.0;    // metres per ripple tile (big = calm ocean)
uniform float ripple_speed = 0.8;
uniform float ripple_strength = 0.45; // normal perturbation amount
uniform float foam_strength = 0.30;   // shoreline brightening (0 = off)
uniform float roughness_min = 0.06;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

// tiny directional sine field; cheap enough for the editor viewport
float wheight(vec2 p, float t) {
	float h = 0.0;
	h += sin(p.x * 1.00 + t * 0.90) * 0.50;
	h += sin(p.y * 1.31 + t * 1.27) * 0.42;
	h += sin((p.x + p.y) * 0.61 - t * 0.68) * 0.35;
	h += sin(p.x * 0.83 - p.y * 1.72 + t * 1.63) * 0.27;
	return h;
}

void fragment() {
	// --- water column depth from the scene depth buffer ---
	float d = texture(depth_tex, SCREEN_UV).x;
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, d);
	vec4 vp = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	float scene_z = -(vp.z / vp.w);        // linear view-space distance to what's under us
	float water_depth = scene_z + VERTEX.z; // VERTEX.z is negative view z of this fragment
	// nothing rendered behind (sky/far plane) reads as deep water
	water_depth = (d <= 0.00001) ? depth_fade : max(water_depth, 0.0);
	float df = clamp(water_depth / max(depth_fade, 0.01), 0.0, 1.0);

	// --- animated procedural ripple normal (finite difference, 2 octaves) ---
	float t = TIME * ripple_speed;
	vec2 p1 = wpos.xz / max(ripple_scale, 0.01);
	vec2 p2 = wpos.xz / max(ripple_scale * 0.29, 0.01) + vec2(3.1, 7.7);
	float e = 0.15;
	float h0 = wheight(p1, t) + 0.45 * wheight(p2, t * 1.7);
	float hx = wheight(p1 + vec2(e, 0.0), t) + 0.45 * wheight(p2 + vec2(e, 0.0), t * 1.7);
	float hz = wheight(p1 + vec2(0.0, e), t) + 0.45 * wheight(p2 + vec2(0.0, e), t * 1.7);
	vec3 wn = normalize(vec3(-(hx - h0) / e * ripple_strength * 0.08, 1.0,
	                         -(hz - h0) / e * ripple_strength * 0.08));
	NORMAL = normalize((VIEW_MATRIX * vec4(wn, 0.0)).xyz);

	// --- fresnel ---
	float fr = pow(1.0 - clamp(dot(NORMAL, normalize(VIEW)), 0.0, 1.0), 5.0);

	// --- shade ---
	vec3 col = mix(shallow_color, deep_color, df);
	// subtle shoreline foam: brighten the last ~metre of depth, shimmered by the ripples
	float foam = foam_strength * smoothstep(1.2, 0.0, water_depth) * (0.6 + 0.4 * sin(h0 * 3.0 + t * 2.0));
	ALBEDO = clamp(col + foam + fr * fresnel_boost * 0.3, 0.0, 1.0);
	ALPHA = clamp(mix(min_alpha, max_alpha, df) + fr * fresnel_boost - foam * 0.5, 0.0, 1.0);
	METALLIC = 0.0;
	SPECULAR = 0.5;
	ROUGHNESS = clamp(roughness_min + df * 0.04 + foam * 0.5, 0.0, 1.0);
}
