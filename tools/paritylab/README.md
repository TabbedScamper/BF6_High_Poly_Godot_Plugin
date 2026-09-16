# BF6 high-poly parity lab

This directory is the supported evidence and regression surface for the native
reader and the Unreal high-poly reconstruction. It coordinates existing tools;
it does not replace their decoders and it never supplies exported data to the
product at runtime.

## First commands

Use the project's required Python explicitly:

```powershell
$py = 'C:\Users\mwalt\AppData\Local\Programs\Python\Python312\python.exe'
& $py .\tools\paritylab\paritylab.py doctor
& $py .\tools\paritylab\paritylab.py list
& $py .\tools\paritylab\paritylab.py run tsuru-terrain --keep-going
```

Each run receives a new directory under
`C:\PortalSDK_1.4.2.0\out\paritylab`. It contains the exact command, executable
hash, environment inventory, stdout/stderr, machine-readable JSON, and a small
HTML summary. These are evidence artifacts, never runtime inputs.

Compare two equal-resolution captures with translation registration and a
histogram-preserving shuffled-block control:

```powershell
& $py .\tools\paritylab\paritylab.py compare game.png unreal.png `
  --out C:\PortalSDK_1.4.2.0\out\paritylab\tsuru-camera-01
```

The report includes RGB error, PSNR, luminance correlation, global SSIM, edge
correlation, edge error, alignment, and the same measurements against the
control. `heatmap.png` localizes error and `blink.gif` makes sub-pixel camera or
geometry drift obvious.

## Running a shipped shader without the game

There is no reliable tool that reconstructs the original HLSL, author names,
material graph and runtime resource values from stripped DXIL. Use three
complementary layers instead:

1. `dxc -dumpbin shader.dxil` (or `IDxcCompiler::Disassemble`) exposes DXIL,
   reflection and resource declarations. This is disassembly, not original
   source recovery.
2. The core D3D12 harness mounts the current Steam data, binds controlled
   resources and executes the shipped bytecode without launching Battlefield.
3. WARP executes the identical D3D12 workload on the CPU. A hardware/WARP
   disagreement is evidence of an incomplete input, undefined behavior, or a
   driver-sensitive operation; it must not be averaged away.

Run the adapter differential directly:

```powershell
& $py .\tools\paritylab\paritylab.py dxil-adapters `
  --out C:\PortalSDK_1.4.2.0\out\paritylab\dxil-adapters
```

Run a complete camera-relative Tsuru page through the shipped evaluator:

```powershell
$exe = '.\core\build\Release\terraindxil_dispatch_test.exe'
& $exe 'C:\Program Files (x86)\Steam\steamapps\common\Battlefield 6' `
  mp_isolated --page-dispatch -778.96216226 412.78984774 `
  'C:\PortalSDK_1.4.2.0\out\paritylab\tsuru-page\basecolor.ppm'
```

The command dispatches an empty-work control, the authored ordered work lists,
and a control with each tile's order reversed. It writes U1 base colour, U2
packed material, U3 packed normal and U4 auxiliary pages as PPM previews and
raw float32 buffers. U0 is also retained as raw float32 plus a ranged PGM, but
its Frostbite VT quantisation transform is not yet recovered. The live Tsuru
DXIL reads that transform from `cb0[275].zw`; the neighboring `cb0[274].w` is a
separate required WorldSizeY input. An initial U1 change blamed on the U0 scale
was retracted after restoring `cb0[274].w`. With that restored, diagnostic U0
scales 0 and 1 produce byte-identical U1 and U2 float buffers; scale 1 exposes
the evaluator's `-0.078491..0.635742` material-displacement range. Use
`--height-output-scale 1` only for that isolation experiment. U0 still remains
an explicitly unresolved diagnostic rather than a claimed engine-encoded
height match.

Use `--debug-layer` with `--page-dispatch` for the routine D3D12 contract check.
The harness gives every authored texture and U0-U7 resource a capture-readable
name, uses a separate CPU descriptor heap for UAV clears, and resets structured
scatter buffers through explicit copy/state transitions. The saved-camera run
completes in about 18 seconds with zero debug messages. `--gpu-validation`
additionally enables shader-side validation, but the full three-dispatch page
did not finish within a five-minute practical ceiling on the RTX 4080. It is an
on-demand diagnostic, not part of the normal profile, until a focused
single-group mode exists.

## In-memory Unreal sidecar seam

`page-pipe` exercises the page transport intended for the Unreal integration:

```powershell
& $py .\tools\paritylab\paritylab.py page-pipe --span 16 `
  --out C:\PortalSDK_1.4.2.0\out\paritylab\tsuru-page-pipe
```

The D3D12 process still mounts the current Steam game and executes the live
shader, but writes no runtime texture file. It frames the resulting U1 page as
`BF6_PAGE_RGBA8_V1`, metadata and base64 RGBA8 on stdout so an Unreal parent
process can validate and upload it directly from its pipe. The consumer checks
that the decoded payload is exactly `side*side*4`; the command removes one
base64 quartet as its negative control and requires that short frame to be
rejected. The saved 16 m Tsuru page is 64 square/16,384 bytes and currently
hashes to `c1137d34d559e042c78a341cb8e207ed188903a7de18e30c0395ffe4c2021507`.
That hash is evidence for this game/executable pair, not a value the product
may bake in or use as a runtime oracle.

The High Poly add-on now consumes this frame directly. Deploy the sidecar next
to `bf6_core.dll` as
`Plugins/BF6UnrealSDK/Source/ThirdParty/libbf6/bin/Win64/terraindxil_dispatch_test.exe`,
build the level normally, then use the Unreal console:

```powershell
& .\tools\paritylab\deploy_unreal_sidecar.ps1
```

```text
BF6.HighPoly.DxilPage 16
BF6.HighPoly.DxilPage -778.96216226 412.78984774 16
BF6.HighPoly.DxilPage off
```

The one-argument form uses the saved Tsuru terrain camera. The three-number
form is game-space X/Z metres and works on the currently mounted level. `off`
is the visual control: it disables the exact rectangle and restores the
generic Unreal ground without rebuilding. For a deterministic startup run:

```powershell
& 'C:\Program Files\Epic Games\UE_5.8\Engine\Binaries\Win64\UnrealEditor.exe' `
  'C:\Users\mwalt\Documents\Unreal Projects\BF6_High_Poly\BF6_Unreal_SDK.uproject' `
  -bf6benchtsuru -bf6dxilpage=16 -NoSound -log
```

Unreal runs the sidecar on a worker, accepts only the versioned frame, checks
finite positive metadata, decodes base64, requires exactly `side*side*4`
bytes, then creates a transient linear RGBA texture on the game thread. A map
epoch and level check discard a late result after any rebuild. No page image is
written or read at runtime. The page is currently a deliberately small U1
base-colour diagnostic: it is RGBA8-quantised and does not yet replace U0/U2-
U4, the terrain geometry, or Frostbite's clipmap/virtual-texture consumer.

The 2026-08-26 Tsuru control passes routing on both devices. The empty-page and
constant-bindless outputs both match exactly, but restoring the spatially
authored texture maps is currently `DIVERGENT` (`0.103418` maximum channel
difference). Clearing every UAV does not change that result. This localizes the
open problem to authored spatial sampling (coordinates, LOD/mips, sampler
semantics, or a missing authored parameter), rather than generic dispatch,
UAV initialization, or bindless routing. Therefore direct execution is
verified, while exact authored-input reconstruction remains explicitly
unverified. RenderDoc can capture this harness and simulate a single DXIL
compute invocation; it cannot reconstruct interactions with the rest of a
thread group, and stripped game shaders generally lack source-level names.

For this specific L6 control, the existing decoded evaluator says the authored
path is stochastic: it feeds `sin(...) * 43758.5` through `frac` to choose
rotated material samples. Small legal differences in transcendental results can
therefore become large texture-coordinate differences between WARP and a GPU.
That is the leading explanation for the measured divergence, not yet proof;
capture the sample coordinates before interpreting WARP as a pixel-exact oracle.

For a portable standalone experiment on NVIDIA hardware, Nsight Graphics can
export a captured frame as compilable C++ once the harness has the desired
workload. `dxil-spirv` is useful as a translation/IR cross-check, not as a
Frostbite behavior oracle.

## Non-invasive visual oracle recorder

`oracle_recorder.py` records the displayed Windows output without opening the
target process. It watches only for an executable image name, captures through
the Windows Desktop Duplication API, and stops when that image exits or the
duration limit is reached. It never launches Battlefield, changes networking,
injects code, reads process memory, modifies game files, or installs a wrapper.

Audit and exercise the complete path on a short-lived loopback control first:

```powershell
$py = 'C:\Users\mwalt\AppData\Local\Programs\Python\Python312\python.exe'
& $py .\tools\paritylab\oracle_recorder.py doctor
& $py .\tools\paritylab\oracle_recorder.py self-test
```

For a small, useful BF6 sample, launch normally, load the desired level, place
the camera, then Alt-Tab and run:

```powershell
& $py .\tools\paritylab\oracle_recorder.py --target bf6.exe record `
  --max-duration 30 --fps 2
```

Output goes to `out/paritylab/oracle/<UTC>-bf6/`: a lossless RGB Matroska
recording, first/middle PNG frames, the exact capture command, FFmpeg and game
executable hashes, process appearance/disappearance events, FFprobe metadata,
and `report.json`. The generated-codec control requires a BGR0 frame to survive
the selected `libx264rgb` path byte-for-byte. A fake image-name control must
remain absent. These controls validate transport, not the game image itself.

The pixel contract is deliberately narrow: 8-bit post-composition desktop RGB,
full range and no chroma subsampling. It is an exact record of that Windows
capture surface, not Frostbite's pre-tone-map HDR buffer, GBuffer or virtual
textures. Keep Windows and BF6 HDR off for an SDR parity session. At 5120x1440,
lossless RGB can grow quickly; two frames per second is enough for a stationary
terrain oracle and the default run is duration-limited.

`--wpr-gpu` optionally requests Windows' system ETW GPU profile. It does not
expose textures, shaders or constants and can require an elevated Performance
Log Users/admin session. The 2026-08-26 non-elevated control failed cleanly with
`0xc5585011`; no trace session remained, so WPR is not enabled for the first BF6
trial.

Ninja Ripper is outside this boundary. Installed 2.14 contains `intruder.dll`
and D3D12/DXGI wrapper DLLs; both its local readme and official FAQ describe DLL
injection/hooks and warn about anti-cheat bans. Do not run it against BF6. Old
`.nr` output, if it already exists, may be parsed offline as evidence, but no
such output was found in the usual user directories during this audit.

## Which tool to use

| Question | First tool | Why |
| --- | --- | --- |
| Did a live Frostbite read path change? | A parity-lab profile | Replays the current Steam install and requires its positive and negative controls. |
| Which texture/descriptor/constant did our DXIL dispatch use? | PIX on the core D3D12 harness | Complete D3D12 state and resource history for code we own. |
| Does the shipped DXIL behave without a GPU? | `paritylab dxil-adapters` | Executes identical live inputs on the RTX hardware path and Microsoft WARP software D3D12, then records the numeric differential. |
| Is PIX showing a tool-specific artifact? | RenderDoc on the same harness | Independent capture/replay implementation and pixel/shader inspection. |
| Is a descriptor stale or indexed out of range? | D3D12 Debug Layer + GPU-Based Validation | Shader-side descriptor and resource-state validation. |
| Did the GPU hang or page-fault? | DRED; Nsight Aftermath or AMD GPU Detective when applicable | Breadcrumb and fault-address evidence after device removal. |
| Where did a native memory corruption begin? | AddressSanitizer first, WinDbg TTD for a focused deterministic repro | ASan catches broad memory-safety classes; TTD can replay the exact write history. |
| Why is the Unreal bench slow or stuttering? | Unreal Insights | Engine-aware CPU, task, IO, render and memory telemetry. |
| Does the reconstructed frame match? | `paritylab compare` on same-pose captures/AOVs | Numeric result beside a shuffled spatial control, plus localized evidence. |
| What changed across a game patch? | Runtime profiles plus Ghidra/Binary Ninja BinDiff | The live read proves behavior; binary diff directs research without becoming a runtime table. |
| Is a proposed binary layout real? | Existing corpus tools, then an executable ImHex/Kaitai-style schema and a fake/shuffled control | Converts prose offsets into checked parsing rules. |

## Capture boundary

PIX, RenderDoc, Nsight, WinDbg and similar instrumentation are for our D3D12
harness and Unreal project only. Do not attach them to retail Battlefield 6.
The verified corpus finding `gpu-frame-capture-of-bf6-is-closed` explains the
technical and contractual boundary. Retail evidence is user-created
screenshots/video and data read through the established installed-game paths.

## Evidence contract

Every promoted parity check must state:

1. Current live input path and game executable identity.
2. Camera, level, game mode, resolution, FOV and exposure state.
3. Positive measurement.
4. Negative control and its measurement.
5. Threshold and why it is appropriate for that buffer.
6. Exact source/executable hashes.
7. Whether failure blocks shipping, marks a subsystem approximate, or retracts
   an earlier claim.

The target is not one whole-frame score. Terrain color, terrain geometry,
decals, water, lighting, meshes and UI need separate buffers and thresholds;
otherwise one large easy region can hide a severe localized error.

## Useful upstream projects

- Microsoft PIX: https://devblogs.microsoft.com/pix/
- RenderDoc: https://github.com/baldurk/renderdoc
- DirectX Shader Compiler: https://github.com/microsoft/DirectXShaderCompiler
- Microsoft WARP: https://learn.microsoft.com/windows/win32/direct3darticles/directx-warp
- dxil-spirv: https://github.com/HansKristian-Work/dxil-spirv
- Direct3D 12 GPU validation: https://learn.microsoft.com/windows/win32/direct3d12/using-d3d12-debug-layer-gpu-based-validation
- DRED: https://learn.microsoft.com/windows/win32/direct3d12/use-dred
- Unreal Insights: https://dev.epicgames.com/documentation/unreal-engine/unreal-insights-in-unreal-engine
- LLVM AddressSanitizer: https://clang.llvm.org/docs/AddressSanitizer.html
- LLVM libFuzzer: https://llvm.org/docs/LibFuzzer.html
- NVIDIA Nsight Graphics: https://developer.nvidia.com/nsight-graphics
- AMD Radeon developer tools: https://gpuopen.com/tools/
- Binary Ninja BinDiff workflow: https://docs.binary.ninja/guide/binexport.html

External software must be downloaded from its official publisher. Do not place
third-party binaries or captures in this source tree.
