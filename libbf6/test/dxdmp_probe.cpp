// DirectX Dump Files capability probe.
//
// This is deliberately a standalone D3D12 test.  It does not open BF6, attach
// to another process, or consume any exported game intermediates.  Its job is
// to establish what this machine's OS/runtime/driver can actually record before
// we invest in a dump-based research path.

#include <windows.h>
#include <d3d12.h>
#include <dxgi1_6.h>
#include <wrl/client.h>

#include <cstdio>
#include <cstring>
#include <string>

using Microsoft::WRL::ComPtr;

extern "C" {
__declspec(dllexport) extern const UINT D3D12SDKVersion = 721;
__declspec(dllexport) extern const char* D3D12SDKPath = ".\\D3D12\\";
}

static std::string utf8(const wchar_t* text)
{
    if (!text) return {};
    const int count = WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0,
                                           nullptr, nullptr);
    if (count <= 1) return {};
    std::string out(static_cast<size_t>(count - 1), '\0');
    WideCharToMultiByte(CP_UTF8, 0, text, -1, out.data(), count, nullptr,
                        nullptr);
    return out;
}

static std::string json_escape(const std::string& value)
{
    std::string out;
    out.reserve(value.size() + 16);
    for (const unsigned char c : value) {
        switch (c) {
        case '\\': out += "\\\\"; break;
        case '"': out += "\\\""; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        default:
            if (c < 0x20) {
                char tmp[7]{};
                std::snprintf(tmp, sizeof(tmp), "\\u%04x", c);
                out += tmp;
            } else {
                out += static_cast<char>(c);
            }
        }
    }
    return out;
}

static std::string hr_hex(HRESULT hr)
{
    char text[16]{};
    std::snprintf(text, sizeof(text), "0x%08X",
                  static_cast<unsigned>(hr));
    return text;
}

static bool developer_mode_enabled()
{
    DWORD value = 0;
    DWORD bytes = sizeof(value);
    const LSTATUS status = RegGetValueW(
        HKEY_LOCAL_MACHINE,
        L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\AppModelUnlock",
        L"AllowDevelopmentWithoutDevLicense", RRF_RT_REG_DWORD, nullptr,
        &value, &bytes);
    return status == ERROR_SUCCESS && value != 0;
}

int main(int argc, char** argv)
{
    bool configure = false;
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--configure") == 0) configure = true;
    }

    ComPtr<IDXGIFactory6> factory;
    HRESULT factory_hr = CreateDXGIFactory2(0, IID_PPV_ARGS(&factory));
    ComPtr<IDXGIAdapter1> adapter;
    ComPtr<ID3D12Device> device;
    DXGI_ADAPTER_DESC1 adapter_desc{};
    HRESULT device_hr = E_FAIL;

    if (SUCCEEDED(factory_hr)) {
        for (UINT index = 0;; ++index) {
            ComPtr<IDXGIAdapter1> candidate;
            const HRESULT enum_hr = factory->EnumAdapterByGpuPreference(
                index, DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,
                IID_PPV_ARGS(&candidate));
            if (enum_hr == DXGI_ERROR_NOT_FOUND) break;
            if (FAILED(enum_hr)) continue;
            DXGI_ADAPTER_DESC1 desc{};
            candidate->GetDesc1(&desc);
            if ((desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) != 0) continue;
            device_hr = D3D12CreateDevice(candidate.Get(),
                                           D3D_FEATURE_LEVEL_12_0,
                                           IID_PPV_ARGS(&device));
            if (SUCCEEDED(device_hr)) {
                adapter = candidate;
                adapter_desc = desc;
                break;
            }
        }
    }

    wchar_t core_path[MAX_PATH]{};
    const HMODULE core = GetModuleHandleW(L"D3D12Core.dll");
    if (core) GetModuleFileNameW(core, core_path, MAX_PATH);

    D3D12_FEATURE_DATA_DUMP_FILE dump{};
    D3D12_FEATURE_DATA_DEBUG_BREAK debug_break{};
    HRESULT dump_hr = E_NOINTERFACE;
    HRESULT debug_break_hr = E_NOINTERFACE;
    HRESULT preview_hr = E_NOINTERFACE;
    HRESULT configure_hr = E_NOTIMPL;
    ComPtr<ID3D12DevicePreview> preview;

    if (device) {
        dump_hr = device->CheckFeatureSupport(D3D12_FEATURE_DUMP_FILE, &dump,
                                              sizeof(dump));
        debug_break_hr = device->CheckFeatureSupport(
            D3D12_FEATURE_DEBUG_BREAK, &debug_break, sizeof(debug_break));
        preview_hr = device.As(&preview);
        if (configure && preview && SUCCEEDED(dump_hr) && dump.SupportedByOS) {
            UINT wanted = D3D12_DUMP_FILE_DRIVER_OPTION_NO_OVERHEAD;
            const UINT detailed = D3D12_DUMP_FILE_DRIVER_OPTION_RESOURCES |
                                  D3D12_DUMP_FILE_DRIVER_OPTION_SHADER_REGISTERS |
                                  D3D12_DUMP_FILE_DRIVER_OPTION_EVENT_MARKERS;
            wanted |= dump.DumpFileDriverOptionsMask & detailed;
            if ((wanted & detailed) == 0) {
                if ((dump.DumpFileDriverOptionsMask &
                     D3D12_DUMP_FILE_DRIVER_OPTION_HIGH_OVERHEAD) != 0) {
                    wanted = D3D12_DUMP_FILE_DRIVER_OPTION_HIGH_OVERHEAD;
                } else if ((dump.DumpFileDriverOptionsMask &
                            D3D12_DUMP_FILE_DRIVER_OPTION_MEDIUM_OVERHEAD) != 0) {
                    wanted = D3D12_DUMP_FILE_DRIVER_OPTION_MEDIUM_OVERHEAD;
                }
            }
            configure_hr = preview->ConfigureDumpFile(
                static_cast<D3D12_DUMP_FILE_DRIVER_OPTIONS>(wanted));
            if (SUCCEEDED(configure_hr)) preview->RetainDumpFile(TRUE);
        }
    }

    const bool capability = SUCCEEDED(device_hr) && SUCCEEDED(dump_hr) &&
                            dump.SupportedByOS != FALSE;
    const bool resource_tracking = capability &&
        (dump.DumpFileDriverOptionsMask &
         D3D12_DUMP_FILE_DRIVER_OPTION_RESOURCES) != 0;

    std::printf("{\n");
    std::printf("  \"schema\": 1,\n");
    std::printf("  \"control\": \"standalone process; no BF6 launch or attachment\",\n");
    std::printf("  \"agility_sdk_requested\": 721,\n");
    std::printf("  \"d3d12_core\": \"%s\",\n",
                json_escape(utf8(core_path)).c_str());
    std::printf("  \"developer_mode_registry\": %s,\n",
                developer_mode_enabled() ? "true" : "false");
    std::printf("  \"factory_hr\": \"%s\",\n", hr_hex(factory_hr).c_str());
    std::printf("  \"device_hr\": \"%s\",\n", hr_hex(device_hr).c_str());
    std::printf("  \"adapter\": \"%s\",\n",
                json_escape(utf8(adapter_desc.Description)).c_str());
    std::printf("  \"vendor_id\": %u,\n", adapter_desc.VendorId);
    std::printf("  \"device_id\": %u,\n", adapter_desc.DeviceId);
    std::printf("  \"dump_feature_hr\": \"%s\",\n",
                hr_hex(dump_hr).c_str());
    std::printf("  \"dump_supported_by_os\": %s,\n",
                dump.SupportedByOS ? "true" : "false");
    std::printf("  \"dump_driver_tier\": %u,\n",
                static_cast<unsigned>(dump.DumpFileDriverTier));
    std::printf("  \"dump_options_mask\": %u,\n",
                dump.DumpFileDriverOptionsMask);
    std::printf("  \"resource_tracking_supported\": %s,\n",
                resource_tracking ? "true" : "false");
    std::printf("  \"debug_break_feature_hr\": \"%s\",\n",
                hr_hex(debug_break_hr).c_str());
    std::printf("  \"debug_break_halt_supported\": %s,\n",
                debug_break.HaltSupported ? "true" : "false");
    std::printf("  \"debug_break_live_supported\": %s,\n",
                debug_break.LiveDebuggingSupported ? "true" : "false");
    std::printf("  \"preview_interface_hr\": \"%s\",\n",
                hr_hex(preview_hr).c_str());
    std::printf("  \"configure_requested\": %s,\n",
                configure ? "true" : "false");
    std::printf("  \"configure_hr\": \"%s\",\n",
                hr_hex(configure_hr).c_str());
    std::printf("  \"usable\": %s\n", capability ? "true" : "false");
    std::printf("}\n");
    return capability ? 0 : 2;
}
