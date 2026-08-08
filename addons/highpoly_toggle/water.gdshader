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
//
// The game's, read off WaterOceanSimulationEntityData in the level's schematic
// (see highpoly_gamesource.water_sim for the measurements behind each):
//   * WindAngle            which way the swell travels. Radians.
//   * WindDistribution     a SplineCurve of energy by direction. Its control
//                          points become the wave components' directions and
//                          relative amplitudes, so a map with one narrow lobe
//                          gets a clean parallel swell and a map with a spread
//                          curve gets a confused cross sea, the way the game's
//                          own sim would.
//   * WindSpeed            overall roughness (wave_gain).
//   * Choppiness           crest sharpness (wave_chop) - the difference between
//                          a sine roll and a peaked Gerstner crest.
//   * FoamThreshold        how high a crest has to be before it goes white.
//   * EnableFoam           whether crest foam appears at all.
//
// OURS, and this is the whole of the line:
//   * the WAVELENGTHS. BF6 runs a real FFT ocean; the length of each band is a
//     property of that simulation and is not written down anywhere. Four fixed
//     ratios off `ripple_scale` stand in (1, 0.63, 0.41, 0.27).
//   * the number of components (four), and the wave model. The game solves a
//     spectrum; this sums four sharpened sines and takes the normal
//     analytically, which is a fragment shader's budget rather than a compute
//     pass's.
//   * which world axis WindAngle measures from, and its sign. The value is the
//     game's; the convention (+X, counter-clockwise seen from above) is a guess
//     that cannot be settled without the game running next to this.
//   * the mapping of WindSpeed / Choppiness / FoamThreshold onto amplitudes.
//     The game's numbers are not in physical units (WindSpeed is 0.01 on calm
//     water and 0.75 on the D-Day sea), so they are normalised here.
//   * the depth-fade curve, the shoreline foam falloff, the specular model.
//
// WaterAbsorption R/G/B (0.2, 0.5, 1.0) is on the game's OceanComponentData but
// reads backwards as an absorption coefficient (it would make deep water red),
// so it is deliberately NOT wired until the direction is measured, not guessed.
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
uniform float ripple_scale = 22.0;    // metres of the LONGEST swell (ours)
uniform float ripple_speed = 0.8;
uniform float ripple_strength = 0.45; // swell normal perturbation amount
uniform float foam_strength = 0.30;   // shoreline brightening (0 = off)

// ---- THE WAVE FIELD, driven by the map's own ocean simulation entity ----
// waves[i] = (dir.x, dir.z, relative amplitude, relative wavelength).
// dir and amplitude are the game's WindAngle + WindDistribution; the wavelength
// ratio is ours. All four slots are always filled: when a level declares no
// simulation, HighpolyWater fills them with a neutral spread so there is one
// code path here and not two.
uniform vec4 waves[4];
uniform float wave_gain = 0.55;       // from WindSpeed, normalised (0.07 = 1.0)
uniform float wave_chop = 0.05;       // from Choppiness, clamped for stability
uniform float foam_cut = 0.35;        // from FoamThreshold, normalised
uniform bool foam_crest = true;       // from EnableFoam
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

const float W_TAU = 6.28318530718;
const float W_G = 9.81;               // gravity, for the deep-water dispersion

// Four directional wave components, standing in for the runtime FFT ocean.
//
// Returns (height, dh/dx, dh/dz, total amplitude). The gradient is ANALYTIC,
// which is why four real components cost less than the old four-term sine field
// did: that one evaluated its whole sum three times to finite-difference a
// normal (24 sines), this evaluates once (16 sin/cos for four components).
//
// The Gerstner part is the phase warp `ph + chop * sin(ph)`. A plain sine rolls;
// warping its own phase by its own sine bunches the wave up at the crest and
// stretches the trough, which is the visible half of what a Gerstner wave's
// horizontal displacement does, without needing displaced vertices (this plane
// is two triangles - all of the shape lives in the normal).
//
// Amplitude is carried as STEEPNESS (a * k) rather than metres, so a component's
// contribution to the normal does not change when `ripple_scale` does.
vec4 wave_field(vec2 p, float t) {
	float h = 0.0;
	float amp = 0.0;
	vec2 g = vec2(0.0);
	for (int i = 0; i < 4; i++) {
		vec4 w = waves[i];
		if (w.z <= 0.0001) { continue; }
		float len = max(ripple_scale * w.w, 0.05);
		float k = W_TAU / len;
		// deep-water dispersion: long waves outrun short ones, as they do at sea
		float ph = dot(w.xy * k, p) + t * sqrt(W_G * k) * ripple_speed;
		float s = sin(ph);
		float warped = ph + wave_chop * s;
		float slope = ripple_strength * w.z * wave_gain;
		float a = slope / k;
		h += a * sin(warped);
		amp += a;
		g += slope * cos(warped) * (1.0 + wave_chop * cos(ph)) * w.xy;
	}
	return vec4(h, g.x, g.y, amp);
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

	// --- swell: the map's own wind, four components, analytic normal ---
	float t = TIME;
	vec4 wf = wave_field(wpos.xz, t);
	float h0 = wf.x;
	vec3 wn = normalize(vec3(-wf.y, 1.0, -wf.z));
	// crest height normalised over this map's own wave amplitude, so the foam
	// cutoff below means the same thing on a glassy river and on an open sea
	float crest_h = clamp(h0 / max(wf.w, 0.001) * 0.5 + 0.5, 0.0, 1.0);

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
	// WHERE the crest foam starts is the game's FoamThreshold (normalised on the
	// way in), and whether there is any is the game's EnableFoam. How wide the
	// band is, and the shoreline falloff, are ours.
	float shore = smoothstep(1.0 + shore_fade * 6.0, 0.0, water_depth);
	float crest = foam_crest
		? smoothstep(foam_cut, min(foam_cut + 0.22, 1.0), crest_h)
		: 0.0;
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
		foam = smoothstep(1.2, 0.0, water_depth) * 0.8 + crest * 0.5;
	}
	foam = clamp(foam * foam_strength * 3.0, 0.0, 1.0);

	ALBEDO = clamp(mix(col, foam_col, foam) + fr * fresnel_boost * 0.3, 0.0, 1.0);
	ALPHA = clamp(mix(min_alpha, max_alpha, df) + fr * fresnel_boost + foam * 0.4, 0.0, 1.0);
	METALLIC = 0.0;
	SPECULAR = 0.5;
	ROUGHNESS = clamp(roughness_min + df * 0.04 + foam * 0.5
		- detail_smooth * 0.02, 0.0, 1.0);
}
