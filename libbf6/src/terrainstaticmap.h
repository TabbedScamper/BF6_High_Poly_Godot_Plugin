/* libbf6 internal - the terrain layer to TEXTURE DESCRIPTOR map, as data.
 *
 * WHY THIS IS A TABLE AND NOT A RULE.
 *
 * A terrain layer whose ShaderLayerInfos row carries no bindless colour has its
 * sheets bound by register, and which layer consumes which group is decided by
 * the compositor's compiled bytecode, not by anything in the shipped data. The
 * ordinal walk that stood in for it - the k-th such layer takes the k-th group -
 * is right on some levels and badly wrong on others, because the GROUP
 * BOUNDARIES are not in the data either: the same descriptor pattern is a
 * separate layer's allocation on one level and part of the previous layer's on
 * another. The best data-only predicate found scores 246 of 261 pairs; only the
 * bytecode closes the remaining fifteen.
 *
 * So the mapping is recovered offline, once, by disassembling every shipped
 * terrain evaluator and reading which texture registers each top-level switch
 * case samples - case N is layer N - and shipped here as a table. Descriptor
 * index d is SRV register t(d + 21); 21 is the only base that fits across all
 * 21 kernels with no misalignment and no runner-up.
 *
 * Generated from BF6_Frostbite_Research/data/terrain_static_layer_map.tsv.
 * Do not hand-edit: regenerate it.
 */
#ifndef LIBBF6_TERRAINSTATICMAP_H
#define LIBBF6_TERRAINSTATICMAP_H

#include <string>

namespace bf6 {

/* The descriptor indices this layer's evaluator case actually samples, or
 * false when the table does not cover this (level, layer). -1 means the case
 * binds nothing for that slot, which is a real answer: a MODIFIER layer has no
 * colour of its own. */
bool static_layer_descriptors(const std::string& level, int layer,
                              int& cv, int& nh, int& third);

/* True when the table covers this level at all, so a caller can say whether it
 * is running on recovered data or on the ordinal fallback. */
bool static_layer_map_has(const std::string& level);

}  // namespace bf6
#endif
