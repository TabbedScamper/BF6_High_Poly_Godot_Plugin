/* Native water raster proof.
 *
 * Reads the current level's selected water VS/PS and exact material cbuffer
 * from the installed game, creates the real D3D12 graphics PSO, executes one
 * offscreen draw, and reads back both render targets.  The geometry and the
 * unbound scene resources are deliberately synthetic-neutral in this first
 * rung; the program says so in its output and must not be treated as a visual
 * parity renderer.
 *
 * waterdraw_test <game_dir> <level> [--debug-layer]
 */
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <d3d12.h>
#include <dxgi1_6.h>
#include <wrl/client.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "bf6_core.h"
#include "source.h"

using Microsoft::WRL::ComPtr;
using namespace bf6;

namespace {

constexpr UINT kSide = 256;
constexpr UINT kSrvCount = 37;

uint32_t rd32(const std::vector<uint8_t>& d, size_t o)
{
    uint32_t v = 0;
    if (o + 4 <= d.size()) std::memcpy(&v, d.data() + o, 4);
    return v;
}

std::string lower(std::string s)
{
    for (char& c : s) c = (char)std::tolower((unsigned char)c);
    return s;
}

std::string hr_text(HRESULT hr)
{
    char* p = nullptr;
    const DWORD n = FormatMessageA(FORMAT_MESSAGE_ALLOCATE_BUFFER |
        FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, nullptr,
        (DWORD)hr, 0, (char*)&p, 0, nullptr);
    std::string out = n && p ? std::string(p, n) : std::string("unknown error");
    if (p) LocalFree(p);
    while (!out.empty() && (out.back() == '\r' || out.back() == '\n')) out.pop_back();
    return out;
}

std::string guid_net(const uint8_t g[16])
{
    char b[64];
    std::snprintf(b, sizeof(b),
        "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
        g[3], g[2], g[1], g[0], g[5], g[4], g[7], g[6],
        g[8], g[9], g[10], g[11], g[12], g[13], g[14], g[15]);
    return b;
}

bool live_container(Source& src, const std::string& guid,
                    std::vector<uint8_t>& out, std::string& resource,
                    std::string& err)
{
    const std::string needle = lower(guid);
    for (const auto& kv : src.res()) {
        const std::string name = lower(kv.first);
        if (name.find("bytecode") == std::string::npos ||
            name.find(needle) == std::string::npos) continue;
        std::vector<uint8_t> wrapped = src.get_res(kv.first, err);
        if (wrapped.empty()) continue;
        size_t at = std::string::npos;
        for (size_t i = 0; i + 4 <= wrapped.size() && i < 8192; ++i)
            if (!std::memcmp(wrapped.data() + i, "DXBC", 4)) { at = i; break; }
        if (at == std::string::npos || at + 0x20 > wrapped.size()) {
            err = "resource has no DXBC/DXIL container";
            return false;
        }
        const uint32_t bytes = rd32(wrapped, at + 0x18);
        if (bytes < 0x20 || at + bytes > wrapped.size()) {
            err = "DXBC/DXIL size is outside wrapper";
            return false;
        }
        out.assign(wrapped.begin() + at, wrapped.begin() + at + bytes);
        resource = kv.first;
        return true;
    }
    err = "no mounted CompiledBytecode resource contains GUID " + guid;
    return false;
}

D3D12_HEAP_PROPERTIES heap_props(D3D12_HEAP_TYPE type)
{
    D3D12_HEAP_PROPERTIES h{};
    h.Type = type;
    h.CreationNodeMask = h.VisibleNodeMask = 1;
    return h;
}

D3D12_RESOURCE_DESC buffer_desc(UINT64 bytes)
{
    D3D12_RESOURCE_DESC d{};
    d.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    d.Width = bytes;
    d.Height = d.DepthOrArraySize = d.MipLevels = 1;
    d.SampleDesc.Count = 1;
    d.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    return d;
}

bool upload_buffer(ID3D12Device* dev, const void* data, size_t bytes,
                   ComPtr<ID3D12Resource>& out, bool cb = false)
{
    const UINT64 alloc = cb ? ((bytes + 255u) & ~255ull) : std::max<UINT64>(bytes, 4);
    D3D12_HEAP_PROPERTIES hp = heap_props(D3D12_HEAP_TYPE_UPLOAD);
    D3D12_RESOURCE_DESC d = buffer_desc(alloc);
    HRESULT hr = dev->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &d,
        D3D12_RESOURCE_STATE_GENERIC_READ, nullptr, IID_PPV_ARGS(&out));
    if (FAILED(hr)) return false;
    uint8_t* p = nullptr;
    D3D12_RANGE none{0, 0};
    if (FAILED(out->Map(0, &none, (void**)&p))) return false;
    std::memset(p, 0, (size_t)alloc);
    if (data && bytes) std::memcpy(p, data, bytes);
    out->Unmap(0, nullptr);
    return true;
}

struct TinyTexture {
    ComPtr<ID3D12Resource> gpu;
    ComPtr<ID3D12Resource> upload;
    DXGI_FORMAT format = DXGI_FORMAT_UNKNOWN;
    UINT array_size = 1;
    UINT mip_count = 1;
};

struct OwnedTexture {
    int width = 0, height = 0, mip_count = 0, srgb = 0;
    bf6_fmt format = BF6_FMT_UNKNOWN;
    std::vector<uint8_t> data;
};

DXGI_FORMAT dxgi_format(const OwnedTexture& t)
{
    switch (t.format) {
    case BF6_FMT_RGBA8: return t.srgb ? DXGI_FORMAT_R8G8B8A8_UNORM_SRGB : DXGI_FORMAT_R8G8B8A8_UNORM;
    case BF6_FMT_BC1: return t.srgb ? DXGI_FORMAT_BC1_UNORM_SRGB : DXGI_FORMAT_BC1_UNORM;
    case BF6_FMT_BC3: return t.srgb ? DXGI_FORMAT_BC3_UNORM_SRGB : DXGI_FORMAT_BC3_UNORM;
    case BF6_FMT_BC4: return DXGI_FORMAT_BC4_UNORM;
    case BF6_FMT_BC5: return DXGI_FORMAT_BC5_UNORM;
    case BF6_FMT_BC7: return t.srgb ? DXGI_FORMAT_BC7_UNORM_SRGB : DXGI_FORMAT_BC7_UNORM;
    case BF6_FMT_BC6H_U: return DXGI_FORMAT_BC6H_UF16;
    case BF6_FMT_BC6H_S: return DXGI_FORMAT_BC6H_SF16;
    case BF6_FMT_R8: return DXGI_FORMAT_R8_UNORM;
    case BF6_FMT_RGBA16F: return DXGI_FORMAT_R16G16B16A16_FLOAT;
    default: return DXGI_FORMAT_UNKNOWN;
    }
}

size_t mip_bytes(UINT w, UINT h, bf6_fmt format)
{
    const UINT bw = std::max(1u, (w + 3) / 4);
    const UINT bh = std::max(1u, (h + 3) / 4);
    switch (format) {
    case BF6_FMT_BC1: case BF6_FMT_BC4: return (size_t)bw * bh * 8;
    case BF6_FMT_BC3: case BF6_FMT_BC5: case BF6_FMT_BC7:
    case BF6_FMT_BC6H_U: case BF6_FMT_BC6H_S: return (size_t)bw * bh * 16;
    case BF6_FMT_RGBA8: return (size_t)w * h * 4;
    case BF6_FMT_R8: return (size_t)w * h;
    case BF6_FMT_RGBA16F: return (size_t)w * h * 8;
    default: return 0;
    }
}

UINT mip_rows(UINT h, bf6_fmt format)
{
    switch (format) {
    case BF6_FMT_BC1: case BF6_FMT_BC3: case BF6_FMT_BC4: case BF6_FMT_BC5:
    case BF6_FMT_BC7: case BF6_FMT_BC6H_U: case BF6_FMT_BC6H_S:
        return std::max(1u, (h + 3) / 4);
    default: return h;
    }
}

bool make_authored_texture(ID3D12Device* dev, ID3D12GraphicsCommandList* cl,
                           const OwnedTexture& source, TinyTexture& out,
                           std::string& err)
{
    out.format = dxgi_format(source);
    out.array_size = 1;
    out.mip_count = (UINT)source.mip_count;
    if (out.format == DXGI_FORMAT_UNKNOWN || source.width <= 0 || source.height <= 0 ||
        source.mip_count <= 0 || source.data.empty()) {
        err = "invalid authored texture"; return false;
    }
    D3D12_RESOURCE_DESC d{};
    d.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    d.Width = (UINT)source.width;
    d.Height = (UINT)source.height;
    d.DepthOrArraySize = 1;
    d.MipLevels = (UINT16)source.mip_count;
    d.Format = out.format;
    d.SampleDesc.Count = 1;
    D3D12_HEAP_PROPERTIES dh = heap_props(D3D12_HEAP_TYPE_DEFAULT);
    HRESULT hr = dev->CreateCommittedResource(&dh, D3D12_HEAP_FLAG_NONE, &d,
        D3D12_RESOURCE_STATE_COPY_DEST, nullptr, IID_PPV_ARGS(&out.gpu));
    if (FAILED(hr)) { err = hr_text(hr); return false; }
    std::vector<D3D12_PLACED_SUBRESOURCE_FOOTPRINT> fp((size_t)source.mip_count);
    std::vector<UINT> rows((size_t)source.mip_count);
    std::vector<UINT64> row_bytes((size_t)source.mip_count);
    UINT64 total = 0;
    dev->GetCopyableFootprints(&d, 0, (UINT)source.mip_count, 0, fp.data(), rows.data(),
                               row_bytes.data(), &total);
    D3D12_HEAP_PROPERTIES uh = heap_props(D3D12_HEAP_TYPE_UPLOAD);
    D3D12_RESOURCE_DESC bd = buffer_desc(total);
    hr = dev->CreateCommittedResource(&uh, D3D12_HEAP_FLAG_NONE, &bd,
        D3D12_RESOURCE_STATE_GENERIC_READ, nullptr, IID_PPV_ARGS(&out.upload));
    if (FAILED(hr)) { err = hr_text(hr); return false; }
    uint8_t* dst = nullptr;
    D3D12_RANGE none{0, 0};
    if (FAILED(out.upload->Map(0, &none, (void**)&dst))) {
        err = "authored texture upload map failed"; return false;
    }
    std::memset(dst, 0, (size_t)total);
    size_t source_at = 0;
    UINT w = (UINT)source.width, h = (UINT)source.height;
    for (UINT mip = 0; mip < (UINT)source.mip_count; ++mip) {
        const size_t bytes = mip_bytes(w, h, source.format);
        const UINT source_rows = mip_rows(h, source.format);
        if (!bytes || source_at + bytes > source.data.size() || !source_rows) {
            out.upload->Unmap(0, nullptr);
            err = "authored texture mip chain is truncated"; return false;
        }
        const size_t source_pitch = bytes / source_rows;
        for (UINT y = 0; y < source_rows; ++y)
            std::memcpy(dst + fp[mip].Offset + (size_t)y * fp[mip].Footprint.RowPitch,
                        source.data.data() + source_at + (size_t)y * source_pitch,
                        source_pitch);
        source_at += bytes;
        w = std::max(1u, w / 2); h = std::max(1u, h / 2);
    }
    out.upload->Unmap(0, nullptr);
    for (UINT mip = 0; mip < (UINT)source.mip_count; ++mip) {
        D3D12_TEXTURE_COPY_LOCATION from{};
        from.pResource = out.upload.Get();
        from.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
        from.PlacedFootprint = fp[mip];
        D3D12_TEXTURE_COPY_LOCATION to{};
        to.pResource = out.gpu.Get();
        to.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        to.SubresourceIndex = mip;
        cl->CopyTextureRegion(&to, 0, 0, 0, &from, nullptr);
    }
    D3D12_RESOURCE_BARRIER b{};
    b.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    b.Transition.pResource = out.gpu.Get();
    b.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    b.Transition.StateBefore = D3D12_RESOURCE_STATE_COPY_DEST;
    b.Transition.StateAfter = D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE |
                              D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;
    cl->ResourceBarrier(1, &b);
    return true;
}

bool make_tiny_texture(ID3D12Device* dev, ID3D12GraphicsCommandList* cl,
                       DXGI_FORMAT format, UINT array_size,
                       const void* texel, size_t texel_bytes,
                       TinyTexture& out)
{
    out.format = format;
    out.array_size = array_size;
    D3D12_RESOURCE_DESC d{};
    d.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    d.Width = d.Height = 1;
    d.DepthOrArraySize = (UINT16)array_size;
    d.MipLevels = 1;
    d.Format = format;
    d.SampleDesc.Count = 1;
    D3D12_HEAP_PROPERTIES dh = heap_props(D3D12_HEAP_TYPE_DEFAULT);
    HRESULT hr = dev->CreateCommittedResource(&dh, D3D12_HEAP_FLAG_NONE, &d,
        D3D12_RESOURCE_STATE_COPY_DEST, nullptr, IID_PPV_ARGS(&out.gpu));
    if (FAILED(hr)) return false;

    std::vector<D3D12_PLACED_SUBRESOURCE_FOOTPRINT> fp(array_size);
    std::vector<UINT> rows(array_size);
    std::vector<UINT64> row_bytes(array_size);
    UINT64 total = 0;
    dev->GetCopyableFootprints(&d, 0, array_size, 0, fp.data(), rows.data(),
                               row_bytes.data(), &total);
    D3D12_HEAP_PROPERTIES uh = heap_props(D3D12_HEAP_TYPE_UPLOAD);
    D3D12_RESOURCE_DESC bd = buffer_desc(total);
    hr = dev->CreateCommittedResource(&uh, D3D12_HEAP_FLAG_NONE, &bd,
        D3D12_RESOURCE_STATE_GENERIC_READ, nullptr, IID_PPV_ARGS(&out.upload));
    if (FAILED(hr)) return false;
    uint8_t* p = nullptr;
    D3D12_RANGE none{0, 0};
    if (FAILED(out.upload->Map(0, &none, (void**)&p))) return false;
    std::memset(p, 0, (size_t)total);
    for (UINT a = 0; a < array_size; ++a)
        std::memcpy(p + fp[a].Offset, texel, texel_bytes);
    out.upload->Unmap(0, nullptr);
    for (UINT a = 0; a < array_size; ++a) {
        D3D12_TEXTURE_COPY_LOCATION from{};
        from.pResource = out.upload.Get();
        from.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
        from.PlacedFootprint = fp[a];
        D3D12_TEXTURE_COPY_LOCATION to{};
        to.pResource = out.gpu.Get();
        to.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        to.SubresourceIndex = a;
        cl->CopyTextureRegion(&to, 0, 0, 0, &from, nullptr);
    }
    D3D12_RESOURCE_BARRIER b{};
    b.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    b.Transition.pResource = out.gpu.Get();
    b.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    b.Transition.StateBefore = D3D12_RESOURCE_STATE_COPY_DEST;
    b.Transition.StateAfter = D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE |
                              D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;
    cl->ResourceBarrier(1, &b);
    return true;
}

void transition(ID3D12GraphicsCommandList* cl, ID3D12Resource* r,
                D3D12_RESOURCE_STATES before, D3D12_RESOURCE_STATES after)
{
    D3D12_RESOURCE_BARRIER b{};
    b.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    b.Transition.pResource = r;
    b.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    b.Transition.StateBefore = before;
    b.Transition.StateAfter = after;
    cl->ResourceBarrier(1, &b);
}

bool make_root(ID3D12Device* dev, ComPtr<ID3D12RootSignature>& root,
               std::string& err)
{
    D3D12_DESCRIPTOR_RANGE srvs{};
    srvs.RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_SRV;
    srvs.NumDescriptors = kSrvCount;
    srvs.BaseShaderRegister = 0;
    srvs.RegisterSpace = 0;
    srvs.OffsetInDescriptorsFromTableStart = 0;

    D3D12_ROOT_PARAMETER p[4]{};
    p[0].ParameterType = D3D12_ROOT_PARAMETER_TYPE_CBV;
    p[0].Descriptor.ShaderRegister = 0;
    p[0].ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
    p[1].ParameterType = D3D12_ROOT_PARAMETER_TYPE_CBV;
    p[1].Descriptor.ShaderRegister = 1;
    p[1].ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
    p[2].ParameterType = D3D12_ROOT_PARAMETER_TYPE_CBV;
    p[2].Descriptor.ShaderRegister = 4;
    p[2].ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
    p[3].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
    p[3].DescriptorTable.NumDescriptorRanges = 1;
    p[3].DescriptorTable.pDescriptorRanges = &srvs;
    p[3].ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;

    D3D12_STATIC_SAMPLER_DESC samplers[8]{};
    for (UINT i = 0; i < 8; ++i) {
        samplers[i].Filter = D3D12_FILTER_MIN_MAG_MIP_LINEAR;
        samplers[i].AddressU = samplers[i].AddressV = samplers[i].AddressW =
            D3D12_TEXTURE_ADDRESS_MODE_WRAP;
        samplers[i].MipLODBias = 0;
        samplers[i].MaxAnisotropy = 1;
        samplers[i].ComparisonFunc = D3D12_COMPARISON_FUNC_ALWAYS;
        samplers[i].BorderColor = D3D12_STATIC_BORDER_COLOR_TRANSPARENT_BLACK;
        samplers[i].MinLOD = 0;
        samplers[i].MaxLOD = D3D12_FLOAT32_MAX;
        samplers[i].ShaderRegister = i;
        samplers[i].ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
    }
    samplers[3].AddressU = samplers[3].AddressV = samplers[3].AddressW =
        D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
    samplers[4].AddressU = samplers[4].AddressV = samplers[4].AddressW =
        D3D12_TEXTURE_ADDRESS_MODE_CLAMP;

    D3D12_ROOT_SIGNATURE_DESC d{};
    d.NumParameters = 4;
    d.pParameters = p;
    d.NumStaticSamplers = 8;
    d.pStaticSamplers = samplers;
    d.Flags = D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT |
              D3D12_ROOT_SIGNATURE_FLAG_ALLOW_STREAM_OUTPUT;
    ComPtr<ID3DBlob> blob, errors;
    HRESULT hr = D3D12SerializeRootSignature(&d, D3D_ROOT_SIGNATURE_VERSION_1,
                                             &blob, &errors);
    if (FAILED(hr)) {
        err = errors ? std::string((const char*)errors->GetBufferPointer(),
                                   errors->GetBufferSize()) : hr_text(hr);
        return false;
    }
    hr = dev->CreateRootSignature(0, blob->GetBufferPointer(), blob->GetBufferSize(),
                                  IID_PPV_ARGS(&root));
    if (FAILED(hr)) { err = hr_text(hr); return false; }
    return true;
}

bool make_pso(ID3D12Device* dev, ID3D12RootSignature* root,
              const std::vector<uint8_t>& vs, const std::vector<uint8_t>& ps,
              ComPtr<ID3D12PipelineState>& pso, std::string& err)
{
    D3D12_GRAPHICS_PIPELINE_STATE_DESC d{};
    d.pRootSignature = root;
    d.VS = {vs.data(), vs.size()};
    d.PS = {ps.data(), ps.size()};
    static const char kPosition[] = "SV_Position";
    D3D12_SO_DECLARATION_ENTRY so_entry{};
    so_entry.Stream = 0;
    so_entry.SemanticName = kPosition;
    so_entry.SemanticIndex = 0;
    so_entry.StartComponent = 0;
    so_entry.ComponentCount = 4;
    so_entry.OutputSlot = 0;
    UINT so_stride = 16;
    d.StreamOutput.pSODeclaration = &so_entry;
    d.StreamOutput.NumEntries = 1;
    d.StreamOutput.pBufferStrides = &so_stride;
    d.StreamOutput.NumStrides = 1;
    d.StreamOutput.RasterizedStream = 0;
    d.BlendState.AlphaToCoverageEnable = FALSE;
    d.BlendState.IndependentBlendEnable = FALSE;
    for (auto& rt : d.BlendState.RenderTarget) {
        rt.BlendEnable = FALSE;
        rt.LogicOpEnable = FALSE;
        rt.SrcBlend = D3D12_BLEND_ONE;
        rt.DestBlend = D3D12_BLEND_ZERO;
        rt.BlendOp = D3D12_BLEND_OP_ADD;
        rt.SrcBlendAlpha = D3D12_BLEND_ONE;
        rt.DestBlendAlpha = D3D12_BLEND_ZERO;
        rt.BlendOpAlpha = D3D12_BLEND_OP_ADD;
        rt.LogicOp = D3D12_LOGIC_OP_NOOP;
        rt.RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
    }
    d.SampleMask = UINT_MAX;
    d.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID;
    d.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
    d.RasterizerState.FrontCounterClockwise = FALSE;
    d.RasterizerState.DepthBias = D3D12_DEFAULT_DEPTH_BIAS;
    d.RasterizerState.DepthBiasClamp = D3D12_DEFAULT_DEPTH_BIAS_CLAMP;
    d.RasterizerState.SlopeScaledDepthBias = D3D12_DEFAULT_SLOPE_SCALED_DEPTH_BIAS;
    d.RasterizerState.DepthClipEnable = FALSE;
    d.RasterizerState.MultisampleEnable = FALSE;
    d.RasterizerState.AntialiasedLineEnable = FALSE;
    d.RasterizerState.ForcedSampleCount = 0;
    d.RasterizerState.ConservativeRaster = D3D12_CONSERVATIVE_RASTERIZATION_MODE_OFF;
    d.DepthStencilState.DepthEnable = FALSE;
    d.DepthStencilState.StencilEnable = FALSE;
    d.InputLayout = {nullptr, 0};
    d.IBStripCutValue = D3D12_INDEX_BUFFER_STRIP_CUT_VALUE_DISABLED;
    d.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    d.NumRenderTargets = 2;
    d.RTVFormats[0] = DXGI_FORMAT_R32G32_UINT;
    d.RTVFormats[1] = DXGI_FORMAT_R32_FLOAT;
    d.SampleDesc.Count = 1;
    d.NodeMask = 0;
    HRESULT hr = dev->CreateGraphicsPipelineState(&d, IID_PPV_ARGS(&pso));
    if (FAILED(hr)) { err = hr_text(hr); return false; }
    return true;
}

bool make_rt(ID3D12Device* dev, DXGI_FORMAT format, ComPtr<ID3D12Resource>& out)
{
    D3D12_RESOURCE_DESC d{};
    d.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    d.Width = d.Height = kSide;
    d.DepthOrArraySize = d.MipLevels = 1;
    d.Format = format;
    d.SampleDesc.Count = 1;
    d.Flags = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    D3D12_CLEAR_VALUE clear{};
    clear.Format = format;
    D3D12_HEAP_PROPERTIES hp = heap_props(D3D12_HEAP_TYPE_DEFAULT);
    return SUCCEEDED(dev->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &d,
        D3D12_RESOURCE_STATE_RENDER_TARGET, &clear, IID_PPV_ARGS(&out)));
}

struct ReadbackStats {
    uint64_t changed = 0;
    uint64_t hash = 1469598103934665603ull;
    double min_value = 0;
    double max_value = 0;
    uint64_t nonfinite = 0;
};

void hash_bytes(ReadbackStats& s, const uint8_t* p, size_t n)
{
    for (size_t i = 0; i < n; ++i) {
        s.hash ^= p[i];
        s.hash *= 1099511628211ull;
    }
}

bool read_rt(ID3D12Device* dev, ID3D12GraphicsCommandList* cl,
             ID3D12Resource* rt, DXGI_FORMAT format,
             ComPtr<ID3D12Resource>& readback,
             D3D12_PLACED_SUBRESOURCE_FOOTPRINT& footprint,
             UINT& rows, UINT64& total)
{
    const D3D12_RESOURCE_DESC td = rt->GetDesc();
    UINT64 row_bytes = 0;
    dev->GetCopyableFootprints(&td, 0, 1, 0, &footprint, &rows, &row_bytes, &total);
    D3D12_HEAP_PROPERTIES hp = heap_props(D3D12_HEAP_TYPE_READBACK);
    D3D12_RESOURCE_DESC bd = buffer_desc(total);
    if (FAILED(dev->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &bd,
        D3D12_RESOURCE_STATE_COPY_DEST, nullptr, IID_PPV_ARGS(&readback)))) return false;
    D3D12_TEXTURE_COPY_LOCATION from{};
    from.pResource = rt;
    from.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    D3D12_TEXTURE_COPY_LOCATION to{};
    to.pResource = readback.Get();
    to.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
    to.PlacedFootprint = footprint;
    cl->CopyTextureRegion(&to, 0, 0, 0, &from, nullptr);
    (void)format;
    return true;
}

ReadbackStats stats_rt(ID3D12Resource* readback,
                       const D3D12_PLACED_SUBRESOURCE_FOOTPRINT& fp,
                       DXGI_FORMAT format)
{
    ReadbackStats s{};
    uint8_t* p = nullptr;
    D3D12_RANGE range{0, fp.Offset + (SIZE_T)fp.Footprint.RowPitch * kSide};
    if (FAILED(readback->Map(0, &range, (void**)&p))) return s;
    bool first = true;
    for (UINT y = 0; y < kSide; ++y) {
        const uint8_t* row = p + fp.Offset + (size_t)y * fp.Footprint.RowPitch;
        const size_t pitch = format == DXGI_FORMAT_R32G32_UINT ? kSide * 8ull : kSide * 4ull;
        hash_bytes(s, row, pitch);
        if (format == DXGI_FORMAT_R32G32_UINT) {
            const uint32_t* v = (const uint32_t*)row;
            for (UINT x = 0; x < kSide * 2; ++x) {
                if (v[x]) ++s.changed;
                const double d = (double)v[x];
                if (first) { s.min_value = s.max_value = d; first = false; }
                else { s.min_value = std::min(s.min_value, d); s.max_value = std::max(s.max_value, d); }
            }
        } else {
            const float* v = (const float*)row;
            for (UINT x = 0; x < kSide; ++x) {
                if (!std::isfinite(v[x])) ++s.nonfinite;
                if (v[x] != 0.f) ++s.changed;
                const double d = (double)v[x];
                if (first) { s.min_value = s.max_value = d; first = false; }
                else if (std::isfinite(d)) {
                    s.min_value = std::min(s.min_value, d);
                    s.max_value = std::max(s.max_value, d);
                }
            }
        }
    }
    D3D12_RANGE written{0, 0};
    readback->Unmap(0, &written);
    return s;
}

struct DrawResult {
    ReadbackStats target0, target1;
    D3D12_QUERY_DATA_PIPELINE_STATISTICS pipeline{};
    uint64_t stream_bytes = 0;
    std::array<std::array<float, 4>, 6> clip_positions{};
};

bool execute_draw(ID3D12Device* dev, ID3D12CommandQueue* queue,
                  ID3D12RootSignature* root, ID3D12PipelineState* pso,
                  const bf6_water_render& water,
                  const std::array<OwnedTexture, 5>& authored,
                  const std::array<std::array<float, 4>, 22>& material,
                  DrawResult& result, std::string& err)
{
    ComPtr<ID3D12CommandAllocator> alloc;
    ComPtr<ID3D12GraphicsCommandList> cl;
    HRESULT hr = dev->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,
                                             IID_PPV_ARGS(&alloc));
    if (FAILED(hr)) { err = hr_text(hr); return false; }
    hr = dev->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, alloc.Get(),
                                pso, IID_PPV_ARGS(&cl));
    if (FAILED(hr)) { err = hr_text(hr); return false; }

    // Scene cbuffer b0: exact known register positions, synthetic-neutral
    // values for the runtime-only view/tile producer.
    std::array<std::array<float, 4>, 45> cb0{};
    for (int r = 4; r <= 19; ++r) cb0[(size_t)r][0] = 1.0e10f;
    // CullViewPosition.w scales distance before the shader's logarithm.  Zero
    // produces -INF and can poison the clip position even with zero FFT input.
    cb0[20] = {0.f, 2.f, 0.f, 1.f};
    cb0[21] = {1.f, 1.f, 1.f / 512.f, 1.f / 64.f};
    cb0[22] = {1.f, 1.f, 1.f / 128.f, 1.f / 32.f};
    cb0[23] = {water.cascade_overlap_params[0], water.cascade_overlap_params[1],
               water.cascade_overlap_params[2], water.cascade_overlap_params[3]};
    cb0[24] = {water.cascade_overlap_params2[0], water.cascade_overlap_params2[1],
               water.cascade_overlap_params2[2], water.cascade_overlap_params2[3]};
    cb0[32] = {0.f, 0.f, 0.f, 1.f};
    for (int r = 33; r <= 36; ++r)
        cb0[(size_t)r] = {-1.f, std::max(0.f, water.wave_amplitude_scale), -1.f, 0.f};
    cb0[38] = {1.f, 1.f, 1.f, 1.f};
    cb0[39] = {0.f, 0.f, 1.f, 1.f};
    cb0[41] = {1.f, 1.f, 1.f, 1.f};
    cb0[42] = {(float)(water.cascade_overlap_enabled != 0),
               water.cascade_overlap_height_scale, 1.f, 0.f};
    cb0[44] = {1.f, 0.f, 0.f, 0.f};

    // Per-pass b4. The real shader consumes the view-projection around
    // registers 88..91, view origin near 99, graph time at 96 and bias at 100.
    std::array<std::array<float, 4>, 113> cb4{};
    cb4[88] = {1.f, 0.f, 0.f, 0.f};
    cb4[89] = {0.f, 0.f, 1.f, 0.f};
    cb4[90] = {0.f, 0.f, 0.f, 0.f};
    cb4[91] = {0.f, 0.f, 0.f, 1.f};
    cb4[96][0] = 1.f;
    cb4[99] = {0.f, 0.f, 0.f, 0.f};
    cb4[100][3] = 0.f;

    ComPtr<ID3D12Resource> b0, b1, b4;
    if (!upload_buffer(dev, cb0.data(), sizeof(cb0), b0, true) ||
        !upload_buffer(dev, material.data(), sizeof(material), b1, true) ||
        !upload_buffer(dev, cb4.data(), sizeof(cb4), b4, true)) {
        err = "constant-buffer allocation failed"; return false;
    }

    const float tiles[4] = {0.f, 0.f, 0.f, 1.f};
    const uint32_t base[1] = {0};
    const float vertices[16] = {
        -0.8f, 0.f, -0.8f, 1.f,  0.8f, 0.f, -0.8f, 1.f,
        -0.8f, 0.f,  0.8f, 1.f,  0.8f, 0.f,  0.8f, 1.f
    };
    const uint32_t indices[6] = {0, 1, 2, 2, 1, 3};
    std::array<float, 12> identity_transform{};
    identity_transform[0] = identity_transform[5] = identity_transform[10] = 1.f;
    ComPtr<ID3D12Resource> tile_buf, base_buf, vertex_buf, index_buf, uint_buf, transform_buf;
    if (!upload_buffer(dev, tiles, sizeof(tiles), tile_buf) ||
        !upload_buffer(dev, base, sizeof(base), base_buf) ||
        !upload_buffer(dev, vertices, sizeof(vertices), vertex_buf) ||
        !upload_buffer(dev, indices, sizeof(indices), index_buf) ||
        !upload_buffer(dev, base, sizeof(base), uint_buf) ||
        !upload_buffer(dev, identity_transform.data(), sizeof(identity_transform), transform_buf)) {
        err = "synthetic geometry allocation failed"; return false;
    }

    const float neutral[4] = {0.5f, 0.5f, 0.5f, 0.f};
    const float zero[4] = {0.f, 0.f, 0.f, 0.f};
    const uint32_t page[2] = {0x8000u, 0u};
    TinyTexture float_tex, zero_tex, uint2_tex, array_tex;
    if (!make_tiny_texture(dev, cl.Get(), DXGI_FORMAT_R32G32B32A32_FLOAT, 1,
                           neutral, sizeof(neutral), float_tex) ||
        !make_tiny_texture(dev, cl.Get(), DXGI_FORMAT_R32G32B32A32_FLOAT, 1,
                           zero, sizeof(zero), zero_tex) ||
        !make_tiny_texture(dev, cl.Get(), DXGI_FORMAT_R32G32_UINT, 1,
                           page, sizeof(page), uint2_tex) ||
        !make_tiny_texture(dev, cl.Get(), DXGI_FORMAT_R32_FLOAT, 1,
                           zero, sizeof(float), array_tex)) {
        err = "synthetic texture allocation failed"; return false;
    }
    std::array<TinyTexture, 5> authored_gpu;
    for (size_t i = 0; i < authored.size(); ++i)
        if (!make_authored_texture(dev, cl.Get(), authored[i], authored_gpu[i], err))
            return false;

    D3D12_DESCRIPTOR_HEAP_DESC shd{};
    shd.Type = D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
    shd.NumDescriptors = kSrvCount;
    shd.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
    ComPtr<ID3D12DescriptorHeap> srv_heap;
    if (FAILED(dev->CreateDescriptorHeap(&shd, IID_PPV_ARGS(&srv_heap)))) {
        err = "SRV heap creation failed"; return false;
    }
    const UINT inc = dev->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    D3D12_CPU_DESCRIPTOR_HANDLE h = srv_heap->GetCPUDescriptorHandleForHeapStart();
    for (UINT i = 0; i < kSrvCount; ++i) {
        D3D12_SHADER_RESOURCE_VIEW_DESC sd{};
        sd.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
        sd.Format = zero_tex.format;
        sd.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D;
        sd.Texture2D.MipLevels = 1;
        dev->CreateShaderResourceView(zero_tex.gpu.Get(), &sd, h);
        h.ptr += inc;
    }
    auto set_texture = [&](UINT slot, TinyTexture& tex, D3D12_SRV_DIMENSION dim) {
        D3D12_CPU_DESCRIPTOR_HANDLE q = srv_heap->GetCPUDescriptorHandleForHeapStart();
        q.ptr += (SIZE_T)slot * inc;
        D3D12_SHADER_RESOURCE_VIEW_DESC sd{};
        sd.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
        sd.Format = tex.format;
        sd.ViewDimension = dim;
        if (dim == D3D12_SRV_DIMENSION_TEXTURE2D) sd.Texture2D.MipLevels = tex.mip_count;
        else { sd.Texture2DArray.MipLevels = tex.mip_count; sd.Texture2DArray.ArraySize = tex.array_size; }
        dev->CreateShaderResourceView(tex.gpu.Get(), &sd, q);
    };
    auto set_buffer = [&](UINT slot, ID3D12Resource* resource, DXGI_FORMAT fmt,
                          UINT elements, UINT stride) {
        D3D12_CPU_DESCRIPTOR_HANDLE q = srv_heap->GetCPUDescriptorHandleForHeapStart();
        q.ptr += (SIZE_T)slot * inc;
        D3D12_SHADER_RESOURCE_VIEW_DESC sd{};
        sd.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
        sd.Format = fmt;
        sd.ViewDimension = D3D12_SRV_DIMENSION_BUFFER;
        sd.Buffer.NumElements = elements;
        sd.Buffer.StructureByteStride = stride;
        sd.Buffer.Flags = D3D12_BUFFER_SRV_FLAG_NONE;
        dev->CreateShaderResourceView(resource, &sd, q);
    };
    set_texture(5, uint2_tex, D3D12_SRV_DIMENSION_TEXTURE2D);
    set_texture(6, array_tex, D3D12_SRV_DIMENSION_TEXTURE2DARRAY);
    // Pixel-only surface/depth/region/material textures.  The FFT and
    // displacement slots t0..t18 intentionally remain exact zero controls.
    for (UINT slot = 23; slot < kSrvCount; ++slot)
        if (slot != 28 && slot != 29)
            set_texture(slot, float_tex, D3D12_SRV_DIMENSION_TEXTURE2D);
    for (UINT i = 0; i < authored_gpu.size(); ++i)
        set_texture(32 + i, authored_gpu[i], D3D12_SRV_DIMENSION_TEXTURE2D);
    set_buffer(19, tile_buf.Get(), DXGI_FORMAT_R32G32B32A32_FLOAT, 1, 0);
    set_buffer(20, base_buf.Get(), DXGI_FORMAT_R32_UINT, 1, 0);
    set_buffer(21, vertex_buf.Get(), DXGI_FORMAT_R32G32B32A32_FLOAT, 4, 0);
    set_buffer(22, index_buf.Get(), DXGI_FORMAT_R32_UINT, 6, 0);
    set_buffer(28, uint_buf.Get(), DXGI_FORMAT_R32_UINT, 1, 0);
    set_buffer(29, transform_buf.Get(), DXGI_FORMAT_UNKNOWN, 1, 48);

    ComPtr<ID3D12Resource> rt0, rt1;
    if (!make_rt(dev, DXGI_FORMAT_R32G32_UINT, rt0) ||
        !make_rt(dev, DXGI_FORMAT_R32_FLOAT, rt1)) {
        err = "render-target creation failed"; return false;
    }
    D3D12_DESCRIPTOR_HEAP_DESC rhd{};
    rhd.Type = D3D12_DESCRIPTOR_HEAP_TYPE_RTV;
    rhd.NumDescriptors = 2;
    ComPtr<ID3D12DescriptorHeap> rtv_heap;
    if (FAILED(dev->CreateDescriptorHeap(&rhd, IID_PPV_ARGS(&rtv_heap)))) {
        err = "RTV heap creation failed"; return false;
    }
    const UINT rinc = dev->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
    D3D12_CPU_DESCRIPTOR_HANDLE rtv[2] = {rtv_heap->GetCPUDescriptorHandleForHeapStart(), {}};
    rtv[1] = rtv[0]; rtv[1].ptr += rinc;
    dev->CreateRenderTargetView(rt0.Get(), nullptr, rtv[0]);
    dev->CreateRenderTargetView(rt1.Get(), nullptr, rtv[1]);

    D3D12_QUERY_HEAP_DESC qhd{};
    qhd.Type = D3D12_QUERY_HEAP_TYPE_PIPELINE_STATISTICS;
    qhd.Count = 1;
    ComPtr<ID3D12QueryHeap> query_heap;
    if (FAILED(dev->CreateQueryHeap(&qhd, IID_PPV_ARGS(&query_heap)))) {
        err = "pipeline-statistics query creation failed"; return false;
    }
    ComPtr<ID3D12Resource> query_readback;
    D3D12_HEAP_PROPERTIES qrhp = heap_props(D3D12_HEAP_TYPE_READBACK);
    D3D12_RESOURCE_DESC qrbd = buffer_desc(sizeof(D3D12_QUERY_DATA_PIPELINE_STATISTICS));
    if (FAILED(dev->CreateCommittedResource(&qrhp, D3D12_HEAP_FLAG_NONE, &qrbd,
        D3D12_RESOURCE_STATE_COPY_DEST, nullptr, IID_PPV_ARGS(&query_readback)))) {
        err = "pipeline-statistics readback creation failed"; return false;
    }

    D3D12_HEAP_PROPERTIES default_hp = heap_props(D3D12_HEAP_TYPE_DEFAULT);
    D3D12_RESOURCE_DESC sobd = buffer_desc(256);
    ComPtr<ID3D12Resource> so_buffer;
    if (FAILED(dev->CreateCommittedResource(&default_hp, D3D12_HEAP_FLAG_NONE, &sobd,
        D3D12_RESOURCE_STATE_STREAM_OUT, nullptr, IID_PPV_ARGS(&so_buffer)))) {
        err = "stream-output buffer creation failed"; return false;
    }
    D3D12_RESOURCE_DESC socd = buffer_desc(8);
    ComPtr<ID3D12Resource> so_counter;
    if (FAILED(dev->CreateCommittedResource(&default_hp, D3D12_HEAP_FLAG_NONE, &socd,
        D3D12_RESOURCE_STATE_COPY_DEST, nullptr, IID_PPV_ARGS(&so_counter)))) {
        err = "stream-output counter creation failed"; return false;
    }
    const uint64_t counter_zero = 0;
    ComPtr<ID3D12Resource> counter_upload;
    if (!upload_buffer(dev, &counter_zero, sizeof(counter_zero), counter_upload)) {
        err = "stream-output counter upload failed"; return false;
    }
    cl->CopyBufferRegion(so_counter.Get(), 0, counter_upload.Get(), 0, 8);
    transition(cl.Get(), so_counter.Get(), D3D12_RESOURCE_STATE_COPY_DEST,
               D3D12_RESOURCE_STATE_STREAM_OUT);
    D3D12_STREAM_OUTPUT_BUFFER_VIEW so_view{};
    so_view.BufferLocation = so_buffer->GetGPUVirtualAddress();
    so_view.SizeInBytes = 256;
    so_view.BufferFilledSizeLocation = so_counter->GetGPUVirtualAddress();

    const float clear[4] = {0.f, 0.f, 0.f, 0.f};
    cl->ClearRenderTargetView(rtv[0], clear, 0, nullptr);
    cl->ClearRenderTargetView(rtv[1], clear, 0, nullptr);
    cl->SetPipelineState(pso);
    cl->SetGraphicsRootSignature(root);
    ID3D12DescriptorHeap* heaps[] = {srv_heap.Get()};
    cl->SetDescriptorHeaps(1, heaps);
    cl->SetGraphicsRootConstantBufferView(0, b0->GetGPUVirtualAddress());
    cl->SetGraphicsRootConstantBufferView(1, b1->GetGPUVirtualAddress());
    cl->SetGraphicsRootConstantBufferView(2, b4->GetGPUVirtualAddress());
    cl->SetGraphicsRootDescriptorTable(3, srv_heap->GetGPUDescriptorHandleForHeapStart());
    D3D12_VIEWPORT vp{0.f, 0.f, (float)kSide, (float)kSide, 0.f, 1.f};
    D3D12_RECT sc{0, 0, (LONG)kSide, (LONG)kSide};
    cl->RSSetViewports(1, &vp);
    cl->RSSetScissorRects(1, &sc);
    cl->OMSetRenderTargets(2, rtv, FALSE, nullptr);
    cl->SOSetTargets(0, 1, &so_view);
    cl->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    cl->BeginQuery(query_heap.Get(), D3D12_QUERY_TYPE_PIPELINE_STATISTICS, 0);
    cl->DrawInstanced(6, 1, 0, 0);
    cl->EndQuery(query_heap.Get(), D3D12_QUERY_TYPE_PIPELINE_STATISTICS, 0);
    cl->ResolveQueryData(query_heap.Get(), D3D12_QUERY_TYPE_PIPELINE_STATISTICS,
                         0, 1, query_readback.Get(), 0);
    transition(cl.Get(), so_buffer.Get(), D3D12_RESOURCE_STATE_STREAM_OUT,
               D3D12_RESOURCE_STATE_COPY_SOURCE);
    transition(cl.Get(), so_counter.Get(), D3D12_RESOURCE_STATE_STREAM_OUT,
               D3D12_RESOURCE_STATE_COPY_SOURCE);
    transition(cl.Get(), rt0.Get(), D3D12_RESOURCE_STATE_RENDER_TARGET,
               D3D12_RESOURCE_STATE_COPY_SOURCE);
    transition(cl.Get(), rt1.Get(), D3D12_RESOURCE_STATE_RENDER_TARGET,
               D3D12_RESOURCE_STATE_COPY_SOURCE);

    ComPtr<ID3D12Resource> rb0, rb1;
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT fp0{}, fp1{};
    UINT rows0 = 0, rows1 = 0; UINT64 total0 = 0, total1 = 0;
    if (!read_rt(dev, cl.Get(), rt0.Get(), DXGI_FORMAT_R32G32_UINT,
                 rb0, fp0, rows0, total0) ||
        !read_rt(dev, cl.Get(), rt1.Get(), DXGI_FORMAT_R32_FLOAT,
                 rb1, fp1, rows1, total1)) {
        err = "readback allocation failed"; return false;
    }
    D3D12_HEAP_PROPERTIES rbhp = heap_props(D3D12_HEAP_TYPE_READBACK);
    ComPtr<ID3D12Resource> so_readback, counter_readback;
    D3D12_RESOURCE_DESC sorbd = buffer_desc(256);
    D3D12_RESOURCE_DESC corbd = buffer_desc(8);
    if (FAILED(dev->CreateCommittedResource(&rbhp, D3D12_HEAP_FLAG_NONE, &sorbd,
            D3D12_RESOURCE_STATE_COPY_DEST, nullptr, IID_PPV_ARGS(&so_readback))) ||
        FAILED(dev->CreateCommittedResource(&rbhp, D3D12_HEAP_FLAG_NONE, &corbd,
            D3D12_RESOURCE_STATE_COPY_DEST, nullptr, IID_PPV_ARGS(&counter_readback)))) {
        err = "stream-output readback creation failed"; return false;
    }
    cl->CopyBufferRegion(so_readback.Get(), 0, so_buffer.Get(), 0, 256);
    cl->CopyBufferRegion(counter_readback.Get(), 0, so_counter.Get(), 0, 8);
    hr = cl->Close();
    if (FAILED(hr)) { err = hr_text(hr); return false; }
    ID3D12CommandList* lists[] = {cl.Get()};
    queue->ExecuteCommandLists(1, lists);
    ComPtr<ID3D12Fence> fence;
    if (FAILED(dev->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&fence)))) {
        err = "fence creation failed"; return false;
    }
    HANDLE event_handle = CreateEvent(nullptr, FALSE, FALSE, nullptr);
    if (!event_handle) { err = "event creation failed"; return false; }
    queue->Signal(fence.Get(), 1);
    fence->SetEventOnCompletion(1, event_handle);
    WaitForSingleObject(event_handle, INFINITE);
    CloseHandle(event_handle);

    const HRESULT removed = dev->GetDeviceRemovedReason();
    if (FAILED(removed)) { err = "device removed: " + hr_text(removed); return false; }
    result.target0 = stats_rt(rb0.Get(), fp0, DXGI_FORMAT_R32G32_UINT);
    result.target1 = stats_rt(rb1.Get(), fp1, DXGI_FORMAT_R32_FLOAT);
    D3D12_QUERY_DATA_PIPELINE_STATISTICS* qs = nullptr;
    D3D12_RANGE qrange{0, sizeof(D3D12_QUERY_DATA_PIPELINE_STATISTICS)};
    if (SUCCEEDED(query_readback->Map(0, &qrange, (void**)&qs)) && qs) {
        result.pipeline = *qs;
        D3D12_RANGE none{0, 0};
        query_readback->Unmap(0, &none);
    }
    uint64_t* filled = nullptr;
    D3D12_RANGE crange{0, 8};
    if (SUCCEEDED(counter_readback->Map(0, &crange, (void**)&filled)) && filled) {
        result.stream_bytes = *filled;
        D3D12_RANGE none{0, 0};
        counter_readback->Unmap(0, &none);
    }
    float* positions = nullptr;
    D3D12_RANGE sorange{0, 256};
    if (SUCCEEDED(so_readback->Map(0, &sorange, (void**)&positions)) && positions) {
        const size_t count = std::min<size_t>(6, (size_t)result.stream_bytes / 16);
        for (size_t i = 0; i < count; ++i)
            for (size_t c = 0; c < 4; ++c)
                result.clip_positions[i][c] = positions[i * 4 + c];
        D3D12_RANGE none{0, 0};
        so_readback->Unmap(0, &none);
    }
    return true;
}

} // namespace

int main(int argc, char** argv)
{
    if (argc < 3) {
        std::fprintf(stderr, "usage: waterdraw_test <game_dir> <level> [--debug-layer]\n");
        return 2;
    }
    bool debug_layer = false;
    for (int i = 3; i < argc; ++i) {
        if (!std::strcmp(argv[i], "--debug-layer")) debug_layer = true;
        else { std::fprintf(stderr, "unknown option: %s\n", argv[i]); return 2; }
    }
    if (debug_layer) {
        ComPtr<ID3D12Debug> debug;
        if (SUCCEEDED(D3D12GetDebugInterface(IID_PPV_ARGS(&debug)))) debug->EnableDebugLayer();
    }

    char error[512]{};
    bf6_ctx* core = bf6_open(argv[1], error, (int)sizeof(error));
    if (!core || bf6_open_level(core, argv[2], nullptr, 0, error, (int)sizeof(error))) {
        std::fprintf(stderr, "core open: %s\n", error);
        if (core) bf6_close(core);
        return 1;
    }
    const int count = bf6_level_water_render(core, argv[2], nullptr, 0);
    std::vector<bf6_water_render> waters(count > 0 ? (size_t)count : 0);
    if (count > 0) bf6_level_water_render(core, argv[2], waters.data(), count);
    if (waters.empty()) {
        std::fprintf(stderr, "no water render record for %s\n", argv[2]);
        bf6_close(core);
        return 1;
    }
    const bf6_water_render* selected = &waters[0];
    for (const auto& w : waters)
        if (w.variant == 1 && w.extended_graph_version) { selected = &w; break; }
    const bf6_water_render water = *selected;
    const int texture_ids[5] = {water.noise, water.contact_foam, water.foam_rgb2,
                                water.detail_normal, water.foam_normal};
    const char* texture_slots[5] = {"noise", "contact_foam", "foam_rgb2",
                                    "detail_normal", "foam_normal"};
    std::array<OwnedTexture, 5> authored;
    for (size_t i = 0; i < authored.size(); ++i) {
        const bf6_texture* t = texture_ids[i] >= 0 ? bf6_texture_at(core, texture_ids[i]) : nullptr;
        if (!t || !t->data || t->data_len <= 0) {
            std::fprintf(stderr, "required live material texture %s is unavailable\n",
                         texture_slots[i]);
            bf6_close(core);
            return 1;
        }
        authored[i].width = t->width;
        authored[i].height = t->height;
        authored[i].mip_count = t->mip_count;
        authored[i].format = t->format;
        authored[i].srgb = t->srgb;
        authored[i].data.assign(t->data, t->data + t->data_len);
        std::printf("TEXTURE slot=t%zu name=%s id=%d size=%dx%d mips=%d format=%d bytes=%d\n",
            i + 32, texture_slots[i], texture_ids[i], t->width, t->height,
            t->mip_count, (int)t->format, t->data_len);
    }
    bf6_close(core);

    const std::string vs_guid = guid_net(water.selected_pass0_vertex_guid);
    const std::string ps_guid = guid_net(water.selected_pass0_pixel_guid);
    std::printf("MODE synthetic_neutral_scene_resources live_game_shaders=1 live_material_cb=1 live_material_textures=1\n");
    std::printf("WATER state_key=%016llx variant=%d extended_graph_version=%u overlap_version=%u\n",
        (unsigned long long)water.state_key, water.variant,
        water.extended_graph_version, water.cascade_overlap_version);
    std::printf("SELECTED vs=%s ps=%s\n", vs_guid.c_str(), ps_guid.c_str());

    Source src;
    std::string err;
    if (!src.open(argv[1], err) || !src.mount_level(argv[2], false, err)) {
        std::fprintf(stderr, "mount: %s\n", err.c_str()); return 1;
    }
    std::vector<uint8_t> ignored, vs, ps;
    std::string resource, fake_err;
    const bool fake = live_container(src, "00000000-0000-0000-0000-000000000000",
                                     ignored, resource, fake_err);
    std::printf("CONTROL fake_guid_found=%d expected=0\n", fake ? 1 : 0);
    std::string vs_res, ps_res;
    if (!live_container(src, vs_guid, vs, vs_res, err)) {
        std::fprintf(stderr, "vertex shader: %s\n", err.c_str()); return 1;
    }
    if (!live_container(src, ps_guid, ps, ps_res, err)) {
        std::fprintf(stderr, "pixel shader: %s\n", err.c_str()); return 1;
    }
    std::printf("SHADER vertex bytes=%zu resource=%s\n", vs.size(), vs_res.c_str());
    std::printf("SHADER pixel bytes=%zu resource=%s\n", ps.size(), ps_res.c_str());

    ComPtr<ID3D12Device> dev;
    HRESULT hr = D3D12CreateDevice(nullptr, D3D_FEATURE_LEVEL_12_0,
                                   IID_PPV_ARGS(&dev));
    if (FAILED(hr)) { std::fprintf(stderr, "D3D12CreateDevice: %s\n", hr_text(hr).c_str()); return 1; }
    ComPtr<ID3D12RootSignature> root;
    if (!make_root(dev.Get(), root, err)) {
        std::fprintf(stderr, "root signature: %s\n", err.c_str()); return 1;
    }
    ComPtr<ID3D12PipelineState> pso;
    if (!make_pso(dev.Get(), root.Get(), vs, ps, pso, err)) {
        std::fprintf(stderr, "graphics PSO: %s\n", err.c_str()); return 1;
    }
    std::printf("PSO live_selected_water=PASS\n");

    D3D12_COMMAND_QUEUE_DESC qd{};
    qd.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
    ComPtr<ID3D12CommandQueue> queue;
    if (FAILED(dev->CreateCommandQueue(&qd, IID_PPV_ARGS(&queue)))) {
        std::fprintf(stderr, "command queue creation failed\n"); return 1;
    }
    std::array<std::array<float, 4>, 22> real{};
    std::memcpy(real.data(), water.extended_cb1, sizeof(real));
    std::array<std::array<float, 4>, 22> shuffled = real;
    std::reverse(shuffled.begin(), shuffled.end());
    DrawResult actual, control;
    if (!execute_draw(dev.Get(), queue.Get(), root.Get(), pso.Get(), water, authored,
                      real, actual, err)) {
        std::fprintf(stderr, "live-cbuffer draw: %s\n", err.c_str()); return 1;
    }
    if (!execute_draw(dev.Get(), queue.Get(), root.Get(), pso.Get(), water, authored,
                      shuffled, control, err)) {
        std::fprintf(stderr, "shuffled-cbuffer draw: %s\n", err.c_str()); return 1;
    }
    std::printf("DRAW target0 changed=%llu hash=%016llx range=%.0f..%.0f\n",
        (unsigned long long)actual.target0.changed,
        (unsigned long long)actual.target0.hash,
        actual.target0.min_value, actual.target0.max_value);
    std::printf("DRAW target1 changed=%llu hash=%016llx range=%.9g..%.9g nonfinite=%llu\n",
        (unsigned long long)actual.target1.changed,
        (unsigned long long)actual.target1.hash,
        actual.target1.min_value, actual.target1.max_value,
        (unsigned long long)actual.target1.nonfinite);
    std::printf("DRAW pipeline ia_vertices=%llu vs=%llu primitives=%llu ps=%llu\n",
        (unsigned long long)actual.pipeline.IAVertices,
        (unsigned long long)actual.pipeline.VSInvocations,
        (unsigned long long)actual.pipeline.CInvocations,
        (unsigned long long)actual.pipeline.PSInvocations);
    std::printf("DRAW stream_bytes=%llu clip0=(%.9g,%.9g,%.9g,%.9g) clip5=(%.9g,%.9g,%.9g,%.9g)\n",
        (unsigned long long)actual.stream_bytes,
        actual.clip_positions[0][0], actual.clip_positions[0][1],
        actual.clip_positions[0][2], actual.clip_positions[0][3],
        actual.clip_positions[5][0], actual.clip_positions[5][1],
        actual.clip_positions[5][2], actual.clip_positions[5][3]);
    std::printf("CONTROL shuffled_cb target0_hash=%016llx target1_hash=%016llx distinct=%d\n",
        (unsigned long long)control.target0.hash,
        (unsigned long long)control.target1.hash,
        (actual.target0.hash != control.target0.hash ||
         actual.target1.hash != control.target1.hash) ? 1 : 0);
    const bool finite = actual.target0.nonfinite == 0 && actual.target1.nonfinite == 0;
    const bool wrote = actual.target0.changed || actual.target1.changed;
    std::printf("RESULT pso=1 executed=1 finite=%d wrote_pixels=%d exact_visual_parity=0\n",
                finite ? 1 : 0, wrote ? 1 : 0);
    std::printf("MISSING live_fft_srv_slots live_depth_region_inputs live_tile_producer deferred_composite\n");
    return fake || !finite ? 1 : 0;
}
