# Verify a High-Poly install against the manifest it shipped with.
#
# WHY THIS EXISTS. The addon has always shipped package-manifest.json, a SHA256
# for every file it installed - and nothing ever read it. So when a user's addon
# disabled itself on 2026-09-17 with 291 "Identifier not declared in the current
# scope" errors, there was no way to answer the only question that mattered: are
# the files on their disk the files we shipped?
#
# It must be PowerShell rather than a tool inside the plugin, because the case
# it diagnoses is the plugin failing to load. A self-check that only runs when
# the plugin works cannot report the plugin being broken.
#
#   powershell -ExecutionPolicy Bypass -File verify_install.ps1
#   powershell -ExecutionPolicy Bypass -File verify_install.ps1 -Project "C:\path\to\GodotProject"
#
# Writes highpoly-install-report.txt next to itself and prints a summary.

param(
    [string]$Project = "",
    [string]$Report  = ""
)

$ErrorActionPreference = "Stop"

function Find-Project {
    param([string]$Given)
    if ($Given) { return $Given }
    # Next to this file, then upwards, then any installed SDK. The person
    # running this may have saved it to their Downloads folder, so nothing here
    # assumes it sits inside the project.
    $d = Split-Path -Parent $PSCommandPath
    for ($i = 0; $i -lt 8 -and $d; $i++) {
        if (Test-Path (Join-Path $d "addons\highpoly_toggle\plugin.cfg")) { return $d }
        $d = Split-Path -Parent $d
    }
    foreach ($pat in @("C:\BF6_SDK\SDKs\PortalSDK-*\GodotProject",
                       "C:\PortalSDK*\GodotProject")) {
        $hit = Get-ChildItem $pat -Directory -EA SilentlyContinue |
               Where-Object { Test-Path (Join-Path $_.FullName "addons\highpoly_toggle\plugin.cfg") } |
               Sort-Object Name | Select-Object -Last 1
        if ($hit) { return $hit.FullName }
    }
    # Still nothing: ask, rather than failing with a path the user cannot act on.
    Write-Host ""
    Write-Host "I could not find the High-Poly addon automatically."
    Write-Host "Please paste the full path to your Godot project folder"
    Write-Host "(the folder containing project.godot), then press Enter:"
    $typed = (Read-Host "Path").Trim().Trim('"')
    if (-not $typed) { throw "No path given." }
    return $typed
}

Write-Host ""
Write-Host "Checking your BF6 High-Poly install..."
$proj = Find-Project $Project
$addon = Join-Path $proj "addons\highpoly_toggle"
if (-not (Test-Path $addon)) { throw "No High-Poly addon found at $addon" }
# The Desktop, so there is nothing to hunt for afterwards.
if (-not $Report) {
    $Report = Join-Path ([Environment]::GetFolderPath("Desktop")) "highpoly-install-report.txt"
}

$out = New-Object System.Collections.Generic.List[string]
function Say([string]$s) { $out.Add($s); Write-Host $s }

Say "High-Poly install report"
Say ("generated  " + (Get-Date -Format "s"))
Say ("project    " + $proj)
Say ""

# ---- version, and whether the editor disabled us -------------------------
$cfg = Join-Path $addon "plugin.cfg"
if (Test-Path $cfg) {
    $v = (Select-String -Path $cfg -Pattern '^version="(.*)"').Matches.Groups[1].Value
    Say ("plugin.cfg version   " + $v)
}
$build = Join-Path $addon "BUILD-INFO.txt"
if (Test-Path $build) { Say ("BUILD-INFO           " + ((Get-Content $build) -join " | ")) }

$pg = Join-Path $proj "project.godot"
if (Test-Path $pg) {
    $en = Select-String -Path $pg -Pattern 'highpoly_toggle/plugin.cfg' -EA SilentlyContinue
    if ($en) { Say "plugin enabled       YES (listed in project.godot)" }
    else     { Say "plugin enabled       NO  - the editor has DISABLED it" }
}

# ---- did Godot register our class_name globals? --------------------------
# This is the direct evidence for the reported failure: the entry script uses
# these globals, so if they are absent here it cannot compile.
$cache = Join-Path $proj ".godot\global_script_class_cache.cfg"
if (Test-Path $cache) {
    $txt = Get-Content $cache -Raw
    $n = ([regex]::Matches($txt, '"(Highpoly|BF6)[A-Za-z]*"')).Count
    Say ("global class cache   present, " + $n + " Highpoly/BF6 class name(s) registered")
} else {
    Say "global class cache   MISSING (.godot not built yet)"
}
Say ""

# ---- the actual integrity check ------------------------------------------
$man = Join-Path $addon "package-manifest.json"
if (-not (Test-Path $man)) {
    Say "package-manifest.json is MISSING - cannot verify the install."
    $out | Set-Content -Path $Report -Encoding utf8
    Write-Host "`nwrote $Report"
    exit 2
}
$json = Get-Content $man -Raw | ConvertFrom-Json
$files = $json.files

$props = @($files.PSObject.Properties)
$okN = 0; $bad = New-Object System.Collections.Generic.List[string]
foreach ($p in $props) {
    # Manifest keys are project-relative ("addons/highpoly_toggle/x.gd").
    $rel = $p.Name -replace '/', '\'
    $path = Join-Path $proj $rel
    if (-not (Test-Path $path)) {
        $bad.Add(("MISSING   {0}" -f $p.Name)); continue
    }
    $size = (Get-Item $path).Length
    $h = (Get-FileHash -Path $path -Algorithm SHA256).Hash.ToLower()
    if ($h -ne $p.Value.ToLower()) {
        $bad.Add(("MISMATCH  {0}  ({1} bytes on disk)" -f $p.Name, $size))
    } else { $okN++ }
}

Say ("files in manifest    " + $props.Count)
Say ("verified OK          " + $okN)
Say ("PROBLEMS             " + $bad.Count)
Say ""
if ($bad.Count -gt 0) {
    Say "--- files that are not what we shipped ---"
    foreach ($b in $bad) { Say ("  " + $b) }
    Say ""
    Say "A MISSING script cannot declare its class_name, and the entry script"
    Say "references those globals, so it fails to compile and the editor"
    Say "disables the plugin. Measured 2026-09-17: deleting one script produced"
    Say "34 'Identifier not declared' errors naming exactly that class."
    Say ""
    Say "A MISMATCH is worth fixing but is not on its own the same fault:"
    Say "truncating four large scripts to 8 KB did NOT reproduce the error,"
    Say "because class_name sits at the top of the file and survives the cut."
} else {
    Say "Every shipped file matches. The install is intact, so the fault is NOT"
    Say "a damaged download - send this report and the Godot log."
}

$out | Set-Content -Path $Report -Encoding utf8
Write-Host ""
Write-Host ("Saved to " + $Report)
Write-Host "Please send that file back."
# HP_QUIET keeps our own tests from opening a Notepad window on someone's
# screen. Users never set it, so they always get the report opened for them.
if (-not $env:HP_QUIET) { Start-Process notepad.exe $Report }
if ($bad.Count -gt 0) { exit 1 } else { exit 0 }
