#include "armory_ui.h"
#include "armory.h"

#include "imgui.h"

#include <algorithm>
#include <cstdio>
#include <cstring>

namespace armory_ui {
namespace {

// The front end's own palette, measured out of its UI assets. Surfaces, text,
// and the six-step rarity ramp whose third step is the selection accent.
constexpr ImU32 kBg      = IM_COL32(0x1E, 0x26, 0x2C, 245);
constexpr ImU32 kTile    = IM_COL32(0x22, 0x31, 0x3C, 235);
constexpr ImU32 kTileHov = IM_COL32(0x2C, 0x3E, 0x4B, 245);
constexpr ImU32 kText    = IM_COL32(0xBF, 0xCA, 0xD1, 255);
constexpr ImU32 kTextDim = IM_COL32(0xBF, 0xCA, 0xD1, 150);
constexpr ImU32 kLine    = IM_COL32(0xBF, 0xCA, 0xD1, 46);
constexpr ImU32 kAccent  = IM_COL32(0x59, 0xBF, 0xF8, 255);
constexpr ImU32 kEquip   = IM_COL32(0x8E, 0xED, 0x6C, 255);
constexpr ImU32 kLocked  = IM_COL32(0xFB, 0x69, 0x4D, 255);

struct Ctx {
    ImDrawList* dl = nullptr;
    ImVec2      mouse{};
    bool        clicked = false;
};

bool hit(const Ctx& c, float x, float y, float w, float h)
{
    return c.mouse.x >= x && c.mouse.x <= x + w &&
           c.mouse.y >= y && c.mouse.y <= y + h;
}

void text(const Ctx& c, ImFont* f, float px, float x, float y,
          ImU32 col, const char* s)
{
    if (f) c.dl->AddText(f, px, ImVec2(x, y), col, s);
    else   c.dl->AddText(ImVec2(x, y), col, s);
}

float text_w(ImFont* f, float px, const char* s)
{
    if (!f) return (float)strlen(s) * px * 0.5f;
    return f->CalcTextSizeA(px, FLT_MAX, 0.f, s).x;
}

// Uppercase, because the front end's button and tab labels are uppercase
// styles (fe_buttonlabel_*_uppercase) rather than uppercased strings.
std::string upper(std::string s)
{
    for (char& ch : s) ch = (char)(ch >= 'a' && ch <= 'z' ? ch - 32 : ch);
    return s;
}

// The class folder names the game files weapons under, mapped to the label the
// armory tabs show. Only the mapping is ours; the classes themselves come from
// the roster we read out of the mount.
const char* class_label(const std::string& cls)
{
    if (cls == "assaultrifle") return "ASSAULT RIFLE";
    if (cls == "carbine")      return "CARBINE";
    if (cls == "smg")          return "SMG";
    if (cls == "mg")           return "LMG";
    if (cls == "dmr")          return "DMR";
    if (cls == "boltaction")   return "SNIPER RIFLE";
    if (cls == "shotgun")      return "SHOTGUN";
    if (cls == "secondary")    return "SIDEARM";
    if (cls == "melee")        return "MELEE";
    if (cls == "battlepickup") return "BATTLE PICKUP";
    return cls.c_str();
}

const bf6::ArmoryWeapon* find(const bf6::Armory& a, const std::string& key)
{
    for (const bf6::ArmoryWeapon& w : a.weapons)
        if (w.cls + "/" + w.name == key) return &w;
    return nullptr;
}

int cost_of(const bf6::ArmoryWeapon& w, const std::string& slot,
            const std::string& att)
{
    for (const bf6::ArmoryAttachment& at : w.attachments)
        if (at.slot == slot && at.name == att) return at.cost;
    return -1;
}

}  // namespace

int spent(const bf6::Armory& a, const State& s)
{
    const bf6::ArmoryWeapon* w = find(a, s.weapon);
    if (!w) return 0;
    int total = 0;
    for (const auto& kv : s.fitted.by_slot)
    {
        if (kv.second.empty()) continue;
        const int c = cost_of(*w, kv.first, kv.second);
        if (c > 0) total += c;
    }
    return total;
}

bool draw(const bf6::Armory& a, State& s, const Fonts& f,
          float x, float y, float w, float h,
          DrawIconFn icon, void* icon_user)
{
    Ctx c;
    c.dl = ImGui::GetBackgroundDrawList();
    c.mouse = ImGui::GetIO().MousePos;
    c.clicked = ImGui::IsMouseClicked(ImGuiMouseButton_Left) &&
                !ImGui::GetIO().WantCaptureMouse;
    bool changed = false;
    s.weapon_changed = s.slot_changed = false;

    // ---- title bar ---------------------------------------------------------
    const float pad = 24.f;
    char title[160];
    if (s.page == Page::Weapons)
        snprintf(title, sizeof(title), "SELECT PRIMARY WEAPON");
    else if (s.page == Page::Customize)
        snprintf(title, sizeof(title), "CUSTOMIZE %s",
                 upper(s.weapon.substr(s.weapon.find('/') + 1)).c_str());
    else
        snprintf(title, sizeof(title), "SELECT %s", upper(s.slot).c_str());

    c.dl->AddRectFilled(ImVec2(x, y), ImVec2(x + w, y + 56.f), kBg);
    text(c, f.header, 24.f, x + pad, y + 16.f, kText, title);
    c.dl->AddLine(ImVec2(x, y + 56.f), ImVec2(x + w, y + 56.f), kLine);

    // A back step that mirrors the game's: picker -> customize -> weapons.
    if (s.page != Page::Weapons)
    {
        const float bx = x + w - 110.f, by = y + 14.f;
        const bool over = hit(c, bx, by, 92.f, 28.f);
        c.dl->AddRectFilled(ImVec2(bx, by), ImVec2(bx + 92.f, by + 28.f),
                            over ? kTileHov : kTile);
        c.dl->AddRect(ImVec2(bx, by), ImVec2(bx + 92.f, by + 28.f), kLine);
        text(c, f.label, 14.f, bx + 14.f, by + 7.f, kText, "< BACK");
        if (over && c.clicked)
        {
            s.page = (s.page == Page::SlotPicker) ? Page::Customize : Page::Weapons;
            changed = true;
        }
    }

    float cy = y + 56.f;

    // ---- category tabs -----------------------------------------------------
    if (s.page == Page::Weapons)
    {
        std::vector<std::string> classes;
        for (const bf6::ArmoryWeapon& wep : a.weapons)
            if (std::find(classes.begin(), classes.end(), wep.cls) == classes.end())
                classes.push_back(wep.cls);
        if (s.category.empty() && !classes.empty()) s.category = classes[0];

        float tx = x + pad;
        const float th = 34.f;
        for (const std::string& cls : classes)
        {
            const char* lab = class_label(cls);
            const float tw = text_w(f.label, 14.f, lab) + 28.f;
            const bool on = (cls == s.category);
            const bool over = hit(c, tx, cy + 10.f, tw, th);
            c.dl->AddRectFilled(ImVec2(tx, cy + 10.f), ImVec2(tx + tw, cy + 10.f + th),
                                on ? IM_COL32(0xBF, 0xCA, 0xD1, 235) : (over ? kTileHov : kTile));
            text(c, f.label, 14.f, tx + 14.f, cy + 19.f,
                 on ? IM_COL32(0x1E, 0x26, 0x2C, 255) : kText, lab);
            if (over && c.clicked) { s.category = cls; changed = true; }
            tx += tw + 6.f;
        }
        cy += 10.f + th + 18.f;

        // ---- weapon grid ---------------------------------------------------
        const float tileW = 232.f, tileH = 104.f, gap = 10.f;
        const int cols = (int)std::max(1.f, (w - pad * 2.f + gap) / (tileW + gap));
        int i = 0;
        for (const bf6::ArmoryWeapon& wep : a.weapons)
        {
            if (wep.cls != s.category) continue;
            const float tx2 = x + pad + (i % cols) * (tileW + gap);
            const float ty2 = cy + (i / cols) * (tileH + gap);
            i++;
            if (ty2 + tileH > y + h) break;

            const std::string key = wep.cls + "/" + wep.name;
            const bool on = (key == s.weapon);
            const bool over = hit(c, tx2, ty2, tileW, tileH);
            c.dl->AddRectFilled(ImVec2(tx2, ty2), ImVec2(tx2 + tileW, ty2 + tileH),
                                over ? kTileHov : kTile);
            c.dl->AddRect(ImVec2(tx2, ty2), ImVec2(tx2 + tileW, ty2 + tileH),
                          on ? kAccent : kLine, 0.f, 0, on ? 2.f : 1.f);

            // Progress pips along the top, the way the game shows mastery.
            for (int p = 0; p < 10; p++)
                c.dl->AddRectFilled(ImVec2(tx2 + 8.f + p * 9.f, ty2 + 8.f),
                                    ImVec2(tx2 + 14.f + p * 9.f, ty2 + 12.f),
                                    p < 3 ? kTextDim : kLine);

            // The line-art silhouette, drawn from the game's own atlas above
            // the name - the same sprite the armory shows on its tiles.
            if (icon) icon(wep.name.c_str(), wep.cls.c_str(), tx2 + 8.f, ty2 + 16.f,
                           tileW - 16.f, tileH - 60.f, icon_user);

            text(c, f.label, 15.f, tx2 + 8.f, ty2 + tileH - 40.f, kText,
                 upper(wep.name).c_str());
            text(c, f.body, 12.f, tx2 + 8.f, ty2 + tileH - 22.f, kTextDim, "FACTORY");

            char n[48];
            snprintf(n, sizeof(n), "%d", (int)wep.attachments.size());
            text(c, f.mono, 12.f, tx2 + tileW - 8.f - text_w(f.mono, 12.f, n),
                 ty2 + tileH - 22.f, kTextDim, n);

            if (over && c.clicked)
            {
                s.weapon = key;
                s.fitted.by_slot.clear();
                s.page = Page::Customize;
                s.weapon_changed = changed = true;
            }
        }
        return changed;
    }

    // ---- customize ---------------------------------------------------------
    const bf6::ArmoryWeapon* wep = find(a, s.weapon);
    if (!wep) return changed;

    // ATTACHMENT POINTS spent/total, with the pip strip the game draws beside
    // it. The budget is read from the weapon's own record; -1 means not read.
    {
        const int sp = spent(a, s);
        const int bud = s.budget > 0 ? s.budget : 100;
        char pts[64];
        snprintf(pts, sizeof(pts), "%d/%d", sp, bud);
        text(c, f.label, 13.f, x + pad, cy + 14.f, kTextDim, "ATTACHMENT POINTS");
        text(c, f.mono, 15.f, x + pad, cy + 32.f, kText, pts);

        const float px0 = x + pad + 70.f;
        const int pips = 12;
        const float pw = 13.f;
        for (int p = 0; p < pips; p++)
        {
            const bool full = (float)p / pips < (float)sp / (float)std::max(bud, 1);
            c.dl->AddRectFilled(ImVec2(px0 + p * pw, cy + 32.f),
                                ImVec2(px0 + p * pw + pw - 3.f, cy + 46.f),
                                full ? kText : kLine);
        }
    }
    cy += 62.f;

    if (s.page == Page::Customize)
    {
        // One row per slot, in the order the weapon declares them, showing what
        // is fitted and what it costs. The game floats these around the 3D
        // weapon on leader lines; that needs the slot anchors projected to
        // screen, which is not decoded yet, so they are listed instead.
        const float rowH = 52.f, colW = 300.f;
        int i = 0;
        for (const auto& kv : wep->slots)
        {
            const float rx = x + pad + (i % 2) * (colW + 12.f);
            const float ry = cy + (i / 2) * (rowH + 8.f);
            i++;
            if (ry + rowH > y + h - 20.f) break;

            const std::string& code = kv.first;
            auto it = s.fitted.by_slot.find(code);
            const bool fitted = it != s.fitted.by_slot.end() && !it->second.empty();
            const bool over = hit(c, rx, ry, colW, rowH);

            c.dl->AddRectFilled(ImVec2(rx, ry), ImVec2(rx + colW, ry + rowH),
                                over ? kTileHov : kTile);
            c.dl->AddRect(ImVec2(rx, ry), ImVec2(rx + colW, ry + rowH), kLine);

            text(c, f.label, 12.f, rx + 10.f, ry + 8.f, kTextDim,
                 upper(code).c_str());
            if (fitted)
            {
                text(c, f.body, 14.f, rx + 10.f, ry + 26.f, kText, it->second.c_str());
                const int cst = cost_of(*wep, code, it->second);
                if (cst >= 0)
                {
                    char cb[24];
                    snprintf(cb, sizeof(cb), "%d", cst);
                    text(c, f.mono, 13.f, rx + colW - 10.f - text_w(f.mono, 13.f, cb),
                         ry + 26.f, kAccent, cb);
                }
            }
            else
            {
                text(c, f.body, 14.f, rx + 10.f, ry + 26.f, kTextDim, "+  empty");
            }
            char n2[40];
            snprintf(n2, sizeof(n2), "%d", (int)kv.second.size());
            text(c, f.mono, 11.f, rx + colW - 10.f - text_w(f.mono, 11.f, n2),
                 ry + 8.f, kTextDim, n2);

            if (over && c.clicked)
            {
                s.slot = code;
                s.page = Page::SlotPicker;
                s.slot_changed = changed = true;
            }
        }
        return changed;
    }

    // ---- slot picker -------------------------------------------------------
    auto sit = wep->slots.find(s.slot);
    if (sit == wep->slots.end()) return changed;

    const float tileW = 190.f, tileH = 78.f, gap = 8.f;
    const int cols = (int)std::max(1.f, (w - pad * 2.f + gap) / (tileW + gap));
    int i = 0;

    // "None" first: unfitting is a real choice and the game offers it.
    for (int pass = 0; pass < 2; pass++)
    for (size_t k = 0; k < (pass == 0 ? size_t(1) : sit->second.size()); k++)
    {
        const bool none = (pass == 0);
        const std::string tok = none ? std::string() : sit->second[k];
        const float tx2 = x + pad + (i % cols) * (tileW + gap);
        const float ty2 = cy + (i / cols) * (tileH + gap);
        i++;
        if (ty2 + tileH > y + h - 20.f) break;

        auto it = s.fitted.by_slot.find(s.slot);
        const bool on = (it == s.fitted.by_slot.end() || it->second.empty()) ? none
                                                                            : it->second == tok;
        const bool over = hit(c, tx2, ty2, tileW, tileH);
        c.dl->AddRectFilled(ImVec2(tx2, ty2), ImVec2(tx2 + tileW, ty2 + tileH),
                            over ? kTileHov : kTile);
        c.dl->AddRect(ImVec2(tx2, ty2), ImVec2(tx2 + tileW, ty2 + tileH),
                      on ? kEquip : kLine, 0.f, 0, on ? 2.f : 1.f);

        const int cst = none ? 0 : cost_of(*wep, s.slot, tok);
        if (cst >= 0)
        {
            char cb[24];
            snprintf(cb, sizeof(cb), "%d", cst);
            c.dl->AddRectFilled(ImVec2(tx2 + 6.f, ty2 + 6.f),
                                ImVec2(tx2 + 6.f + text_w(f.mono, 12.f, cb) + 12.f,
                                       ty2 + 24.f), IM_COL32(0x1E, 0x26, 0x2C, 220));
            text(c, f.mono, 12.f, tx2 + 12.f, ty2 + 8.f, kText, cb);
        }
        text(c, f.body, 13.f, tx2 + 8.f, ty2 + tileH - 24.f, on ? kEquip : kText,
             none ? "None" : tok.c_str());

        if (over && c.clicked)
        {
            s.fitted.by_slot[s.slot] = tok;
            changed = true;
        }
    }
    return changed;
}

}  // namespace armory_ui
