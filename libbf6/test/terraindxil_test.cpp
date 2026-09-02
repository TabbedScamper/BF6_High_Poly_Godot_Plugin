/* terraindxil_test - prove that the installed game's terrain evaluator can be
 * executed directly instead of approximated with a hand-written material.
 *
 * This is deliberately a research harness, not a runtime exporter.  It mounts
 * the user's game, finds CompiledBytecode by its live resource GUID, strips the
 * Frostbite wrapper, and asks D3D12 to create a compute PSO from that exact
 * container.  No dumped DXBC is consumed.
 *
 * Controls:
 *   - a fake GUID must resolve no resource;
 *   - the real shader with a deliberately incomplete root signature must be
 *     rejected;
 *   - the full binding contract must create a PSO.
 *
 *   terraindxil_test <game_dir> <level> [bytecode_guid]
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d12.h>
#include <wrl/client.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "source.h"
#include "terrainshader.h"

using Microsoft::WRL::ComPtr;
using namespace bf6;

namespace {

uint32_t rd32(const std::vector<uint8_t>& d, size_t o)
{
    uint32_t v = 0;
    if (o + sizeof(v) <= d.size()) std::memcpy(&v, d.data() + o, sizeof(v));
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

bool live_container(Source& src, const std::string& guid,
                    std::vector<uint8_t>& out, std::string& resource,
                    std::string& err)
{
    const std::string needle = lower(guid);
    for (const auto& kv : src.res())
    {
        const std::string n = lower(kv.first);
        if (n.find("bytecode") == std::string::npos ||
            n.find(needle) == std::string::npos) continue;
        std::vector<uint8_t> wrapped = src.get_res(kv.first, err);
        if (wrapped.empty()) continue;
        size_t at = std::string::npos;
        for (size_t o = 0; o + 4 <= wrapped.size() && o < 8192; ++o)
            if (!std::memcmp(wrapped.data() + o, "DXBC", 4)) { at = o; break; }
        if (at == std::string::npos || at + 0x20 > wrapped.size())
        { err = "resource has no DXBC container"; return false; }
        const uint32_t bytes = rd32(wrapped, at + 0x18);
        if (bytes < 0x20 || at + bytes > wrapped.size())
        { err = "DXBC container size is outside its resource"; return false; }
        out.assign(wrapped.begin() + at, wrapped.begin() + at + bytes);
        resource = kv.first;
        return true;
    }
    err = "no mounted CompiledBytecode resource contains GUID " + guid;
    return false;
}

bool make_root(ID3D12Device* dev, bool full,
               ComPtr<ID3D12RootSignature>& root, std::string& err)
{
    // Full shipped contract read from the container's PSV/RDAT metadata:
    // cb0..1; t0..102 space0; t0[] space1; u0..7; s0..7.
    D3D12_DESCRIPTOR_RANGE ranges[4] = {};
    ranges[0] = { D3D12_DESCRIPTOR_RANGE_TYPE_CBV, full ? 2u : 1u, 0, 0,
                  D3D12_DESCRIPTOR_RANGE_OFFSET_APPEND };
    ranges[1] = { D3D12_DESCRIPTOR_RANGE_TYPE_SRV, 103, 0, 0,
                  D3D12_DESCRIPTOR_RANGE_OFFSET_APPEND };
    ranges[2] = { D3D12_DESCRIPTOR_RANGE_TYPE_SRV, UINT_MAX, 0, 1,
                  D3D12_DESCRIPTOR_RANGE_OFFSET_APPEND };
    ranges[3] = { D3D12_DESCRIPTOR_RANGE_TYPE_UAV, 8, 0, 0,
                  D3D12_DESCRIPTOR_RANGE_OFFSET_APPEND };

    D3D12_ROOT_PARAMETER params[4] = {};
    const UINT nparams = full ? 4u : 1u;
    for (UINT i = 0; i < nparams; ++i)
    {
        params[i].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
        params[i].DescriptorTable.NumDescriptorRanges = 1;
        params[i].DescriptorTable.pDescriptorRanges = &ranges[i];
        params[i].ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
    }

    D3D12_STATIC_SAMPLER_DESC samplers[8] = {};
    for (UINT i = 0; i < 8; ++i)
    {
        D3D12_STATIC_SAMPLER_DESC& s = samplers[i];
        s.Filter = D3D12_FILTER_MIN_MAG_MIP_LINEAR;
        s.AddressU = s.AddressV = s.AddressW = D3D12_TEXTURE_ADDRESS_MODE_WRAP;
        s.MipLODBias = 0;
        s.MaxAnisotropy = 1;
        s.ComparisonFunc = D3D12_COMPARISON_FUNC_ALWAYS;
        s.BorderColor = D3D12_STATIC_BORDER_COLOR_TRANSPARENT_BLACK;
        s.MinLOD = 0;
        s.MaxLOD = D3D12_FLOAT32_MAX;
        s.ShaderRegister = i;
        s.RegisterSpace = 0;
        s.ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
    }

    D3D12_ROOT_SIGNATURE_DESC desc = {};
    desc.NumParameters = nparams;
    desc.pParameters = params;
    desc.NumStaticSamplers = full ? 8u : 0u;
    desc.pStaticSamplers = full ? samplers : nullptr;
    desc.Flags = D3D12_ROOT_SIGNATURE_FLAG_NONE;

    ComPtr<ID3DBlob> blob, errors;
    HRESULT hr = D3D12SerializeRootSignature(&desc, D3D_ROOT_SIGNATURE_VERSION_1,
                                             &blob, &errors);
    if (FAILED(hr))
    {
        err = errors ? std::string((const char*)errors->GetBufferPointer(),
                                   errors->GetBufferSize()) : hr_text(hr);
        return false;
    }
    hr = dev->CreateRootSignature(0, blob->GetBufferPointer(), blob->GetBufferSize(),
                                  IID_PPV_ARGS(&root));
    if (FAILED(hr)) { err = hr_text(hr); return false; }
    return true;
}

HRESULT make_pso(ID3D12Device* dev, ID3D12RootSignature* root,
                 const std::vector<uint8_t>& shader,
                 ComPtr<ID3D12PipelineState>& pso)
{
    D3D12_COMPUTE_PIPELINE_STATE_DESC p = {};
    p.pRootSignature = root;
    p.CS = { shader.data(), shader.size() };
    return dev->CreateComputePipelineState(&p, IID_PPV_ARGS(&pso));
}

} // namespace

int main(int argc, char** argv)
{
    if (argc < 3)
    {
        std::fprintf(stderr, "usage: terraindxil_test <game_dir> <level> [bytecode_guid]\n");
        return 2;
    }
    const std::string real_guid = argc > 3 ? argv[3] : std::string();

    Source src;
    std::string err;
    if (!src.open(argv[1], err))
    { std::fprintf(stderr, "open: %s\n", err.c_str()); return 1; }
    if (!src.mount_level(argv[2], false, err))
    { std::fprintf(stderr, "mount: %s\n", err.c_str()); return 1; }

    std::vector<uint8_t> ignored;
    std::string ignored_res, fake_err;
    const bool fake_found = live_container(src,
        "00000000-0000-0000-0000-000000000000", ignored, ignored_res, fake_err);
    std::printf("control fake GUID: %s (%s)\n", fake_found ? "FAIL" : "PASS",
                fake_found ? ignored_res.c_str() : fake_err.c_str());

    std::vector<uint8_t> shader;
    std::string resource;
    std::string resolved_guid = real_guid;
    if (real_guid.empty()) {
        TerrainShaderProgram program;
        if (!load_terrain_shader(src, argv[2], program, err))
        { std::fprintf(stderr, "live terrain shader walk: %s\n", err.c_str()); return 1; }
        shader = program.bytecode;
        resource = program.bytecode_resource;
        resolved_guid = program.bytecode_guid;
        std::printf("live read path: permutation %llu, shared %llu, row %u bytes\n",
            (unsigned long long)program.permutation_id,
            (unsigned long long)program.shared_data_id,
            program.layer_row_stride());
    } else if (!live_container(src, real_guid, shader, resource, err)) {
        std::fprintf(stderr, "real shader: %s\n", err.c_str()); return 1;
    }
    std::printf("live shader: %s, %zu-byte DXBC/DXIL container\n",
                resource.c_str(), shader.size());

    ComPtr<ID3D12Device> dev;
    HRESULT hr = D3D12CreateDevice(nullptr, D3D_FEATURE_LEVEL_12_0,
                                   IID_PPV_ARGS(&dev));
    if (FAILED(hr))
    { std::fprintf(stderr, "D3D12CreateDevice: %s\n", hr_text(hr).c_str()); return 1; }

    D3D12_FEATURE_DATA_D3D12_OPTIONS1 opts = {};
    hr = dev->CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS1, &opts, sizeof(opts));
    if (FAILED(hr) || !opts.WaveOps)
    { std::fprintf(stderr, "device does not support the evaluator's wave operations\n"); return 1; }
    std::printf("device wave ops: PASS (lane min %u, max %u)\n",
                opts.WaveLaneCountMin, opts.WaveLaneCountMax);

    ComPtr<ID3D12RootSignature> short_root;
    if (!make_root(dev.Get(), false, short_root, err))
    { std::fprintf(stderr, "short root: %s\n", err.c_str()); return 1; }
    ComPtr<ID3D12PipelineState> short_pso;
    const HRESULT short_hr = make_pso(dev.Get(), short_root.Get(), shader, short_pso);
    std::printf("control incomplete binding contract: %s (HRESULT 0x%08lx)\n",
                FAILED(short_hr) ? "PASS/rejected" : "FAIL/accepted", (unsigned long)short_hr);

    ComPtr<ID3D12RootSignature> full_root;
    if (!make_root(dev.Get(), true, full_root, err))
    { std::fprintf(stderr, "full root: %s\n", err.c_str()); return 1; }
    ComPtr<ID3D12PipelineState> pso;
    hr = make_pso(dev.Get(), full_root.Get(), shader, pso);
    if (FAILED(hr))
    {
        std::fprintf(stderr, "real shader + full binding contract: FAIL 0x%08lx: %s\n",
                     (unsigned long)hr, hr_text(hr).c_str());
        return 1;
    }
    std::printf("real shader + full binding contract: PASS\n");
    return fake_found || SUCCEEDED(short_hr) ? 1 : 0;
}
