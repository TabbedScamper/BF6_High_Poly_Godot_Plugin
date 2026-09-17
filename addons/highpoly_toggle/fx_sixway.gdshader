shader_type spatial;
// ONE BF6 EMITTER LAYER, drawn the way the game draws it.
//
// WHY THIS EXISTS. The old path drew every particle as an unshaded quad with a
// flattened sheet, because none of the data needed to do better had been read
// yet. It now has been, per LAYER rather than per graph archetype, so this
// shader implements the three things that were missing and that decide whether
// smoke reads as smoke:
//
//   1. SIX-WAY LIGHTING. A LeftRightTiles sheet is a six-way lightmap: the same
//      frames twice, the halves carrying the light arriving from six directions,
//      with DENSITY in the LEFT half's alpha (findings/atlastexture-grid-and-
//      sixway-packing). The old code averaged the six into one grey scalar and
//      drew it unshaded, which is why our plumes read flat: a real plume is
//      bright where the sun hits it and dark on the other side, and an average
//      is neither. 806 of the 1,567 layers that state a lighting model are
//      GnomonLit.
//   2. ALIGNMENT. Six modes, and 209 layers on MP_Subsurface alone ask for
//      something other than plain screen-facing. Drawing them all as billboards
//      makes every directional effect face the wrong way.
//   3. OVER-LIFE CURVES. Opacity and rotation are authored as CUBICS in the
//      particle's normalised age, not as constants (findings/fx-over-life-
//      fields-are-cubic-coefficients). 518 layers on one level author the
//      opacity one. Without it nothing ever fades.
//
// Lighting is computed here and the surface drawn unshaded, because a particle
// is not a surface: it has no normal to hand the renderer, and the six-way
// terms already ARE its response to light from every direction.
//
// WHAT IS NOT SETTLED. The six-way finding proves L.rgb and R.rgb are three
// directions and their three opposites, and deliberately does NOT settle which
// channel is which axis - "that needs a shader, not a statistical test". So the
// assignment is a UNIFORM here, not a baked-in guess: `axis_order` picks the
// permutation and `flip_halves` swaps which half is positive. A wrong choice
// shows as a plume lit from the wrong side, which is visible at once and costs
// one uniform to correct rather than a rebuild.
render_mode blend_mix, cull_disabled, unshaded, depth_draw_never;

#include "res://addons/highpoly_toggle/fx_sixway.gdshaderinc"
