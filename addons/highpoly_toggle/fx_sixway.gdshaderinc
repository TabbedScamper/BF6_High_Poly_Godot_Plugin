// THE BODY OF THE FX PARTICLE SHADER, shared by both blend variants.
//
// Godot's `render_mode` is compile time, so "draw this layer additively" cannot
// be a uniform - it has to be a different shader. Emissive layers (fire, sparks,
// muzzle flash) genuinely add light and the rest composite over the scene, so
// there are two shaders and ONE body, here. Duplicating the body instead is how
// a fix lands in one of them and not the other.

uniform sampler2D sheet : source_color, filter_linear_mipmap;
// The atlas grid, AUTHORED in the atlas's own EBX and never inferred from the
// filename: a 6x36 grid read off an 8x64 sheet samples the wrong frames, which
// reads as the animation stuttering rather than as a mismatch.
uniform int cols = 8;
uniform int frames = 64;
uniform bool left_right = true;
uniform bool has_sheet = true;
uniform bool frame_blend = true;

// The level's own sun, passed in by the builder from the map's lighting.
uniform vec3 sun_direction = vec3(0.0, -1.0, 0.0);
uniform vec3 sun_color : source_color = vec3(1.0);
uniform vec3 ambient_color : source_color = vec3(0.35, 0.40, 0.48);
// The layer's authored scales. A layer that authors none gets 1.0 from the
// builder, which is the builder saying so rather than this file inventing a
// different default.
uniform float sun_scale = 1.0;
uniform float ambient_scale = 1.0;
uniform float backlight = 0.0;
uniform vec3 tint : source_color = vec3(1.0);
uniform float opacity = 1.0;
uniform float alpha_cull = 0.0;
// Per-particle sheet flips. FlipVProbability is authored on 14,561 layers and
// FlipU on 5,137: without them every particle of a plume shows the identical
// frame the same way up, which reads as a repeating pattern rather than smoke.
uniform float flip_u_probability = 0.0;
uniform float flip_v_probability = 0.0;
// The card's size over its life, same cubic encoding as the opacity curve.
uniform vec4 size_curve = vec4(0.0, 0.0, 0.0, 1.0);
uniform bool size_curve_on = false;
// PivotY moves the card's origin off centre, so a flame grows upward from its
// base instead of outward from its middle. -1 is bottom-aligned, 0 centred.
uniform float pivot_y = 0.0;
// THE SOFT-PARTICLE FADE. A card that intersects geometry shows a hard cut
// line, which is the most obvious tell that smoke is a flat quad.
// InvZFadeMultiplier is authored on 8,714 layers, CameraBias on 12,256.
// SOFT PARTICLES ARE NOT HERE, and that is deliberate.
//
// The depth fade is the right feature - InvZFadeMultiplier is authored on 8,714
// layers and without it a card slices through geometry with a hard line. But it
// needs the scene depth, and in Godot that means a `hint_depth_texture` uniform,
// which makes the material DEPEND on the depth buffer whether or not the branch
// that reads it ever runs. With 263 FX materials across 2,434 emitters that
// dependency stalled the GPU: a minidump of the hung editor showed the main
// thread blocked in the NVIDIA Vulkan driver at 16.9 GB.
//
// So it is removed rather than left in and hoped over. Re-adding it means a
// separate shader VARIANT that only the layers which actually author the fade
// declare, so the other 146 materials never carry the dependency - and it needs
// measuring on a GPU before it ships, which is exactly what did not happen the
// first time.
uniform float inv_z_fade = 0.0;
uniform float camera_bias = 0.0;
// How sharp the backlit rim is, authored on 17,345 layers.
uniform float backlight_contrast = 1.0;
// WHICH CHANNEL IS WHICH AXIS. The packing finding proves the halves carry
// three directions and their three opposites and deliberately does not settle
// the assignment. The DEFAULT here is not arbitrary though: the six-way smoke
// lightmap is an EA DICE technique and its published convention is
//
//     texture 1 RGB = Right, Up, Back      texture 2 RGB = Left, Down, Front
//
// which is exactly identity order against this shader's card basis (right, up,
// normal-toward-camera) with the LEFT half positive. So order 0 with
// flip_halves off is the convention, not a guess - but it is the convention
// rather than a measurement of THIS game, so it stays a uniform. A wrong choice
// shows as a plume lit from the wrong side, visible at once and correctable
// without a rebuild. native/probe_sixway_axes.gd measures it from the pixels.
uniform int axis_order = 0;
uniform bool flip_halves = false;

// f(t) = x*t^3 + y*t^2 + z*t + w over the particle's normalised age. The
// identity curve is (0,0,0,1), so a layer that authors none costs nothing.
uniform vec4 opacity_curve = vec4(0.0, 0.0, 0.0, 1.0);
uniform vec4 rotation_curve = vec4(0.0, 0.0, 0.0, 0.0);
uniform bool rotation_curve_on = false;

// 0 Screen, 1 Directional, 2 ScreenStretch, 3 FullRotation, 4 Emitter, 5 Up.
uniform int align_mode = 0;

// INSTANCE_CUSTOM IS VERTEX-ONLY in Godot's spatial shaders, so anything the
// fragment stage needs from the particle has to be carried across as a varying.
// Reading it in fragment() compiles nowhere and fails the whole shader.
varying float particle_seed;
varying vec3 card_right;
varying vec3 card_up;
varying vec3 card_normal;
varying float life01;

float cubic(vec4 k, float t) { return ((k.x * t + k.y) * t + k.z) * t + k.w; }

void vertex() {
	life01 = clamp(INSTANCE_CUSTOM.y, 0.0, 1.0);
	// One number per particle, stable for its whole life, for the sheet flips.
	particle_seed = fract(INSTANCE_CUSTOM.z * 0.6180339887 + INSTANCE_CUSTOM.w);

	// THE PARTICLE'S OWN ROTATION, plus the authored curve over its life.
	// CUSTOM.x is the angle Godot's process material maintains.
	float a = INSTANCE_CUSTOM.x;
	if (rotation_curve_on) { a += cubic(rotation_curve, life01); }

	vec3 right, up, normal;
	if (align_mode == 3 || align_mode == 4) {
		// FullRotation and Emitter do not face the camera at all: the particle
		// carries its own orientation and billboarding it would throw away the
		// only thing those modes mean.
		right  = normalize(MODEL_MATRIX[0].xyz);
		up     = normalize(MODEL_MATRIX[1].xyz);
		normal = normalize(MODEL_MATRIX[2].xyz);
	} else if (align_mode == 1 || align_mode == 2 || align_mode == 5) {
		// Axis-constrained billboard: turn to face the camera but keep one axis
		// pinned. Directional and ScreenStretch pin the particle's own Y, which
		// the process material has aligned to its velocity, so a spark or a
		// spray stretches ALONG its travel instead of facing flat. Up pins
		// world up, which is what a ground-hugging dust sheet wants.
		vec3 axis = align_mode == 5 ? vec3(0.0, 1.0, 0.0) : normalize(MODEL_MATRIX[1].xyz);
		vec3 to_cam = normalize(INV_VIEW_MATRIX[3].xyz - MODEL_MATRIX[3].xyz);
		vec3 x = cross(axis, to_cam);
		// Looking straight down the pinned axis leaves the cross product at
		// zero and the card degenerate; any perpendicular will do there.
		if (dot(x, x) < 1e-8) { x = abs(axis.y) < 0.9 ? cross(axis, vec3(0.0, 1.0, 0.0)) : vec3(1.0, 0.0, 0.0); }
		right = normalize(x);
		up = axis;
		normal = cross(right, up);
	} else {
		right  = normalize(INV_VIEW_MATRIX[0].xyz);
		up     = normalize(INV_VIEW_MATRIX[1].xyz);
		normal = normalize(INV_VIEW_MATRIX[2].xyz);
	}

	// Spin the card in its own plane, then restore the emitter's scale, which
	// normalising the axes above has just discarded.
	vec3 r2 = right * cos(a) + up * sin(a);
	vec3 u2 = up * cos(a) - right * sin(a);
	float sx = length(MODEL_MATRIX[0].xyz);
	float sy = length(MODEL_MATRIX[1].xyz);
	if (size_curve_on) {
		float gsz = max(cubic(size_curve, life01), 0.0);
		sx *= gsz;
		sy *= gsz;
	}
	// PivotY shifts the card in its own plane before it is placed, so the
	// origin the artist authored is the one it grows from.
	vec4 origin = MODEL_MATRIX[3];
	origin.xyz += u2 * (pivot_y * sy * 0.5);
	// CameraBias pulls the card toward the viewer, which is how the game keeps
	// a flame from z-fighting the surface it stands on.
	if (camera_bias != 0.0) {
		origin.xyz += normalize(INV_VIEW_MATRIX[3].xyz - origin.xyz) * camera_bias;
	}
	mat4 m = mat4(vec4(r2 * sx, 0.0), vec4(u2 * sy, 0.0),
	              vec4(normal, 0.0), origin);
	MODELVIEW_MATRIX = VIEW_MATRIX * m;

	// The six-way basis is the CARD'S, so it is carried forward rather than
	// recomputed in the fragment stage from a normal the card does not have.
	card_right = right;
	card_up = up;
	card_normal = normal;
}

vec3 order3(vec3 v, int o) {
	if (o == 1) { return v.rbg; }
	if (o == 2) { return v.grb; }
	if (o == 3) { return v.gbr; }
	if (o == 4) { return v.brg; }
	if (o == 5) { return v.bgr; }
	return v;
}

void fragment() {
	// THE FLIPBOOK, clocked off the particle's own life so a short spark and a
	// long plume each play their sheet exactly once.
	// NO SHEET IS NOT A WHITE CARD.
	//
	// A sheetless layer used to start from vec4(1.0), so its density came out 1
	// everywhere and it drew as a SOLID OPAQUE SQUARE - which is what "some of
	// them are just blank squares" was. The families without a sheet are not
	// missing art: sparks, pebbles, thin debris and sand are driven by noise in
	// the game's own compute shader and carry no flipbook at all.
	//
	// So this is a STAND-IN and says so: a soft round falloff, which is what a
	// spark or a mote actually looks like, rather than a square, which is what
	// nothing looks like. It makes no claim about the real pattern.
	float radial = 1.0 - clamp(length(UV - vec2(0.5)) * 2.0, 0.0, 1.0);
	vec4 L = vec4(1.0, 1.0, 1.0, radial * radial);
	vec4 R = L;
	if (has_sheet) {
		float fcount = max(float(frames), 1.0);
		float fpos = life01 * fcount;
		float f0 = min(floor(fpos), fcount - 1.0);
		float f1 = min(f0 + 1.0, fcount - 1.0);
		float fmix = frame_blend ? fract(fpos) : 0.0;

		float c = max(float(cols), 1.0);
		float rows = ceil(fcount / c);
		// A LeftRightTiles sheet is the frames twice side by side, so one half
		// is half the sheet wide and the frame grid lives inside it.
		float half_w = left_right ? 0.5 : 1.0;
		// The particle's own seed decides its flips, so one particle keeps the
		// same orientation for its whole life rather than flickering.
		vec2 uv = UV;
		if (fract(particle_seed * 7.0) < flip_u_probability) { uv.x = 1.0 - uv.x; }
		if (fract(particle_seed * 13.0) < flip_v_probability) { uv.y = 1.0 - uv.y; }

		vec2 cell = vec2(half_w / c, 1.0 / rows);
		vec2 uv0 = vec2(mod(f0, c), floor(f0 / c)) * cell + uv * cell;
		vec2 uv1 = vec2(mod(f1, c), floor(f1 / c)) * cell + uv * cell;

		L = mix(texture(sheet, uv0), texture(sheet, uv1), fmix);
		R = L;
		if (left_right) {
			R = mix(texture(sheet, uv0 + vec2(0.5, 0.0)),
			        texture(sheet, uv1 + vec2(0.5, 0.0)), fmix);
		}
		if (flip_halves) { vec4 t = L; L = R; R = t; }
	}

	// DENSITY IS THE LEFT HALF'S ALPHA. Proved by a sheet whose right alpha is
	// entirely empty while the effect plainly renders; taking the right would
	// draw that effect as nothing at all.
	float density = L.a;
	if (density <= alpha_cull) { discard; }

	vec3 lit;
	if (has_sheet && left_right) {
		// Six terms: L.rgb three directions, R.rgb their opposites. The card's
		// own basis decides which of the six the sun arrives along.
		vec3 dir = normalize(-sun_direction);
		vec3 proj = vec3(dot(dir, card_right), dot(dir, card_up), dot(dir, card_normal));
		vec3 pterm = order3(L.rgb, axis_order);
		vec3 nterm = order3(R.rgb, axis_order);
		float direct = dot(max(proj, vec3(0.0)), pterm) + dot(max(-proj, vec3(0.0)), nterm);
		// Ambient arrives from every direction at once, which is the mean of
		// the six - the same number the old fold produced, kept here as the
		// ambient term rather than used as the whole answer.
		float omni = (pterm.r + pterm.g + pterm.b + nterm.r + nterm.g + nterm.b) / 6.0;
		// Backlight: a plume glows when the sun is behind it. Authored per
		// layer as GnomonBacklight, 17,083 shipped overrides.
		float through = pow(max(-dot(dir, card_normal), 0.0),
		                    max(backlight_contrast, 0.01)) * omni * backlight;
		lit = sun_color * (direct * sun_scale + through)
		    + ambient_color * omni * ambient_scale;
	} else if (has_sheet) {
		// An ordinary flipbook carries no direction, so the honest answer is
		// its own colour under ambient rather than a directional guess made
		// from data that does not contain one.
		lit = L.rgb * (ambient_color * ambient_scale + sun_color * sun_scale);
	} else {
		// Sparks and debris have no sheet at all: they are driven by noise in
		// the game's compute shader, not by art we failed to find.
		lit = ambient_color * ambient_scale + sun_color * sun_scale;
	}

	// The authored fade. Clamped, because many curves run negative before t=1,
	// which only makes sense if the engine clamps - see the finding.
	float fade = clamp(cubic(opacity_curve, life01), 0.0, 1.0);

	// The soft-particle fade would go here; see the note beside inv_z_fade for
	// why it does not, and what re-adding it requires.
	float soft = 1.0;

	ALBEDO = tint * lit * COLOR.rgb;
	ALPHA = density * opacity * fade * soft * COLOR.a;
}
