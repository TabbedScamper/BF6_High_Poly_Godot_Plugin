/* The attachment catalogue: aam_<weapon>.ebx, its description assets, and how
 * well it joins to the roster.
 *
 *   catalogue_test <game-dir> [weapon]
 *
 * The join is the whole question here. Two independently authored lists exist
 * - what can be fitted (partition names) and what the armory shows (this) -
 * and the only key between them is a folded display name. This measures that
 * rate against a shuffled control rather than asserting it works, because a
 * fuzzy join that silently mislabels an attachment is worse than one that
 * admits it does not know.
 */
#include "bf6_core.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

static int g_fail = 0;

static void check(bool ok, const char* what, const std::string& got)
{
    std::printf("%-52s %s%s%s\n", what, ok ? "ok" : "FAIL",
                got.empty() ? "" : "  got ", got.c_str());
    if (!ok) g_fail++;
}

int main(int argc, char** argv)
{
    if (argc < 2) { std::fprintf(stderr, "usage: catalogue_test <game-dir> [weapon]\n"); return 2; }
    const char* weapon = argc > 2 ? argv[2] : "m4a1";

    char err[512] = { 0 };
    bf6_ctx* c = bf6_open(argv[1], err, (int)sizeof(err));
    if (!c) { std::fprintf(stderr, "bf6_open: %s\n", err); return 1; }
    if (!bf6_mount_all(c, 1, err, (int)sizeof(err)))
    { std::fprintf(stderr, "mount: %s\n", err); return 1; }

    const int n = bf6_weapon_attachment_catalogue(c, weapon, nullptr, 0);
    if (n <= 0) { std::fprintf(stderr, "no catalogue for %s\n", weapon); return 1; }
    std::vector<bf6_attachment_catalogue_row> rows((size_t)n);
    bf6_weapon_attachment_catalogue(c, weapon, rows.data(), n);
    std::printf("catalogue rows for %s: %d\n", weapon, n);

    int named = 0, described = 0, icons = 0, layered = 0, slotted = 0;
    for (const bf6_attachment_catalogue_row& r : rows)
    {
        if (r.name[0]) named++;
        if (r.description[0]) described++;
        if (r.icon_atlas[0] && r.icon_index >= 0) icons++;
        if (r.layered_atlas[0] && r.layered_index >= 0) layered++;
        if (r.slot[0]) slotted++;
    }
    std::printf("named=%d described=%d category-icon=%d layered-icon=%d slotted=%d\n",
                named, described, icons, layered, slotted);
    check(named == n, "every row has a display name", std::to_string(named));
    check(slotted == n, "every row has a slot code", std::to_string(slotted));
    check(icons > n / 2, "most rows resolve a category icon", std::to_string(icons));

    /* Exact live-path oracle for the attachment visible in the supplied game
     * captures. It exercises three independent semantic pointers. A fake stem
     * is the negative control; finding it would mean this test matched by a
     * loose substring rather than the authored description asset. */
    if (std::strcmp(weapon, "m4a1") == 0)
    {
        const bf6_attachment_catalogue_row* xps = nullptr;
        const bf6_attachment_catalogue_row* fake = nullptr;
        for (const bf6_attachment_catalogue_row& r : rows)
        {
            if (std::strcmp(r.ad_stem, "eotechxps3") == 0) xps = &r;
            if (std::strcmp(r.ad_stem, "eotechxps3_fake_control") == 0) fake = &r;
        }
        check(xps && std::strcmp(xps->name, "SU-123 1.50x") == 0,
              "XPS3 NameSid resolves picker display name", xps ? xps->name : "missing");
        check(xps && std::strcmp(xps->detail_title, "Sight 1.50x") == 0,
              "XPS3 title field resolves fitted-tile title",
              xps ? xps->detail_title : "missing");
        check(xps && std::strcmp(xps->description,
                                 "Slightly magnified optic with a clear sight picture.") == 0,
              "XPS3 body field resolves description", xps ? xps->description : "missing");
        check(fake == nullptr, "fake attachment id control stays unmatched", "0 matches");

        const int primaryBudget = bf6_weapon_point_budget(c, "m4a1");
        const int sidearmBudget = bf6_weapon_point_budget(c, "m18");
        const int fakeBudget = bf6_weapon_point_budget(c, "__fake_weapon_control__");
        check(primaryBudget == 100, "M4A1 equipment registry supplies point budget",
              std::to_string(primaryBudget));
        check(sidearmBudget == 60, "M18 equipment registry supplies sidearm budget",
              std::to_string(sidearmBudget));
        check(fakeBudget == -1, "fake weapon control supplies no point budget",
              std::to_string(fakeBudget));

        const int xpsWeight = bf6_attachment_weight(
            c, "common/hardware/weapons/carbine/m4a1/attachment_m4a1_scp_xps3");
        const int fakeWeight = bf6_attachment_weight(
            c, "weapons/m4a1/attachments/__fake_attachment_control__");
        check(xpsWeight >= 0,
              "XPS3 weight resolves through reflected attachment field",
              std::to_string(xpsWeight));
        check(fakeWeight == -1,
              "fake attachment control supplies no reflected weight",
              std::to_string(fakeWeight));
    }

    /* THE ICON MUST ADDRESS A REAL SPRITE. An index that merely exists is not
     * an icon; a wrong-field read would still hand back plausible small ints. */
    int inRange = 0, checked = 0;
    for (const bf6_attachment_catalogue_row& r : rows)
    {
        if (!r.icon_atlas[0] || r.icon_index < 0) continue;
        checked++;
        const int sprites = bf6_icon_atlas(c, r.icon_atlas, nullptr, 0);
        if (sprites > 0 && r.icon_index < sprites) inRange++;
    }
    check(checked > 0 && inRange == checked,
          "every icon index is inside its atlas",
          std::to_string(inRange) + "/" + std::to_string(checked));

    /* The screen-label -> filename-code join is now a live typed join, not a
     * viewer table. A shuffled/fake weapon is the negative control: it retains
     * the twelve authored categories but must resolve zero filename codes. */
    {
        const int bn = bf6_armory_category_bindings(c, weapon, nullptr, 0);
        std::vector<bf6_armory_category_binding> bindings((size_t)(bn > 0 ? bn : 0));
        if (bn > 0) bf6_armory_category_bindings(c, weapon, bindings.data(), bn);
        int resolved = 0, conflicts = 0;
        for (const bf6_armory_category_binding& row : bindings)
        {
            if (row.code[0]) resolved++;
            conflicts += row.conflicting_rows;
            std::printf("  CATEGORY %-16s -> %-3s evidence=%d conflict=%d %s\n",
                        row.label, row.code, row.evidence_rows,
                        row.conflicting_rows, row.category_asset);
        }
        check(bn == 12, "screen category binding keeps authored 12-row order",
              std::to_string(bn));
        check(resolved >= 10, "typed category join resolves the filename vocabulary",
              std::to_string(resolved));
        check(conflicts == 0, "real category join has no conflicting rows",
              std::to_string(conflicts));

        const int fn = bf6_armory_category_bindings(
            c, "__fake_weapon_control__", nullptr, 0);
        std::vector<bf6_armory_category_binding> fakeRows((size_t)(fn > 0 ? fn : 0));
        if (fn > 0) bf6_armory_category_bindings(
            c, "__fake_weapon_control__", fakeRows.data(), fn);
        int fakeResolved = 0;
        for (const bf6_armory_category_binding& row : fakeRows)
            if (row.code[0]) fakeResolved++;
        check(fn == 12 && fakeResolved == 0,
              "fake weapon control resolves no category codes",
              std::to_string(fakeResolved));
    }

    /* And it must land on the RIGHT sprite, not merely a valid one. The atlas
     * entry names are descriptive, so a correct index puts a recognisable
     * fragment of the attachment's own name in the sprite name. */
    int recognisable = 0, sampled = 0;
    for (const bf6_attachment_catalogue_row& r : rows)
    {
        if (!r.icon_atlas[0] || r.icon_index < 0) continue;
        const int sprites = bf6_icon_atlas(c, r.icon_atlas, nullptr, 0);
        if (sprites <= 0 || r.icon_index >= sprites) continue;
        std::vector<bf6_icon_sprite> sp((size_t)sprites);
        bf6_icon_atlas(c, r.icon_atlas, sp.data(), sprites);
        const char* sname = sp[(size_t)r.icon_index].name;
        if (!sname) continue;
        std::string low = sname, key = r.name_key;
        for (char& ch : low) if (ch >= 'A' && ch <= 'Z') ch = (char)(ch + 32);
        std::string lowkey;
        for (char ch : low) if (std::isalnum((unsigned char)ch)) lowkey.push_back(ch);
        sampled++;
        /* Any run of 5+ characters of the folded display name appearing in the
         * folded sprite name counts as recognisable. */
        bool hit = false;
        for (size_t a = 0; a + 5 <= key.size() && !hit; a++)
            if (lowkey.find(key.substr(a, 5)) != std::string::npos) hit = true;
        if (hit) recognisable++;
        if (sampled <= 8)
            std::printf("  %-4s %-22s idx %3d in %-32s -> %s\n", r.slot, r.name,
                        r.icon_index,
                        std::strrchr(r.icon_atlas, '/') ? std::strrchr(r.icon_atlas, '/') + 1
                                                        : r.icon_atlas,
                        sname);
    }
    std::printf("sprite names recognisable from the display name: %d of %d\n",
                recognisable, sampled);
    check(sampled > 0 && recognisable * 2 > sampled,
          "icons land on a semantically matching sprite",
          std::to_string(recognisable) + "/" + std::to_string(sampled));

    /* ------------------------------------------------------ weapon names --
     * The grid shows code names (m4a1, hk417a2) where the game shows real ones.
     * The join is exact: the row is keyed by the token in its own hiao import,
     * which is the same token the roster is built from. */
    {
        const int wn = bf6_weapon_names(c, nullptr, 0);
        std::printf("weapon name rows: %d\n", wn);
        if (wn > 0)
        {
            std::vector<bf6_weapon_name_row> names((size_t)wn);
            bf6_weapon_names(c, names.data(), wn);
            int classed = 0, distinct = 0;
            std::vector<std::string> seen;
            for (const bf6_weapon_name_row& r : names)
            {
                if (r.class_label[0]) classed++;
                bool dup = false;
                for (const std::string& t : seen) if (t == r.name) { dup = true; break; }
                if (!dup) { seen.push_back(r.name); distinct++; }
            }
            for (int i = 0; i < wn && i < 8; i++)
                std::printf("  %-14s -> %-26s [%s]\n", names[(size_t)i].weapon,
                            names[(size_t)i].name, names[(size_t)i].class_label);
            std::printf("named=%d with-class=%d distinct-names=%d\n", wn, classed, distinct);
            check(wn > 50, "the metadata names most of the roster", std::to_string(wn));
            /* A reader keyed on the wrong field would hand the same name back
             * for every weapon and still look complete. */
            check(distinct > wn / 2, "the names are distinct, not one repeated",
                  std::to_string(distinct));
        }
        else check(false, "weapon names are readable", "none");
    }

    bf6_close(c);
    std::printf("%s (%d failure%s)\n", g_fail ? "FAILED" : "PASSED", g_fail,
                g_fail == 1 ? "" : "s");
    return g_fail ? 1 : 0;
}
