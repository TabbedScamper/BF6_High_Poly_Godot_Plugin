shader_type spatial;
// BF6 map-context water surface (editor preview).
//
// WHAT IS THE GAME'S AND WHAT IS OURS
//
// The game's, read out of the install every time a map is opened:
//   * the water colours          two linear float3 depot constants on the
//                                foam variant, one on the ocean variant. These
//                                are per map and they are why mp_dumbo's East
//                                River is grey and mp_aftermath's is teal.
//   * t_waterfoam_rgb            R foam patches, G bubble detail, B crest
//                                streaks. Bound by the harbour maps.
//   * t_oceanmicrodetail_nsh     the ripple NORMAL. RG = normal.xy,
//                                B = smoothness, A = height. Ocean maps only.
//   * t_oceanfoam_nsh            the ocean variant's foam, same packing.
//   * t_oceannoise               3-channel noise, used to break up tiling.
//
// Ours, still: the WAVE SHAPE. BF6 runs a GPU ocean simulation
// (WaterOceanSimulationEntityData: wind angle/speed, choppiness, spectrum) and
// writes displacement and normals into render targets at runtime. Nothing on
// disk holds the resulting wave field, so the low-frequency swell below is
// still a sine sum. What the real data now does is decide the COLOUR, the FOAM
// and (on ocean maps) the high-frequency ripple normal that sits on top of it.
//
// Also still ours: the depth-fade curve, the shoreline foam falloff, and the
// specular model. WaterAbsorption R/G/B (0.2, 0.5, 1.0) is on the game's
// OceanComponentData but reads backwards as an absorption coefficient (it would
// make deep water red), so it is deliberately NOT wired until the direction is
// measured rather than guessed.
render_mode blend_mix, cull_disabled, specular_schlick_ggx;

// ---- the approximation's own palette (used when the game data is absent) ----
uniform vec3 shallow_color : source_color = vec3(0.11, 0.34, 0.36);
uniform vec3 deep_color : source_color = vec3(0.012, 0.074, 0.135);

// ---- mined, LINEAR, no source_color hint: these are already linear floats and
// a second sRGB->linear conversion would darken them to mud ----
uniform bool use_game_color = false;
uniform vec3 game_shallow = vec3(0.068, 0.068, 0.068);
uniform vec3 game_deep = vec3(0.022, 0.022, 0.022);

uniform float depth_fade = 14.0;      // metres of water depth to reach the deep colour
uniform float min_alpha = 0.45;       // shoreline opacity
uniform float max_alpha = 0.94;       // deep-water opacity
uniform float fresnel_boost = 0.25;   // extra opacity/brightness at grazing angles
uniform float ripple_scale = 22.0;    // metres per swell tile (big = calm ocean)
uniform float ripple_speed = 0.8;
uniform float ripple_strength = 0.45; // swell normal perturbation amount
uniform float foam_strength = 0.30;   // shoreline brightening (0 = off)
uniform float roughness_min = 0.06;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;

// ---- the game's textures. `*_mode` is 0 when the map does not bind one, so a
// map on the reduced shader never samples a slot it has no data for. ----
uniform sampler2D foam_tex : filter_linear_mipmap, repeat_enable;
uniform int foam_mode = 0;            // 0 none, 1 _rgb (R patch, G bubbles, B streaks), 2 _nsh
uniform float foam_tiling = 26.0;     // metres per foam tile
uniform sampler2D detail_tex : filter_linear_mipmap, repeat_enable;
uniform bool has_detail = false;      // t_oceanmicrodetail_nsh present
uniform float detail_tiling = 5.5;    // metres per ripple tile
uniform float detail_strength = 1.0;
uniform float shore_fade = 0.3;       // OceanComponentData.ShoreFadeDistance

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

// tiny directional sine field standing in for the runtime ocean sim
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

	// --- swell: procedural, two octaves, finite-difference normal ---
	float t = TIME * ripple_speed;
	vec2 p1 = wpos.xz / max(ripple_scale, 0.01);
	vec2 p2 = wpos.xz / max(ripple_scale * 0.29, 0.01) + vec2(3.1, 7.7);
	float e = 0.15;
	float h0 = wheight(p1, t) + 0.45 * wheight(p2, t * 1.7);
	float hx = wheight(p1 + vec2(e, 0.0), t) + 0.45 * wheight(p2 + vec2(e, 0.0), t * 1.7);
	float hz = wheight(p1 + vec2(0.0, e), t) + 0.45 * wheight(p2 + vec2(0.0, e), t * 1.7);
	vec3 wn = normalize(vec3(-(hx - h0) / e * ripple_strength * 0.08, 1.0,
	                         -(hz - h0) / e * ripple_strength * 0.08));

	// --- the game's ripple normal on top of the swell ---
	// Two samples at different scales scrolling in different directions, which
	// is how a single tiling normal is made to read as moving water. RG is the
	// normal, B the smoothness, A the height (per the _nsh channel packing).
	float detail_smooth = 0.0;
	if (has_detail) {
		vec2 duv = wpos.xz / max(detail_tiling, 0.01);
		vec4 n1 = texture(detail_tex, duv + vec2(0.021, 0.013) * TIME);
		vec4 n2 = texture(detail_tex, duv * 0.47 + vec2(-0.009, 0.017) * TIME);
		vec2 dxz = ((n1.rg - 0.5) + (n2.rg - 0.5)) * 2.0 * detail_strength;
		wn = normalize(wn + vec3(dxz.x, 0.0, dxz.y));
		detail_smooth = 0.5 * (n1.b + n2.b);
	}
	NORMAL = normalize((VIEW_MATRIX * vec4(wn, 0.0)).xyz);

	// --- fresnel ---
	float fr = pow(1.0 - clamp(dot(NORMAL, normalize(VIEW)), 0.0, 1.0), 5.0);

	// --- colour: the map's own water, when we have it ---
	vec3 sc = use_game_color ? game_shallow : shallow_color;
	vec3 dc = use_game_color ? game_deep : deep_color;
	vec3 col = mix(sc, dc, df);

	// --- foam ---
	// Shoreline coverage is our own falloff (the game computes it from the sim's
	// depth buffer); ShoreFadeDistance scales how far it reaches. What the real
	// texture supplies is the SHAPE: patches, bubbles and crest streaks, which
	// is the part a sine field cannot fake.
	float shore = smoothstep(1.0 + shore_fade * 6.0, 0.0, water_depth);
	float crest = smoothstep(0.35, 0.95, h0 * 0.5 + 0.5);
	float foam = 0.0;
	vec3 foam_col = vec3(1.0);
	if (foam_mode == 1) {
		vec2 fuv = wpos.xz / max(foam_tiling, 0.01) + vec2(0.006, 0.004) * TIME;
		vec3 f = texture(foam_tex, fuv).rgb;
		foam = f.r * shore + f.b * crest;      // R patches at the shore, B streaks on crests
		foam_col = vec3(clamp(f.g * 1.6, 0.0, 1.0));
	} else if (foam_mode == 2) {
		vec2 fuv = wpos.xz / max(foam_tiling, 0.01) + vec2(0.006, 0.004) * TIME;
		vec4 f = texture(foam_tex, fuv);
		foam = f.a * (shore + crest);          // A is the foam height on the _nsh packing
		foam_col = vec3(clamp(0.6 + f.b * 0.6, 0.0, 1.0));
	} else {
		foam = foam_strength * smoothstep(1.2, 0.0, water_depth)
			* (0.6 + 0.4 * sin(h0 * 3.0 + t * 2.0));
	}
	foam = clamp(foam * foam_strength * 3.0, 0.0, 1.0);

	ALBEDO = clamp(mix(col, foam_col, foam) + fr * fresnel_boost * 0.3, 0.0, 1.0);
	ALPHA = clamp(mix(min_alpha, max_alpha, df) + fr * fresnel_boost + foam * 0.4, 0.0, 1.0);
	METALLIC = 0.0;
	SPECULAR = 0.5;
	ROUGHNESS = clamp(roughness_min + df * 0.04 + foam * 0.5
		- detail_smooth * 0.02, 0.0, 1.0);
}
