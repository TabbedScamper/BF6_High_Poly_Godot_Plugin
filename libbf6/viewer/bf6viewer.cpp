// BF6 weapon viewer - a native window that reads the install directly.
//
// The browser previewer needs a 38 GB staged tree because it can only eat GLB
// and webp. This eats the install: libbf6 hands over positions, normals, both
// UV sets and BCn texture payloads that are already in the exact layout the
// GPU wants, so the mesh path is a memcpy and the texture path is a
// CreateTexture2D over bytes nobody had to transcode.
//
// Shell is Dear ImGui's own Win32 + D3D11 example, unmodified in shape. Only
// the BF6-specific half is ours: the mount, the armory, the mesh upload and
// the shading.
//
//   bf6viewer [game_dir]
//
// With no argument it reads the path the previewer already remembered in
// %APPDATA%\bf6-weapon-previewer\config.json, so it starts with no setup on a
// machine that has used the other tool.
// windows.h defines min/max as macros, which turns every std::min into a
// syntax error at the call site rather than anywhere near the cause.
#define NOMINMAX
#define WIN32_LEAN_AND_MEAN

#include "bf6_core.h"
#include "rime.h"
#include "armory.h"
#include "armory_ui.h"

#include "imgui.h"
#include "backends/imgui_impl_win32.h"
#include "backends/imgui_impl_dx11.h"

#include <d3d11.h>
#include <d3dcompiler.h>
#include <DirectXMath.h>
#include <windows.h>
#include <shlobj.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <atomic>
#include <map>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "d3dcompiler.lib")

using namespace DirectX;

// ---------------------------------------------------------------- globals
static ID3D11Device*           g_dev = nullptr;
static ID3D11DeviceContext*    g_ctx = nullptr;
static IDXGISwapChain*         g_swap = nullptr;
static ID3D11RenderTargetView* g_rtv = nullptr;
static ID3D11DepthStencilView* g_dsv = nullptr;
static ID3D11Texture2D*        g_depth = nullptr;
static int  g_w = 1600, g_h = 950;
static bool g_resize = false;

struct Vtx { float p[3]; float n[3]; float t[2]; float t1[2]; };

struct GpuSection {
    ID3D11Buffer* vb = nullptr;
    ID3D11Buffer* ib = nullptr;
    UINT          index_count = 0;
    ID3D11ShaderResourceView* srv[3] = { nullptr, nullptr, nullptr }; // albedo, normal, mro
};

struct GpuMesh {
    std::vector<GpuSection> sections;
    XMFLOAT3 lo{}, hi{};
    std::string name;
    long long verts = 0, tris = 0;
    void release()
    {
        for (GpuSection& s : sections)
        {
            if (s.vb) s.vb->Release();
            if (s.ib) s.ib->Release();
            // SRVs are owned by g_texCache, never by the section.
            for (ID3D11ShaderResourceView*& v : s.srv) v = nullptr;
        }
        sections.clear();
        verts = tris = 0;
    }
};

// ----------------------------------------------------------------- shaders
//
// Deliberately plain. Matching the game's shading is a research problem the
// Unreal add-on is still working through; pretending to have solved it here
// with an invented BRDF would produce something that looks confident and is
// wrong. This lights the real albedo with the real normal map and the real
// packed MRO and stops there.
static const char* kHlsl = R"(
cbuffer CB : register(b0)
{
    float4x4 mvp;
    float4x4 model;
    float4   camPos;
    float4   opts;      // x = has normal map, y = has mro, z = uv set, w = unlit
};

struct VSIn  { float3 p : POSITION; float3 n : NORMAL; float2 t : TEXCOORD0; float2 t1 : TEXCOORD1; };
struct VSOut { float4 pos : SV_POSITION; float3 wn : NORMAL; float2 uv : TEXCOORD0;
               float2 uv1 : TEXCOORD1; float3 wp : TEXCOORD2; };

VSOut VS(VSIn i)
{
    VSOut o;
    o.pos = mul(float4(i.p, 1.0), mvp);
    o.wn  = normalize(mul(float4(i.n, 0.0), model).xyz);
    o.uv  = i.t;
    o.uv1 = i.t1;
    o.wp  = mul(float4(i.p, 1.0), model).xyz;
    return o;
}

Texture2D    texAlbedo : register(t0);
Texture2D    texNormal : register(t1);
Texture2D    texMro    : register(t2);
SamplerState samp      : register(s0);

float4 PS(VSOut i) : SV_TARGET
{
    float2 uv = opts.z > 0.5 ? i.uv1 : i.uv;
    float4 alb = texAlbedo.Sample(samp, uv);

    float3 N = normalize(i.wn);
    if (opts.x > 0.5)
    {
        // BC5-style two-channel tangent normal: Z is reconstructed, never
        // stored. Reading .b here would sample whatever the codec left there.
        float2 nxy = texNormal.Sample(samp, uv).rg * 2.0 - 1.0;
        float  nz  = sqrt(saturate(1.0 - dot(nxy, nxy)));
        // No tangent basis in the vertex stream yet, so perturb in world space
        // rather than claim a correct TBN. Honest and cheap; a real tangent
        // frame is the next step.
        N = normalize(N + float3(nxy, nz - 1.0) * 0.5);
    }

    float rough = 0.6, ao = 1.0, metal = 0.0;
    if (opts.y > 0.5)
    {
        float3 mro = texMro.Sample(samp, uv).rgb;
        metal = mro.r; rough = saturate(mro.g); ao = mro.b;
    }

    if (opts.w > 0.5) return float4(alb.rgb, 1.0);

    // Two lights and a ground bounce: enough to read the form of a weapon
    // without inventing a studio rig we have not measured yet.
    float3 V = normalize(camPos.xyz - i.wp);
    float3 L1 = normalize(float3( 0.6, 0.8,  0.5));
    float3 L2 = normalize(float3(-0.7, 0.3, -0.6));

    float3 lit = 0;
    [unroll] for (int k = 0; k < 2; k++)
    {
        float3 L = k == 0 ? L1 : L2;
        float3 H = normalize(L + V);
        float  ndl = saturate(dot(N, L));
        float  ndh = saturate(dot(N, H));
        float  spec = pow(ndh, lerp(128.0, 8.0, rough)) * (1.0 - rough) * 0.6;
        float3 tint = k == 0 ? float3(1.0, 0.97, 0.92) : float3(0.55, 0.62, 0.75);
        lit += (alb.rgb * ndl + spec * lerp(float3(0.04,0.04,0.04), alb.rgb, metal)) * tint * (k == 0 ? 1.0 : 0.45);
    }
    lit += alb.rgb * 0.10 * ao;                       // ambient
    lit = lit / (lit + 1.0);                          // Reinhard, keeps highlights
    return float4(pow(saturate(lit), 1.0 / 2.2), 1.0);
}
)";

static ID3D11VertexShader* g_vs = nullptr;
static ID3D11PixelShader*  g_ps = nullptr;
static ID3D11InputLayout*  g_il = nullptr;
static ID3D11Buffer*       g_cb = nullptr;
static ID3D11SamplerState* g_samp = nullptr;
static ID3D11RasterizerState*   g_rs = nullptr;
static ID3D11DepthStencilState* g_ds = nullptr;

struct CB {
    XMFLOAT4X4 mvp, model;
    XMFLOAT4   camPos, opts;
};

// --------------------------------------------------------------- d3d setup
static void CreateRT()
{
    ID3D11Texture2D* bb = nullptr;
    g_swap->GetBuffer(0, IID_PPV_ARGS(&bb));
    if (!bb) return;
    g_dev->CreateRenderTargetView(bb, nullptr, &g_rtv);
    D3D11_TEXTURE2D_DESC bd{};
    bb->GetDesc(&bd);
    bb->Release();

    D3D11_TEXTURE2D_DESC dd{};
    dd.Width = bd.Width; dd.Height = bd.Height;
    dd.MipLevels = 1; dd.ArraySize = 1;
    dd.Format = DXGI_FORMAT_D32_FLOAT;
    dd.SampleDesc.Count = 1;
    dd.Usage = D3D11_USAGE_DEFAULT;
    dd.BindFlags = D3D11_BIND_DEPTH_STENCIL;
    g_dev->CreateTexture2D(&dd, nullptr, &g_depth);
    if (g_depth) g_dev->CreateDepthStencilView(g_depth, nullptr, &g_dsv);
}

static void ReleaseRT()
{
    if (g_rtv)   { g_rtv->Release();   g_rtv = nullptr; }
    if (g_dsv)   { g_dsv->Release();   g_dsv = nullptr; }
    if (g_depth) { g_depth->Release(); g_depth = nullptr; }
}

static bool InitD3D(HWND hwnd)
{
    DXGI_SWAP_CHAIN_DESC sd{};
    sd.BufferCount = 2;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferDesc.RefreshRate.Numerator = 60;
    sd.BufferDesc.RefreshRate.Denominator = 1;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = hwnd;
    sd.SampleDesc.Count = 1;
    sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;

    const D3D_FEATURE_LEVEL want[] = { D3D_FEATURE_LEVEL_11_0 };
    D3D_FEATURE_LEVEL got{};
    if (FAILED(D3D11CreateDeviceAndSwapChain(
            nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, want, 1,
            D3D11_SDK_VERSION, &sd, &g_swap, &g_dev, &got, &g_ctx)))
        return false;
    CreateRT();

    ID3DBlob* vsb = nullptr; ID3DBlob* psb = nullptr; ID3DBlob* err = nullptr;
    if (FAILED(D3DCompile(kHlsl, strlen(kHlsl), nullptr, nullptr, nullptr, "VS", "vs_5_0", 0, 0, &vsb, &err)))
    {
        MessageBoxA(hwnd, err ? (char*)err->GetBufferPointer() : "VS failed", "shader", MB_OK);
        return false;
    }
    if (FAILED(D3DCompile(kHlsl, strlen(kHlsl), nullptr, nullptr, nullptr, "PS", "ps_5_0", 0, 0, &psb, &err)))
    {
        MessageBoxA(hwnd, err ? (char*)err->GetBufferPointer() : "PS failed", "shader", MB_OK);
        return false;
    }
    g_dev->CreateVertexShader(vsb->GetBufferPointer(), vsb->GetBufferSize(), nullptr, &g_vs);
    g_dev->CreatePixelShader(psb->GetBufferPointer(), psb->GetBufferSize(), nullptr, &g_ps);

    const D3D11_INPUT_ELEMENT_DESC il[] = {
        { "POSITION", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 0,  D3D11_INPUT_PER_VERTEX_DATA, 0 },
        { "NORMAL",   0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 12, D3D11_INPUT_PER_VERTEX_DATA, 0 },
        { "TEXCOORD", 0, DXGI_FORMAT_R32G32_FLOAT,    0, 24, D3D11_INPUT_PER_VERTEX_DATA, 0 },
        { "TEXCOORD", 1, DXGI_FORMAT_R32G32_FLOAT,    0, 32, D3D11_INPUT_PER_VERTEX_DATA, 0 },
    };
    g_dev->CreateInputLayout(il, 4, vsb->GetBufferPointer(), vsb->GetBufferSize(), &g_il);
    vsb->Release(); psb->Release();

    D3D11_BUFFER_DESC cbd{};
    cbd.ByteWidth = sizeof(CB);
    cbd.Usage = D3D11_USAGE_DYNAMIC;
    cbd.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
    cbd.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    g_dev->CreateBuffer(&cbd, nullptr, &g_cb);

    D3D11_SAMPLER_DESC sm{};
    sm.Filter = D3D11_FILTER_ANISOTROPIC;
    sm.MaxAnisotropy = 8;
    sm.AddressU = sm.AddressV = sm.AddressW = D3D11_TEXTURE_ADDRESS_WRAP;
    sm.MaxLOD = D3D11_FLOAT32_MAX;
    g_dev->CreateSamplerState(&sm, &g_samp);

    D3D11_RASTERIZER_DESC rd{};
    rd.FillMode = D3D11_FILL_SOLID;
    rd.CullMode = D3D11_CULL_NONE;      // weapon parts are authored both ways
    rd.DepthClipEnable = TRUE;
    g_dev->CreateRasterizerState(&rd, &g_rs);

    D3D11_DEPTH_STENCIL_DESC dsd{};
    dsd.DepthEnable = TRUE;
    dsd.DepthWriteMask = D3D11_DEPTH_WRITE_MASK_ALL;
    dsd.DepthFunc = D3D11_COMPARISON_LESS;
    g_dev->CreateDepthStencilState(&dsd, &g_ds);
    return true;
}

// ------------------------------------------------------------- bf6 -> gpu
//
// The whole argument for a native tool is in this function: the bytes libbf6
// returns are already a GPU resource. No transcode, no intermediate file.
static DXGI_FORMAT ToDxgi(bf6_fmt f, int srgb)
{
    switch (f)
    {
    case BF6_FMT_RGBA8:   return srgb ? DXGI_FORMAT_R8G8B8A8_UNORM_SRGB : DXGI_FORMAT_R8G8B8A8_UNORM;
    case BF6_FMT_BC1:     return srgb ? DXGI_FORMAT_BC1_UNORM_SRGB : DXGI_FORMAT_BC1_UNORM;
    case BF6_FMT_BC3:     return srgb ? DXGI_FORMAT_BC3_UNORM_SRGB : DXGI_FORMAT_BC3_UNORM;
    case BF6_FMT_BC4:     return DXGI_FORMAT_BC4_UNORM;
    case BF6_FMT_BC5:     return DXGI_FORMAT_BC5_UNORM;
    case BF6_FMT_BC7:     return srgb ? DXGI_FORMAT_BC7_UNORM_SRGB : DXGI_FORMAT_BC7_UNORM;
    case BF6_FMT_BC6H_U:  return DXGI_FORMAT_BC6H_UF16;
    case BF6_FMT_BC6H_S:  return DXGI_FORMAT_BC6H_SF16;
    case BF6_FMT_R8:      return DXGI_FORMAT_R8_UNORM;
    case BF6_FMT_RGBA16F: return DXGI_FORMAT_R16G16B16A16_FLOAT;
    default:              return DXGI_FORMAT_UNKNOWN;
    }
}

static int BlockBytes(bf6_fmt f)
{
    switch (f)
    {
    case BF6_FMT_BC1: case BF6_FMT_BC4: return 8;
    case BF6_FMT_BC3: case BF6_FMT_BC5: case BF6_FMT_BC7:
    case BF6_FMT_BC6H_U: case BF6_FMT_BC6H_S: return 16;
    default: return 0;                  // uncompressed
    }
}

// ONE UPLOAD PER TEXTURE, NOT PER PART.
//
// A weapon's parts share a texture set: m4a1, p90 and mp7a2 each report the
// same 37.75 MB (4096 albedo + 4096 normal + 2048 mro). Uploading that per
// part turned "assemble a weapon" into a gigabyte of duplicated VRAM and a
// multi-second stall in the middle of a UI callback. Keyed by the texture id
// libbf6 hands out, which is stable for the life of the context.
static std::map<int, ID3D11ShaderResourceView*> g_texCache;

static void ClearTexCache()
{
    for (auto& kv : g_texCache) if (kv.second) kv.second->Release();
    g_texCache.clear();
}

static ID3D11ShaderResourceView* UploadTextureUncached(const bf6_texture* t)
{
    if (!t || !t->data || t->data_len <= 0) return nullptr;
    const DXGI_FORMAT fmt = ToDxgi(t->format, t->srgb);
    if (fmt == DXGI_FORMAT_UNKNOWN) return nullptr;

    const int bb = BlockBytes(t->format);
    const int mips = t->mip_count > 0 ? t->mip_count : 1;

    // Walk the mip chain: the payload is every mip tightly packed, so each
    // level's row pitch has to be computed rather than assumed.
    std::vector<D3D11_SUBRESOURCE_DATA> sub((size_t)mips);
    const uint8_t* p = t->data;
    int w = t->width, h = t->height;
    int used = 0, real_mips = 0;
    for (int m = 0; m < mips; m++)
    {
        int pitch, bytes;
        if (bb)
        {
            const int bw = (w + 3) / 4, bh = (h + 3) / 4;
            pitch = bw * bb; bytes = pitch * bh;
        }
        else
        {
            const int bpp = (t->format == BF6_FMT_R8) ? 1 : (t->format == BF6_FMT_RGBA16F ? 8 : 4);
            pitch = w * bpp; bytes = pitch * h;
        }
        if (used + bytes > t->data_len) break;     // short payload: stop, do not read past
        sub[(size_t)m].pSysMem = p + used;
        sub[(size_t)m].SysMemPitch = (UINT)pitch;
        used += bytes; real_mips++;
        w = w > 1 ? w / 2 : 1;
        h = h > 1 ? h / 2 : 1;
    }
    if (real_mips == 0) return nullptr;

    D3D11_TEXTURE2D_DESC d{};
    d.Width = (UINT)t->width; d.Height = (UINT)t->height;
    d.MipLevels = (UINT)real_mips; d.ArraySize = 1;
    d.Format = fmt;
    d.SampleDesc.Count = 1;
    d.Usage = D3D11_USAGE_IMMUTABLE;
    d.BindFlags = D3D11_BIND_SHADER_RESOURCE;

    ID3D11Texture2D* tex = nullptr;
    if (FAILED(g_dev->CreateTexture2D(&d, sub.data(), &tex)) || !tex) return nullptr;
    ID3D11ShaderResourceView* srv = nullptr;
    g_dev->CreateShaderResourceView(tex, nullptr, &srv);
    tex->Release();
    return srv;
}

static ID3D11ShaderResourceView* GetTexture(bf6_ctx* c, int id)
{
    if (id < 0) return nullptr;
    auto it = g_texCache.find(id);
    if (it != g_texCache.end()) return it->second;
    ID3D11ShaderResourceView* srv = UploadTextureUncached(bf6_texture_at(c, id));
    g_texCache[id] = srv;              // cache misses too, so we retry nothing
    return srv;
}

static bool BuildMesh(bf6_ctx* c, const char* res, GpuMesh& out)
{
    out.release();
    bf6_mesh* m = bf6_read_mesh(c, res, 0);
    if (!m) return false;

    out.name = res;
    out.lo = XMFLOAT3(m->aabb_min[0], m->aabb_min[1], m->aabb_min[2]);
    out.hi = XMFLOAT3(m->aabb_max[0], m->aabb_max[1], m->aabb_max[2]);

    for (int i = 0; i < m->section_count; i++)
    {
        const bf6_section& s = m->sections[i];
        if (s.vertex_count <= 0 || s.index_count <= 0) continue;

        std::vector<Vtx> v((size_t)s.vertex_count);
        for (int k = 0; k < s.vertex_count; k++)
        {
            Vtx& o = v[(size_t)k];
            o.p[0] = s.positions[k * 3]; o.p[1] = s.positions[k * 3 + 1]; o.p[2] = s.positions[k * 3 + 2];
            if (s.normals) { o.n[0] = s.normals[k * 3]; o.n[1] = s.normals[k * 3 + 1]; o.n[2] = s.normals[k * 3 + 2]; }
            else           { o.n[0] = 0; o.n[1] = 1; o.n[2] = 0; }
            if (s.uv0) { o.t[0] = s.uv0[k * 2]; o.t[1] = s.uv0[k * 2 + 1]; } else { o.t[0] = o.t[1] = 0; }
            // uv1 is the camo/paint set. It only started arriving once the ABI
            // stopped dropping it; guard anyway, plenty of sections have none.
            if (s.uv1) { o.t1[0] = s.uv1[k * 2]; o.t1[1] = s.uv1[k * 2 + 1]; } else { o.t1[0] = o.t[0]; o.t1[1] = o.t[1]; }
        }

        GpuSection g;
        g.index_count = (UINT)s.index_count;

        D3D11_BUFFER_DESC bd{};
        bd.ByteWidth = (UINT)(v.size() * sizeof(Vtx));
        bd.Usage = D3D11_USAGE_IMMUTABLE;
        bd.BindFlags = D3D11_BIND_VERTEX_BUFFER;
        D3D11_SUBRESOURCE_DATA sr{}; sr.pSysMem = v.data();
        if (FAILED(g_dev->CreateBuffer(&bd, &sr, &g.vb))) continue;

        bd.ByteWidth = (UINT)(s.index_count * sizeof(uint32_t));
        bd.BindFlags = D3D11_BIND_INDEX_BUFFER;
        sr.pSysMem = s.indices;
        if (FAILED(g_dev->CreateBuffer(&bd, &sr, &g.ib))) { g.vb->Release(); continue; }

        if (s.material >= 0 && s.material < m->material_count)
        {
            const bf6_material_desc& md = m->materials[s.material];
            for (int b = 0; b < md.texture_count; b++)
            {
                const bf6_tex_binding& tb = md.textures[b];
                if (tb.texture < 0) continue;
                int slot = -1;
                if      (tb.slot == BF6_TEX_ALBEDO) slot = 0;
                else if (tb.slot == BF6_TEX_NORMAL) slot = 1;
                else if (tb.slot == BF6_TEX_MRO)    slot = 2;
                if (slot < 0 || g.srv[slot]) continue;
                g.srv[slot] = GetTexture(c, tb.texture);
            }
        }

        out.verts += s.vertex_count;
        out.tris  += s.index_count / 3;
        out.sections.push_back(g);
    }
    bf6_free(c, m);
    return !out.sections.empty();
}

// ------------------------------------------------------------------- state
static bf6_ctx* g_bf6 = nullptr;
static std::vector<std::string> g_meshes;      // every mesh resource in the mount for the query
static std::vector<std::string> g_weapons;     // weapon folder names
static GpuMesh g_mesh;
// A WEAPON IS NOT ONE MESH. It is a receiver plus a barrel, a magazine, a
// stock, sights and rail parts, each its own resource. Drawing one resource
// draws one part, which is why the first version showed a lone component.
static std::vector<GpuMesh> g_parts;
static bool g_assembled = false;
static char    g_query[128] = "m4a1";
static float   g_yaw = 0.6f, g_pitch = 0.25f, g_dist = 1.0f;
static bool    g_unlit = false, g_useUv1 = false, g_autoRot = false;
static std::string g_status = "starting";

// The screen's own category order, read from the game at startup.
static std::vector<std::string> g_categories;

// The game's own screen tree, drawn through ImDrawList as a quad batcher.
// The whole roster, built from the mount's own name table: 64 weapons with
// attachment rows, grouped by the class folder the game files them under.
static bf6::Armory g_armory;
static std::string g_selectedWeapon;

// The armory flow: categories -> weapon grid -> customize -> slot picker,
// drawn in the game's palette and typefaces. On by default, because it is the
// point of the tool; the debug panel is the thing that should be opt-in.
static armory_ui::State g_ui;
static bool g_showArmory = true;

// ---------------------------------------------------------- outline icons
//
// The line-art silhouettes on weapon tiles and attachment tiles. One
// <weapon>_layerediconatlas partition carries a sprite per layer with its UV
// rect in the page, its pixel size and its placement - so the card and the
// icons are the same data and neither needs an exported image.
//
// The sprites are 2-CHANNEL: line art in R, fill in G. Alpha is not coverage;
// sampling it draws a solid box. ImGui's draw list samples RGBA, so the page
// is uploaded and the shader-free path relies on R being the visible channel -
// which is why these read as outlines rather than filled shapes.
struct IconSprite {
    std::string name;
    uint32_t hash = 0;
    float uv[4]{}, size[2]{}, offset[2]{};   // offset = packed-sheet slot
    float card[2]{};                          // authored CARD placement
    bool  placed = false;
    int   page = 0;
};
struct IconSet {
    std::string cls;
    std::vector<IconSprite> sprites;
    std::vector<ID3D11ShaderResourceView*> pages;
};
static std::map<std::string, IconSet> g_icons;   // weapon -> its atlas

static const IconSet* IconsFor(const std::string& bare, const std::string& cls)
{
    auto it = g_icons.find(bare);
    if (it != g_icons.end()) return &it->second;
    if (!g_bf6) return nullptr;

    IconSet set;
    set.cls = cls;
    const std::string part =
        "common/ui/assets/images/hardware/generated/layerediconsatlases/" + bare +
        "_layerediconatlas";
    const int n = bf6_icon_atlas(g_bf6, part.c_str(), nullptr, 0);
    if (n > 0)
    {
        std::vector<bf6_icon_sprite> v((size_t)n);
        const int got = bf6_icon_atlas(g_bf6, part.c_str(), v.data(), n);
        int maxPage = 0;
        for (int i = 0; i < got; i++)
        {
            IconSprite s2;
            s2.name = v[(size_t)i].name ? v[(size_t)i].name : "";
            for (int k = 0; k < 4; k++) s2.uv[k] = v[(size_t)i].uv[k];
            for (int k = 0; k < 2; k++)
            { s2.size[k] = v[(size_t)i].size[k]; s2.offset[k] = v[(size_t)i].offset[k]; }
            s2.page = v[(size_t)i].page;
            s2.hash = v[(size_t)i].name_hash;
            if (s2.page > maxPage) maxPage = s2.page;
            set.sprites.push_back(std::move(s2));
        }
        // THE CARD PLACEMENT, which is authored separately in hiao_<weapon>.
        // A sprite's Offset in the atlas is its slot in the PACKED SHEET -
        // the m4a1's read (0,0), (0,94), (0,182), a column - so composing
        // with those stacks every layer vertically and looks like one
        // mangled part. This is the real placement, and it is fractional and
        // often negative.
        {
            const std::string hi = "common/hardware/weapons/" + set.cls + "/" +
                                   bare + "/hiao_" + bare;
            const int hn = bf6_card_layers(g_bf6, hi.c_str(), nullptr, 0);
            if (hn > 0)
            {
                std::vector<bf6_card_layer> hv((size_t)hn);
                const int hg = bf6_card_layers(g_bf6, hi.c_str(), hv.data(), hn);
                for (IconSprite& sp : set.sprites)
                    for (int k = 0; k < hg; k++)
                        if (hv[(size_t)k].sprite_hash == sp.hash)
                        {
                            sp.card[0] = hv[(size_t)k].offset[0];
                            sp.card[1] = hv[(size_t)k].offset[1];
                            sp.placed = true;
                            break;
                        }
            }
        }

        for (int pg = 0; pg <= maxPage; pg++)
        {
            char nm[512];
            snprintf(nm, sizeof(nm), "%s_atlas%d", part.c_str(), pg);
            const int tid = bf6_texture_id_by_name(g_bf6, nm);
            ID3D11ShaderResourceView* srv = nullptr;
            if (tid >= 0) srv = UploadTextureUncached(bf6_texture_at(g_bf6, tid));
            set.pages.push_back(srv);
        }
    }
    auto ins = g_icons.emplace(bare, std::move(set));
    return &ins.first->second;
}

// ---------------------------------------------------------------- async load
//
// EVERY libbf6 CALL HAPPENS ON THE WORKER. The context is explicitly not
// thread-safe against itself - one reader per context - and mesh reads
// decompress, so doing them in a UI callback freezes the window for as long as
// the weapon takes. That is what made selecting a weapon feel dead.
//
// The worker produces CPU-side geometry; the main thread does the D3D upload,
// because the immediate context is not free-threaded either. Two threads, one
// job each, no locking of either library against the other.
struct CpuSection {
    std::vector<Vtx>      verts;
    std::vector<uint32_t> idx;
    int tex[3] = { -1, -1, -1 };      // libbf6 texture ids; uploaded on main
};
struct CpuPart {
    std::string name;
    std::vector<CpuSection> sections;
    float lo[3] = { 0, 0, 0 }, hi[3] = { 0, 0, 0 };
};

// A texture COPIED OUT on the worker.
//
// The ids alone are not enough. Resolving an id to bytes means calling back
// into libbf6, and doing that from the main thread while the worker is reading
// another mesh is two readers on one context - which the header says outright
// is unsupported. The visible symptom was every surface rendering BLACK,
// because the albedo view came back null and a null SRV samples as zero.
struct CpuTex {
    int      id = -1;
    int      w = 0, h = 0, mips = 0;
    int      fmt = 0, srgb = 0;
    std::vector<uint8_t> data;
};

// Upload from a payload the worker already copied. No libbf6 call, so this is
// safe to run on the render thread while the worker is reading the next
// weapon.
static ID3D11ShaderResourceView* UploadCpuTex(const CpuTex& ct)
{
    bf6_texture t{};
    t.width = ct.w; t.height = ct.h; t.mip_count = ct.mips;
    t.format = (bf6_fmt)ct.fmt; t.srgb = ct.srgb;
    t.data = ct.data.data(); t.data_len = (int32_t)ct.data.size();
    return UploadTextureUncached(&t);
}

struct LoadJob {
    std::string weapon;               // bare name, e.g. "m4a1"
    std::vector<CpuPart> parts;       // filled by the worker
    bool done = false;
};

static std::mutex              g_jobLock;
static std::condition_variable g_jobCv;
static std::deque<std::string> g_jobQueue;      // weapons to load
static std::vector<CpuPart>    g_jobResult;
static std::vector<CpuTex>     g_jobTex;
static std::string             g_jobResultFor;
static bool                    g_jobHasResult = false;
static bool                    g_jobBusy = false;
static std::atomic<bool>       g_quit{false};

static void RequestWeapon(const std::string& bare)
{
    std::lock_guard<std::mutex> k(g_jobLock);
    g_jobQueue.clear();               // only the newest request matters
    g_jobQueue.push_back(bare);
    g_jobCv.notify_one();
}

// The camera FRAMES A TARGET rather than jumping to it. The armory never cuts:
// selecting a slot glides the camera onto that part and back out again, which
// is most of why it reads as one continuous scene. Target is a centre plus a
// distance; the live camera eases toward it.
static XMFLOAT3 g_focus   = XMFLOAT3(0, 0, 0);   // where we are looking
static XMFLOAT3 g_focusTo = XMFLOAT3(0, 0, 0);   // where we want to look
static float    g_distTo  = 1.0f;

// Frame the whole assembled weapon: the union of every loaded part.
static void FocusWholeWeapon()
{
    if (g_mesh.hi.x <= g_mesh.lo.x) return;
    g_focusTo = XMFLOAT3((g_mesh.lo.x + g_mesh.hi.x) * 0.5f,
                         (g_mesh.lo.y + g_mesh.hi.y) * 0.5f,
                         (g_mesh.lo.z + g_mesh.hi.z) * 0.5f);
    const float sx = g_mesh.hi.x - g_mesh.lo.x;
    const float sy = g_mesh.hi.y - g_mesh.lo.y;
    const float sz = g_mesh.hi.z - g_mesh.lo.z;
    g_distTo = sqrtf(sx * sx + sy * sy + sz * sz) * 1.35f;
}

// Frame the part that lives in one slot.
//
// The game anchors its per-slot cameras to the slot's own mount BONE
// (Wep_Scope_ATT, Wep_Muzzle_ATT, Wep_MGZ_ATT...). Those bones are decoded but
// not yet exposed across the ABI, so this frames the loaded PART whose mesh
// name matches the slot instead. Same intent, and it uses the part's own
// measured bounds rather than an invented offset - but it is an approximation
// of the authored framing, not the authored framing.
static bool FocusSlot(const std::string& slotCode)
{
    struct Map { const char* code; const char* words; };
    static const Map kMap[] = {
        { "scp", "sight|scope|optic|reflex|holo" }, { "sca", "sight|offset|canted" },
        { "mzl", "muzzle|suppressor|flashhider|brake|comp" },
        { "brl", "barrel" },  { "mag", "magazine|mag|drum" },
        { "btm", "grip|foregrip|bipod|handstop|vertical" },
        { "top", "toprail|rail" }, { "lft", "left|panel" }, { "rgt", "right|light|laser" },
        { "erg", "trigger|stock|ergonomic|buffer" }, { "amo", "magazine|mag" },
    };
    const char* words = nullptr;
    for (const Map& m : kMap) if (slotCode == m.code) { words = m.words; break; }
    if (!words) return false;

    // Split the alternatives and take the first loaded part that matches.
    std::string w(words);
    size_t a = 0;
    while (a <= w.size())
    {
        const size_t b = w.find('|', a);
        const std::string tok = w.substr(a, (b == std::string::npos ? w.size() : b) - a);
        a = (b == std::string::npos) ? w.size() + 1 : b + 1;
        if (tok.empty()) continue;
        for (const GpuMesh& m : g_parts)
        {
            if (m.name.find(tok) == std::string::npos) continue;
            if (m.hi.x <= m.lo.x) continue;
            g_focusTo = XMFLOAT3((m.lo.x + m.hi.x) * 0.5f,
                                 (m.lo.y + m.hi.y) * 0.5f,
                                 (m.lo.z + m.hi.z) * 0.5f);
            const float sx = m.hi.x - m.lo.x, sy = m.hi.y - m.lo.y, sz = m.hi.z - m.lo.z;
            // Keep a floor under it: a tiny part would otherwise pull the
            // camera inside its own geometry.
            g_distTo = (std::max)(sqrtf(sx * sx + sy * sy + sz * sz) * 2.1f, 0.09f);
            return true;
        }
    }
    return false;
}

static std::vector<rime::Screen> g_screens;
static int  g_screenIdx = 0;
static bool g_drawRime = false;
static bool g_rimeOutlines = false;
static rime::Screen g_rimeFlat;
static int  g_rimeUnresolved = 0;
static int  g_rimeBuiltFor = -1;
static bool g_rimeSolved = true;   // rects came pre-solved

// THE GAME'S OWN TYPEFACES, extracted from the install as raw TrueType.
// Sizes come from the 67 authored font styles, which record POINTS at a 1.5
// scale: "fe_body_14px_(21pt)" is point_size 21.02, so px = pt / 1.5.
static ImFont* g_fHeader = nullptr;   // BF_HEADLINE_SEMI_BOLD, 24 px
static ImFont* g_fLabel  = nullptr;   // BF_SUB_HEADLINE_BOLD,  14 px
static ImFont* g_fBody   = nullptr;   // BFText-Regular,        14 px
static ImFont* g_fMono   = nullptr;   // BF_SUB_HEADLINE_MONO,  14 px

// STARTUP RUNS ON A WORKER, and it has to.
//
// Mounting an install, loading the 197 MB type schema and parsing the slot
// definitions is about three minutes of work on a cold cache. Doing that
// between CreateWindow and the message loop - which is where it started out -
// means the window never pumps a message for three minutes, and Windows
// paints it over with "Not Responding". The work was fine; the UI was simply
// never given a turn.
static std::atomic<bool> g_loading{true};
static std::atomic<bool> g_mounted{false};
static std::mutex        g_lock;          // guards g_status and g_meshes
static std::thread       g_worker;

static void SetStatus(const std::string& s)
{
    std::lock_guard<std::mutex> k(g_lock);
    g_status = s;
}

static std::string ConfiguredGameDir()
{
    // Reuse the path the previewer already asked for, so this starts with no
    // setup on a machine that has used the other tool.
    PWSTR ap = nullptr;
    std::string out;
    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_RoamingAppData, 0, nullptr, &ap)) && ap)
    {
        char buf[MAX_PATH * 2];
        wcstombs(buf, ap, sizeof(buf));
        CoTaskMemFree(ap);
        std::string p = std::string(buf) + "\\bf6-weapon-previewer\\config.json";
        if (FILE* f = fopen(p.c_str(), "rb"))
        {
            std::string j;
            char b[4096]; size_t n;
            while ((n = fread(b, 1, sizeof(b), f)) > 0) j.append(b, n);
            fclose(f);
            const size_t k = j.find("\"game_dir\"");
            if (k != std::string::npos)
            {
                size_t a = j.find('"', j.find(':', k)) + 1;
                size_t e = a;
                std::string s;
                while (e < j.size() && j[e] != '"')
                {
                    if (j[e] == '\\' && e + 1 < j.size()) { s += j[e + 1]; e += 2; continue; }
                    s += j[e++];
                }
                out = s;
            }
        }
    }
    return out;
}

static void Search(const char* q)
{
    g_meshes.clear();
    if (!g_bf6 || !q || !*q) return;
    const int n = bf6_list_res(g_bf6, q, nullptr, 0);
    if (n <= 0) { SetStatus("no match"); return; }
    std::vector<bf6_asset> rows((size_t)n);
    const int got = bf6_list_res(g_bf6, q, rows.data(), n);
    for (int i = 0; i < got; i++)
    {
        const char* nm = rows[(size_t)i].name;
        if (!nm) continue;
        const std::string s = nm;
        if (s.find("_mesh") == std::string::npos) continue;
        if (s.find("shadow") != std::string::npos || s.find("_zonly") != std::string::npos) continue;
        g_meshes.push_back(s);
    }
    std::sort(g_meshes.begin(), g_meshes.end());
    char b[128];
    snprintf(b, sizeof(b), "%d meshes", (int)g_meshes.size());
    SetStatus(b);
}

// Load every part of one weapon and draw them together.
//
// THE OPEN QUESTION THIS ANSWERS: are part meshes authored in weapon space, or
// does each need its socket transform applied? If they are authored in place,
// drawing them all at identity assembles the weapon and the union of their
// boxes is weapon-sized. If they are each authored at the origin, they stack
// on top of each other and the union is barely bigger than one part. The
// status line reports which, so this is a measurement and not a hope.
static void AssembleWeapon()
{
    for (GpuMesh& m : g_parts) m.release();
    g_parts.clear();
    if (!g_bf6) return;

    float lo[3] = { 1e30f, 1e30f, 1e30f }, hi[3] = { -1e30f, -1e30f, -1e30f };
    float biggest = 0.f;
    int skipped = 0;

    for (const std::string& r : g_meshes)
    {
        // One variant per part: prefer first person, and never draw a shadow
        // proxy or a depth-only twin as though it were geometry.
        if (r.find("_1p_mesh") == std::string::npos) { skipped++; continue; }

        // THESE ARE VARIANTS, NOT COMPONENTS. An m4a1 ships 21 first-person
        // part meshes, but they are not 21 pieces of one rifle: there are
        // three barrels, three magazines and three iron-sight states, and only
        // ONE of each is fitted at a time. Loading them all draws three
        // barrels through each other and reads as misalignment.
        //
        // Interim rule, and it is interim: drop skin-coded parts outright
        // (wse/wsl/wser/wsd are cosmetic re-skins of a part already loaded),
        // then keep only the first member of each variant family. The correct
        // source is the weapon's own fitted configuration from the armory
        // records, which is the next piece of the port.
        {
            const size_t leaf = r.find_last_of('/');
            const std::string nm = leaf == std::string::npos ? r : r.substr(leaf + 1);
            if (nm.find("_ws") != std::string::npos) { skipped++; continue; }

            static const char* kFamilies[] = { "barrel", "magazine", "ironsight",
                                               "charmholder", "panel", "muzzle",
                                               "defaultmag", "magwell" };
            bool dup = false;
            for (const char* fam : kFamilies)
            {
                if (nm.find(fam) == std::string::npos) continue;
                for (const GpuMesh& already : g_parts)
                    if (already.name.find(fam) != std::string::npos) { dup = true; break; }
                break;
            }
            if (dup) { skipped++; continue; }
        }

        GpuMesh m;
        if (!BuildMesh(g_bf6, r.c_str(), m)) { skipped++; continue; }
        lo[0] = (std::min)(lo[0], m.lo.x); hi[0] = (std::max)(hi[0], m.hi.x);
        lo[1] = (std::min)(lo[1], m.lo.y); hi[1] = (std::max)(hi[1], m.hi.y);
        lo[2] = (std::min)(lo[2], m.lo.z); hi[2] = (std::max)(hi[2], m.hi.z);
        const float d = (std::max)((std::max)(m.hi.x - m.lo.x, m.hi.y - m.lo.y), m.hi.z - m.lo.z);
        biggest = (std::max)(biggest, d);
        g_parts.push_back(std::move(m));
    }

    if (g_parts.empty()) { SetStatus("no 1p parts loaded"); return; }

    g_mesh.lo = XMFLOAT3(lo[0], lo[1], lo[2]);
    g_mesh.hi = XMFLOAT3(hi[0], hi[1], hi[2]);
    const float span = (std::max)((std::max)(hi[0] - lo[0], hi[1] - lo[1]), hi[2] - lo[2]);
    g_dist = span * 1.8f;
    g_assembled = true;

    long long v = 0, t = 0;
    for (const GpuMesh& m : g_parts) { v += m.verts; t += m.tris; }
    char b[256];
    snprintf(b, sizeof(b),
             "%d parts, %lld verts, %lld tris | union %.3f m vs largest single part %.3f m -> %s",
             (int)g_parts.size(), v, t, span, biggest,
             span > biggest * 1.25f ? "AUTHORED IN WEAPON SPACE"
                                    : "parts stack at origin, sockets needed");
    (void)skipped;
    SetStatus(b);
}

// Read one weapon's parts into CPU memory. Worker thread only.
static void WorkerLoadWeapon(const std::string& key, std::vector<CpuPart>& out,
                             std::vector<CpuTex>& tex)
{
    out.clear();
    tex.clear();
    // ANCHOR THE SEARCH TO THE ASSET'S OWN FOLDER.
    //
    // A bare substring match is wrong and visibly so: "m18" is a substring of
    // "m18claymore", so loading the M18 pistol pulled the claymore's meshes in
    // and hung an explosive off the slide. The key is "<group>/<name>", so the
    // path must contain "/<group>/<name>/" - a boundary on both sides.
    const size_t slash = key.find('/');
    const std::string group = slash == std::string::npos ? std::string() : key.substr(0, slash);
    const std::string bare  = slash == std::string::npos ? key : key.substr(slash + 1);
    const std::string anchor = "/" + group + "/" + bare + "/";

    int n = bf6_list_res(g_bf6, bare.c_str(), nullptr, 0);
    if (n <= 0) return;
    const std::string used = bare;

    std::vector<bf6_asset> rows((size_t)n);
    const int got = bf6_list_res(g_bf6, used.c_str(), rows.data(), n);

    std::vector<std::string> names;
    for (int i = 0; i < got; i++)
    {
        const char* nm = rows[(size_t)i].name;
        if (!nm) continue;
        const std::string r = nm;
        // The anchor is what keeps m18claymore out of the M18.
        if (!anchor.empty() && r.find(anchor) == std::string::npos) continue;
        if (r.find("_1p_mesh") == std::string::npos) continue;
        if (r.find("shadow") != std::string::npos || r.find("_zonly") != std::string::npos) continue;
        const size_t leaf = r.find_last_of('/');
        const std::string ln = leaf == std::string::npos ? r : r.substr(leaf + 1);
        if (ln.find("_ws") != std::string::npos) continue;   // skin re-skins
        names.push_back(r);
    }
    std::sort(names.begin(), names.end());

    // One member per variant family: three barrels are three CHOICES, not
    // three pieces of one rifle.
    static const char* kFam[] = { "barrel", "magazine", "ironsight", "charmholder",
                                  "panel", "muzzle", "defaultmag", "magwell" };
    std::vector<std::string> keep;
    for (const std::string& r : names)
    {
        const size_t leaf = r.find_last_of('/');
        const std::string ln = leaf == std::string::npos ? r : r.substr(leaf + 1);
        bool dup = false;
        for (const char* fam : kFam)
        {
            if (ln.find(fam) == std::string::npos) continue;
            for (const std::string& k : keep)
                if (k.find(fam) != std::string::npos) { dup = true; break; }
            break;
        }
        if (!dup) keep.push_back(r);
    }

    // THE SKINNING PALETTE, once per weapon.
    //
    // A weapon mesh is skinned: the bolt, ejection cover, charging handle and
    // trigger are BONES, not separate meshes. Drawing vertices as authored
    // leaves those pieces at the generic bind pose, floating off the receiver -
    // measured at a median 89.8 mm out. Applying the palette is what puts them
    // back.
    std::vector<bf6_bone_xform> skin;
    {
        std::string mdp;
        const std::string q2 = std::string("md_") + bare;
        const int c2 = bf6_list_ebx(g_bf6, q2.c_str(), nullptr, 0);
        if (c2 > 0)
        {
            std::vector<bf6_asset> rr((size_t)c2);
            const int g2 = bf6_list_ebx(g_bf6, q2.c_str(), rr.data(), c2);
            for (int i = 0; i < g2; i++)
            {
                const std::string nm2 = rr[(size_t)i].name ? rr[(size_t)i].name : "";
                if (nm2.find("/md_") == std::string::npos) continue;
                if (nm2.find("_bundle") != std::string::npos) continue;
                if (mdp.empty() || nm2.size() < mdp.size()) mdp = nm2;
            }
        }
        const int nb = bf6_weapon_skin(g_bf6, mdp.empty() ? nullptr : mdp.c_str(), nullptr, 0);
        if (nb > 0)
        {
            skin.resize((size_t)nb);
            bf6_weapon_skin(g_bf6, mdp.empty() ? nullptr : mdp.c_str(), skin.data(), nb);
        }
    }

    // A LOAD LOG, because nobody can inspect a running window from outside it.
    // One line per part saying what bound and what did not - which is the only
    // way to answer "why is this part black" without guessing.
    FILE* lg = fopen("bf6viewer_load.log", "w");
    if (lg)
    {
        fprintf(lg, "weapon %s\\n", bare.c_str());
        fprintf(lg, "skin bones %d\\n", (int)skin.size());
        fprintf(lg, "%-56s %5s %5s %4s %4s %4s\\n",
                "part", "verts", "secs", "alb", "nrm", "mro");
    }

    for (const std::string& r : keep)
    {
        if (g_quit) return;
        bf6_mesh* m = bf6_read_mesh(g_bf6, r.c_str(), 0);

        // IF NOTHING BOUND, ASK THE PART'S OWN BUNDLE.
        //
        // A part's material lives in dpf_<weapon>_<part>_<hash>_bundle_1p, not
        // in the bundle its mesh shipped in. On 6p67 the receiver - 16,674 of
        // ~35,000 vertices - binds nothing the default way and the whole gun
        // renders black, while dpf_6p67_base_cvlhw2_bundle_1p holds it.
        // Only ever a fallback: when the default resolves, it is already right.
        if (m)
        {
            bool anyTex = false;
            for (int mi = 0; mi < m->material_count && !anyTex; mi++)
                for (int b = 0; b < m->materials[mi].texture_count; b++)
                    if (m->materials[mi].textures[b].texture >= 0) { anyTex = true; break; }
            if (!anyTex)
            {
                // part token = the mesh leaf between the weapon name and _1p_mesh
                const size_t lf = r.find_last_of('/');
                std::string leaf = (lf == std::string::npos) ? r : r.substr(lf + 1);
                const size_t up = leaf.find("_1p_mesh");
                if (up != std::string::npos) leaf = leaf.substr(0, up);
                const size_t wp = leaf.find("_" + bare + "_");
                std::string part = (wp == std::string::npos)
                                 ? std::string()
                                 : leaf.substr(wp + bare.size() + 2);
                char bnd[256] = { 0 };
                if (!part.empty() &&
                    bf6_part_bundle(g_bf6, bare.c_str(), part.c_str(), bnd, (int)sizeof(bnd)) > 0)
                {
                    bf6_mesh* m2 = bf6_read_mesh_scoped(g_bf6, r.c_str(), 0, bnd, nullptr);
                    if (m2) { bf6_free(g_bf6, m); m = m2; }
                }
            }
        }
        if (!m) continue;
        CpuPart p;
        p.name = r;
        // Bounds from the SKINNED vertices: the authored aabb describes where
        // the parts sit before the palette moves them, so framing on it aims
        // the camera at empty space.
        for (int k = 0; k < 3; k++) { p.lo[k] = 1e30f; p.hi[k] = -1e30f; }
        for (int i = 0; i < m->section_count; i++)
        {
            const bf6_section& sec = m->sections[i];
            if (sec.vertex_count <= 0 || sec.index_count <= 0) continue;
            CpuSection cs;
            cs.verts.resize((size_t)sec.vertex_count);
            for (int v = 0; v < sec.vertex_count; v++)
            {
                Vtx& o = cs.verts[(size_t)v];
                const float* P = sec.positions + v * 3;
                if (!skin.empty() && sec.bones)
                {
                    int b = (int)sec.bones[v];
                    if (b < 0 || b >= (int)skin.size()) b = 0;
                    const float* M = skin[(size_t)b].m;
                    for (int col = 0; col < 3; col++)
                        o.p[col] = P[0]*M[0*3+col] + P[1]*M[1*3+col] + P[2]*M[2*3+col] + M[9+col];
                    // The normal rotates by the same basis, without the
                    // translation - skipping this lights moved parts wrongly.
                    if (sec.normals)
                    {
                        const float* Nn = sec.normals + v * 3;
                        for (int col = 0; col < 3; col++)
                            o.n[col] = Nn[0]*M[0*3+col] + Nn[1]*M[1*3+col] + Nn[2]*M[2*3+col];
                    }
                }
                else
                {
                    o.p[0] = P[0]; o.p[1] = P[1]; o.p[2] = P[2];
                }
                const bool skinned = (!skin.empty() && sec.bones);
                if (!skinned)
                {
                    if (sec.normals) { o.n[0]=sec.normals[v*3]; o.n[1]=sec.normals[v*3+1]; o.n[2]=sec.normals[v*3+2]; }
                    else             { o.n[0]=0; o.n[1]=1; o.n[2]=0; }
                }
                if (sec.uv0) { o.t[0]=sec.uv0[v*2]; o.t[1]=sec.uv0[v*2+1]; } else { o.t[0]=o.t[1]=0; }
                if (sec.uv1) { o.t1[0]=sec.uv1[v*2]; o.t1[1]=sec.uv1[v*2+1]; } else { o.t1[0]=o.t[0]; o.t1[1]=o.t[1]; }
            }
            cs.idx.assign(sec.indices, sec.indices + sec.index_count);
            if (sec.material >= 0 && sec.material < m->material_count)
            {
                const bf6_material_desc& md = m->materials[sec.material];
                for (int b = 0; b < md.texture_count; b++)
                {
                    const bf6_tex_binding& tb = md.textures[b];
                    if (tb.texture < 0) continue;
                    int slot = -1;
                    if      (tb.slot == BF6_TEX_ALBEDO) slot = 0;
                    else if (tb.slot == BF6_TEX_NORMAL) slot = 1;
                    else if (tb.slot == BF6_TEX_MRO)    slot = 2;
                    if (slot >= 0 && cs.tex[slot] < 0) cs.tex[slot] = tb.texture;
                }
            }
            for (const Vtx& vv : cs.verts)
                for (int k = 0; k < 3; k++)
                {
                    if (vv.p[k] < p.lo[k]) p.lo[k] = vv.p[k];
                    if (vv.p[k] > p.hi[k]) p.hi[k] = vv.p[k];
                }
            p.sections.push_back(std::move(cs));
        }
        if (lg)
        {
            int alb = 0, nrm = 0, mro = 0;
            long long vv = 0;
            for (const CpuSection& cs : p.sections)
            {
                vv += (long long)cs.verts.size();
                if (cs.tex[0] >= 0) alb++;
                if (cs.tex[1] >= 0) nrm++;
                if (cs.tex[2] >= 0) mro++;
            }
            const size_t leaf2 = r.find_last_of('/');
            fprintf(lg, "%-56s %5lld %5d %4d %4d %4d%s\\n",
                    (leaf2 == std::string::npos ? r : r.substr(leaf2 + 1)).c_str(),
                    vv, (int)p.sections.size(), alb, nrm, mro,
                    alb == 0 ? "   <- NO ALBEDO, draws black" : "");
        }
        if (!p.sections.empty()) out.push_back(std::move(p));
        bf6_free(g_bf6, m);          // the handle was leaking every load
    }

    if (lg) { fclose(lg); }

    // Copy every distinct texture this weapon needs, once, here on the worker.
    std::vector<int> want;
    for (const CpuPart& p : out)
        for (const CpuSection& cs : p.sections)
            for (int k = 0; k < 3; k++)
                if (cs.tex[k] >= 0 &&
                    std::find(want.begin(), want.end(), cs.tex[k]) == want.end())
                    want.push_back(cs.tex[k]);

    for (int id : want)
    {
        if (g_quit) return;
        const bf6_texture* t = bf6_texture_at(g_bf6, id);
        if (!t || !t->data || t->data_len <= 0) continue;
        CpuTex ct;
        ct.id = id; ct.w = t->width; ct.h = t->height;
        ct.mips = t->mip_count; ct.fmt = (int)t->format; ct.srgb = t->srgb;
        ct.data.assign(t->data, t->data + t->data_len);
        tex.push_back(std::move(ct));
    }
}

// ------------------------------------------------------------------ win32
extern IMGUI_IMPL_API LRESULT ImGui_ImplWin32_WndProcHandler(HWND, UINT, WPARAM, LPARAM);

static LRESULT WINAPI WndProc(HWND h, UINT msg, WPARAM wp, LPARAM lp)
{
    if (ImGui_ImplWin32_WndProcHandler(h, msg, wp, lp)) return true;
    switch (msg)
    {
    case WM_SIZE:
        if (wp != SIZE_MINIMIZED) { g_w = LOWORD(lp); g_h = HIWORD(lp); g_resize = true; }
        return 0;
    case WM_SYSCOMMAND:
        if ((wp & 0xfff0) == SC_KEYMENU) return 0;
        break;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(h, msg, wp, lp);
}

int main(int argc, char** argv)
{
    std::string game = argc > 1 ? argv[1] : ConfiguredGameDir();

    WNDCLASSEXW wc = { sizeof(wc), CS_CLASSDC, WndProc, 0, 0, GetModuleHandle(nullptr),
                       nullptr, nullptr, nullptr, nullptr, L"BF6Viewer", nullptr };
    RegisterClassExW(&wc);
    HWND hwnd = CreateWindowW(wc.lpszClassName, L"BF6 Weapon Viewer - reading the install directly",
                              WS_OVERLAPPEDWINDOW, 60, 60, g_w, g_h, nullptr, nullptr, wc.hInstance, nullptr);
    if (!InitD3D(hwnd)) { MessageBoxA(hwnd, "D3D11 init failed", "bf6viewer", MB_OK); return 1; }
    ShowWindow(hwnd, SW_SHOWDEFAULT);
    UpdateWindow(hwnd);

    ImGui::CreateContext();
    ImGui::GetIO().ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
    // THE GAME'S OWN FRONT-END PALETTE, measured out of its UI assets rather
    // than eyedropped off a screenshot. Surfaces DarkNavy #1E262C and Charcoal
    // #22313C, text FE-Text #BFCAD1, and the six-step rarity ramp.
    //
    // Square corners are not a style choice here: 5,709 of 7,402 authored
    // corners have curvature exactly 0, so the front end has no rounded
    // rectangle idiom at all.
    ImGui::StyleColorsDark();
    {
        auto C = [](int hex, float a = 1.0f) {
            return ImVec4(((hex >> 16) & 255) / 255.0f, ((hex >> 8) & 255) / 255.0f,
                          (hex & 255) / 255.0f, a);
        };
        const ImVec4 darkNavy = C(0x1E262C), charcoal = C(0x22313C), text = C(0xBFCAD1);
        const ImVec4 accent   = C(0x59BFF8);          // rarity ramp, step 3
        ImGuiStyle& st = ImGui::GetStyle();
        st.WindowRounding = st.FrameRounding = st.GrabRounding = 0.0f;
        st.ChildRounding  = st.PopupRounding = st.ScrollbarRounding = 0.0f;
        st.WindowBorderSize = 1.0f;
        st.Colors[ImGuiCol_WindowBg]        = C(0x1E262C, 0.96f);
        st.Colors[ImGuiCol_ChildBg]         = C(0x22313C, 0.55f);
        st.Colors[ImGuiCol_TitleBg]         = darkNavy;
        st.Colors[ImGuiCol_TitleBgActive]   = charcoal;
        st.Colors[ImGuiCol_Text]            = text;
        st.Colors[ImGuiCol_Border]          = C(0xBFCAD1, 0.18f);
        st.Colors[ImGuiCol_FrameBg]         = C(0x22313C, 0.85f);
        st.Colors[ImGuiCol_FrameBgHovered]  = C(0x59BFF8, 0.25f);
        st.Colors[ImGuiCol_Button]          = C(0x22313C, 0.95f);
        st.Colors[ImGuiCol_ButtonHovered]   = C(0x59BFF8, 0.40f);
        st.Colors[ImGuiCol_ButtonActive]    = accent;
        st.Colors[ImGuiCol_Header]          = C(0x59BFF8, 0.30f);
        st.Colors[ImGuiCol_HeaderHovered]   = C(0x59BFF8, 0.45f);
        st.Colors[ImGuiCol_HeaderActive]    = accent;
        st.Colors[ImGuiCol_CheckMark]       = accent;
        st.Colors[ImGuiCol_SliderGrab]      = accent;
        st.Colors[ImGuiCol_Separator]       = C(0xBFCAD1, 0.20f);
    }
    {
        // Loaded beside the exe. If the folder is missing the atlas falls back
        // to ImGui's built-in face rather than failing to start - a viewer with
        // the wrong font still shows the weapon.
        ImGuiIO& fio = ImGui::GetIO();
        const char* dir = "assets/fonts/";
        struct F { ImFont** slot; const char* file; float px; };
        const F want[] = {
            { &g_fBody,   "bftext-regular.ttf",                    14.0f },
            { &g_fLabel,  "bf_sub_headline_bold_fixed.ttf",        14.0f },
            { &g_fHeader, "bf_headline_semi_bold_fixed.ttf",       24.0f },
            { &g_fMono,   "bf_sub_headline_mono_medium_fixed.ttf", 14.0f },
        };
        for (const F& f : want)
        {
            std::string path = std::string(dir) + f.file;
            if (FILE* t = fopen(path.c_str(), "rb"))
            {
                fclose(t);
                *f.slot = fio.Fonts->AddFontFromFileTTF(path.c_str(), f.px);
            }
        }
        if (g_fBody) fio.FontDefault = g_fBody;
    }

    {
        // Prefer the SOLVED layout: absolute rects, verified against
        // independently measured geometry, references already instantiated.
        // The raw tree is the fallback and needs our own box law, which got
        // the axis order wrong three ways before it was measured properly.
        std::string rerr;
        if (!rime::load_solved_tsv("assets/ui/rime_layout_solved.tsv", g_screens, rerr))
        {
            g_screens.clear();
            if (!rime::load_tree_tsv("assets/ui/ui_armory_screen_tree.tsv", g_screens, rerr))
                g_screens.clear();
            g_rimeSolved = false;
        }
    }

    ImGui_ImplWin32_Init(hwnd);
    ImGui_ImplDX11_Init(g_dev, g_ctx);

    // Startup on a worker so the window can paint and pump from frame one.
    // Only libbf6 work happens here; the GPU upload stays on the main thread,
    // because the immediate context is not free-threaded.
    g_worker = std::thread([game]()
    {
        char err[512] = { 0 };
        SetStatus("opening install...");
        g_bf6 = bf6_open(game.c_str(), err, (int)sizeof(err));
        if (!g_bf6) { SetStatus(std::string("open failed: ") + err); g_loading = false; return; }

        SetStatus("mounting archives (this is the slow one)...");
        if (!bf6_mount_all(g_bf6, 1, err, (int)sizeof(err)))
        { SetStatus(std::string("mount failed: ") + err); g_loading = false; return; }

        SetStatus("loading type schema and slot definitions...");
        const int ns = bf6_armory_slots(g_bf6, nullptr, 0);

        const int nc = bf6_armory_categories(g_bf6, nullptr, 0);
        if (nc > 0)
        {
            std::vector<const char*> cats((size_t)nc);
            bf6_armory_categories(g_bf6, cats.data(), nc);
            std::lock_guard<std::mutex> k(g_lock);
            g_categories.clear();
            for (int i = 0; i < nc; i++) if (cats[(size_t)i]) g_categories.push_back(cats[(size_t)i]);
        }

        SetStatus("building the armory roster...");
        {
            const int na = bf6_list_ebx(g_bf6, nullptr, nullptr, 0);
            std::vector<bf6_asset> arows((size_t)(na > 0 ? na : 0));
            const int agot = na > 0 ? bf6_list_ebx(g_bf6, nullptr, arows.data(), na) : 0;
            std::vector<std::string> anames;
            anames.reserve((size_t)agot);
            for (int i = 0; i < agot; i++)
                if (arows[(size_t)i].name) anames.emplace_back(arows[(size_t)i].name);
            bf6::Armory a2 = bf6::armory_from_names(anames);

            // READ THE COSTS. armory_from_names builds the table from the
            // mount's name list alone, so every cost is still -1 and the
            // points total stays at zero no matter what is fitted. The value
            // is Int32 at offset 0x80 of the attachment partition.
            int64_t got2 = 0;
            for (bf6::ArmoryWeapon& w2 : a2.weapons)
                for (bf6::ArmoryAttachment& at2 : w2.attachments)
                {
                    if (at2.ebx.empty()) continue;
                    const uint8_t* pp = nullptr;
                    const int64_t nn = bf6_read_raw(g_bf6, BF6_RAW_EBX, at2.ebx.c_str(), &pp);
                    if (nn >= 0x84 && pp) { std::memcpy(&at2.cost, pp + 0x80, 4); got2++; }
                }
            {
                char cb[96];
                snprintf(cb, sizeof(cb), "read %lld attachment costs", (long long)got2);
                SetStatus(cb);
            }

            std::lock_guard<std::mutex> k(g_lock);
            g_armory = std::move(a2);
        }

        SetStatus("searching...");
        Search(g_query);

        char b[160];
        snprintf(b, sizeof(b), "ready - %d slot definitions, %d meshes",
                 ns, (int)g_meshes.size());
        SetStatus(b);
        g_mounted = true;
        g_loading = false;

        // Stay alive and serve load requests. The alternative - spawning a
        // thread per selection - would race two readers on one context.
        for (;;)
        {
            std::string want;
            {
                std::unique_lock<std::mutex> k(g_jobLock);
                g_jobCv.wait(k, [] { return g_quit || !g_jobQueue.empty(); });
                if (g_quit) return;
                want = g_jobQueue.back();
                g_jobQueue.clear();
                g_jobBusy = true;
            }
            SetStatus("loading " + want + "...");
            std::vector<CpuPart> parts;
            std::vector<CpuTex>  texs;
            WorkerLoadWeapon(want, parts, texs);
            if (g_quit) return;
            {
                std::lock_guard<std::mutex> k(g_jobLock);
                g_jobTex = std::move(texs);
                g_jobResult = std::move(parts);
                g_jobResultFor = want;
                g_jobHasResult = true;
                g_jobBusy = false;
            }
            SetStatus(want + " ready");
        }
    });

    bool running = true;
    while (running)
    {
        MSG msg;
        while (PeekMessage(&msg, nullptr, 0, 0, PM_REMOVE))
        {
            TranslateMessage(&msg);
            DispatchMessage(&msg);
            if (msg.message == WM_QUIT) running = false;
        }
        if (!running) break;

        if (g_resize)
        {
            ReleaseRT();
            g_swap->ResizeBuffers(0, (UINT)g_w, (UINT)g_h, DXGI_FORMAT_UNKNOWN, 0);
            CreateRT();
            g_resize = false;
        }

        // Upload anything the worker finished. GPU work stays on this thread.
        {
            std::vector<CpuPart> ready;
            std::vector<CpuTex>  readyTex;
            std::string readyFor;
            {
                std::lock_guard<std::mutex> k(g_jobLock);
                if (g_jobHasResult)
                {
                    ready = std::move(g_jobResult);
                    readyTex = std::move(g_jobTex);
                    readyFor = g_jobResultFor;
                    g_jobHasResult = false;
                }
            }
            // Cache by id so a weapon's parts share one upload of each sheet.
            for (const CpuTex& ct : readyTex)
                if (g_texCache.find(ct.id) == g_texCache.end())
                    g_texCache[ct.id] = UploadCpuTex(ct);
            if (!ready.empty())
            {
                for (GpuMesh& m : g_parts) m.release();
                g_parts.clear();
                float lo[3] = { 1e30f, 1e30f, 1e30f }, hi[3] = { -1e30f, -1e30f, -1e30f };
                for (CpuPart& cp : ready)
                {
                    GpuMesh gm;
                    gm.name = cp.name;
                    gm.lo = XMFLOAT3(cp.lo[0], cp.lo[1], cp.lo[2]);
                    gm.hi = XMFLOAT3(cp.hi[0], cp.hi[1], cp.hi[2]);
                    for (CpuSection& cs : cp.sections)
                    {
                        GpuSection g;
                        g.index_count = (UINT)cs.idx.size();
                        D3D11_BUFFER_DESC bd{};
                        bd.ByteWidth = (UINT)(cs.verts.size() * sizeof(Vtx));
                        bd.Usage = D3D11_USAGE_IMMUTABLE;
                        bd.BindFlags = D3D11_BIND_VERTEX_BUFFER;
                        D3D11_SUBRESOURCE_DATA sr{}; sr.pSysMem = cs.verts.data();
                        if (FAILED(g_dev->CreateBuffer(&bd, &sr, &g.vb))) continue;
                        bd.ByteWidth = (UINT)(cs.idx.size() * sizeof(uint32_t));
                        bd.BindFlags = D3D11_BIND_INDEX_BUFFER;
                        sr.pSysMem = cs.idx.data();
                        if (FAILED(g_dev->CreateBuffer(&bd, &sr, &g.ib))) { g.vb->Release(); continue; }
                        for (int t = 0; t < 3; t++)
                        {
                            g.srv[t] = nullptr;
                            if (cs.tex[t] < 0) continue;
                            auto tit = g_texCache.find(cs.tex[t]);
                            if (tit != g_texCache.end()) g.srv[t] = tit->second;
                        }
                        gm.verts += (long long)cs.verts.size();
                        gm.tris  += (long long)(cs.idx.size() / 3);
                        gm.sections.push_back(g);
                    }
                    for (int k2 = 0; k2 < 3; k2++)
                    {
                        lo[k2] = (std::min)(lo[k2], (&gm.lo.x)[k2]);
                        hi[k2] = (std::max)(hi[k2], (&gm.hi.x)[k2]);
                    }
                    if (!gm.sections.empty()) g_parts.push_back(std::move(gm));
                }
                if (!g_parts.empty())
                {
                    g_mesh.lo = XMFLOAT3(lo[0], lo[1], lo[2]);
                    g_mesh.hi = XMFLOAT3(hi[0], hi[1], hi[2]);
                    g_assembled = true;
                    FocusWholeWeapon();
                    g_focus = g_focusTo;          // first frame: no glide in
                    g_dist  = g_distTo;
                }
            }
        }

        ImGui_ImplDX11_NewFrame();
        ImGui_ImplWin32_NewFrame();
        ImGui::NewFrame();

        ImGui::SetNextWindowPos(ImVec2(10, 10), ImGuiCond_FirstUseEver);
        ImGui::SetNextWindowSize(ImVec2(430, 640), ImGuiCond_FirstUseEver);
        ImGui::Begin("Armory");
        // The screen's twelve categories, in the order the game presents them.
        // Read from BFUIWeaponCustomizationViewManagerConfig at startup, so
        // this list is the game's and not ours - and note it is deliberately
        // not alphabetical: Sight, Magazine, OpticAccessory, Barrel, Muzzle...
        if (!g_categories.empty())
        {
            if (g_fHeader) ImGui::PushFont(g_fHeader);
            ImGui::TextUnformatted("CUSTOMIZE");
            if (g_fHeader) ImGui::PopFont();
            if (g_fLabel) ImGui::PushFont(g_fLabel);
            for (size_t i = 0; i < g_categories.size(); i++)
            {
                char row[96];
                snprintf(row, sizeof(row), "%02d  %s", (int)i + 1, g_categories[i].c_str());
                ImGui::Selectable(row, false);
            }
            if (g_fLabel) ImGui::PopFont();
            ImGui::Separator();
        }
        ImGui::TextWrapped("%s", game.empty() ? "no install configured" : game.c_str());
        ImGui::TextColored(ImVec4(0.6f, 0.8f, 1.0f, 1.0f), "%s", g_status.c_str());
        ImGui::Separator();

        if (ImGui::InputText("search", g_query, sizeof(g_query),
                             ImGuiInputTextFlags_EnterReturnsTrue))
            Search(g_query);
        ImGui::SameLine();
        if (ImGui::Button("go")) Search(g_query);

        // The roster, by class, in the game's own folder grouping. Picking a
        // weapon searches its meshes - no need to know the internal name.
        if (!g_armory.weapons.empty())
        {
            ImGui::Separator();
            if (g_fLabel) ImGui::PushFont(g_fLabel);
            ImGui::Text("WEAPONS  %d", (int)g_armory.weapons.size());
            if (g_fLabel) ImGui::PopFont();
            ImGui::BeginChild("roster", ImVec2(0, 200), true);
            std::string cls;
            for (const bf6::ArmoryWeapon& w : g_armory.weapons)
            {
                if (w.cls != cls)
                {
                    cls = w.cls;
                    ImGui::TextColored(ImVec4(0.35f, 0.75f, 0.97f, 1.0f), "%s", cls.c_str());
                }
                char row[160];
                snprintf(row, sizeof(row), "   %-18s %d slots, %d attachments",
                         w.name.c_str(), (int)w.slots.size(), (int)w.attachments.size());
                if (ImGui::Selectable(row, g_selectedWeapon == w.name))
                {
                    g_selectedWeapon = w.name;
                    snprintf(g_query, sizeof(g_query), "%s", w.name.c_str());
                    Search(g_query);
                    g_assembled = false;
                    if (!g_meshes.empty()) BuildMesh(g_bf6, g_meshes[0].c_str(), g_mesh);
                }
            }
            ImGui::EndChild();
        }

        ImGui::Separator();
        ImGui::BeginChild("meshes", ImVec2(0, 380), true);
        for (size_t i = 0; i < g_meshes.size(); i++)
        {
            const std::string& m = g_meshes[i];
            size_t sl = m.find_last_of('/');
            const char* leaf = sl == std::string::npos ? m.c_str() : m.c_str() + sl + 1;
            const bool sel = (m == g_mesh.name);
            if (ImGui::Selectable(leaf, sel))
            {
                g_assembled = false;
                if (BuildMesh(g_bf6, m.c_str(), g_mesh))
                {
                    const float sx = g_mesh.hi.x - g_mesh.lo.x;
                    const float sy = g_mesh.hi.y - g_mesh.lo.y;
                    const float sz = g_mesh.hi.z - g_mesh.lo.z;
                    g_dist = sqrtf(sx*sx + sy*sy + sz*sz) * 1.6f;
                }
            }
        }
        ImGui::EndChild();

        ImGui::Separator();
        ImGui::Checkbox("draw the game's screen tree", &g_drawRime);
        if (g_drawRime && !g_screens.empty())
        {
            ImGui::SameLine();
            ImGui::Checkbox("outlines", &g_rimeOutlines);
            const rime::Screen& sc = g_screens[(size_t)g_screenIdx % g_screens.size()];
            ImGui::Text("%s", sc.partition.c_str());
            ImGui::TextColored(ImVec4(0.98f, 0.41f, 0.30f, 1.0f),
                               "LAYOUT ONLY - geometry is verified, paint data not loaded yet");
            ImGui::Text("%d authored -> %d instantiated, %d refs unresolved",
                        (int)sc.elements.size(), (int)g_rimeFlat.elements.size(),
                        g_rimeUnresolved);
            ImGui::SliderInt("screen", &g_screenIdx, 0, (int)g_screens.size() - 1);
        }
        ImGui::Separator();
        if (ImGui::Button("Assemble whole weapon (all 1p parts)")) AssembleWeapon();
        ImGui::SameLine();
        if (ImGui::Button("single part")) g_assembled = false;
        ImGui::Separator();
        ImGui::Checkbox("unlit (raw albedo)", &g_unlit);
        ImGui::Checkbox("use UV1 (camo set)", &g_useUv1);
        ImGui::Checkbox("auto-rotate", &g_autoRot);
        ImGui::SliderFloat("distance", &g_dist, 0.05f, 5.0f);
        if (!g_mesh.sections.empty())
        {
            ImGui::Separator();
            ImGui::Text("sections   %d", (int)g_mesh.sections.size());
            ImGui::Text("vertices   %lld", g_mesh.verts);
            ImGui::Text("triangles  %lld", g_mesh.tris);
            ImGui::Text("size       %.3f x %.3f x %.3f m",
                        g_mesh.hi.x - g_mesh.lo.x, g_mesh.hi.y - g_mesh.lo.y, g_mesh.hi.z - g_mesh.lo.z);
        }
        ImGui::Separator();
        ImGui::Text("%.1f fps", ImGui::GetIO().Framerate);
        ImGui::End();

        // ---- camera ----
        ImGuiIO& io = ImGui::GetIO();
        if (!io.WantCaptureMouse)
        {
            if (io.MouseDown[0]) { g_yaw += io.MouseDelta.x * 0.01f; g_pitch += io.MouseDelta.y * 0.01f; }
            if (io.MouseWheel != 0.f)
            {
                g_distTo *= (1.0f - io.MouseWheel * 0.1f);
                g_distTo = std::max(0.02f, std::min(g_distTo, 20.0f));
            }
        }
        // Ease toward the framing target. Exponential so it settles rather
        // than arriving abruptly; frame-rate independent.
        {
            const float k = 1.0f - powf(0.0025f, io.DeltaTime);
            g_focus.x += (g_focusTo.x - g_focus.x) * k;
            g_focus.y += (g_focusTo.y - g_focus.y) * k;
            g_focus.z += (g_focusTo.z - g_focus.z) * k;
            g_dist    += (g_distTo   - g_dist)    * k;
        }
        if (g_autoRot) g_yaw += io.DeltaTime * 0.5f;
        g_pitch = std::max(-1.5f, std::min(g_pitch, 1.5f));

        // ---- the armory flow ---------------------------------------------
        struct IconDraw {
            static bool go(const char* bare, const char* cls,
                           float x, float y, float w, float h, void*)
            {
                const IconSet* set = IconsFor(bare ? bare : "", cls ? cls : "");
                if (!set || set->sprites.empty() || set->pages.empty()) return false;

                // COMPOSITE EVERY PLACED LAYER. An outline is the receiver
                // PLUS barrel, sight, panels and the rest, each at its own
                // authored offset. Drawing only the receiver is why it read
                // as a single part.
                float lo[2] = { 1e30f, 1e30f }, hi2[2] = { -1e30f, -1e30f };
                int placed = 0;
                for (const IconSprite& sp : set->sprites)
                {
                    if (!sp.placed) continue;
                    placed++;
                    for (int k = 0; k < 2; k++)
                    {
                        lo[k]  = (std::min)(lo[k],  sp.card[k]);
                        hi2[k] = (std::max)(hi2[k], sp.card[k] + sp.size[k]);
                    }
                }
                if (!placed) return false;

                const float cw  = (std::max)(hi2[0] - lo[0], 1.f);
                const float chh = (std::max)(hi2[1] - lo[1], 1.f);
                const float k   = (std::min)(w / cw, h / chh);
                const float ox  = x + (w - cw * k) * 0.5f;
                const float oy  = y + (h - chh * k) * 0.5f;

                ImDrawList* dl = ImGui::GetBackgroundDrawList();
                for (const IconSprite& sp : set->sprites)
                {
                    if (!sp.placed) continue;
                    if (sp.page < 0 || sp.page >= (int)set->pages.size()) continue;
                    ID3D11ShaderResourceView* srv = set->pages[(size_t)sp.page];
                    if (!srv) continue;
                    const float dx = ox + (sp.card[0] - lo[0]) * k;
                    const float dy = oy + (sp.card[1] - lo[1]) * k;
                    dl->AddImage((ImTextureID)srv, ImVec2(dx, dy),
                                 ImVec2(dx + sp.size[0] * k, dy + sp.size[1] * k),
                                 ImVec2(sp.uv[0], sp.uv[1]),
                                 ImVec2(sp.uv[2], sp.uv[3]),
                                 IM_COL32(0xBF, 0xCA, 0xD1, 235));
                }
                return true;
            }
        };
        if (g_showArmory && !g_armory.weapons.empty())
        {
            const armory_ui::Page prevPage = g_ui.page;
            armory_ui::Fonts af;
            af.header = g_fHeader; af.label = g_fLabel;
            af.body = g_fBody;     af.mono = g_fMono;
            const float panelW = (float)g_w * 0.52f;
            if (armory_ui::draw(g_armory, g_ui, af, 0.f, 0.f, panelW, (float)g_h,
                                &IconDraw::go, nullptr))
            {
                // A new weapon means new geometry; a new slot will mean a new
                // camera once the per-slot framing is wired.
                if (g_ui.weapon_changed && !g_ui.weapon.empty())
                {
                    snprintf(g_query, sizeof(g_query), "%s", g_ui.weapon.c_str());
                    // The WHOLE weapon, off-thread, keyed by "<group>/<name>"
                    // so the mesh search can anchor to its folder.
                    RequestWeapon(g_ui.weapon);
                }
                if (g_ui.slot_changed && !g_ui.slot.empty())
                    FocusSlot(g_ui.slot);            // glide onto the part
                if (prevPage == armory_ui::Page::SlotPicker &&
                    g_ui.page != armory_ui::Page::SlotPicker)
                    FocusWholeWeapon();              // backing out pulls back
            }
        }

        // ---- the game's screen, drawn from its own element tree ----------
        if (g_drawRime && !g_screens.empty())
        {
            const size_t root = (size_t)g_screenIdx % g_screens.size();
            if (g_rimeBuiltFor != (int)root)
            {
                g_rimeFlat = g_rimeSolved ? g_screens[root]
                                          : rime::instantiate(g_screens, root, 8, &g_rimeUnresolved);
                g_rimeBuiltFor = (int)root;
            }
            rime::Screen& sc = g_rimeFlat;
            // Authored against a 1920x1080 canvas until the design resolution
            // is confirmed; scaled to fit so the proportions stay honest.
            // 1920x1080 is the authored canvas, established from the data:
            // 275 elements carry that size pair and nothing sits near 1440p.
            // A consumer multiplies offsets by NOTHING - the 1.5 factor is a
            // font-unit convention only (px = PointSize / 1.5).
            const float CW = 1920.f, CH = 1080.f;
            if (!g_rimeSolved) rime::solve(sc, CW, CH);
            const float k = (std::min)((float)g_w / CW, (float)g_h / CH);
            const float ox = ((float)g_w - CW * k) * 0.5f;
            const float oy = ((float)g_h - CH * k) * 0.5f;

            ImDrawList* dl = ImGui::GetBackgroundDrawList();
            auto X = [&](float v) { return ox + v * k; };
            auto Y = [&](float v) { return oy + v * k; };

            int bad = 0;
            for (const rime::Element& e : sc.elements)
            {
                if (!e.solved) { bad++; continue; }
                const ImVec2 a(X(e.x0), Y(e.y0)), b(X(e.x1), Y(e.y1));
                switch (e.kind)
                {
                case rime::Kind::Fill:
                    dl->AddRectFilled(a, b, IM_COL32(0x1E, 0x26, 0x2C, 235));
                    break;
                case rime::Kind::VectorShape:
                    dl->AddRectFilled(a, b, IM_COL32(0x22, 0x31, 0x3C, 220));
                    dl->AddRect(a, b, IM_COL32(0xBF, 0xCA, 0xD1, 60));
                    break;
                case rime::Kind::RepeatShape:
                {   // the point-cost pip strip: count and spacing still unknown
                    const float wpx = b.x - a.x;
                    const int pips = 10;
                    for (int i = 0; i < pips; i++)
                    {
                        const float w0 = a.x + wpx * i / pips + 1.0f;
                        const float w1 = a.x + wpx * (i + 1) / pips - 1.0f;
                        dl->AddRectFilled(ImVec2(w0, a.y), ImVec2(w1, b.y),
                                          IM_COL32(0x59, 0xBF, 0xF8, 200));
                    }
                    break;
                }
                case rime::Kind::Label:
                    if (g_fLabel) dl->AddText(g_fLabel, 14.f * k, a,
                                              IM_COL32(0xBF, 0xCA, 0xD1, 255),
                                              e.name.c_str());
                    break;
                case rime::Kind::Movie:
                    dl->AddRectFilled(a, b, IM_COL32(0, 0, 0, 200));
                    dl->AddRect(a, b, IM_COL32(0xFB, 0x69, 0x4D, 120));
                    break;
                case rime::Kind::WidgetReference:
                case rime::Kind::Container:
                case rime::Kind::StackContainer:
                case rime::Kind::LayerEntity:
                    // LAYOUT ONLY - a plain container never draws. Painting
                    // them is what turned this into a stack of overlapping
                    // rectangles. Visible on the outline toggle, for debugging
                    // the tree, and not otherwise.
                    if (g_rimeOutlines)
                        dl->AddRect(a, b, IM_COL32(0x8E, 0xED, 0x6C, 55));
                    break;
                default:
                    if (g_rimeOutlines) dl->AddRect(a, b, IM_COL32(0xBF, 0xCA, 0xD1, 28));
                    break;
                }
            }
            if (bad)
            {
                char m[128];
                snprintf(m, sizeof(m), "%d element(s) solved to a negative box - box law is wrong", bad);
                dl->AddText(ImVec2(ox + 12, oy + 12), IM_COL32(0xFB, 0x69, 0x4D, 255), m);
            }
        }

        ImGui::Render();
        const float clear[4] = { 0.09f, 0.10f, 0.12f, 1.0f };
        g_ctx->OMSetRenderTargets(1, &g_rtv, g_dsv);
        g_ctx->ClearRenderTargetView(g_rtv, clear);
        if (g_dsv) g_ctx->ClearDepthStencilView(g_dsv, D3D11_CLEAR_DEPTH, 1.0f, 0);

        std::vector<const GpuMesh*> draw;
        if (g_assembled) { for (const GpuMesh& m : g_parts) draw.push_back(&m); }
        else if (!g_mesh.sections.empty()) draw.push_back(&g_mesh);

        if (!draw.empty())
        {
            const XMVECTOR mid = XMVectorSet(g_focus.x, g_focus.y, g_focus.z, 0);
            const XMVECTOR eye = XMVectorAdd(mid, XMVectorSet(
                g_dist * cosf(g_pitch) * sinf(g_yaw),
                g_dist * sinf(g_pitch),
                g_dist * cosf(g_pitch) * cosf(g_yaw), 0));
            const XMMATRIX view = XMMatrixLookAtLH(eye, mid, XMVectorSet(0, 1, 0, 0));
            // THE GAME'S OWN ARMORY LENS, not a guess. Camera_DefaultBody is a
            // 36.0 x 20.25 mm sensor and every armory camera mode runs
            // Lens_Anamorphic_35mm_T6 at 35.0 mm, which is
            //     vFOV = 2*atan(20.25/2 / 35) = 32.27 deg   (hFOV 54.43)
            // Modes differ only in aperture and shutter, so the field of view
            // is a single constant across the whole screen.
            const float kArmoryVFovDeg = 32.27f;
            const XMMATRIX proj = XMMatrixPerspectiveFovLH(
                XMConvertToRadians(kArmoryVFovDeg),
                (float)g_w / (float)std::max(g_h, 1), 0.005f, 200.0f);
            const XMMATRIX model = XMMatrixIdentity();

            D3D11_MAPPED_SUBRESOURCE ms;
            if (SUCCEEDED(g_ctx->Map(g_cb, 0, D3D11_MAP_WRITE_DISCARD, 0, &ms)))
            {
                CB cb{};
                XMStoreFloat4x4(&cb.mvp, XMMatrixTranspose(model * view * proj));
                XMStoreFloat4x4(&cb.model, XMMatrixTranspose(model));
                XMStoreFloat4(&cb.camPos, eye);
                cb.opts = XMFLOAT4(0, 0, g_useUv1 ? 1.0f : 0.0f, g_unlit ? 1.0f : 0.0f);
                memcpy(ms.pData, &cb, sizeof(cb));
                g_ctx->Unmap(g_cb, 0);
            }

            g_ctx->IASetInputLayout(g_il);
            g_ctx->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
            g_ctx->VSSetShader(g_vs, nullptr, 0);
            g_ctx->PSSetShader(g_ps, nullptr, 0);
            g_ctx->VSSetConstantBuffers(0, 1, &g_cb);
            g_ctx->PSSetConstantBuffers(0, 1, &g_cb);
            g_ctx->PSSetSamplers(0, 1, &g_samp);
            g_ctx->RSSetState(g_rs);
            g_ctx->OMSetDepthStencilState(g_ds, 0);
            D3D11_VIEWPORT vp{ 0, 0, (float)g_w, (float)g_h, 0, 1 };
            g_ctx->RSSetViewports(1, &vp);

            for (const GpuMesh* dm : draw)
            for (const GpuSection& s : dm->sections)
            {
                // Per-section flags: a section with no normal map must not be
                // shaded as though it had one.
                if (SUCCEEDED(g_ctx->Map(g_cb, 0, D3D11_MAP_WRITE_DISCARD, 0, &ms)))
                {
                    CB cb{};
                    XMStoreFloat4x4(&cb.mvp, XMMatrixTranspose(model * view * proj));
                    XMStoreFloat4x4(&cb.model, XMMatrixTranspose(model));
                    XMStoreFloat4(&cb.camPos, eye);
                    cb.opts = XMFLOAT4(s.srv[1] ? 1.0f : 0.0f, s.srv[2] ? 1.0f : 0.0f,
                                       g_useUv1 ? 1.0f : 0.0f, g_unlit ? 1.0f : 0.0f);
                    memcpy(ms.pData, &cb, sizeof(cb));
                    g_ctx->Unmap(g_cb, 0);
                }
                UINT stride = sizeof(Vtx), off = 0;
                g_ctx->IASetVertexBuffers(0, 1, &s.vb, &stride, &off);
                g_ctx->IASetIndexBuffer(s.ib, DXGI_FORMAT_R32_UINT, 0);
                ID3D11ShaderResourceView* srvs[3] = { s.srv[0], s.srv[1], s.srv[2] };
                g_ctx->PSSetShaderResources(0, 3, srvs);
                g_ctx->DrawIndexed(s.index_count, 0, 0);
            }
        }

        ImGui_ImplDX11_RenderDrawData(ImGui::GetDrawData());
        g_swap->Present(1, 0);
    }

    // Join before closing the context the worker is using, or shutdown races
    // a mount that is still walking archives.
    g_quit = true;
    g_jobCv.notify_all();
    if (g_worker.joinable()) g_worker.join();
    g_mesh.release();
    for (GpuMesh& m : g_parts) m.release();
    ClearTexCache();
    if (g_bf6) bf6_close(g_bf6);
    ImGui_ImplDX11_Shutdown();
    ImGui_ImplWin32_Shutdown();
    ImGui::DestroyContext();
    ReleaseRT();
    if (g_swap) g_swap->Release();
    if (g_ctx)  g_ctx->Release();
    if (g_dev)  g_dev->Release();
    DestroyWindow(hwnd);
    UnregisterClassW(wc.lpszClassName, wc.hInstance);
    return 0;
}
