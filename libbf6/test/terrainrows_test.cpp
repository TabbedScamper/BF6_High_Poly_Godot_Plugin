/* Live ShaderLayerInfos row materialization.
 *
 * Control A supplies no bindless descriptors and must bind none.  Control B
 * shifts every descriptor by 1000; only texture fields may change and each of
 * them must change by exactly 1000.  This catches both positional field reads
 * and accidentally embedded descriptor tables.
 */
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <vector>

#include "source.h"
#include "terrainlayers.h"
#include "terrainshader.h"

using namespace bf6;

static uint32_t u32(const std::vector<uint8_t>& d, size_t o)
{ uint32_t v=0; if(o+4<=d.size())std::memcpy(&v,d.data()+o,4); return v; }

int main(int argc,char** argv)
{
    if(argc<3){std::fprintf(stderr,"usage: terrainrows_test <game_dir> <level>\n");return 2;}
    Source src;std::string err;
    if(!src.open(argv[1],err)||!src.mount_level(argv[2],false,err))
    {std::fprintf(stderr,"mount: %s\n",err.c_str());return 1;}
    TerrainShaderProgram shader;TerrainLayers layers;
    if(!load_terrain_shader(src,argv[2],shader,err)||!layers.load(src,argv[2],err))
    {std::fprintf(stderr,"read: %s\n",err.c_str());return 1;}

    std::map<std::string,uint32_t> real,shifted;
    uint32_t next=1;
    for(const TerrainLayer& l:layers.layers())for(const auto& kv:l.material.raw_textures)
        if(!real.count(kv.second))real[kv.second]=next++;
    for(const auto& kv:real)shifted[kv.first]=kv.second+1000;

    std::vector<uint8_t> a,b,empty;TerrainRowBuildStats sa,sb,se;
    if(!build_terrain_layer_rows(shader,layers,real,a,sa,err)||
       !build_terrain_layer_rows(shader,layers,shifted,b,sb,err)||
       !build_terrain_layer_rows(shader,layers,{},empty,se,err))
    {std::fprintf(stderr,"rows: %s\n",err.c_str());return 1;}

    const TerrainShaderBindingRecord* schema=nullptr;
    for(const auto& r:shader.layer_records)if(!schema||r.destination_span>schema->destination_span)schema=&r;
    bool exact=true,shift_only=true;uint64_t checked_constants=0,checked_textures=0;
    for(const TerrainLayer& l:layers.layers())for(const TerrainShaderDecl& d:schema->declarations){
        const size_t at=(size_t)l.index*shader.layer_row_stride()+d.destination;
        if(d.type_hash==0xcc84d53d){
            auto ti=l.material.raw_textures.find(d.name32());if(ti==l.material.raw_textures.end())continue;
            checked_textures++;
            if(u32(a,at)!=real[ti->second]||u32(b,at)!=shifted[ti->second]||u32(empty,at)!=0)exact=false;
        }else{
            auto ci=l.material.raw_constants.find(d.name32());if(ci==l.material.raw_constants.end())continue;
            checked_constants++;
            const size_t n=std::min<size_t>(ci->second.size(),shader.layer_row_stride()-d.destination);
            if(std::memcmp(a.data()+at,ci->second.data(),n)||std::memcmp(a.data()+at,b.data()+at,n))shift_only=false;
        }
    }
    const bool control=se.bound_textures==0&&se.missing_textures>0;
    std::printf("live schema: permutation %llu, %u-byte rows, %u row(s)\n",
        (unsigned long long)shader.permutation_id,shader.layer_row_stride(),sa.rows);
    std::printf("authored row copies: %s (%llu constants, %llu textures)\n",
        exact&&shift_only?"PASS":"FAIL",(unsigned long long)checked_constants,(unsigned long long)checked_textures);
    std::printf("control empty descriptor map: %s (%u missing, %u bound)\n",
        control?"PASS":"FAIL",se.missing_textures,se.bound_textures);
    std::printf("control descriptor shift: %s (only texture dwords changed by +1000)\n",
        exact&&shift_only?"PASS":"FAIL");
    std::printf("defaults disclosed: %u known schema values defaulted\n",sa.defaulted_values);
    return exact&&shift_only&&control?0:1;
}
