#include "armory_camera_composition.h"

#include <cmath>
#include <cstdio>

int main()
{
    /* Shipped weaponbehavior row and sensor gate are an oracle here, never a
     * runtime input to the viewer.  The live companion test independently
     * reads both values from the installed game. */
    armory_camera::Input in{};
    in.mode.focal_length_mm=35.f;
    in.mode.pre_offset[0]=-1.308591f;
    in.mode.pre_offset[1]= 0.104254f;
    in.mode.pre_offset[2]=-0.600497f;
    in.mode.pre_rotation_degrees[0]=0.6005f;
    in.mode.post_offset[0]=-0.208340f;
    in.mode.post_offset[1]=-0.104851f;
    in.sensor_width_mm=36.f; in.sensor_height_mm=20.25f;
    in.viewport_width=1920.f; in.viewport_height=1080.f;

    armory_camera::Output vertical{}, horizontal{}, target{};
    in.sensor_fit=armory_camera::SensorFit::Vertical;
    const bool v=armory_camera::compose(in,vertical);
    in.sensor_fit=armory_camera::SensorFit::Horizontal;
    const bool h=armory_camera::compose(in,horizontal);
    in.post_law=armory_camera::PostOffsetLaw::LookAtTarget;
    const bool t=armory_camera::compose(in,target);

    const float fov_delta=std::fabs(vertical.horizontal_fov_radians-horizontal.horizontal_fov_radians)+
                          std::fabs(vertical.vertical_fov_radians-horizontal.vertical_fov_radians);
    const float law_delta=std::fabs(vertical.eye.x-target.eye.x)+std::fabs(vertical.eye.y-target.eye.y)+
                          std::fabs(vertical.eye.z-target.eye.z)+
                          std::fabs(vertical.forward.x-target.forward.x)+
                          std::fabs(vertical.forward.y-target.forward.y)+
                          std::fabs(vertical.forward.z-target.forward.z);
    armory_camera::Vec3 center{};
    const bool p=armory_camera::project(vertical,vertical.focus_target,0,0,1920,1080,center);

    armory_camera::Input fake=in; fake.mode.focal_length_mm=0.f;
    armory_camera::Output rejected{};
    const bool fake_ok=armory_camera::compose(fake,rejected);
    const bool pass=v&&h&&t&&p&&!fake_ok&&fov_delta<1e-6f&&law_delta>0.01f&&
                    std::isfinite(center.x)&&std::isfinite(center.y);
    std::printf("native-aspect fit delta=%.9g post-law delta=%.9g focus projection=(%.3f,%.3f) fake=%d\n",
                fov_delta,law_delta,center.x,center.y,fake_ok?1:0);
    std::printf("%s\n",pass?"PASS":"FAIL");
    return pass?0:1;
}
