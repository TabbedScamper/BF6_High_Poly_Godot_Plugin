#include <cstdio>
#include <cstdlib>
#include <set>
#include <string>

#include "groundsplat.h"
#include "source.h"
#include "terrainlayers.h"
#include "terrainmask.h"
#include "terrainshader.h"
#include "terraintextures.h"

using namespace bf6;

int main(int argc,char** argv)
{
    if(argc<5){std::fprintf(stderr,"usage: terrainbindless_test <game_dir> <level> <x_m> <z_m>\n");return 2;}
    Source src;std::string err;if(!src.open(argv[1],err)||!src.mount_level(argv[2],false,err)){std::fprintf(stderr,"mount: %s\n",err.c_str());return 1;}
    const float x=(float)std::atof(argv[3]),z=(float)std::atof(argv[4]);GroundCoverageOpts o;o.size=64;o.max_slots=8;o.rect_size=64;o.rect_min[0]=x-32;o.rect_min[1]=z-32;GroundCoverage g;
    if(!ground_coverage(src,argv[2],o,g,err)){std::fprintf(stderr,"coverage: %s\n",err.c_str());return 1;}TerrainMaskAtlas a;if(!build_terrain_mask_atlas(g,a,err)){std::fprintf(stderr,"atlas: %s\n",err.c_str());return 1;}
    std::set<int> active;for(const auto& kv:a.layer_panel)active.insert(kv.first);TerrainLayers layers;TerrainShaderProgram shader;
    if(!layers.load(src,argv[2],err)||!load_terrain_shader(src,argv[2],shader,err)){std::fprintf(stderr,"schema: %s\n",err.c_str());return 1;}
    TerrainBindlessTable table;if(!load_terrain_bindless(src,layers,active,512,table,err)){std::fprintf(stderr,"bindless: %s\n",err.c_str());return 1;}
    std::vector<uint8_t> rows;TerrainRowBuildStats stats;if(!build_terrain_layer_rows(shader,layers,table.descriptor_by_guid,rows,stats,err)){std::fprintf(stderr,"rows: %s\n",err.c_str());return 1;}
    uint64_t bytes=0;int mipmapped=0,srgb=0;for(const auto& t:table.textures){bytes+=t.image.blocks.size();mipmapped+=t.image.mip_count>1;srgb+=t.image.srgb;}
    bool active_complete=true;uint32_t active_decl=0;for(const auto& l:layers.layers())if(active.count((int)l.index))for(const auto& kv:l.material.raw_textures){active_decl++;active_complete&=table.descriptor_by_guid.count(kv.second)>0;}
    std::printf("camera bindless: %u declarations -> %u unique live textures, %.1f MiB authored BCn\n",table.declarations,table.unique_guids,bytes/1048576.0);
    std::printf("active descriptor join: %s (%u declarations)\n",active_complete?"PASS":"FAIL",active_decl);
    std::printf("authored mip chains: %d/%zu; sRGB: %d/%zu; row binds: %u\n",mipmapped,table.textures.size(),srgb,table.textures.size(),stats.bound_textures);
    return active_complete&&table.textures.size()==table.unique_guids?0:1;
}
