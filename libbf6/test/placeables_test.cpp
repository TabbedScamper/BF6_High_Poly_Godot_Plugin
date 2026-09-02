// placeables_test - proves the SDK placeable catalogue loads and the per-level
// filter matches the counts computed straight from the JSON:
//   items 11142, universal 1516, levels 25,
//   MP_Dumbo -> 3015 (1499 restricted + 1516 universal),
//   MP_Abbasid -> 2862, MP_Capstone -> 2126.
//
// Uses PlaceableDB directly (no game install needed). Pass the Portal SDK's
// FbExportData directory as argv[1]. This is a verification oracle, never a
// runtime input to the viewer or engine bindings.

#include "placeables.h"
#include <cstdio>
#include <string>

static int count_for(const bf6::PlaceableDB& db, const std::string& level) {
    int n = 0;
    for (const auto& p : db.items())
        if (bf6::PlaceableDB::allowed_on(p, level)) n++;
    return n;
}

int main(int argc, char** argv) {
    if (argc != 2) {
        std::printf("usage: placeables_test <PortalSDK/FbExportData>\n");
        return 2;
    }
    std::string dir = argv[1];

    bf6::PlaceableDB db;
    std::string err;
    if (!db.load(dir, err)) { std::printf("load FAILED: %s\n", err.c_str()); return 1; }

    int total = (int)db.items().size();
    int universal = 0;
    for (const auto& p : db.items()) if (p.universal) universal++;

    std::printf("levels    : %d\n", (int)db.levels().size());
    std::printf("placeables: %d\n", total);
    std::printf("universal : %d\n", universal);
    std::printf("MP_Dumbo    : %d (expect 3015)\n", count_for(db, "MP_Dumbo"));
    std::printf("MP_Abbasid  : %d (expect 2862)\n", count_for(db, "MP_Abbasid"));
    std::printf("MP_Capstone : %d (expect 2126)\n", count_for(db, "MP_Capstone"));
    std::printf("(all)       : %d (expect 11142)\n", count_for(db, ""));

    // Spot-check a couple of entries carry a mesh + directory.
    int with_mesh = 0;
    for (const auto& p : db.items()) if (!p.mesh.empty()) with_mesh++;
    std::printf("with mesh   : %d (expect 11139)\n", with_mesh);

    // Properties: gameplay objects should carry their editable fields.
    for (const char* want : {"CombatArea", "CapturePoint"}) {
        for (const auto& p : db.items()) {
            if (p.type != want) continue;
            std::printf("\n[%s] %d properties:\n", want, (int)p.props.size());
            for (const auto& pr : p.props)
                std::printf("   - %-28s : %-14s (def: %s)\n", pr.name.c_str(), pr.type.c_str(), pr.def.c_str());
            break;
        }
    }

    bool ok = (total == 11142) && (universal == 1516) &&
              ((int)db.levels().size() == 25) &&
              (count_for(db, "MP_Dumbo") == 3015) &&
              (count_for(db, "MP_Abbasid") == 2862) &&
              (count_for(db, "MP_Capstone") == 2126);
    std::printf("\n%s\n", ok ? "PASS - counts match the JSON" : "MISMATCH");
    return ok ? 0 : 2;
}
