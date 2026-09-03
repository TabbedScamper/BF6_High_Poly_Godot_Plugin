/* resprov_test - what does data/res_types.tsv actually count?
 *
 * Its totals are ~18x the install's distinct RES names and the per-type ratio
 * varies 2x-76x. A distinct-name count cannot vary like that; a per-bundle
 * LISTING count can, because different resource types are referenced by
 * different numbers of bundles. This measures both numbers directly.
 */
#include "source.h"
#include <cstdio>
#include <map>
#include <string>
int main(int argc, char** argv){
    if(argc<2){ std::printf("usage: resprov_test <game>\n"); return 2; }
    bf6::Source s; std::string e;
    if(!s.open(argv[1],e)||!s.mount_level("",true,e)){ std::printf("%s\n",e.c_str()); return 1; }

    std::map<uint32_t,uint64_t> distinct;
    for(const auto& kv : s.res()) distinct[kv.second.type]++;

    std::printf("RES LISTINGS across all bundles (pre-dedup) : %llu\n",
                (unsigned long long)s.res_entries_total());
    std::printf("RES DISTINCT NAMES (post-dedup)             : %zu\n", s.res().size());
    std::printf("overall listings / distinct                 : %.2fx\n",
                (double)s.res_entries_total() / (double)s.res().size());
    std::printf("\n%-12s %14s %12s %8s   (res_types.tsv figure for comparison)\n",
                "type","listings","distinct","ratio");
    struct R { const char* nm; uint32_t t; long table; };
    const R rows[] = {
        {"ZoneStreamerGrid",0xEFC70728,24},{"OccluderMesh",0x30B4A553,4002},
        {"Texture",0x6BDE20BA,1451638},{"AtlasTexture",0x957C32B1,7010},
        {"RenderTexture",0x41D57E10,542},{"CompiledOnnx",0x4CEFA867,764},
        {"PhysicsResource",0x41759364,669966},
    };
    for(const R& r : rows){
        const uint64_t L = s.res_entries_by_type().count(r.t) ? s.res_entries_by_type().at(r.t) : 0;
        const uint64_t D = distinct.count(r.t) ? distinct.at(r.t) : 0;
        std::printf("%-12s %14llu %12llu %7.1fx   table %ld  %s\n", r.nm,
                    (unsigned long long)L, (unsigned long long)D,
                    D ? (double)L/(double)D : 0.0, r.table,
                    (long)L == r.table ? "<== LISTINGS MATCH THE TABLE" : "");
    }
    /* --tsv: every type, measured. Emitted so units can quote an install
     * figure with a provenance line instead of an undocumented table. */
    bool tsv=false;
    for(int i=2;i<argc;i++) if(std::string(argv[i])=="--tsv") tsv=true;
    if(tsv){
        std::printf("\nBEGIN_TSV\n");
        std::printf("res_type	distinct_names	bundle_listings\n");
        for(const auto& kv : s.res_entries_by_type()){
            const uint64_t D = distinct.count(kv.first) ? distinct.at(kv.first) : 0;
            std::printf("0x%08X	%llu	%llu\n", kv.first,
                        (unsigned long long)D, (unsigned long long)kv.second);
        }
        std::printf("END_TSV\n");
    }
    return 0;
}
