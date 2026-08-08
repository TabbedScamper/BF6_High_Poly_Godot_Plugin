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
uniform vec4 waves[8];
uniform float wave_gain = 0.55;       // from WindSpeed, normalised (0.07 = 1.0)
uniform float wave_chop = 0.05;       // from Choppiness, clamped for stability
uniform float foam_cut = 0.62;        // from FoamThreshold, normalised
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
// WHY EIGHT AND NOT FOUR, AND WHY THE LENGTHS ARE NOT ROUND NUMBERS.
//
// Four components at ratios 1 / 0.63 / 0.41 / 0.27 read as corduroy, and where
// the map's own curve put two lobes half a turn apart (mp_dumbo does) the two
// opposed trains stood still against each other and produced a regular
// egg-crate lattice. Both are artefacts of OUR reconstruction, not of the
// game's data: the component count and the length ladder were always ours.
//
// A sum of sines repeats on the least common multiple of its wavelengths, so
// near-rational ratios repeat SOON and visibly. The ladder is now powers of
// 1/phi (0.618...), whose continued fraction is all ones - the hardest number
// to approximate with a rational, which is exactly the property wanted here.
// The pattern still repeats, but not inside any water a level contains.
const int WAVE_N = 8;

// THE FOAM SHEET, TWICE, THE SECOND COPY TURNED.
//
// One tap at one scale repeats every foam_tiling metres, and because the crest
// term is non-zero nearly everywhere that repeat is drawn over the WHOLE
// surface: it reads as a regular grid of identical flecks, which is exactly
// what it was doing at 26 m. Two taps at different scales and orientations
// break it for one extra fetch. The scales are deliberately not a ratio of
// small integers, or the two grids would come back into step periodically.
//
// Combined by max rather than by average: foam is a coverage, and averaging two
// coverages halves the contrast and turns crisp streaks into grey haze.
vec4 foam_sample(vec2 p) {
	vec2 uv = p / max(foam_tiling, 0.01);
	const float FCA = 0.7986;   // cos 37
	const float FSA = 0.6018;   // sin 37
	vec2 rot = vec2(uv.x * FCA - uv.y * FSA, uv.x * FSA + uv.y * FCA);
	vec4 a = texture(foam_tex, uv + vec2(0.006, 0.004) * TIME);
	vec4 b = texture(foam_tex, rot * 0.63 + vec2(-0.005, 0.007) * TIME);
	return max(a, b);
}

vec4 wave_field(vec2 p, float t) {
	float h = 0.0;
	float amp = 0.0;
	vec2 g = vec2(0.0);
	for (int i = 0; i < WAVE_N; i++) {
		vec4 w = waves[i];
		if (w.z <= 0.0001) { continue; }
		float len = max(ripple_scale * w.w, 0.05);
		float k = W_TAU / len;
		// EVERY COMPONENT USED TO START IN PHASE AT THE WORLD ORIGIN, and that
		// is most of why this read as a repeating lattice rather than as water.
		// With no offset all eight sines cross zero together on the line through
		// p = 0, so their crests keep re-aligning on a regular grid and the eye
		// locks onto it immediately. A real spectrum's components have unrelated
		// phases. Offsetting by the golden angle per component decorrelates them
		// for the cost of one add, and being deterministic it stays identical
		// between sessions and between machines.
		float ph0 = float(i) * 2.39996323;
		// deep-water dispersion: long waves outrun short ones, as they do at sea
		float ph = ph0 + dot(w.xy * k, p) + t * sqrt(W_G * k) * ripple_speed;
		float s = sin(ph);
		float warped = ph + wave_chop * s;
		float slope = ripple_strength * w.z * wave_gain;
		float a = slope / k;
		h += a * sin(warped);
		// TOTAL SLOPE, not total amplitude. The only consumer is the foam test,
		// which is now a steepness test, and steepness has to be normalised
		// against a steepness: `a` is in metres and grows with ripple_scale, so
		// dividing a slope by it would have made foam coverage depend on how
		// long the swell was set to be.
		amp += slope;
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

	// --- swell: the map's own wind, eight components, analytic normal ---
	float t = TIME;
	vec4 wf = wave_field(wpos.xz, t);
	vec3 wn = normalize(vec3(-wf.y, 1.0, -wf.z));
	// WHITECAPS BREAK ON STEEP WATER, NOT ON TALL WATER, and using height was
	// the last thing keeping this looking manufactured.
	//
	// The height of a sum of sines is dominated by its LONGEST component - that
	// is what "longest" means - so a foam cutoff on normalised height fired in
	// clean regular bands wherever that one component crested, and the eight
	// components underneath it made no difference to where the foam went. Rows
	// of identical flecks, on a map whose waves are otherwise gentle.
	//
	// Slope is the opposite: each component contributes a*k, so the SHORT ones
	// dominate it, and the sum is broadband and irregular. It is also the
	// physical criterion - a crest whitecaps when it gets too steep to hold, not
	// when it gets too high - so this is closer to the game as well as calmer to
	// look at. Height is still what the surface normal comes from; only the foam
	// test changes.
	float steep = length(vec2(wf.y, wf.z));
	// normalised over this field's own mean steepness, so the cutoff means the
	// same thing on a glassy river and on an open sea
	float crest_h = clamp(steep / max(wf.w * 0.55, 0.001), 0.0, 1.0);

	// --- the game's ripple normal on top of the swell ---
	// Two samples at different scales scrolling in different directions, which
	// is how a single tiling normal is made to read as moving water. RG is the
	// normal, B the smoothness, A the height (per the _nsh channel packing).
	//
	// THE SECOND SAMPLE IS ROTATED, and that is the whole point of it. Scaling a
	// tile by 0.47 and leaving it axis-aligned does not hide the tile: both
	// copies keep the same grid orientation, so their seams stay parallel and
	// REINFORCE instead of cancelling. At 5.5 m per tile that reads as a regular
	// speckle grid over the whole surface, which is what it was doing. A
	// rotation by an angle that is not a multiple of 90 degrees breaks the
	// alignment, and 37 degrees is far from every one of them. Same two fetches.
	float detail_smooth = 0.0;
	if (has_detail) {
		vec2 duv = wpos.xz / max(detail_tiling, 0.01);
		const float CA = 0.7986;   // cos 37
		const float SA = 0.6018;   // sin 37
		vec2 rot = vec2(duv.x * CA - duv.y * SA, duv.x * SA + duv.y * CA);
		vec4 n1 = texture(detail_tex, duv + vec2(0.021, 0.013) * TIME);
		vec4 n2 = texture(detail_tex, rot * 0.47 + vec2(-0.009, 0.017) * TIME);
		// The rotated sample's normal has to be rotated BACK, or its ripples run
		// 37 degrees off the ones they are being added to and the surface picks
		// up a permanent diagonal bias.
		vec2 r2 = (n2.rg - 0.5) * 2.0;
		r2 = vec2(r2.x * CA + r2.y * SA, -r2.x * SA + r2.y * CA);
		vec2 dxz = ((n1.rg - 0.5) * 2.0 + r2) * detail_strength;
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
		vec4 f = foam_sample(wpos.xz);
		foam = f.r * shore + f.b * crest;      // R patches at the shore, B streaks on crests
		foam_col = vec3(clamp(f.g * 1.6, 0.0, 1.0));
	} else if (foam_mode == 2) {
		vec4 f = foam_sample(wpos.xz);
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
