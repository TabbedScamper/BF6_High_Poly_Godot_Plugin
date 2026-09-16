[CmdletBinding()]
param(
    [string]$UnrealProject = 'C:\Users\mwalt\Documents\Unreal Projects\BF6_High_Poly',
    [ValidateSet('Debug', 'Release', 'RelWithDebInfo', 'MinSizeRel')]
    [string]$Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$PreviewRoot = (Resolve-Path -LiteralPath (Join-Path $Here '..\..')).Path
$ProjectRoot = (Resolve-Path -LiteralPath $UnrealProject).Path
$ProjectFile = Join-Path $ProjectRoot 'BF6_Unreal_SDK.uproject'
if (-not (Test-Path -LiteralPath $ProjectFile -PathType Leaf)) {
    throw "BF6 Unreal project not found: $ProjectFile"
}

$Source = Join-Path $PreviewRoot "core\build\$Configuration\terraindxil_dispatch_test.exe"
if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
    throw "Build the terraindxil_dispatch_test target first: $Source"
}

$DestinationDir = Join-Path $ProjectRoot 'Plugins\BF6UnrealSDK\Source\ThirdParty\libbf6\bin\Win64'
$ResolvedDestination = (Resolve-Path -LiteralPath $DestinationDir).Path
$ExpectedPrefix = Join-Path $ProjectRoot 'Plugins\BF6UnrealSDK'
if (-not $ResolvedDestination.StartsWith($ExpectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing unexpected destination outside BF6UnrealSDK: $ResolvedDestination"
}

$Destination = Join-Path $ResolvedDestination 'terraindxil_dispatch_test.exe'
Copy-Item -LiteralPath $Source -Destination $Destination -Force
$Hash = Get-FileHash -Algorithm SHA256 -LiteralPath $Destination
[pscustomobject]@{
    Source = (Resolve-Path -LiteralPath $Source).Path
    Destination = $Destination
    Bytes = (Get-Item -LiteralPath $Destination).Length
    SHA256 = $Hash.Hash.ToLowerInvariant()
}
