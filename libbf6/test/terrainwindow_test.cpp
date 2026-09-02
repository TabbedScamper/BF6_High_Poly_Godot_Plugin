/* Camera-relative coverage input for the shipped terrain evaluator.
 * Usage: terrainwindow_test <game_dir> <level> <x_m> <z_m> [side_m] [size]
 */
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <string>

#include "groundsplat.h"
#include "source.h"

using namespace bf6;

int main(int argc,char** argv)
{
    if(argc<5){std::fprintf(stderr,"usage: terrainwindow_test <game_dir> <level> <x_m> <z_m> [side_m] [size]\n");return 2;}
    const float x=(float)std::atof(argv[3]),z=(float)std::atof(argv[4]);
    const float side=argc>5?(float)std::atof(argv[5]):64.f;const int size=argc>6?std::atoi(argv[6]):64;
    Source src;std::string err;if(!src.open(argv[1],err)||!src.mount_level(argv[2],false,err)){std::fprintf(stderr,"mount: %s\n",err.c_str());return 1;}
    GroundCoverageOpts o;o.size=size;o.max_slots=8;o.rect_min[0]=x-side*.5f;o.rect_min[1]=z-side*.5f;o.rect_size=side;
    GroundCoverage g;if(!ground_coverage(src,argv[2],o,g,err)){std::fprintf(stderr,"coverage: %s\n",err.c_str());return 1;}
    std::map<int,uint64_t> texels;std::map<int,uint64_t> weight;
    for(size_t p=0;p<(size_t)g.size*g.size;p++)for(int s=0;s<g.slots;s++){
        const uint8_t mi=g.idx[p*g.slots+s],w=g.w[p*g.slots+s];if(mi==255||!w||mi>=g.materials.size())continue;
        texels[g.materials[mi].layer]++;weight[g.materials[mi].layer]+=w;
    }
    std::printf("window %.3f %.3f, %.1fm -> %dx%d (%.3fm/texel), %zu material(s), %.2f%% empty\n",x,z,side,g.size,g.size,side/g.size,g.materials.size(),100.0*(double)g.empty_texels/(g.size*g.size));
    for(const auto& kv:texels){const GroundMaterial* m=nullptr;for(const auto& q:g.materials)if(q.layer==kv.first){m=&q;break;}std::printf("  L%-2d %5.1f%% mask-mean %6.3f  %s\n",kv.first,100.0*kv.second/(g.size*g.size),(double)weight[kv.first]/(255.0*kv.second),m&& !m->albedo_res.empty()?m->albedo_res.c_str():"(shader/static or unresolved)");}
    return 0;
}
