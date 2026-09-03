/* exedb_test - which installed executable carries a READABLE type database.
 * The distinction is not cosmetic: an encrypted typeinfo section does not fail
 * to open, it opens and resolves nothing, which looks like an empty game. */
#include "types.h"
#include <cstdio>
#include <string>
#include <vector>
#include <cstdlib>
#include <cstring>
using namespace bf6;
int main(int argc, char** argv)
{
    if (argc < 2) { std::printf("usage: exedb_test <game>\n"); return 2; }
    std::vector<std::string> cand;
    { const std::string a(argv[1]);
      if (a.size()>4 && a.substr(a.size()-4)==".exe") cand.push_back(a);
      else cand = TypeDb::exe_candidates(a); }
    for (const std::string& e : cand) {
        TypeDb db; std::string err;
        const bool ok = db.open(e, err);
        double bits = 0, zero = 0;
        if (ok) db.entropy(bits, zero);
        std::printf("%-70s open=%d typeinfo=%d size=%llu entropy=%.2f bits/byte zero=%.1f%% %s\n",
                    e.c_str(), (int)ok, (int)db.typeinfo_found(),
                    (unsigned long long)db.typeinfo_size(), bits, zero * 100.0,
                    ok && db.looks_encrypted() ? "<== ENCRYPTED" : (db.lifted() ? "<== LIFTED" : ""));
        if (!ok) std::printf("    err: %s\n", err.c_str());
    }

    /* DECISIVE: does a KNOWN type resolve to fields? An encrypted typeinfo
     * opens fine and resolves nothing, which is indistinguishable from an
     * empty game unless you ask it for a type you know ships. */
    static const char* kKnown[] = {
        "08b96045-a9e6-03a6-0368-f9edc629cc87",  /* BTSequenceNode */
        "687e80c3-04b7-c975-ba09-b82293d46674",  /* BasicAffectorAsset */
        "cc1986ac-ccec-1262-ea8a-ca0345d9ba82",  /* ActionMessageAsset */
    };
    for (const std::string& e : cand) {
        TypeDb db; std::string err;
        if (!db.open(e, err)) continue;
        std::printf("%s\n", e.c_str());
        for (const char* g : kKnown) {
            /* TEXTUAL form -> STORED bytes. The first three groups are
             * BYTE-REVERSED, the rest are as written; guid_str is the exact
             * inverse. Parsing the digits straight through looks reasonable
             * and silently looks up a guid that does not exist, reporting as
             * "0 fields" - i.e. as an encrypted database rather than as the
             * caller's own bug. Both spellings are tried so the difference is
             * visible instead of assumed. */
            uint8_t raw[16] = {0}; int n = 0;
            for (const char* q = g; *q && n < 16; ) {
                if (*q == '-') { q++; continue; }
                char hx[3] = { q[0], q[1], 0 };
                raw[n++] = (uint8_t)strtoul(hx, nullptr, 16); q += 2;
            }
            TypeGuid asis{}, swapped{};
            for (int k = 0; k < 16; k++) asis[k] = raw[k];
            swapped[0]=raw[3]; swapped[1]=raw[2]; swapped[2]=raw[1]; swapped[3]=raw[0];
            swapped[4]=raw[5]; swapped[5]=raw[4];
            swapped[6]=raw[7]; swapped[7]=raw[6];
            for (int k = 8; k < 16; k++) swapped[k] = raw[k];
            std::printf("    %s -> as-written %zu fields | byte-swapped %zu fields\n",
                        g, db.layout_full(asis).fields.size(),
                        db.layout_full(swapped).fields.size());
        }
    }
    return 0;
}
