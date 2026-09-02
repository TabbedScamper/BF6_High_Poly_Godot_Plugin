#include "bf6_core.h"
#include "armory_camera_composition.h"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <set>
#include <string>
#include <vector>

static int progress(void*, const char* stage, int done, int total)
{
    if (done == 0 || done == total || (done % 25000) == 0)
        std::fprintf(stderr,"progress %s %d/%d\n",stage?stage:"?",done,total);
    return 1;
}

int main(int argc, char** argv)
{
    if (argc < 2) { std::fprintf(stderr,"usage: armory_camera_composition_test <game_dir>\n"); return 2; }
    char err[512]{};
    bf6_ctx* c=bf6_open(argv[1],err,(int)sizeof(err));
    if (!c) { std::fprintf(stderr,"open: %s\n",err); return 1; }
    bf6_set_progress(c,&progress,nullptr);
    if (!bf6_mount_frontend(c,err,(int)sizeof(err))) {
        std::fprintf(stderr,"mount: %s\n",err); bf6_close(c); return 1;
    }

    bf6_armory_camera_sensor sensor{};
    const bool sensor_ok=bf6_armory_camera_sensor_read(c,&sensor)!=0;
    std::printf("sensor real=%d candidates=%d asset=%s gate=%.6fx%.6f\n",
                sensor_ok?1:0,sensor.candidates,sensor.asset,sensor.width_mm,sensor.height_mm);
    if (!sensor_ok) {
        const int bn=bf6_list_ebx(c,"body",nullptr,0);
        std::vector<bf6_asset> body_assets(bn>0?(size_t)bn:0);
        if (bn>0) bf6_list_ebx(c,"body",body_assets.data(),bn);
        for (const bf6_asset& a:body_assets)
            if (a.name && std::strstr(a.name,"camera")) std::printf("camera-body candidate %s\n",a.name);
    }

    const int modes=bf6_armory_camera_modes(c,nullptr,0);
    std::vector<bf6_armory_camera_mode> inventory(modes>0?(size_t)modes:0);
    if (modes>0) bf6_armory_camera_modes(c,inventory.data(),modes);

    const int correction_count=bf6_armory_camera_weapon_corrections(c,nullptr,0);
    std::vector<bf6_armory_camera_weapon_correction> corrections(
        correction_count>0?(size_t)correction_count:0);
    if (correction_count>0)
        bf6_armory_camera_weapon_corrections(c,corrections.data(),correction_count);
    int correction_records=0, correction_nonzero=0, shuffled_equal=0;
    std::string fallback_weapons;
    for (int i=0;i<correction_count;++i) {
        correction_records += corrections[(size_t)i].has_record ? 1 : 0;
        if (!corrections[(size_t)i].has_record) {
            if (!fallback_weapons.empty()) fallback_weapons += ",";
            fallback_weapons += corrections[(size_t)i].weapon;
        }
        for (int s=0;s<BF6_ARMORY_CAMERA_CORRECTION_COUNT;++s)
            if (corrections[(size_t)i].correction[s][0]!=0.f ||
                corrections[(size_t)i].correction[s][1]!=0.f ||
                corrections[(size_t)i].correction[s][2]!=0.f) ++correction_nonzero;
        if (i+1<correction_count && std::memcmp(corrections[(size_t)i].correction,
            corrections[(size_t)i+1].correction,sizeof(corrections[(size_t)i].correction))==0)
            ++shuffled_equal;
    }
    bf6_armory_camera_weapon_correction m4{}, fake_correction{};
    const bool m4_correction=bf6_armory_camera_weapon_correction_read(c,"M4A1",&m4)!=0;
    const bool fake_correction_ok=bf6_armory_camera_weapon_correction_read(
        c,"__fabricated_weapon",&fake_correction)!=0;
    armory_camera::Vec3 m4_pre{},m4_post{};
    const bool m4_sight=m4_correction && armory_camera::correction_for_mode(
        m4,"weaponsightbehavior",m4_pre,m4_post);
    armory_camera::Vec3 unknown_pre{},unknown_post{};
    const bool unknown_mode=m4_correction && armory_camera::correction_for_mode(
        m4,"__fabricated_mode",unknown_pre,unknown_post);
    std::printf("corrections refs=%d records=%d nonzero_vec3=%d shuffled_adjacent_equal=%d fallbacks=%s m4=%d fake=%d\n",
        correction_count,correction_records,correction_nonzero,shuffled_equal,
        fallback_weapons.c_str(),m4_correction?1:0,fake_correction_ok?1:0);

    const int aslo_m18=bf6_armory_slot_anchors(c,"m18",nullptr,0);
    std::vector<bf6_armory_slot_anchor> m18anchors(aslo_m18>0?(size_t)aslo_m18:0);
    if (aslo_m18>0) bf6_armory_slot_anchors(c,"m18",m18anchors.data(),aslo_m18);
    int m18_nonzero=0;
    for (const auto& a:m18anchors) m18_nonzero+=a.has_position?1:0;
    const int aslo_fake=bf6_armory_slot_anchors(c,"__fabricated_weapon",nullptr,0);
    const int aslon=bf6_list_ebx(c,"aslo_",nullptr,0);
    std::vector<bf6_asset> asloassets(aslon>0?(size_t)aslon:0);
    if (aslon>0) bf6_list_ebx(c,"aslo_",asloassets.data(),aslon);
    std::set<std::string> asloweapons;
    for (const auto& a:asloassets) if (a.name) {
        std::string p=a.name;
        const size_t slash=p.find_last_of("/\\");
        const std::string leaf=slash==std::string::npos?p:p.substr(slash+1);
        if (leaf.compare(0,5,"aslo_")!=0) continue;
        const std::string token=leaf.substr(5);
        const std::string parent=slash==std::string::npos?"":p.substr(0,slash);
        const size_t ps=parent.find_last_of("/\\");
        const std::string parent_leaf=ps==std::string::npos?parent:parent.substr(ps+1);
        if (token==parent_leaf) asloweapons.insert(token);
    }
    int aslo_rows=0,aslo_nonzero=0,aslo_line_nonzero=0;
    for (const std::string& weapon:asloweapons) {
        const int count=bf6_armory_slot_anchors(c,weapon.c_str(),nullptr,0);
        std::vector<bf6_armory_slot_anchor> values(count>0?(size_t)count:0);
        if (count>0) bf6_armory_slot_anchors(c,weapon.c_str(),values.data(),count);
        if (count>0) aslo_rows+=count;
        for (const auto& a:values) {
            aslo_nonzero+=a.has_position?1:0;
            aslo_line_nonzero+=(a.line_offset[0]!=0.f||a.line_offset[1]!=0.f)?1:0;
        }
    }
    std::printf("aslo assets=%zu rows=%d nonzero_vec3=%d nonzero_vec2=%d m18_rows=%d m18_nonzero=%d fake_rows=%d\n",
        asloweapons.size(),aslo_rows,aslo_nonzero,aslo_line_nonzero,
        aslo_m18,m18_nonzero,aslo_fake);

    std::string md_m4a1;
    const int mdn=bf6_list_ebx(c,"md_m4a1",nullptr,0);
    std::vector<bf6_asset> mdrows(mdn>0?(size_t)mdn:0);
    if (mdn>0) bf6_list_ebx(c,"md_m4a1",mdrows.data(),mdn);
    for (const auto& a:mdrows) if (a.name) {
        std::string p=a.name, leaf=p.substr(p.find_last_of("/\\")+1);
        if (leaf=="md_m4a1") { md_m4a1=p; break; }
    }
    armory_camera::Transform align{},scope{},fake_bone{};
    const bool align_ok=!md_m4a1.empty() && armory_camera::read_weapon_bone(
        c,md_m4a1.c_str(),"Wep_Align",align);
    const bool scope_ok=!md_m4a1.empty() && armory_camera::read_weapon_bone(
        c,md_m4a1.c_str(),"Wep_Scope_ATT",scope);
    const bool fake_bone_ok=!md_m4a1.empty() && armory_camera::read_weapon_bone(
        c,md_m4a1.c_str(),"__fabricated_bone",fake_bone);
    std::printf("bones md=%s align=%d scope=%d fake=%d scope_pos=(%.6f %.6f %.6f)\n",
        md_m4a1.c_str(),align_ok?1:0,scope_ok?1:0,fake_bone_ok?1:0,
        scope.position.x,scope.position.y,scope.position.z);
    int compose_ok=0;
    for (const bf6_armory_camera_mode& mode:inventory) {
        armory_camera::Input in{}; in.mode=mode;
        in.sensor_width_mm=sensor.width_mm; in.sensor_height_mm=sensor.height_mm;
        in.viewport_width=1920.f; in.viewport_height=1080.f;
        armory_camera::Output out{};
        if (armory_camera::compose(in,out)) ++compose_ok;
    }

    bf6_armory_camera_mode overview{}, fake{};
    const bool real=bf6_armory_camera_mode_read(c,"weaponbehavior",&overview)!=0;
    const bool fabricated=bf6_armory_camera_mode_read(c,"__fabricated_camera",&fake)!=0;
    armory_camera::Input input{}; input.mode=overview;
    input.sensor_width_mm=sensor.width_mm; input.sensor_height_mm=sensor.height_mm;
    input.viewport_width=1920.f; input.viewport_height=1080.f;
    armory_camera::Output dolly{}, target{};
    input.post_law=armory_camera::PostOffsetLaw::CameraDolly;
    const bool dolly_ok=armory_camera::compose(input,dolly);
    input.post_law=armory_camera::PostOffsetLaw::LookAtTarget;
    const bool target_ok=armory_camera::compose(input,target);
    const float law_delta=std::fabs(dolly.eye.x-target.eye.x)+std::fabs(dolly.eye.y-target.eye.y)+
                          std::fabs(dolly.eye.z-target.eye.z)+std::fabs(dolly.forward.x-target.forward.x)+
                          std::fabs(dolly.forward.y-target.forward.y)+std::fabs(dolly.forward.z-target.forward.z);
    armory_camera::Input null_post=input;
    null_post.mode.post_offset[0]=null_post.mode.post_offset[1]=null_post.mode.post_offset[2]=0.f;
    null_post.weapon_post_offset={};
    armory_camera::Output null_dolly{},null_target{};
    null_post.post_law=armory_camera::PostOffsetLaw::CameraDolly;
    const bool null_dolly_ok=armory_camera::compose(null_post,null_dolly);
    null_post.post_law=armory_camera::PostOffsetLaw::LookAtTarget;
    const bool null_target_ok=armory_camera::compose(null_post,null_target);
    const float null_law_delta=std::fabs(null_dolly.eye.x-null_target.eye.x)+
        std::fabs(null_dolly.eye.y-null_target.eye.y)+std::fabs(null_dolly.eye.z-null_target.eye.z)+
        std::fabs(null_dolly.forward.x-null_target.forward.x)+
        std::fabs(null_dolly.forward.y-null_target.forward.y)+
        std::fabs(null_dolly.forward.z-null_target.forward.z);
    armory_camera::Input invalid=input; invalid.mode.focal_length_mm=0.f;
    armory_camera::Output rejected{};
    const bool invalid_ok=armory_camera::compose(invalid,rejected);
    const float pi=3.14159265358979323846f;
    std::printf("modes live=%d composed=%d real=%d fake=%d\n",modes,compose_ok,real?1:0,fabricated?1:0);
    std::printf("overview hfov=%.6f vfov=%.6f autofocus=%.6f laws_delta=%.9f null_delta=%.9f invalid=%d\n",
        dolly.horizontal_fov_radians*180.f/pi,dolly.vertical_fov_radians*180.f/pi,
        dolly.autofocus_distance,law_delta,null_law_delta,invalid_ok?1:0);

    const bool pass=sensor_ok && sensor.candidates>=1 && real && !fabricated &&
        modes==17 && compose_ok==modes && dolly_ok && target_ok && law_delta>0.01f &&
        null_dolly_ok && null_target_ok && null_law_delta<1e-6f && !invalid_ok &&
        correction_count>0 && correction_records==correction_count-2 &&
        correction_nonzero>0 && shuffled_equal<correction_count/4 && m4_correction &&
        !fake_correction_ok && m4_sight && !unknown_mode && aslo_m18>0 &&
        m18_nonzero>0 && aslo_fake==0 && asloweapons.size()==13 && aslo_rows==123 &&
        aslo_nonzero==25 && aslo_line_nonzero==0 && align_ok && scope_ok && !fake_bone_ok;
    bf6_close(c);
    std::printf("%s\n",pass?"PASS":"FAIL");
    return pass?0:1;
}
