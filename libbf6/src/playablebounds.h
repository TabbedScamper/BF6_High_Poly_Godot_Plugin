/* libbf6 internal - the PLAYABLE BOX of a level, in world XZ metres.
 *
 * WHY IT MATTERS. A level's terrain footprint is much larger than the area a
 * player can reach: MP_Isolated builds 8,192 m of ground and only 2,555 m of it
 * is playable, the rest being the BACKDROP RING. The ring is authored with
 * distance sheets - flat baked images of far scenery, tiling every hundred
 * metres - because it is only ever meant to be seen from kilometres away.
 * Rebuilt at ground resolution and walked on, it reads as a smear of unrelated
 * object textures across the terrain, which looks like a decoding failure and
 * is not one.
 *
 * WHERE IT COMES FROM. The Portal SDK's own terrain decal plugin ships a box
 * per level in `addons/bf_portal/terrain_decal/bounds.json`, used to place the
 * editor's map overlay. `size` is the FULL box in metres and `position` its
 * centre; the Y components are the decal's projection depth and say nothing
 * about the ground, so only XZ are carried here.
 *
 * Generated from that file. Do not hand-edit: regenerate it.
 */
#ifndef LIBBF6_PLAYABLEBOUNDS_H
#define LIBBF6_PLAYABLEBOUNDS_H

#include <string>

namespace bf6 {

/* The playable box centre and FULL size in world XZ metres. False when the SDK
 * ships no box for this level, in which case a caller should use the whole
 * footprint rather than invent one. */
bool playable_box(const std::string& level,
                  float& cx, float& cz, float& sx, float& sz);

}  // namespace bf6
#endif
