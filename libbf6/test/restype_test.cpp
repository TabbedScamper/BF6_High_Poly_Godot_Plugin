/* restype_test - how many resources of a RES type does the INSTALL actually
 * carry, and where? data/res_types.tsv counts a dump; this counts the mount. */
#include "bf6_core.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <vector>
int main(int argc, char** argv){
    if(argc<3){ std::printf("usage: restype_test <game> <0xTYPE> [prefixdepth]\n"); return 2; }
    const uint32_t want=(uint32_t)strtoul(argv[2],nullptr,0);
    const int depth=(argc>3)?atoi(argv[3]):4;
    char e[512]={0}; bf6_ctx* c=bf6_open(argv[1],e,512);
    if(!c||!bf6_mount_all(c,1,e,512)){ std::printf("%s\n",e); return 1; }
    int n=bf6_list_res(c,nullptr,nullptr,0);
    std::vector<bf6_asset> a((size_t)(n>0?n:0));
    int got=bf6_list_res(c,nullptr,a.data(),n);
    std::map<std::string,int> fam; long long bytes=0; int total=0;
    for(int i=0;i<got;i++){
        if(!a[i].name||a[i].type!=want) continue;
        total++; bytes+=a[i].size;
        std::string s=a[i].name; int slash=0; size_t cut=s.size();
        for(size_t k=0;k<s.size();k++){ if(s[k]=='/'){ if(++slash==depth){cut=k;break;} } }
        fam[s.substr(0,cut)]++;
    }
    std::printf("type 0x%08X : %d resources in the mount, %.1f MB total\n",
                want,total,(double)bytes/1048576.0);
    for(const auto&kv:fam) std::printf("   %5d  %s\n",kv.second,kv.first.c_str());
    bf6_close(c); return total>0?0:1;
}
