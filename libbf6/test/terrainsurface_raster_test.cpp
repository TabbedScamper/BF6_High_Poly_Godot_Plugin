/* Live final-terrain-raster audit.
 *
 * Reads the mounted level's SurfaceShaderBlockKey, follows its ESDB slots to
 * raster permutations, prints the common/variant BindingSets, joins the exact
 * surface ShaderBlockDepot values, and optionally writes the current install's
 * stage-2 DXIL containers for disassembly.  Dumped files are diagnostics only;
 * no runtime consumer reads them.
 *
 *   terrainsurface_raster_test <game_dir> <level> [--out-dir <dir>]
 */
#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <map>
#include <set>
#include <string>
#include <vector>

#include "depot.h"
#include "source.h"
#include "terrainlayers.h"

using namespace bf6;

template <typename T> static T rd(const std::vector<uint8_t>& d, size_t o)
{ T v{}; if (o + sizeof(T) <= d.size()) std::memcpy(&v, d.data() + o, sizeof(T)); return v; }

static std::string lower(std::string s)
{ for (char& c : s) c = (char)std::tolower((unsigned char)c); return s; }

static std::string texture_asset(Source& src, const std::string& guid)
{
    const auto& index = src.partition_index();
    auto it = index.find(guid);
    if (it == index.end()) return "<unresolved>";
    std::string name = it->second;
    if (name.size() > 4 && name.compare(name.size() - 4, 4, ".ebx") == 0)
        name.resize(name.size() - 4);
    return name;
}

static std::string guid_net(const std::vector<uint8_t>& d, size_t o)
{
    if (o + 16 > d.size()) return {};
    char b[64];
    std::snprintf(b, sizeof(b),
        "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
        d[o+3],d[o+2],d[o+1],d[o],d[o+5],d[o+4],d[o+7],d[o+6],
        d[o+8],d[o+9],d[o+10],d[o+11],d[o+12],d[o+13],d[o+14],d[o+15]);
    return b;
}

struct Decl { uint64_t param{}; uint32_t type{}, dest{}; uint16_t flags{}, name_hi{}, meta{};
    uint32_t name32() const { return ((uint32_t)name_hi << 16) | (uint32_t)((param >> 48) & 0xffff); } };
struct BsRec { uint32_t span{}; uint16_t fixups{}; std::vector<Decl> decls; };

static bool read_bindingset(Source& src, uint64_t id, std::vector<BsRec>& out, std::string& err)
{
    out.clear(); if (!id) return true;
    char nm[128]; std::snprintf(nm, sizeof(nm), "expressionshader/bindingset/%llu", (unsigned long long)id);
    const std::vector<uint8_t> d = src.get_res(nm, err);
    if (d.size() < 12) { err = "missing BindingSet " + std::string(nm); return false; }
    const uint32_t n = rd<uint32_t>(d, 0); const uint64_t p = rd<uint64_t>(d, 4);
    if (!n || n > 4096 || p >= d.size()) { err = "invalid BindingSet table"; return false; }
    for (uint32_t r = 0; r < n; ++r) {
        const size_t at = (size_t)p + (size_t)r * 0x38;
        if (at + 0x38 > d.size()) { err = "truncated BindingSet record"; return false; }
        BsRec b; b.span = rd<uint32_t>(d, at + 8); const uint16_t nd = rd<uint16_t>(d, at + 0x10);
        b.fixups = rd<uint16_t>(d, at + 0x12); const uint64_t dp = rd<uint64_t>(d, at + 0x20);
        const uint64_t sp = rd<uint64_t>(d, at + 0x28);
        for (uint16_t i = 0; i < nd; ++i) {
            const size_t da=(size_t)dp+(size_t)i*16, sa=(size_t)sp+(size_t)i*8;
            if (da+16>d.size() || sa+8>d.size()) { err="truncated BindingSet declaration"; return false; }
            Decl x; x.param=rd<uint64_t>(d,da); x.type=rd<uint32_t>(d,da+8);
            x.flags=rd<uint16_t>(d,da+12); x.name_hi=rd<uint16_t>(d,da+14);
            x.dest=rd<uint32_t>(d,sa); x.meta=rd<uint16_t>(d,sa+6); b.decls.push_back(x);
        }
        out.push_back(std::move(b));
    }
    return true;
}

static bool find_key(const std::vector<uint8_t>& db, uint64_t key,
                     uint32_t programs, size_t& at)
{
    at = 0;
    for (size_t o=0; o+12<=db.size(); o+=4) {
        if (rd<uint64_t>(db,o)!=key) continue;
        const uint32_t n=rd<uint32_t>(db,o+8); if (!n || n>8 || o+12ull+4ull*n>db.size()) continue;
        bool ok=true; for (uint32_t i=0;i<n;++i) if (rd<uint32_t>(db,o+12+4ull*i)>=programs) ok=false;
        if (ok) { at=o; return true; }
    }
    return false;
}

static bool bare_dxbc(Source& src, const std::string& guid, std::vector<uint8_t>& out, std::string& err)
{
    const std::string needle=lower(guid); std::vector<uint8_t> wrapped;
    for (const auto& kv:src.res()) {
        const std::string n=lower(kv.first);
        if (n.find("bytecode")==std::string::npos || n.find(needle)==std::string::npos) continue;
        wrapped=src.get_res(kv.first,err); if (!wrapped.empty()) break;
    }
    size_t at=std::string::npos;
    for (size_t o=0;o+4<=wrapped.size() && o<8192;++o) if (!std::memcmp(wrapped.data()+o,"DXBC",4)){at=o;break;}
    if (at==std::string::npos || at+0x20>wrapped.size()) { err="no DXBC container for "+guid; return false; }
    const uint32_t n=rd<uint32_t>(wrapped,at+0x18);
    if (n<0x20 || at+n>wrapped.size()) { err="invalid DXBC size for "+guid; return false; }
    out.assign(wrapped.begin()+at,wrapped.begin()+at+n); return true;
}

static void print_set(Source& src, const char* label, uint64_t id,
                      const MaterialBinding& surface, std::string& err)
{
    std::vector<BsRec> recs; if (!read_bindingset(src,id,recs,err)) { std::printf("%s ERROR %s\n",label,err.c_str()); return; }
    std::printf("%s id=%llu records=%zu\n",label,(unsigned long long)id,recs.size());
    for (size_t r=0;r<recs.size();++r) {
        std::printf("  rec%zu span=%u fixups=%u decls=%zu\n",r,recs[r].span,recs[r].fixups,recs[r].decls.size());
        std::vector<Decl> ds=recs[r].decls; std::sort(ds.begin(),ds.end(),[](const Decl&a,const Decl&b){return a.dest<b.dest;});
        for (const Decl& x:ds) {
            const uint32_t n=x.name32(); std::printf("    dest=%u name32=%08x type=%08x",x.dest,n,x.type);
            auto ti=surface.textures.find(n); auto ci=surface.constants.find(n);
            if (ti!=surface.textures.end()) std::printf(" texture=%s asset=%s",ti->second.c_str(),texture_asset(src,ti->second).c_str());
            else if (ci!=surface.constants.end()) { std::printf(" bytes="); for(uint8_t b:ci->second) std::printf("%02x",b); }
            else std::printf(" missing");
            std::printf("\n");
        }
    }
}

int main(int argc,char**argv)
{
    if(argc<3){std::fprintf(stderr,"usage: terrainsurface_raster_test <game_dir> <level> [--out-dir <dir>]\n");return 2;}
    std::filesystem::path outdir; for(int i=3;i+1<argc;++i) if(std::string(argv[i])=="--out-dir") outdir=argv[++i];
    Source src; std::string err; if(!src.open(argv[1],err)||!src.mount_level(argv[2],false,err)){std::fprintf(stderr,"mount: %s\n",err.c_str());return 1;}
    TerrainLayers layers; if(!layers.load(src,argv[2],err)){std::fprintf(stderr,"terrain layers: %s\n",err.c_str());return 1;}
    const uint64_t key=layers.surface_key(); std::printf("level=%s surface_key=%016llx\n",argv[2],(unsigned long long)key);
    MaterialBinding surface; bool have_surface=false;
    for(const auto&kv:src.res()) if(lower(kv.first).find("shaderblockdepot")!=std::string::npos){
        const std::vector<uint8_t>d=src.get_res(kv.first,err); Depot dep; if(d.empty()||!dep.parse(d,err)||!dep.has_key(key))continue;
        surface=dep.textures_for(key,d); have_surface=true; std::printf("surface_depot=%s constants=%zu textures=%zu\n",kv.first.c_str(),surface.constants.size(),surface.textures.size()); break;
    }
    if(!have_surface){std::fprintf(stderr,"surface key has no live depot record\n");return 1;}
    std::string dbname; for(const auto&kv:src.res()){const std::string n=lower(kv.first);if(n.find("shaderstate_db")!=std::string::npos&&n.find(lower(argv[2]))!=std::string::npos){dbname=kv.first;break;}}
    const std::vector<uint8_t>db=src.get_res(dbname,err); if(db.size()<12){std::fprintf(stderr,"no ESDB\n");return 1;}
    const uint32_t programs=rd<uint32_t>(db,0); const uint64_t pp=rd<uint64_t>(db,4); size_t key_at=0,fake_at=0;
    if(!find_key(db,key,programs,key_at)){std::fprintf(stderr,"real surface key absent from ESDB\n");return 1;}
    const uint64_t fake=key^0x9e3779b97f4a7c15ull; const bool fake_hit=find_key(db,fake,programs,fake_at);
    std::printf("control_fake_key=%016llx hits=%d\n",(unsigned long long)fake,fake_hit?1:0);
    if(fake_hit){std::fprintf(stderr,"fake-key control failed\n");return 1;}
    std::map<uint64_t,std::string> perms; for(const auto&kv:src.res()){
        const std::string n=lower(kv.first); const size_t p=n.find("expressionshader/permutation"); if(p==std::string::npos||n.find("shareddata")!=std::string::npos)continue;
        const uint64_t id=std::strtoull(n.c_str()+p+28,nullptr,10); if(id)perms[id]=kv.first;
    }
    if(!outdir.empty()) std::filesystem::create_directories(outdir);
    std::set<std::string> stages; std::set<uint64_t> shared_seen; uint32_t raster=0;
    const uint32_t nslots=rd<uint32_t>(db,key_at+8); std::printf("program_slots=%u\n",nslots);
    for(uint32_t si=0;si<nslots;++si){
        const uint32_t slot=rd<uint32_t>(db,key_at+12+4ull*si); const size_t rec=(size_t)pp+(size_t)slot*0xA8;
        if(rec+0xA8>db.size())continue; const uint32_t np=rd<uint32_t>(db,rec+0x60), po=rd<uint32_t>(db,rec+0x64);
        std::printf("slot[%u]=%u permutations=%u\n",si,slot,np);
        for(uint32_t pi=0;pi<np&&pi<1024;++pi){
            const uint64_t pid=rd<uint64_t>(db,(size_t)po+8ull*pi); auto it=perms.find(pid); if(it==perms.end())continue;
            const std::vector<uint8_t>pr=src.get_res(it->second,err); if(pr.size()<52)continue; ++raster;
            const uint64_t shared=rd<uint64_t>(pr,0); const std::string stage2=pr.size()>=68?guid_net(pr,0x30):std::string();
            std::printf("  raster pid=%llu bytes=%zu shared=%llu stage2=%s\n",(unsigned long long)pid,pr.size(),(unsigned long long)shared,stage2.c_str());
            if(shared_seen.insert(shared).second){
                char sn[128];std::snprintf(sn,sizeof(sn),"expressionshader/permutationshareddata/%llu",(unsigned long long)shared);
                const std::vector<uint8_t>sd=src.get_res(sn,err); if(sd.size()>=0x28){print_set(src,"  common",rd<uint64_t>(sd,0x18),surface,err);print_set(src,"  variant",rd<uint64_t>(sd,0x20),surface,err);}
            }
            if(!stage2.empty()&&stages.insert(stage2).second&&!outdir.empty()){
                std::vector<uint8_t>dxbc;if(!bare_dxbc(src,stage2,dxbc,err)){std::fprintf(stderr,"%s\n",err.c_str());return 1;}
                const std::filesystem::path path=outdir/(stage2+".dxbc"); FILE*f=nullptr;fopen_s(&f,path.string().c_str(),"wb");if(!f){std::fprintf(stderr,"cannot write %s\n",path.string().c_str());return 1;}fwrite(dxbc.data(),1,dxbc.size(),f);fclose(f);
            }
        }
    }
    std::printf("SUMMARY raster_records=%u unique_stage2=%zu fake_hits=0\n",raster,stages.size());
    return raster&&stages.size()>=1?0:1;
}
