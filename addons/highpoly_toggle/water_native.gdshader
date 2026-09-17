shader_type spatial;
// Native BF6 ocean surface. Port of the Unreal add-on water material
// (BF6HighPoly.cpp FFT WPO, FFT normal and foam nodes). Godot world is game
// XYZ metres, Y up: Unreal (x, y, z) maps to Godot (x, z, y) with no *0.01.
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// ---- cascades: (Dx, height, Dz, 0) and (foam, nx*0.5+0.5, nz*0.5+0.5, 1)
// Quads per draw-tree tile edge, from HighpolyNativeWater.PATCH_QUADS. A
// constant here instead would be a second copy of the mesh's own subdivision
// and would silently stop matching the day the patch changes.
// A BISECTION SWITCH, not a feature. One per cascade, multiplying everything
// that cascade contributes - displacement, choppiness and normals alike. Three
// diagnoses of the boiling have now been wrong, each one reasoned from the
// shader source rather than from seeing which cascade actually misbehaves.
// Turning them off one at a time answers that in a single look, and the default
// (1,1,1,1) is exactly the current behaviour so it costs nothing to leave in.
uniform vec4 cascade_mask = vec4(1.0, 1.0, 1.0, 1.0);
// The interactive Gerstner sum is NOT one of the four FFT cascades, so masking
// them all still leaves it running. Bisecting needs to be able to silence it
// too, or "everything off and still moving" is unreachable as an observation.
uniform float interactive_mask = 1.0;
uniform float patch_quads = 16.0;
uniform sampler2D disp0 : hint_default_black, filter_linear_mipmap, repeat_enable;
uniform sampler2D disp1 : hint_default_black, filter_linear_mipmap, repeat_enable;
uniform sampler2D disp2 : hint_default_black, filter_linear_mipmap, repeat_enable;
uniform sampler2D disp3 : hint_default_black, filter_linear_mipmap, repeat_enable;
uniform sampler2D nf0 : hint_default_black, filter_linear_mipmap, repeat_enable;
uniform sampler2D nf1 : hint_default_black, filter_linear_mipmap, repeat_enable;
uniform sampler2D nf2 : hint_default_black, filter_linear_mipmap, repeat_enable;
uniform sampler2D nf3 : hint_default_black, filter_linear_mipmap, repeat_enable;
// (tile metres, choppiness, enabled, foam enabled); absent = (1, 0, 0, 0)
uniform vec4 cascade0 = vec4(1.0, 0.0, 0.0, 0.0);
uniform vec4 cascade1 = vec4(1.0, 0.0, 0.0, 0.0);
uniform vec4 cascade2 = vec4(1.0, 0.0, 0.0, 0.0);
uniform vec4 cascade3 = vec4(1.0, 0.0, 0.0, 0.0);
uniform vec4 cascade_texel_m = vec4(1000000.0);
uniform float fft_enabled = 0.0;
uniform float amplitude = 1.0;
uniform vec2 water_origin = vec2(0.0);
uniform float surface_height = 0.0;
uniform float sim_time = 0.0;
uniform vec4 overlap_params = vec4(0.0, 1.0, 0.0, 0.0);
uniform vec4 overlap_params2 = vec4(1.0);
uniform float overlap_enabled = 0.0;
uniform float overlap_height = 1.0;

// ---- shore
uniform float shore_depth = 0.0;
uniform float additional_depth = 0.0;
uniform float use_authored_shore = 0.0;
uniform vec4 shore_blend = vec4(0.0, 0.0, 0.0, 1.0);
// uint16 LE heights as RG8 raw bytes
uniform sampler2D terrain_heights : filter_nearest, repeat_disable;
uniform float terrain_available = 0.0;
uniform vec2 terrain_min = vec2(0.0);
uniform vec2 terrain_span = vec2(1.0);
uniform vec2 terrain_size = vec2(1.0);
uniform vec2 terrain_texel_m = vec2(1.0);
uniform float terrain_metres_per_raw = 0.0;
uniform sampler2D level_heights : filter_nearest, repeat_disable;
uniform float level_available = 0.0;
uniform vec2 level_min = vec2(0.0);
uniform vec2 level_span = vec2(1.0);
uniform vec2 level_size = vec2(1.0);
uniform vec2 level_texel_m = vec2(1.0);
uniform float level_metres_per_raw = 0.0;
// CoarseMask utility raster
uniform sampler2D mask_indirection : filter_nearest, repeat_disable;
uniform sampler2DArray mask_atlas : filter_linear, repeat_disable;
uniform float mask_available = 0.0;
uniform vec2 mask_min = vec2(0.0);
uniform vec2 mask_span = vec2(1.0);
uniform vec4 mask_meta = vec4(1.0, 0.0, 1.0, 1.0); // interior, border, tile side, indirection side
uniform float mask_polarity = 0.0; // 0 = selected 1-mask law

// ---- pixel detail and foam
uniform float detail_fade_start = 100.0;
uniform float detail_fade_end = 300.0;
uniform sampler2D micro_sheet : hint_default_black, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D foam_sheet : hint_default_black, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D contact_foam : hint_default_black, filter_linear_mipmap, repeat_enable;
uniform sampler2D broad_pattern : hint_default_black, filter_linear_mipmap, repeat_enable;
uniform sampler2D noise_tex : hint_default_black, filter_linear_mipmap, repeat_enable;
uniform float use_sheets = 0.0;
// Unreal parent-material defaults (BF6HighPoly.cpp 6183, 6367-6375, 6425-6431).
uniform float micro_uv_scale = 0.0464;
uniform float foam_uv_scale = 0.14;
uniform float micro_flow_speed = 0.9;
uniform float detail_strength = 1.0;
uniform float foam_sheet_strength = 0.35;
uniform float use_contact = 0.0;
uniform float contact_divisor = 73718.0;
uniform float contact_remap_low = 0.0;
uniform float contact_gain = 0.916;
uniform float composite_low = 0.0427;
uniform float composite_high = 1.14;
uniform float foam_chain = 0.0;
uniform vec4 foam_weights = vec4(0.0);
uniform float shore_suppression = 1.0;
uniform float draw_threshold = 0.0;
uniform float foam_contrast = 1.0;
uniform float use_broad = 0.0;
uniform float graph_version = 0.0;
uniform vec4 graph_cb[22];
// Unreal preview controls GWaterBroadCarrierSize / GWaterBroadTimeScale defaults.
uniform float broad_wave_size = 1.0;
// 0 = the broad crest sheet holds still, which is what it should do. The
// driver sets this explicitly; the default here matches so a material built
// without the driver does not start sliding. See highpoly_native_water.gd.
uniform float broad_time_scale = 0.0;
uniform float foam_depth_ramp = 0.5;
uniform float foam_wave_height = 0.0;
uniform float interactive_enabled = 0.0;
uniform float interactive_height = 0.0;
uniform float interactive_length = 120.0;
uniform float interactive_rate = 0.35;

// ---- shading
uniform float absorption_available = 0.0;
uniform vec3 extinction = vec3(0.0);
uniform vec3 scatter_albedo = vec3(0.0);
uniform vec3 surface_tint = vec3(0.0);
uniform vec3 foam_tint = vec3(0.711);
uniform float water_roughness = 0.04;
uniform float foam_roughness = 0.3;
uniform float water_specular = 0.4;
uniform sampler2D scene_depth : hint_depth_texture, filter_nearest, repeat_disable;
uniform sampler2D scene_color : hint_screen_texture, filter_linear, repeat_disable;

const float WATER_F0 = 0.0256;
const float FAR_PATH_M = 10000.0;

float raw_u16(vec4 c) {
	return floor(c.r * 255.0 + 0.5) + 256.0 * floor(c.g * 255.0 + 0.5);
}

// Manual bilinear over exact texels, texel-centre registration as Unreal's
// bilinear height texture. Returns (metres, weight).
vec2 height_bilinear(sampler2D tex, vec2 uv, vec2 size, float metres_per_raw, bool zero_absent) {
	vec2 g = uv * size - 0.5;
	vec2 base = floor(g);
	vec2 f = g - base;
	ivec2 hi = max(ivec2(size) - ivec2(1), ivec2(0));
	float acc = 0.0;
	float wsum = 0.0;
	for (int k = 0; k < 4; k++) {
		ivec2 o = ivec2(k & 1, (k >> 1) & 1);
		ivec2 p = clamp(ivec2(base) + o, ivec2(0), hi);
		float raw = raw_u16(texelFetch(tex, p, 0));
		float w = (o.x == 1 ? f.x : 1.0 - f.x) * (o.y == 1 ? f.y : 1.0 - f.y);
		if (zero_absent && raw < 0.5) {
			w = 0.0;
		}
		acc += w * raw * metres_per_raw;
		wsum += w;
	}
	return vec2(wsum > 1e-6 ? acc / wsum : 0.0, wsum);
}

float terrain_y(vec2 xz) {
	vec2 uv = clamp((xz - terrain_min) / max(terrain_span, vec2(1e-4)), 0.0, 1.0);
	return height_bilinear(terrain_heights, uv, terrain_size, terrain_metres_per_raw, false).x;
}

// Authored water-level raster. Zero texels are absent, never a lift.
float level_y(vec2 xz, out float valid) {
	vec2 hq = (xz - level_min) / max(level_span, vec2(1e-4));
	float inside = step(0.0, hq.x) * step(hq.x, 1.0) * step(0.0, hq.y) * step(hq.y, 1.0);
	vec2 s = height_bilinear(level_heights, clamp(hq, 0.0, 1.0), level_size, level_metres_per_raw, true);
	valid = level_available * inside * step(1e-6, s.y);
	return s.x;
}

float shore_term(float world_y, vec2 xz) {
	float shore_on = step(1e-4, shore_depth);
	float dep = world_y - terrain_y(xz) + additional_depth;
	float t = clamp(dep / max(shore_depth, 1e-4), 0.0, 1.0);
	float authored = clamp(dot(vec4(t * t * t, t * t, t, 1.0), shore_blend), 0.0, 1.0);
	return mix(1.0, mix(t * t * (3.0 - 2.0 * t), authored, use_authored_shore), terrain_available * shore_on);
}

float coarse_mask(vec2 xz) {
	vec2 uv = min(clamp((xz - mask_min) / max(mask_span, vec2(1e-4)), 0.0, 1.0), vec2(0.999999));
	float side = max(mask_meta.w, 1.0);
	ivec2 cell = clamp(ivec2(floor(uv * side)), ivec2(0), ivec2(int(side) - 1));
	vec4 mi = texelFetch(mask_indirection, cell, 0);
	int b0 = int(floor(mi.r * 255.0 + 0.5));
	int b1 = int(floor(mi.g * 255.0 + 0.5));
	int b2 = int(floor(mi.b * 255.0 + 0.5));
	float inline_flag = b1 >= 128 ? 1.0 : 0.0;       // int16(Lo) < 0
	float inline_value = float(b0) / 255.0;          // Lo & 0x7fff & 0xff
	float page = float(b0);                          // Lo & 0xff
	float shift = float(b2 & 31);                    // (V >> 16) & 31
	vec2 local_uv = fract(uv * (side / pow(2.0, shift)));
	vec2 atlas_uv = (local_uv * mask_meta.x + mask_meta.y + 0.5) / max(mask_meta.z, 1.0);
	float page_value = textureLod(mask_atlas, vec3(atlas_uv, page), 0.0).r;
	float value = mix(page_value, inline_value, inline_flag);
	return clamp(mix(1.0 - value, value, mask_polarity), 0.0, 1.0);
}

vec2 overlap_uv(vec2 pm) {
	float p0 = overlap_params.y * pm.x + overlap_params.x * pm.y;
	float p1 = overlap_params.y * pm.y - overlap_params.x * pm.x;
	p1 -= overlap_params.w * p0;
	p0 -= overlap_params.z * p1;
	return vec2(overlap_params2.x * p0, overlap_params2.y * p1) / max(cascade0.x, 1e-4);
}

// Unreal broad draw-graph vertex bridge (BF6HighPoly.cpp 7004-7103); only bm0
// and noiseR reach the returned height.
float broad_body(vec2 xz) {
	float carrier = max(broad_wave_size, 1.0);
	float bt = sim_time * broad_time_scale;
	vec2 base = xz * graph_cb[13].w;
	vec2 dir = normalize(vec2(overlap_params.y, overlap_params.x) + vec2(1e-5, 0.0));
	float primary_freq = max(abs(graph_cb[13].w * graph_cb[15].y * 0.000584) / carrier, 1e-6);
	float noise_freq = max(abs(graph_cb[13].w * 0.033), 1e-6);
	float mip = clamp(log2(carrier), 0.0, 5.0);
	float r = 0.0030 * (1.0 + mip);
	vec2 bx = vec2(-dir.y, dir.x) * (r * 2.0);
	vec2 by = dir * r;
	vec2 u0 = base * (graph_cb[15].y * 0.000584 / carrier) - dir * (bt * sqrt(9.81 * primary_freq / 6.2831853));
	vec4 p0 = 0.5 * textureLod(broad_pattern, u0, mip) + 0.125 * (textureLod(broad_pattern, u0 + bx, mip)
		+ textureLod(broad_pattern, u0 - bx, mip) + textureLod(broad_pattern, u0 + by, mip) + textureLod(broad_pattern, u0 - by, mip));
	float bm0 = clamp((dot(p0.rgb, vec3(0.0, 0.8, 0.2)) + 0.05) / 0.85, 0.0, 1.0);
	vec2 un = base * 0.033 - dir * (bt * sqrt(9.81 * noise_freq / 6.2831853));
	float noise_r = 0.5 * textureLod(noise_tex, un, mip).r + 0.125 * (textureLod(noise_tex, un + bx, mip).r
		+ textureLod(noise_tex, un - bx, mip).r + textureLod(noise_tex, un + by, mip).r + textureLod(noise_tex, un - by, mip).r);
	float body = clamp(0.10 * noise_r + 0.90 * bm0, 0.0, 1.0);
	return body * body * (3.0 - 2.0 * body);
}

// Unreal provisional interactive modal seed (7108-7116, 7292-7300).
// Returns (height, dh/dx, dh/dz) before the enable/attenuation factors.
vec3 interactive_wave(vec2 xz) {
	vec2 idir = normalize(vec2(0.84, 0.54));
	float ilen = max(interactive_length, 4.0);
	float z = 0.0;
	vec2 grad = vec2(0.0);
	for (int ii = 0; ii < 4; ii++) {
		float w = ii == 0 ? 0.52 : (ii == 1 ? 0.25 : (ii == 2 ? 0.15 : 0.08));
		float rr = ii == 0 ? 1.0 : (ii == 1 ? 0.58 : (ii == 2 ? 0.34 : 0.21));
		float k = 6.2831853 / (ilen * rr);
		float a = (ii & 1) == 1 ? -0.22 : 0.17;
		vec2 d = normalize(vec2(idir.x - a * idir.y, idir.y + a * idir.x));
		float ph = k * dot(d, xz) - sqrt(9.81 * k) * sim_time * interactive_rate + float(ii) * 1.713;
		z += w * sin(ph);
		grad += interactive_height * w * k * d * cos(ph);
	}
	return vec3(interactive_height * z, grad);
}

vec2 slope_of(vec2 x, float scale) {
	return x * scale * inversesqrt(max(1.0 - dot(x, x), 1e-5));
}

void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 xz = world.xz;
	vec2 pm = xz - water_origin;
	float level_valid;
	float level_surface = level_y(xz, level_valid);
	float lift = level_valid * max(level_surface - surface_height, 0.0);
	float shore = shore_term(world.y, xz);
	float coarse = mix(shore, coarse_mask(xz), mask_available);
	// THE DISPLACEMENT MIP, floored by what the MESH can actually carry.
	//
	// The screen footprint below is a stand-in for the game's unread vertex LOD
	// ramp, and on its own it is the wrong metric here: this is the VERTEX
	// stage moving geometry, so the limit is the distance between vertices, not
	// the size of a pixel. Close to the camera the footprint goes to mip 0 and
	// pulls in waves shorter than one quad, which no mesh can represent - each
	// vertex then samples an unrelated phase, and as the camera or the clock
	// moves that spatial aliasing becomes temporal churn. That is what "the
	// water is boiling" is.
	//
	// Measured on mp_isolated (Tsuru Reef), which authors FOUR cascades:
	//   #0 tile 300 m, texel 2.34 m   #1 67.6 m, 1.06 m
	//   #2 tile  43 m, texel 1.34 m   #3 12.0 m, texel 0.094 m
	// At the finest draw-tree tile the mesh has one metre between vertices, so
	// cascades 0-2 are already coarser than the mesh and the floor changes
	// nothing for them. Cascade 3 is TEN TIMES finer, and it is the one that
	// boils. The floor costs nothing where it is not needed and is exactly the
	// Nyquist limit where it is.
	float dcam = max(length(CAMERA_POSITION_WORLD - world), 1.0);
	float pixel_angle = 2.0 / max(PROJECTION_MATRIX[0][0] * VIEWPORT_SIZE.x, 1e-4);
	vec4 screen_mip = log2(max(vec4(dcam * pixel_angle) / max(cascade_texel_m, vec4(1e-4)), vec4(1.0)));
	// The instance's own width is the tile width, so this needs no uniform that
	// could disagree with the tree the core handed us.
	float vertex_spacing_m = length(MODEL_MATRIX[0].xyz) / max(patch_quads, 1.0);
	vec4 mesh_mip = log2(max(vec4(vertex_spacing_m) / max(cascade_texel_m, vec4(1e-4)), vec4(1.0)));
	vec4 mips = max(screen_mip, mesh_mip);
	vec4 d0 = textureLod(disp0, pm / max(cascade0.x, 1e-4), mips.x) * cascade0.z * cascade_mask.x;
	vec4 d1 = textureLod(disp1, pm / max(cascade1.x, 1e-4), mips.y) * cascade1.z * cascade_mask.y;
	vec4 d2 = textureLod(disp2, pm / max(cascade2.x, 1e-4), mips.z) * cascade2.z * cascade_mask.z;
	vec4 d3 = textureLod(disp3, pm / max(cascade3.x, 1e-4), mips.w) * cascade3.z * cascade_mask.w;
	vec4 od = textureLod(disp0, overlap_uv(pm), mips.x) * cascade0.z * cascade_mask.x;
	float ox = overlap_params2.z * (-cascade0.y * od.x);
	float oz = overlap_params2.w * (-cascade0.y * od.z);
	float tx = ox + overlap_params.z * oz;
	float tz = oz + overlap_params.w * tx;
	vec2 oh = vec2(overlap_params.y * tx - overlap_params.x * tz, overlap_params.x * tx + overlap_params.y * tz);
	vec2 h = -coarse * (cascade0.y * d0.xz + cascade1.y * d1.xz) - cascade2.y * d2.xz - cascade3.y * d3.xz;
	float v = amplitude * (coarse * (d0.y + d1.y) + d2.y + d3.y);
	h += coarse * overlap_enabled * oh;
	v += coarse * overlap_enabled * amplitude * overlap_height * od.y;
	// broadZ and interactiveZ sit outside BF6FFTEnabled, as in Unreal.
	float broad_z = coarse * clamp(use_broad * graph_version, 0.0, 1.0) * foam_wave_height * mix(-0.10, 1.0, broad_body(xz));
	float interactive_z = interactive_mask * interactive_enabled * coarse * interactive_wave(xz).x;
	vec3 offset = vec3(fft_enabled * h.x, fft_enabled * v + lift + broad_z + interactive_z, fft_enabled * h.y);
	VERTEX += inverse(mat3(MODEL_MATRIX)) * offset;
}

void fragment() {
	vec3 world = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 xz = world.xz;
	vec2 pm = xz - water_origin;

	// Water-level raster slope, only where it rises above this surface.
	float hvalid;
	float unused;
	float hc = level_y(xz, hvalid);
	float hl = level_y(xz - vec2(level_texel_m.x, 0.0), unused);
	float hr = level_y(xz + vec2(level_texel_m.x, 0.0), unused);
	float hb = level_y(xz - vec2(0.0, level_texel_m.y), unused);
	float ht = level_y(xz + vec2(0.0, level_texel_m.y), unused);
	float hactive = hvalid * step(surface_height + 1e-4, hc);
	vec2 height_slope = -hactive * vec2((hr - hl) / max(2.0 * level_texel_m.x, 1e-4), (ht - hb) / max(2.0 * level_texel_m.y, 1e-4));

	float shore = shore_term(world.y, xz);
	float coarse = mix(shore, coarse_mask(xz), mask_available);
	float dist = length(world - CAMERA_POSITION_WORLD);
	float df = clamp((dist - detail_fade_end) / min(detail_fade_start - detail_fade_end, -1e-4), 0.0, 1.0);

	// Derivative samples for cascades 0/1, explicit mip 0 for 2/3; never fract().
	vec4 n0 = texture(nf0, pm / max(cascade0.x, 1e-4)) * cascade_mask.x;
	vec4 n1 = texture(nf1, pm / max(cascade1.x, 1e-4)) * cascade_mask.y;
	// CASCADES 2 AND 3 WERE PINNED AT MIP 0, and that is what made the water
	// bubble. textureLod(..., 0.0) forces the finest level at EVERY distance,
	// so cascade 3 - a 12 m tile at 128 texels, 9.4 cm per texel, carrying waves
	// down to about 0.19 m - was drawn at full detail from any range. Waves that
	// short oscillate at roughly 3 Hz under the dispersion relation, so the
	// whole surface fizzed with detail that should have filtered away with
	// distance. Cascades 0 and 1 below always used plain texture() and always
	// looked right; the asymmetry WAS the bug.
	//
	// texture() takes its mip from the screen-space derivatives, which is the
	// correct metric here because this is the fragment stage shading a surface.
	// Close up the fine waves are still there, as they should be; further out
	// they blend away instead of flickering.
	vec4 n2 = texture(nf2, pm / max(cascade2.x, 1e-4)) * cascade_mask.z;
	vec4 n3 = texture(nf3, pm / max(cascade3.x, 1e-4)) * cascade_mask.w;
	vec4 on = texture(nf0, overlap_uv(pm)) * cascade_mask.x;
	// Gate SIGNED normals: gating a packed value first makes the camera circle.
	vec2 s0 = slope_of((n0.yz * 2.0 - 1.0) * cascade0.z, amplitude);
	vec2 s1 = slope_of((n1.yz * 2.0 - 1.0) * cascade1.z, amplitude);
	vec2 s2 = slope_of((n2.yz * 2.0 - 1.0) * cascade2.z, amplitude);
	vec2 s3 = slope_of((n3.yz * 2.0 - 1.0) * cascade3.z, amplitude);
	vec2 os = slope_of((on.yz * 2.0 - 1.0) * cascade0.z, amplitude * overlap_height);
	float oy = os.y - os.x * overlap_params.z;
	float ox = os.x - oy * overlap_params.w;
	vec2 overlap_slope = vec2(overlap_params.y * ox - overlap_params.x * oy, overlap_params.x * ox + overlap_params.y * oy);
	vec2 slope = height_slope + coarse * (s0 + s1 + overlap_enabled * overlap_slope) + df * (s2 + s3);
	vec3 n = normalize(mix(vec3(0.0, 1.0, 0.0), vec3(slope.x, 1.0, slope.y), fft_enabled));

	// Draw sheets and contact foam.
	vec2 micro_base = xz * micro_uv_scale;
	float micro_phase = sim_time * micro_flow_speed;
	vec4 micro_a = texture(micro_sheet, micro_base + vec2(micro_phase) * 0.01);
	vec4 micro_b = texture(micro_sheet, micro_base - micro_phase * vec2(0.008, 0.0075));
	vec4 foam_s = texture(foam_sheet, xz * foam_uv_scale);
	float contact_raw = texture(contact_foam, xz / max(contact_divisor, 1.0) - 0.5).r;
	float contact = clamp((contact_raw - contact_remap_low) / max(1.0 - contact_remap_low, 1e-4), 0.0, 1.0) * contact_gain * use_contact;

	// Ocean-family cascade foam chain (Tungsten pass-0 order).
	float cf0 = clamp(n0.x * cascade0.z, 0.0, 1.0);
	float cf1 = clamp(n1.x * cascade1.z, 0.0, 1.0);
	float cf2 = clamp(n2.x * cascade2.z, 0.0, 1.0);
	float cf3 = clamp(n3.x * cascade3.z, 0.0, 1.0);
	float fch = cf0 * shore * foam_weights.x;
	fch = mix(fch, foam_weights.y, cf1 * shore);
	fch = mix(fch, foam_weights.z, cf2);
	fch = mix(fch, foam_weights.w, cf3);
	float shore_amount = 1.0 - shore;
	float chain_damp = 1.0 - shore_suppression * shore_amount;
	float acc = (draw_threshold - 0.5) + chain_damp * (1.0 - draw_threshold) * fch;
	float micro_w = use_sheets * pow(max(micro_a.w, micro_b.w), 2.0);
	float fast_sheet = use_sheets * foam_s.w - micro_w;
	float coverage_ocean = clamp(clamp((0.5 - micro_w) + use_sheets * foam_s.w + 2.0 * acc, 0.0, 1.0) / max(foam_contrast, 1e-4), 0.0, 1.0);
	float authored_simple = mix(clamp(2.0 * contact - 0.5 + fast_sheet, 0.0, 1.0), coverage_ocean, foam_chain);

	// MP_Isolated extended graph; G rows are the live material cbuffer.
	vec4 G0 = graph_cb[0]; vec4 G1 = graph_cb[1]; vec4 G5 = graph_cb[5]; vec4 G6 = graph_cb[6];
	vec4 G8 = graph_cb[8]; vec4 G10 = graph_cb[10]; vec4 G11 = graph_cb[11]; vec4 G12 = graph_cb[12];
	vec4 G13 = graph_cb[13]; vec4 G14 = graph_cb[14]; vec4 G15 = graph_cb[15]; vec4 G18 = graph_cb[18];
	float broad_t = sim_time * broad_time_scale;
	float detail_t = sim_time * 0.05;
	vec2 broad_base = xz * G13.w;
	vec2 broad_dir = normalize(vec2(overlap_params.y, overlap_params.x) + vec2(1e-5, 0.0));
	float primary_freq = max(abs(G13.w * G15.y * 0.000584), 1e-6);
	float noise_freq = max(abs(G13.w * 0.033), 1e-6);
	float primary_rate = sqrt(9.81 * primary_freq / 6.2831853);
	float noise_rate = sqrt(9.81 * noise_freq / 6.2831853);
	vec4 p0 = texture(broad_pattern, broad_base * G15.y * 0.000584 - broad_dir * (broad_t * primary_rate));
	float m0 = clamp((dot(p0.rgb, vec3(0.0, 0.8, 0.2)) + 0.05) / 0.85, 0.0, 1.0);
	float threshold = mix(G6.x, G6.y, m0);
	float shore_gate = clamp((shore_amount - threshold) / min(G15.z - threshold, -1e-4), 0.0, 1.0);
	float distance_gate = clamp((G8.z - dist) / max(G8.z, 1e-4), 0.0, 1.0);
	float a = mix(G5.z, G5.w, distance_gate) * shore_gate + contact + foam_chain * acc;
	vec4 p1 = texture(broad_pattern, xz * G12.y + detail_t * vec2(G11.y * 0.1, G11.y * 0.0001));
	float m1 = 1.0 + G11.x * (dot(p1, G1) - 1.0);
	vec4 p2 = texture(broad_pattern, xz * G11.z - detail_t * vec2(G11.y, G11.y * 0.001));
	vec4 p3 = texture(broad_pattern, xz * G18.w);
	float q3 = G10.z + G10.w * G10.z * (2.0 * p3.w - 1.0);
	float shaped = clamp((m1 - G12.w + q3 * m1 * (dot(p2, G0) - 1.0)) / max(G12.x - G12.w, 1e-4), 0.0, 1.0);
	a += G13.y * shaped;
	vec4 p4 = texture(broad_pattern, xz * (G13.w * G15.y * 0.000584 * G14.y) - detail_t * vec2(0.011, 0.008));
	float m4 = clamp((dot(p4.yz, vec2(0.3, 0.7)) - G15.x) / max(0.8 - G15.x, 1e-4), 0.0, 1.0);
	float vv = m0 + (2.0 * m0 * m4 - m0) * p4.w;
	float mixed = a * (1.0 + G14.w * (vv - 1.0));
	float noise_r = texture(noise_tex, broad_base * 0.033 - broad_dir * (broad_t * noise_rate)).r;
	float rr = clamp((mixed - 0.1) * (4.0 / 3.0), 0.0, 1.0);
	float draw_acc = mixed - (1.0 - noise_r) * 0.75 * G14.z * (0.35 - 0.23 * rr);
	float authored_extended = clamp(2.0 * draw_acc - 0.5 + fast_sheet, 0.0, 1.0);
	float authored = mix(authored_simple, authored_extended, clamp(use_broad * graph_version, 0.0, 1.0));
	float combined = clamp((authored - composite_low) / max(composite_high - composite_low, 1e-4), 0.0, 1.0);

	// Path length. World-space terrain depth where bound; otherwise the scene
	// depth reconstructed along the view ray (Forward+/Mobile reversed Z).
	vec3 to_eye = normalize(CAMERA_POSITION_WORLD - world);
	float terrain_depth = world.y - terrain_y(xz);
	float terrain_path = max(terrain_depth, 0.0) / max(abs(to_eye.y), 0.05);
	float depth_raw = texture(scene_depth, SCREEN_UV).r;
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	float ndc_z = depth_raw * 2.0 - 1.0;
	bool scene_hit = depth_raw > 0.0;
#else
	float ndc_z = depth_raw;
	bool scene_hit = depth_raw > 0.0;
#endif
	vec4 scene_clip = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, ndc_z, 1.0);
	vec3 scene_view = scene_clip.xyz / scene_clip.w;
	// Volume path from scene depth only (Unreal Single Layer Water); terrain is
	// not used for transmission. Sky resolves to a finite far path.
	// UE 5.8 SingleLayerWaterShading.ush:160 uses a view-depth difference,
	// not radial distance. This also works for an orthographic editor camera.
	float scene_path = scene_hit ? max(VERTEX.z - scene_view.z, 0.0) : FAR_PATH_M;
	float path = min(scene_path, FAR_PATH_M);

	float foam_path = max(terrain_depth + additional_depth, 0.0) / max(abs(to_eye.y), 0.05);
	float foam_depth_gate = mix(1.0, clamp(foam_path / max(foam_depth_ramp, 0.01), 0.0, 1.0), terrain_available);
	float foam = clamp(combined * foam_depth_gate, 0.0, 1.0);

	// Sheet normal perturbation. Frame is world +X / +Z projected onto n.
	vec2 micro_n = 0.5 * (micro_a.xy + micro_b.xy) - 0.5;
	vec2 sheet_n = mix(detail_strength * micro_n, foam_sheet_strength * (foam_s.xy - 0.5), foam);
	vec2 dnxy = use_sheets * 2.0 * df * sheet_n;
	float dnz = sqrt(clamp(1.0 - dot(dnxy, dnxy), 0.0, 1.0));
	// Unreal cotangent frame (7226-7230). Unreal (x,y,z) -> Godot (x,z,y) is a
	// reflection, so each cross product changes sign; derived, sign unmeasured.
	vec3 dpx = dFdx(world);
	vec3 dpy = dFdy(world);
	vec2 dux = dFdx(micro_base);
	vec2 duy = dFdy(micro_base);
	vec3 tangent_w = -(cross(dpy, n) * dux.x + cross(n, dpx) * dux.y);
	vec3 bitangent_w = -(cross(dpy, n) * duy.x + cross(n, dpx) * duy.y);
	float inv_len = inversesqrt(max(max(dot(tangent_w, tangent_w), dot(bitangent_w, bitangent_w)), 1e-8));
	vec3 nd = dnz * n - dnxy.x * tangent_w * inv_len + dnxy.y * bitangent_w * inv_len;
	vec2 i_normal = -interactive_enabled * coarse * interactive_wave(xz).yz;
	vec3 normal_world = normalize(vec3(nd.x + i_normal.x, 1.0, nd.z + i_normal.y));
	vec3 normal_view = normalize((VIEW_MATRIX * vec4(normal_world, 0.0)).xyz);
	NORMAL = normal_view;

	vec3 transmittance = exp(-extinction * path);
	vec3 background = texture(scene_color, SCREEN_UV).rgb;
	float n_dot_v = clamp(dot(normal_view, VIEW), 0.0, 1.0);
	float fresnel = WATER_F0 + (1.0 - WATER_F0) * pow(1.0 - n_dot_v, 5.0);
	// Unreal layers its BaseColor over the volume using Opacity=foam. Applying
	// that bright tint at full coverage would wash out otherwise clear water.
	// Godot has no SLW lighting pass: volume in-scatter remains Lambert-lit
	// here, and the transmitted background is emitted without distortion.
	vec3 in_scatter = scatter_albedo * (1.0 - transmittance) * absorption_available;
	vec3 water_emission = background * transmittance * (1.0 - fresnel) * absorption_available;
	vec3 opaque_layer = mix(surface_tint, foam_tint, foam);
	ALBEDO = mix(in_scatter, opaque_layer, foam);
	EMISSION = water_emission * (1.0 - foam);
	ROUGHNESS = mix(water_roughness, foam_roughness, foam);
	SPECULAR = water_specular;   // 0.4: Godot 0.16*s^2 = Unreal 0.08*0.32 = 0.0256
	METALLIC = 0.0;
}
