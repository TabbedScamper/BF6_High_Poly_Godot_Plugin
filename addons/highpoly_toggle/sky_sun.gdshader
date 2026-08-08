shader_type sky;

// THE PANORAMA, WITH A SUN DRAWN ON TOP OF IT.
//
// BF6's sky panoramas contain no sun disc. Verified by rendering all 22 and
// crushing exposure until only real highlights survive: every one goes black.
// The engine draws the disc itself, DrawSunDisc = 1 on every map. So a
// PanoramaSkyMaterial, which can only show the texture, renders a sky with no
// sun in it at all, and the brightest thing in the scene is missing.
//
// This is the panorama sampled exactly as PanoramaSkyMaterial samples it, plus a
// disc and a halo placed from the DirectionalLight the rig has already aimed
// from the level's own SunRotationX/Y. The sky is behind, the sun is in front.

uniform sampler2D panorama : source_color, filter_linear;
uniform float energy_multiplier = 1.0;

// The real sun subtends about 0.53 degrees. Slightly wider reads better at
// editor exposures, where a half-degree disc is a couple of pixels.
uniform float sun_size_deg = 0.9;
uniform float sun_intensity = 12.0;
// The bloom around it. BF6's own skies carry a painted glow already, so this is
// deliberately gentle: it is here to seat the disc, not to replace the art.
uniform float halo_deg = 7.0;
uniform float halo_intensity = 0.18;

const float TAU_ = 6.283185307179586;
const float PI_ = 3.141592653589793;

void sky() {
	// EXACTLY PanoramaSkyMaterial'S MAPPING, including the wrap. Offsetting by
	// 0.5 instead of wrapping negatives looks equivalent and is half a turn out,
	// which shows up as a sky that is rotated 180 degrees rather than as an
	// error.
	vec2 c = vec2(atan(EYEDIR.x, -EYEDIR.z), acos(clamp(EYEDIR.y, -1.0, 1.0)));
	if (c.x < 0.0) {
		c.x += TAU_;
	}
	c /= vec2(TAU_, PI_);
	vec3 col = texture(panorama, c).rgb * energy_multiplier;

	if (LIGHT0_ENABLED) {
		// LIGHT0_DIRECTION IN A SKY SHADER ALREADY POINTS TOWARD THE LIGHT.
		//
		// Not the direction the light travels, which is what the same name means
		// on the light node and what we assumed first. Measured: aiming a
		// DirectionalLight so it travels toward -X and sampling both ways, the
		// disc appears where +LIGHT0_DIRECTION points.
		//
		// Getting it backwards puts the disc at the ANTISOLAR point, which on a
		// daytime sky is below the horizon and therefore never seen. It reads as
		// "the sun did not draw" rather than as a sign error, which is exactly
		// how the same mistake hid in the spot-light cone direction.
		float cd = dot(normalize(EYEDIR), normalize(LIGHT0_DIRECTION));
		float disc = smoothstep(cos(radians(sun_size_deg)),
				cos(radians(sun_size_deg * 0.55)), cd);
		float halo = smoothstep(cos(radians(halo_deg)), 1.0, cd);
		col += LIGHT0_COLOR * LIGHT0_ENERGY
				* (disc * sun_intensity + halo * halo_intensity);
	}

	COLOR = col;
}
