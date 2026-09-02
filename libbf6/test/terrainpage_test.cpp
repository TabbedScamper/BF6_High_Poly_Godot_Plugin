#include <cstdio>
#include <cstdlib>
#include <map>
#include <string>
#include "source.h"
#include "terrainpage.h"
using namespace bf6;
int main(int argc,char** argv){
 if(argc<5){std::fprintf(stderr,"usage: terrainpage_test <game_dir> <level> <x_m> <z_m>\n");return 2;}
 Source src;std::string err;if(!src.open(argv[1],err)||!src.mount_level(argv[2],false,err)){std::fprintf(stderr,"mount: %s\n",err.c_str());return 1;}
 const float x=(float)std::atof(argv[3]),z=(float)std::atof(argv[4]);TerrainPageOpts o;o.rect_min[0]=x-32;o.rect_min[1]=z-32;TerrainPageInputs p;
 if(!prepare_terrain_page(src,argv[2],o,p,err)){std::fprintf(stderr,"page: %s\n",err.c_str());return 1;}
 uint64_t sb=0,bb=0;int arrays=0;std::map<int,int> formats;for(const auto& t:p.statics){sb+=t.texture.image.blocks.size();arrays+=t.texture.image.slices>1;formats[t.texture.image.dxgi]++;}for(const auto& t:p.bindless.textures){bb+=t.image.blocks.size();formats[t.image.dxgi]++;}
 std::printf("page inputs: %dpx/%.1fm, %zu mask layers, %zu work entries\n",p.coverage.size,o.rect_size,p.masks.layer_panel.size(),p.masks.packed_work.size()/2);
 std::printf("height window: %dx%d R16, %.3fm/texel, %llu unresolved samples\n",p.height.size,p.height.size,p.height.texel_m,(unsigned long long)p.height.missing);
 std::printf("shader %zu bytes, rows %zu bytes, static %zu (arrays %d, %.1f MiB), bindless %zu (%.1f MiB)\n",p.shader.bytecode.size(),p.rows.size(),p.statics.size(),arrays,sb/1048576.0,p.bindless.textures.size(),bb/1048576.0);
 std::printf("texture formats:");for(const auto& kv:formats)std::printf(" DXGI%d=%d",kv.first,kv.second);std::printf("\n");
 for(const auto& u:p.unresolved_statics)std::printf("unresolved static t%u: format %d, %dx%dx%d, %s, %s\n",21+u.descriptor,u.source_format,u.source_width,u.source_height,u.source_slices,u.resource.c_str(),u.error.c_str());
 const bool pass=p.masks.packed_head.size()==64&&!p.rows.empty()&&!p.statics.empty()&&!p.bindless.textures.empty()&&p.unresolved_statics.empty()&&!p.height.heights.empty()&&p.height.missing==0;std::printf("complete live material+height page contract: %s (%zu unresolved static resources, %llu unresolved height samples)\n",pass?"PASS":"FAIL",p.unresolved_statics.size(),(unsigned long long)p.height.missing);return pass?0:1;
}
