/* libbf6 internal - the ground as WEIGHTS plus a material list, for renderers
 * that blend per pixel instead of consuming a flattened bake.
 *
 * WHY THIS EXISTS ALONGSIDE terraincomposite.
 *
 * terraincomposite flattens the ground into one albedo raster. That is the
 * right shape for an offline look, an atlas or a thumbnail, and the wrong
 * shape for a viewport: a whole-map raster lands at two to four metres a
 * texel, while the layer materials themselves repeat every one to seven
 * metres. Flattening at that density averages each material away before the
 * renderer ever sees it, and the result reads as a low-resolution photograph
 * of ground rather than as ground.
 *
 * The game does not flatten either. It composites into virtual-texture pages
 * at whatever density the camera needs, which is a streaming system no
 * consumer of this library is going to reimplement. The practical equivalent
 * is what every terrain renderer does: carry the COVERAGE, which varies
 * slowly and rasterises happily at a couple of metres, and sample the
 * MATERIALS per pixel at their own tiling, blending by that coverage. The
 * detail then comes from the material sheets at full resolution and only the
 * mixing weights are baked.
 *
 * So this hands a binding two things:
 *   - a coverage raster: per texel, up to four layer indices and weights
 *   - the material list those indices refer to, with each layer's sheet and
 *     the tiling it is authored at
 */
#ifndef LIBBF6_GROUNDSPLAT_H
#define LIBBF6_GROUNDSPLAT_H

#include <cstdint>
#include <string>
#include <vector>

#include "source.h"

namespace bf6 {

// One entry of the material list a coverage index refers to.
struct GroundMaterial {
    int32_t     layer = 0;             // the layer index this came from
    std::string albedo_res;            // texture resource, empty when unbound
    std::string normal_res;
    float       metres_per_repeat = 4.f;
    float       uv_rotation_deg = 0.f;
    float       tint[3] = {1.f, 1.f, 1.f};
};

struct GroundCoverage {
    int   size = 0;
    float lo[2] = {0, 0};              // world XZ of the low corner, metres
    float hi[2] = {0, 0};

    // size*size*4 each. idx[i*4+s] indexes MATERIALS (not raw layer ids), so a
    // consumer can bind exactly the sheets it needs; 255 means "no layer".
    // w[i*4+s] is that slot's weight, 0..255, weight-sorted with the first
    // zero ending the list.
    std::vector<uint8_t> idx;
    std::vector<uint8_t> w;

    std::vector<GroundMaterial> materials;
    uint64_t empty_texels = 0;
};

// Builds the coverage and the material list for a level. `src` must already
// have the level mounted.
bool ground_coverage(Source& src, const std::string& level, int size,
                     GroundCoverage& out, std::string& err);

}  // namespace bf6
#endif
