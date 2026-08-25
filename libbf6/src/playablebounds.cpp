/* GENERATED - see playablebounds.h. Do not hand-edit. */
#include "playablebounds.h"

#include <cctype>

namespace bf6 {
namespace {

struct Box { const char* level; float cx, cz, sx, sz; };

const Box kBoxes[] = {
    { "mp_abbasid", -84.7048f, 122.9507f, 1085.4724f, 1085.4724f },
    { "mp_aftermath", -577.0000f, -30.0000f, 876.0000f, 876.0000f },
    { "mp_badlands", 0.0000f, -100.0000f, 1400.0000f, 1400.0000f },
    { "mp_battery", 696.9600f, 88.3200f, 1400.0000f, 1400.0000f },
    { "mp_capstone", 69.0000f, -100.0000f, 1538.0000f, 1538.0000f },
    { "mp_contaminated", 0.0000f, -100.0000f, 1400.0000f, 1400.0000f },
    { "mp_dumbo", 0.0000f, -155.0000f, 1400.0000f, 1400.0000f },
    { "mp_eastwood", 0.0000f, -188.0000f, 1400.0000f, 1400.0000f },
    { "mp_firestorm", 0.0000f, 21.0000f, 1642.0000f, 1642.0000f },
    { "mp_golmudrailway", -125.0000f, 850.0000f, 2100.0000f, 2100.0000f },
    { "mp_granite_clubhouse_portal", -450.0000f, -575.0000f, 1000.0000f, 1000.0000f },
    { "mp_granite_mainstreet_portal", -1106.6234f, 152.6258f, 1000.0000f, 1000.0000f },
    { "mp_granite_marina_portal", -1201.9591f, -604.8143f, 1000.0000f, 1000.0000f },
    { "mp_granite_militaryrnd_portal", 469.2352f, -685.0893f, 1000.0000f, 1000.0000f },
    { "mp_granite_militarystorage_portal", 561.6601f, 388.4477f, 1000.0000f, 1000.0000f },
    { "mp_granite_techcampus_portal", -209.7229f, 320.6738f, 1000.0000f, 1000.0000f },
    { "mp_granite_underground_portal", 785.0909f, -404.1485f, 1000.0000f, 1000.0000f },
    { "mp_isolated", -417.0430f, -4.6954f, 2554.6530f, 2554.6530f },
    { "mp_limestone", 696.9600f, 88.3200f, 1400.0000f, 1400.0000f },
    { "mp_outskirts", -382.0000f, -90.0000f, 1740.0000f, 1740.0000f },
    { "mp_plaza", 14.0000f, 100.0000f, 1000.0000f, 1000.0000f },
    { "mp_portal_sand", 0.0000f, 0.0000f, 1000.0000f, 1000.0000f },
    { "mp_subsurface", 0.0000f, -100.0000f, 1400.0000f, 1400.0000f },
    { "mp_tungsten", 60.0000f, -25.0000f, 1550.0000f, 1550.0000f },
};

}  // namespace

bool playable_box(const std::string& level,
                  float& cx, float& cz, float& sx, float& sz)
{
    std::string lv = level;
    for (char& c : lv) c = (char)std::tolower((unsigned char)c);
    for (const Box& b : kBoxes)
    {
        if (lv != b.level) continue;
        cx = b.cx; cz = b.cz; sx = b.sx; sz = b.sz;
        return true;
    }
    return false;
}

}  // namespace bf6
