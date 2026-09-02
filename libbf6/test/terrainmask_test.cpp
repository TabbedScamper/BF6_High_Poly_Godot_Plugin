#include <cstdio>
#include <cstdlib>
#include <map>
#include <string>

#include "groundsplat.h"
#include "source.h"
#include "terrainmask.h"

using namespace bf6;

int main(int argc,char** argv)
{
    if(argc<5){std::fprintf(stderr,"usage: terrainmask_test <game_dir> <level> <x_m> <z_m>\n");return 2;}
    Source src;std::string err;if(!src.open(argv[1],err)||!src.mount_level(argv[2],false,err)){std::fprintf(stderr,"mount: %s\n",err.c_str());return 1;}
    const float x=(float)std::atof(argv[3]),z=(float)std::atof(argv[4]);GroundCoverageOpts o;o.size=64;o.max_slots=8;o.rect_size=64;o.rect_min[0]=x-32;o.rect_min[1]=z-32;
    GroundCoverage g;if(!ground_coverage(src,argv[2],o,g,err)){std::fprintf(stderr,"coverage: %s\n",err.c_str());return 1;}
    TerrainMaskAtlas a;if(!build_terrain_mask_atlas(g,a,err)){std::fprintf(stderr,"atlas: %s\n",err.c_str());return 1;}
    uint64_t real_bad=0,shuffle_bad=0,checks=0;std::map<int,int> next;int prev=-1,first=-1;
    for(const auto& kv:a.layer_panel){if(first<0)first=kv.first;if(prev>=0)next[prev]=kv.first;prev=kv.first;}if(prev>=0)next[prev]=first;
    for(int zz=0;zz<g.size;zz++)for(int xx=0;xx<g.size;xx++)for(const auto& kv:a.layer_panel){
        uint8_t want=0;const size_t p=(size_t)zz*g.size+xx;
        for(int s=0;s<g.slots;s++){const size_t at=p*g.slots+s;const uint8_t mi=g.idx[at];if(g.w[at]&&mi!=255&&mi<g.materials.size()&&g.materials[mi].layer==kv.first)want=g.w[at];}
        auto sample=[&](int layer){int q=a.layer_panel[layer];return a.r8[(size_t)((q/a.grid)*g.size+zz)*a.atlas_size+(q%a.grid)*g.size+xx];};
        if(sample(kv.first)!=want)real_bad++;if(sample(next[kv.first])!=want)shuffle_bad++;checks++;
    }
    uint32_t minlist=999,maxlist=0;for(uint32_t n:a.list_count){minlist=std::min(minlist,n);maxlist=std::max(maxlist,n);}
    std::printf("live atlas: %dx%d, %zu layer panels, %dx%d work tiles, list range %u..%u\n",a.atlas_size,a.atlas_size,a.layer_panel.size(),a.tiles_per_side,a.tiles_per_side,minlist,maxlist);
    bool heads=true;for(size_t i=0;i<a.packed_head.size();i++)heads&=(a.packed_head[i]&255u)==a.list_count[i]&&(a.packed_head[i]>>8)==a.list_offset[i];
    std::printf("t9/t13 packing: %s (%zu tile descriptors/heads)\n",heads?"PASS":"FAIL",a.packed_head.size());
    std::printf("real layer/mask join: %s (%llu/%llu mismatches)\n",real_bad?"FAIL":"PASS",(unsigned long long)real_bad,(unsigned long long)checks);
    std::printf("shuffled-layer control: %s (%llu/%llu mismatches)\n",shuffle_bad?"PASS/rejected":"FAIL/accepted",(unsigned long long)shuffle_bad,(unsigned long long)checks);
    return !real_bad&&shuffle_bad&&heads?0:1;
}
