shader_type spatial;
// BF6 backdrop-FX flipbook card (editor playback of the game's own data).
// The sheet packs the card's smoke density at 3 OFFSET ANIMATION TIMES in
// R/G/B (alpha = the card silhouette); the game's Frostbite shader crossfades
// the channels to animate. This does the same, ping-ponging R>G>B>G so the
// 3-sample loop never pops. Speed is the one guessed value (the real rate
// lives in the unparsed material graph) — tune `speed` to taste.
render_mode blend_mix, cull_disabled, unshaded;

uniform sampler2D packed_tex : source_color, filter_linear_mipmap;
uniform float speed = 0.25;      // ping-pong legs per second
uniform vec3 tint = vec3(1.0);

void fragment() {
	vec4 s = texture(packed_tex, UV);
	float t = TIME * speed;
	float leg = floor(mod(t, 4.0));      // R>G, G>B, B>G, G>R
	float f = smoothstep(0.0, 1.0, fract(t));
	float a0 = leg < 0.5 ? s.r : (leg < 1.5 ? s.g : (leg < 2.5 ? s.b : s.g));
	float a1 = leg < 0.5 ? s.g : (leg < 1.5 ? s.b : (leg < 2.5 ? s.g : s.r));
	float d = mix(a0, a1, f);
	ALBEDO = tint * d;
	ALPHA = s.a;
}
