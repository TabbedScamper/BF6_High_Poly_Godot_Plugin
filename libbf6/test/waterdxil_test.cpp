/* Execute BF6's shipped ocean compute chain against H0 read from the current
 * installed game. This is a research oracle, never a runtime data exporter.
 *
 * waterdxil_test <game_dir> <level> [--zero] [--all]
 *
 * The N=128 path used by MP_Isolated's strongest current cascade is:
 *   shipped Dispersion -> shipped positive column FFT -> shipped positive
 *   real-output row FFT -> shipped half4 Merge.
 * Every shader is read from the mounted install. The GUIDs are locators for
 * the current build and failure is loud; no dumped DXBC is consumed.
 */
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <d3d12.h>
#include <wrl/client.h>

#include <algorithm>
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

constexpr const char* kDispersion = "9e132eef-0f4f-5264-0348-9423c38cc6ce";
constexpr const char* kFftColumnInverse = "ec29cb5a-a06d-f031-91bf-63983b82e10d";
constexpr const char* kFftRowInverseReal = "4e3cfd7c-646c-c2d8-c538-fe1b8a8de8fb";
constexpr const char* kMerge = "bcf63891-56a1-2011-be38-defc092d7074";

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
            err = "resource has no DXBC/DXIL container"; return false;
        }
        const uint32_t bytes = rd32(wrapped, at + 0x18);
        if (bytes < 0x20 || at + bytes > wrapped.size()) {
            err = "DXBC/DXIL size is outside wrapper"; return false;
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
    h.CPUPageProperty = D3D12_CPU_PAGE_PROPERTY_UNKNOWN;
    h.MemoryPoolPreference = D3D12_MEMORY_POOL_UNKNOWN;
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

D3D12_RESOURCE_DESC texture_desc(UINT n, DXGI_FORMAT format,
                                 D3D12_RESOURCE_FLAGS flags)
{
    D3D12_RESOURCE_DESC d{};
    d.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    d.Width = n; d.Height = n;
    d.DepthOrArraySize = d.MipLevels = 1;
    d.Format = format;
    d.SampleDesc.Count = 1;
    d.Layout = D3D12_TEXTURE_LAYOUT_UNKNOWN;
    d.Flags = flags;
    return d;
}

void transition(ID3D12GraphicsCommandList* cl, ID3D12Resource* resource,
                D3D12_RESOURCE_STATES before, D3D12_RESOURCE_STATES after)
{
    D3D12_RESOURCE_BARRIER b{};
    b.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    b.Transition.pResource = resource;
    b.Transition.StateBefore = before;
    b.Transition.StateAfter = after;
    b.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    cl->ResourceBarrier(1, &b);
}

void uav_barrier(ID3D12GraphicsCommandList* cl, ID3D12Resource* resource)
{
    D3D12_RESOURCE_BARRIER b{};
    b.Type = D3D12_RESOURCE_BARRIER_TYPE_UAV;
    b.UAV.pResource = resource;
    cl->ResourceBarrier(1, &b);
}

float half_to_float(uint16_t h)
{
    const uint32_t sign = (uint32_t)(h & 0x8000u) << 16;
    uint32_t exp = (h >> 10) & 31u;
    uint32_t mant = h & 1023u;
    uint32_t bits;
    if (!exp) {
        if (!mant) bits = sign;
        else {
            exp = 113;
            while (!(mant & 1024u)) { mant <<= 1; --exp; }
            bits = sign | (exp << 23) | ((mant & 1023u) << 13);
        }
    } else if (exp == 31) bits = sign | 0x7f800000u | (mant << 13);
    else bits = sign | ((exp + 112u) << 23) | (mant << 13);
    float f;
    std::memcpy(&f, &bits, 4);
    return f;
}

struct ShaderSet {
    std::vector<uint8_t> dispersion, col, row, merge;
};

bool make_root(ID3D12Device* dev, ComPtr<ID3D12RootSignature>& root,
               std::string& err)
{
    D3D12_DESCRIPTOR_RANGE ranges[3]{};
    ranges[0] = {D3D12_DESCRIPTOR_RANGE_TYPE_CBV, 1, 0, 0,
                 D3D12_DESCRIPTOR_RANGE_OFFSET_APPEND};
    ranges[1] = {D3D12_DESCRIPTOR_RANGE_TYPE_SRV, 3, 0, 0,
                 D3D12_DESCRIPTOR_RANGE_OFFSET_APPEND};
    ranges[2] = {D3D12_DESCRIPTOR_RANGE_TYPE_UAV, 3, 0, 0,
                 D3D12_DESCRIPTOR_RANGE_OFFSET_APPEND};
    D3D12_ROOT_PARAMETER params[3]{};
    for (UINT i = 0; i < 3; ++i) {
        params[i].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
        params[i].DescriptorTable.NumDescriptorRanges = 1;
        params[i].DescriptorTable.pDescriptorRanges = &ranges[i];
        params[i].ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
    }
    D3D12_ROOT_SIGNATURE_DESC d{};
    d.NumParameters = 3; d.pParameters = params;
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
              const std::vector<uint8_t>& shader,
              ComPtr<ID3D12PipelineState>& out, std::string& err)
{
    D3D12_COMPUTE_PIPELINE_STATE_DESC d{};
    d.pRootSignature = root;
    d.CS = {shader.data(), shader.size()};
    const HRESULT hr = dev->CreateComputePipelineState(&d, IID_PPV_ARGS(&out));
    if (FAILED(hr)) { err = hr_text(hr); return false; }
    return true;
}

struct GpuResult {
    std::vector<float> rgba;
    std::string adapter;
};

bool execute(ID3D12Device* dev, const ShaderSet& shaders, int n, float tile,
             const std::vector<float>& h0, GpuResult& result, std::string& err)
{
    ComPtr<ID3D12RootSignature> root;
    if (!make_root(dev, root, err)) return false;
    ComPtr<ID3D12PipelineState> pDisp, pCol, pRow, pMerge;
    if (!make_pso(dev, root.Get(), shaders.dispersion, pDisp, err) ||
        !make_pso(dev, root.Get(), shaders.col, pCol, err) ||
        !make_pso(dev, root.Get(), shaders.row, pRow, err) ||
        !make_pso(dev, root.Get(), shaders.merge, pMerge, err)) return false;

    ComPtr<ID3D12CommandQueue> queue;
    D3D12_COMMAND_QUEUE_DESC qd{};
    if (FAILED(dev->CreateCommandQueue(&qd, IID_PPV_ARGS(&queue)))) {
        err = "CreateCommandQueue"; return false;
    }
    ComPtr<ID3D12CommandAllocator> alloc;
    ComPtr<ID3D12GraphicsCommandList> cl;
    if (FAILED(dev->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,
                                            IID_PPV_ARGS(&alloc))) ||
        FAILED(dev->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT,
                                      alloc.Get(), nullptr, IID_PPV_ARGS(&cl)))) {
        err = "create command list"; return false;
    }

    const auto hpDefault = heap_props(D3D12_HEAP_TYPE_DEFAULT);
    const auto hpUpload = heap_props(D3D12_HEAP_TYPE_UPLOAD);
    const auto hpRead = heap_props(D3D12_HEAP_TYPE_READBACK);
    const D3D12_RESOURCE_DESC rg = texture_desc((UINT)n, DXGI_FORMAT_R32G32_FLOAT,
                                                D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    const D3D12_RESOURCE_DESC half4 = texture_desc((UINT)n,
        DXGI_FORMAT_R16G16B16A16_FLOAT, D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    ComPtr<ID3D12Resource> input, spec[3], tmp[3], spatial[3], merged;
    D3D12_RESOURCE_DESC inputDesc = rg; inputDesc.Flags = D3D12_RESOURCE_FLAG_NONE;
    if (FAILED(dev->CreateCommittedResource(&hpDefault, D3D12_HEAP_FLAG_NONE,
            &inputDesc, D3D12_RESOURCE_STATE_COPY_DEST, nullptr, IID_PPV_ARGS(&input)))) {
        err = "create H0 texture"; return false;
    }
    for (int i = 0; i < 3; ++i) {
        if (FAILED(dev->CreateCommittedResource(&hpDefault, D3D12_HEAP_FLAG_NONE,
                &rg, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, nullptr, IID_PPV_ARGS(&spec[i]))) ||
            FAILED(dev->CreateCommittedResource(&hpDefault, D3D12_HEAP_FLAG_NONE,
                &rg, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, nullptr, IID_PPV_ARGS(&tmp[i]))) ||
            FAILED(dev->CreateCommittedResource(&hpDefault, D3D12_HEAP_FLAG_NONE,
                &rg, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, nullptr, IID_PPV_ARGS(&spatial[i])))) {
            err = "create FFT texture"; return false;
        }
    }
    if (FAILED(dev->CreateCommittedResource(&hpDefault, D3D12_HEAP_FLAG_NONE,
            &half4, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, nullptr,
            IID_PPV_ARGS(&merged)))) { err = "create merge texture"; return false; }

    D3D12_PLACED_SUBRESOURCE_FOOTPRINT inFp{};
    UINT rows = 0; UINT64 rowBytes = 0, uploadBytes = 0;
    dev->GetCopyableFootprints(&inputDesc, 0, 1, 0, &inFp, &rows, &rowBytes, &uploadBytes);
    ComPtr<ID3D12Resource> upload;
    D3D12_RESOURCE_DESC uploadDesc = buffer_desc(uploadBytes);
    if (FAILED(dev->CreateCommittedResource(&hpUpload, D3D12_HEAP_FLAG_NONE,
            &uploadDesc, D3D12_RESOURCE_STATE_GENERIC_READ, nullptr,
            IID_PPV_ARGS(&upload)))) { err = "create H0 upload"; return false; }
    uint8_t* mapped = nullptr;
    D3D12_RANGE noRead{0, 0};
    upload->Map(0, &noRead, (void**)&mapped);
    for (int y = 0; y < n; ++y)
        std::memcpy(mapped + inFp.Offset + (size_t)y * inFp.Footprint.RowPitch,
                    h0.data() + (size_t)y * n * 2, (size_t)n * 2 * sizeof(float));
    upload->Unmap(0, nullptr);
    D3D12_TEXTURE_COPY_LOCATION dst{}; dst.pResource = input.Get();
    dst.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    D3D12_TEXTURE_COPY_LOCATION src{}; src.pResource = upload.Get();
    src.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT; src.PlacedFootprint = inFp;
    cl->CopyTextureRegion(&dst, 0, 0, 0, &src, nullptr);
    transition(cl.Get(), input.Get(), D3D12_RESOURCE_STATE_COPY_DEST,
               D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);

    ComPtr<ID3D12Resource> cb;
    D3D12_RESOURCE_DESC cbd = buffer_desc(512);
    if (FAILED(dev->CreateCommittedResource(&hpUpload, D3D12_HEAP_FLAG_NONE,
            &cbd, D3D12_RESOURCE_STATE_GENERIC_READ, nullptr, IID_PPV_ARGS(&cb)))) {
        err = "create constants"; return false;
    }
    cb->Map(0, &noRead, (void**)&mapped);
    std::memset(mapped, 0, 512);
    std::memcpy(mapped + 0, &n, 4);
    const float invTile = 1.f / tile, seconds = 5.f;
    std::memcpy(mapped + 4, &invTile, 4); std::memcpy(mapped + 8, &seconds, 4);
    const uint32_t halfN = (uint32_t)n / 2;
    std::memcpy(mapped + 256, &halfN, 4);
    cb->Unmap(0, nullptr);

    constexpr UINT kPasses = 8, kBlock = 7;
    D3D12_DESCRIPTOR_HEAP_DESC hd{};
    hd.Type = D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
    hd.NumDescriptors = kPasses * kBlock;
    hd.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
    ComPtr<ID3D12DescriptorHeap> heap;
    if (FAILED(dev->CreateDescriptorHeap(&hd, IID_PPV_ARGS(&heap)))) {
        err = "create descriptor heap"; return false;
    }
    const UINT inc = dev->GetDescriptorHandleIncrementSize(hd.Type);
    const auto cpu = [&](UINT i) { auto h = heap->GetCPUDescriptorHandleForHeapStart(); h.ptr += (SIZE_T)i * inc; return h; };
    const auto gpu = [&](UINT i) { auto h = heap->GetGPUDescriptorHandleForHeapStart(); h.ptr += (UINT64)i * inc; return h; };
    auto make_block = [&](UINT pass, UINT cbOffset,
                          ID3D12Resource* s0, ID3D12Resource* s1, ID3D12Resource* s2,
                          ID3D12Resource* u0, ID3D12Resource* u1, ID3D12Resource* u2,
                          DXGI_FORMAT u0fmt) {
        const UINT base = pass * kBlock;
        D3D12_CONSTANT_BUFFER_VIEW_DESC cv{cb->GetGPUVirtualAddress() + cbOffset, 256};
        dev->CreateConstantBufferView(&cv, cpu(base));
        ID3D12Resource* sr[3] = {s0, s1, s2};
        for (UINT i = 0; i < 3; ++i) {
            D3D12_SHADER_RESOURCE_VIEW_DESC v{}; v.Format = DXGI_FORMAT_R32G32_FLOAT;
            v.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D;
            v.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
            v.Texture2D.MipLevels = 1;
            dev->CreateShaderResourceView(sr[i], &v, cpu(base + 1 + i));
        }
        ID3D12Resource* ur[3] = {u0, u1, u2};
        for (UINT i = 0; i < 3; ++i) {
            D3D12_UNORDERED_ACCESS_VIEW_DESC v{};
            v.Format = i == 0 ? u0fmt : DXGI_FORMAT_R32G32_FLOAT;
            v.ViewDimension = D3D12_UAV_DIMENSION_TEXTURE2D;
            dev->CreateUnorderedAccessView(ur[i], nullptr, &v, cpu(base + 4 + i));
        }
    };
    make_block(0, 0, input.Get(), nullptr, nullptr,
               spec[0].Get(), spec[1].Get(), spec[2].Get(), DXGI_FORMAT_R32G32_FLOAT);
    for (UINT i = 0; i < 3; ++i)
        make_block(1 + i, 256, spec[i].Get(), nullptr, nullptr,
                   tmp[i].Get(), nullptr, nullptr, DXGI_FORMAT_R32G32_FLOAT);
    for (UINT i = 0; i < 3; ++i)
        make_block(4 + i, 256, tmp[i].Get(), nullptr, nullptr,
                   spatial[i].Get(), nullptr, nullptr, DXGI_FORMAT_R32G32_FLOAT);
    make_block(7, 256, spatial[0].Get(), spatial[1].Get(), spatial[2].Get(),
               merged.Get(), nullptr, nullptr, DXGI_FORMAT_R16G16B16A16_FLOAT);

    ID3D12DescriptorHeap* heaps[] = {heap.Get()};
    cl->SetDescriptorHeaps(1, heaps);
    cl->SetComputeRootSignature(root.Get());
    auto bind = [&](UINT pass) {
        const UINT base = pass * kBlock;
        cl->SetComputeRootDescriptorTable(0, gpu(base));
        cl->SetComputeRootDescriptorTable(1, gpu(base + 1));
        cl->SetComputeRootDescriptorTable(2, gpu(base + 4));
    };
    cl->SetPipelineState(pDisp.Get()); bind(0);
    cl->Dispatch((UINT)(n + 15) / 16, (UINT)(n / 2 + 16) / 16, 1);
    for (int i = 0; i < 3; ++i) {
        uav_barrier(cl.Get(), spec[i].Get());
        transition(cl.Get(), spec[i].Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
                   D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        cl->SetPipelineState(pCol.Get()); bind(1 + i); cl->Dispatch((UINT)n, 1, 1);
        uav_barrier(cl.Get(), tmp[i].Get());
        transition(cl.Get(), tmp[i].Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
                   D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        cl->SetPipelineState(pRow.Get()); bind(4 + i); cl->Dispatch((UINT)n, 1, 1);
        uav_barrier(cl.Get(), spatial[i].Get());
        transition(cl.Get(), spatial[i].Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
                   D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    }
    cl->SetPipelineState(pMerge.Get()); bind(7); cl->Dispatch((UINT)n / 16, (UINT)n / 16, 1);
    uav_barrier(cl.Get(), merged.Get());
    transition(cl.Get(), merged.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
               D3D12_RESOURCE_STATE_COPY_SOURCE);

    D3D12_PLACED_SUBRESOURCE_FOOTPRINT outFp{};
    UINT64 readBytes = 0;
    dev->GetCopyableFootprints(&half4, 0, 1, 0, &outFp, &rows, &rowBytes, &readBytes);
    ComPtr<ID3D12Resource> readback;
    D3D12_RESOURCE_DESC rbd = buffer_desc(readBytes);
    if (FAILED(dev->CreateCommittedResource(&hpRead, D3D12_HEAP_FLAG_NONE, &rbd,
            D3D12_RESOURCE_STATE_COPY_DEST, nullptr, IID_PPV_ARGS(&readback)))) {
        err = "create readback"; return false;
    }
    D3D12_TEXTURE_COPY_LOCATION rdst{}; rdst.pResource = readback.Get();
    rdst.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT; rdst.PlacedFootprint = outFp;
    D3D12_TEXTURE_COPY_LOCATION rsrc{}; rsrc.pResource = merged.Get();
    rsrc.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    cl->CopyTextureRegion(&rdst, 0, 0, 0, &rsrc, nullptr);
    if (FAILED(cl->Close())) { err = "close command list"; return false; }
    ID3D12CommandList* lists[] = {cl.Get()}; queue->ExecuteCommandLists(1, lists);
    ComPtr<ID3D12Fence> fence;
    if (FAILED(dev->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&fence)))) {
        err = "create fence"; return false;
    }
    HANDLE eventHandle = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    queue->Signal(fence.Get(), 1);
    if (fence->GetCompletedValue() < 1) {
        fence->SetEventOnCompletion(1, eventHandle);
        WaitForSingleObject(eventHandle, INFINITE);
    }
    CloseHandle(eventHandle);

    D3D12_RANGE rr{0, (SIZE_T)readBytes};
    readback->Map(0, &rr, (void**)&mapped);
    result.rgba.resize((size_t)n * n * 4);
    for (int y = 0; y < n; ++y) {
        const uint16_t* row = reinterpret_cast<const uint16_t*>(
            mapped + outFp.Offset + (size_t)y * outFp.Footprint.RowPitch);
        for (int x = 0; x < n; ++x)
            for (int c = 0; c < 4; ++c)
                result.rgba[((size_t)y * n + x) * 4 + c] = half_to_float(row[x * 4 + c]);
    }
    readback->Unmap(0, nullptr);
    return true;
}

} // namespace

int main(int argc, char** argv)
{
    if (argc < 3) {
        std::fprintf(stderr, "usage: waterdxil_test <game_dir> <level> [--zero] [--all]\n");
        return 2;
    }
    bool zero = false, all = false;
    for (int i = 3; i < argc; ++i) {
        if (!std::strcmp(argv[i], "--zero")) zero = true;
        else if (!std::strcmp(argv[i], "--all")) all = true;
        else {
            std::fprintf(stderr, "unknown option: %s\n", argv[i]);
            return 2;
        }
    }
    char error[512]{};
    bf6_ctx* core = bf6_open(argv[1], error, (int)sizeof(error));
    if (!core || bf6_open_level(core, argv[2], nullptr, 0, error, (int)sizeof(error))) {
        std::fprintf(stderr, "core open: %s\n", error); if (core) bf6_close(core); return 1;
    }
    const int count = bf6_level_water_sims(core, argv[2], nullptr, 0);
    std::vector<bf6_water_sim_v2> sims(count > 0 ? (size_t)count : 0);
    if (count > 0) bf6_level_water_sims(core, argv[2], sims.data(), count);
    int strongest = -1;
    double bestEnergy = -1;
    std::vector<std::vector<float>> spectra((size_t)count);
    for (int i = 0; i < count; ++i) {
        const int floats = bf6_water_spectrum_h0(&sims[i], nullptr, 0);
        std::vector<float> candidate(floats > 0 ? (size_t)floats : 0);
        if (floats <= 0 || bf6_water_spectrum_h0(&sims[i], candidate.data(), floats) != floats) continue;
        double e = 0; for (float v : candidate) e += (double)v * v;
        spectra[(size_t)i] = std::move(candidate);
        if (sims[i].resolution == 128 && e > bestEnergy) {
            bestEnergy = e;
            strongest = i;
        }
    }
    if (strongest < 0) { std::fprintf(stderr, "no N=128 water cascade\n"); bf6_close(core); return 1; }
    if (zero)
        for (auto& h0 : spectra) std::fill(h0.begin(), h0.end(), 0.f);
    bf6_close(core);

    Source src;
    std::string err;
    if (!src.open(argv[1], err) || !src.mount_level(argv[2], false, err)) {
        std::fprintf(stderr, "mount: %s\n", err.c_str()); return 1;
    }
    std::vector<uint8_t> ignored;
    std::string resource, fakeErr;
    const bool fake = live_container(src, "00000000-0000-0000-0000-000000000000",
                                     ignored, resource, fakeErr);
    std::printf("CONTROL fake_guid=%d expected=0\n", fake ? 1 : 0);
    ShaderSet shaders;
    const char* guids[] = {kDispersion, kFftColumnInverse, kFftRowInverseReal, kMerge};
    std::vector<uint8_t>* dst[] = {&shaders.dispersion, &shaders.col, &shaders.row, &shaders.merge};
    for (int i = 0; i < 4; ++i) {
        if (!live_container(src, guids[i], *dst[i], resource, err)) {
            std::fprintf(stderr, "shader %s: %s\n", guids[i], err.c_str()); return 1;
        }
        std::printf("SHADER %s bytes=%zu resource=%s\n", guids[i], dst[i]->size(), resource.c_str());
    }

    ComPtr<ID3D12Device> dev;
    HRESULT hr = D3D12CreateDevice(nullptr, D3D_FEATURE_LEVEL_12_0, IID_PPV_ARGS(&dev));
    if (FAILED(hr)) { std::fprintf(stderr, "D3D12CreateDevice: %s\n", hr_text(hr).c_str()); return 1; }
    int failures = fake ? 1 : 0;
    for (int selected = 0; selected < count; ++selected) {
        if (!all && selected != strongest) continue;
        if (spectra[(size_t)selected].empty()) {
            std::fprintf(stderr, "cascade %d has no H0\n", selected);
            ++failures;
            continue;
        }
        const bf6_water_sim_v2& sim = sims[selected];
        GpuResult result;
        if (!execute(dev.Get(), shaders, sim.resolution, sim.tile_dimension,
                     spectra[(size_t)selected], result, err)) {
            std::fprintf(stderr, "execute cascade %d: %s\n", selected, err.c_str());
            ++failures;
            continue;
        }
        double minv = result.rgba[1], maxv = result.rgba[1], sum2 = 0;
        size_t nonzero = 0, nonfinite = 0;
        for (size_t i = 0; i < result.rgba.size() / 4; ++i) {
            const float v = result.rgba[i * 4 + 1];
            if (!std::isfinite(v)) ++nonfinite;
            if (v != 0.f) ++nonzero;
            minv = std::min(minv, (double)v); maxv = std::max(maxv, (double)v);
            sum2 += (double)v * v;
        }
        const double rms = std::sqrt(sum2 / (result.rgba.size() / 4));
        std::printf("RESULT level=%s cascade=%d source=%d N=%d tile=%.9g zero=%d "
                    "height_min_m=%.12g height_max_m=%.12g height_rms_m=%.12g "
                    "nonzero=%zu/%zu nonfinite=%zu\n",
                    argv[2], selected, sim.source_index, sim.resolution, sim.tile_dimension,
                    zero ? 1 : 0, minv, maxv, rms, nonzero, result.rgba.size() / 4, nonfinite);
        if (nonfinite || (zero && nonzero)) ++failures;
    }
    return failures ? 1 : 0;
}
