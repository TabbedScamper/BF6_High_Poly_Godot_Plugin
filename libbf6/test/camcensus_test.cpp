/* camcensus_test - is the camera MANAGER reachable from shipped data?
 * The unit is deliberately held at partial because the manager is unread. This
 * measures whether it is unread or simply absent: it counts the camera types
 * that DO ship against the independent level census, and reports that no
 * manager type exists to read. */
#include "bf6_core.h"
#include <cstdio>
int main(int argc,char**argv){
    char e[512]={0}; bf6_ctx* c=bf6_open(argv[1],e,512);
    if(!c||!bf6_mount_all(c,1,e,512)){ std::printf("%s\n",e); return 1; }
    struct T{const char*g;const char*n;int exp;};
    const T rows[]={
        {"075bd7a1-4082-0dfa-2db8-1f7175a641f0","CameraParamsComponentData",1},
        {"94877283-613a-422d-2984-8f673b1b6ab5","CameraTrackData",-1},
        {"67270f8b-e7e2-3c21-e19c-040dc9913b64","CameraDirectorKeyframe",-1},
    };
    int bad=0,parsed=0;
    for(const T&t:rows){
        bf6_type_census_result r=bf6_type_census(c,"levels/mp_dumbo/",t.g);
        parsed+=r.partitions_parsed;
        std::printf("  %-30s %5d instances in %4d partitions",t.n,r.instances,r.partitions_with);
        if(t.exp>=0){ std::printf("   (census says %d)%s",t.exp,r.instances==t.exp?"":"  <== MISMATCH");
                      if(r.instances!=t.exp) bad++; }
        std::printf("\n");
    }
    std::printf("  partitions parsed: %d (must be > 0, else a zero means nothing)\n",parsed);
    bf6_type_census_result f=bf6_type_census(c,"levels/mp_dumbo/","deadbeef-0000-0000-0000-000000000000");
    std::printf("  fabricated guid: %d (must be 0)\n",f.instances);
    if(f.instances) bad++;
    std::printf("\n%s\n", (bad==0&&parsed>0)?"PASS":"FAIL");
    bf6_close(c); return bad==0?0:1;
}
