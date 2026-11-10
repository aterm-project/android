#requires -Version 7.2
<#
Daily Windows x64 release (CI, windows-2022 runner, pwsh).

Follows docs/INSTALLATION.en.md: vcpkg openssl/zlib (x64-windows-static-md),
integration/native/build_rdp_windows.ps1 (pinned FreeRDP 3.33.0, VS 2022
generator) and `flutter build windows --release` with ATERMIUS_RDP_DIR. The
portable ZIP keeps atermius_rdp.dll, its licenses (data/licenses/desktop),
flutter_pty and every Flutter/plugin DLL. It is not code-signed.

Workers: build_rdp_windows.ps1 -Workers 2, VCPKG_MAX_CONCURRENCY=2,
CMAKE_BUILD_PARALLEL_LEVEL=2, MSBuild -maxCpuCount:2 / CL_MPCount=2.

Env: ATERMIUS_SOURCE_SHA ATERMIUS_RELEASE_TAG ATERMIUS_OUT ATERMIUS_VCPKG_CACHE
     ATERMIUS_FIREBASE_CACHE RUNNER_TEMP; flutter on PATH.
#>
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'
$Workers = 2
# Firebase C++ SDK digests verified out of band (the plugin's CMake would
# otherwise download it without any check). Unknown versions are recorded.
$FirebaseSdkSha256 = @{ '13.12.0' = 'c4a11fcbe192084f3007b9e08ee1f4134b844e4b5951ccaabe64cf69c33a7cee' }

function Need([string]$Name) {
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($v)) { throw "Missing environment value $Name." }
    return $v
}
function Sha256([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

$SourceSha = Need 'ATERMIUS_SOURCE_SHA'
$Tag = Need 'ATERMIUS_RELEASE_TAG'
$Out = Need 'ATERMIUS_OUT'
$VcpkgCache = Need 'ATERMIUS_VCPKG_CACHE'
$FirebaseCache = Need 'ATERMIUS_FIREBASE_CACHE'
$Temp = Need 'RUNNER_TEMP'
$Root = (git rev-parse --show-toplevel).Trim()
$Tools = Join-Path $Root '.github/daily-build'
$Meta = Join-Path $Temp 'meta'
if ((git -C $Root rev-parse HEAD).Trim() -ne $SourceSha) { throw 'Checkout is not the claimed source.' }
New-Item -ItemType Directory -Force -Path $Out, $Meta, $VcpkgCache, $FirebaseCache | Out-Null
$Info = [ordered]@{}

Write-Host '::group::Visual Studio 2022 with C++ x64 and ATL'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs = @(& $vswhere -latest -products * -version '[17.0,18.0)' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 Microsoft.VisualStudio.Component.VC.ATL -format json | Out-String | ConvertFrom-Json)
if ($vs.Count -ne 1) { throw 'Runner lacks Visual Studio 2022 with C++ x64 tools and ATL (build_rdp_windows.ps1 uses the VS 2022 generator; flutter_secure_storage needs ATL).' }
$latest = & $vswhere -latest -products * -property installationVersion
if (-not "$latest".StartsWith('17.')) { throw "build_rdp_windows.ps1 picks the newest Visual Studio ($latest) but generates for VS 2022; use a VS 2022-only image." }
$Info.visual_studio = [ordered]@{ display = $vs[0].displayName; version = $vs[0].installationVersion }
Write-Host '::endgroup::'

Write-Host '::group::vcpkg openssl + zlib (x64-windows-static-md)'
$Vcpkg = Need 'VCPKG_INSTALLATION_ROOT'
$env:VCPKG_MAX_CONCURRENCY = "$Workers"
$env:VCPKG_DEFAULT_BINARY_CACHE = $VcpkgCache
$env:VCPKG_DISABLE_METRICS = '1'
& (Join-Path $Vcpkg 'vcpkg.exe') install openssl:x64-windows-static-md zlib:x64-windows-static-md
$Info.vcpkg = [ordered]@{
    commit = (git -C $Vcpkg rev-parse HEAD).Trim()
    # `vcpkg list` accepts at most one filter. Query once, then retain both
    # installed target packages for the release evidence.
    packages = @(& (Join-Path $Vcpkg 'vcpkg.exe') list | ForEach-Object { "$_".Trim() } |
        Where-Object { $_ -match '^(openssl|zlib):x64-windows-static-md\s' })
}
Write-Host '::endgroup::'

Write-Host '::group::RDP engine (build_rdp_windows.ps1)'
& (Join-Path $Root 'integration/native/build_rdp_windows.ps1') -VcpkgRoot $Vcpkg -Workers $Workers
$Bundle = Join-Path $Root 'apps/client/native/desktop/build/windows/bundle'
foreach ($f in 'atermius_rdp.dll', 'build-manifest.json', 'licenses/desktop/FreeRDP.txt', 'licenses/desktop/OpenSSL.txt', 'licenses/desktop/zlib.txt') {
    if (!(Test-Path -LiteralPath (Join-Path $Bundle $f) -PathType Leaf)) { throw "Engine bundle lacks $f." }
}
$EngineSha = Sha256 (Join-Path $Bundle 'atermius_rdp.dll')
Copy-Item (Join-Path $Bundle 'build-manifest.json') (Join-Path $Meta 'engine-manifest.json')
Write-Host '::endgroup::'

Write-Host '::group::Flutter dependencies and Firebase C++ SDK'
& python -I (Join-Path $Tools 'recipe/flutter_sdk.py') verify --out (Join-Path $Meta 'flutter-version.json')
$App = Join-Path $Root 'apps/client'
Push-Location $App
try { flutter config --no-analytics | Out-Null; flutter pub get --enforce-lockfile } finally { Pop-Location }
$pcPath = [IO.Path]::GetFullPath((Join-Path $App '.dart_tool/package_config.json'))
$fc = @((Get-Content -LiteralPath $pcPath -Raw | ConvertFrom-Json).packages | Where-Object { $_.name -eq 'firebase_core' })
$Info.firebase_sdk = $null
if ($fc.Count -eq 1) {
    $fcRoot = [IO.Path]::GetFullPath(([Uri]::new([Uri]::new($pcPath), [string]$fc[0].rootUri)).LocalPath)
    $cm = Get-Content -LiteralPath (Join-Path $fcRoot 'windows/CMakeLists.txt') -Raw
    if ($cm -notmatch 'set\(FIREBASE_SDK_VERSION "(?<v>\d+\.\d+\.\d+)"\)') { throw 'Cannot read FIREBASE_SDK_VERSION from firebase_core.' }
    $fbVersion = $Matches['v']
    $fbDir = Join-Path $FirebaseCache "firebase_cpp_sdk_windows_$fbVersion"
    $fbZip = Join-Path $FirebaseCache "firebase_cpp_sdk_windows_$fbVersion.zip"
    if (!(Test-Path -LiteralPath $fbZip)) {
        Invoke-WebRequest -Uri "https://dl.google.com/firebase/sdk/cpp/firebase_cpp_sdk_windows_$fbVersion.zip" -OutFile $fbZip -MaximumRetryCount 3 -RetryIntervalSec 15
    }
    $fbSha = Sha256 $fbZip
    $pinned = $FirebaseSdkSha256[$fbVersion]
    if ($pinned -and $fbSha -ne $pinned) { Remove-Item -LiteralPath $fbZip; throw "Firebase C++ SDK $fbVersion digest $fbSha differs from the pin." }
    if (-not $pinned) { Write-Host "::warning::Firebase C++ SDK $fbVersion is not pinned (sha256 $fbSha); add it to desktop_windows.ps1." }
    if (!(Test-Path -LiteralPath (Join-Path $fbDir 'firebase_cpp_sdk_windows/include/firebase/version.h'))) {
        if (Test-Path -LiteralPath $fbDir) { Remove-Item -Recurse -Force -LiteralPath $fbDir }
        Expand-Archive -LiteralPath $fbZip -DestinationPath $fbDir
    }
    $env:FIREBASE_CPP_SDK_DIR = ((Join-Path $fbDir 'firebase_cpp_sdk_windows') -replace '\\', '/')
    $Info.firebase_sdk = [ordered]@{ version = $fbVersion; sha256 = $fbSha; pinned = [bool]$pinned }
}
Write-Host '::endgroup::'

Write-Host '::group::flutter build windows --release'
# MSBuild reads Directory.Build.rsp from ancestors of the generated projects;
# the checkout's parent directory is outside the repository.
Set-Content -LiteralPath (Join-Path (Split-Path $Root -Parent) 'Directory.Build.rsp') -Encoding ascii -Value @("-maxCpuCount:$Workers", '-nodeReuse:false')
$env:CMAKE_BUILD_PARALLEL_LEVEL = "$Workers"
$env:UseMultiToolTask = 'true'
$env:EnforceProcessCountAcrossBuilds = 'true'
$env:CL_MPCount = "$Workers"
$env:ATERMIUS_RDP_DIR = ($Bundle -replace '\\', '/')
Push-Location $App
try { flutter build windows --release --no-pub --target lib/main.dart } finally { Pop-Location }
$Release = Join-Path $App 'build/windows/x64/runner/Release'
foreach ($f in 'aterm_client.exe', 'flutter_windows.dll', 'atermius_rdp.dll', 'data/app.so', 'data/icudtl.dat',
               'data/licenses/desktop/FreeRDP.txt', 'data/licenses/desktop/OpenSSL.txt', 'data/licenses/desktop/zlib.txt') {
    if (!(Test-Path -LiteralPath (Join-Path $Release $f) -PathType Leaf)) { throw "Release output lacks $f." }
}
if ((Sha256 (Join-Path $Release 'atermius_rdp.dll')) -ne $EngineSha) { throw 'Packaged atermius_rdp.dll is not the engine built by this run.' }
if (@(Get-ChildItem -LiteralPath $Release -Filter '*pty*.dll').Count -eq 0) { throw 'Release output lacks the flutter_pty DLL.' }
Write-Host '::endgroup::'

Write-Host '::group::Package'
$Stage = Join-Path $Temp 'stage'
if (Test-Path $Stage) { Remove-Item -Recurse -Force $Stage }
New-Item -ItemType Directory -Path $Stage | Out-Null
$excluded = @()
Get-ChildItem -LiteralPath $Release -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Substring($Release.Length + 1)
    if ($_.Extension -in '.pdb', '.lib', '.exp', '.ilk') { $excluded += $rel; return }
    $dest = Join-Path $Stage $rel
    New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent) | Out-Null
    Copy-Item -LiteralPath $_.FullName -Destination $dest
}
$Info.excluded_build_byproducts = $excluded
$files = @(Get-ChildItem -LiteralPath $Stage -Recurse -File | Sort-Object FullName | ForEach-Object {
    [ordered]@{ path = $_.FullName.Substring($Stage.Length + 1).Replace('\', '/'); size = $_.Length; sha256 = Sha256 $_.FullName } })
$files | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $Meta 'bundle-files.json') -Encoding utf8NoBOM
$Info.engine_sha256 = $EngineSha
$Info | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $Meta 'windows.json') -Encoding utf8NoBOM
$version = ((Get-Content (Join-Path $App 'pubspec.yaml') | Where-Object { $_ -match '^version:\s*([0-9][0-9.]*)' } | Select-Object -First 1) -replace '^version:\s*([0-9][0-9.]*).*$', '$1')
$name = "atermius-desktop-windows-x64-$version-$($Tag.Substring(6)).zip"
& python -I (Join-Path $Tools 'release_tool.py') archive --src $Stage --out (Join-Path $Out $name) --prefix atermius-windows-x64
& python -I (Join-Path $Tools 'release_tool.py') evidence --platform windows-x64 --out-dir $Out --artifact $name `
    --meta "version_name=$version" --meta 'entry_point=lib/main.dart' --meta "build_workers=$Workers" `
    --meta "rdp_engine_sha256=$EngineSha" `
    --attach "flutter=$(Join-Path $Meta 'flutter-version.json')" --attach "engine_manifest=$(Join-Path $Meta 'engine-manifest.json')" `
    --attach "windows=$(Join-Path $Meta 'windows.json')" --attach "bundle_files=$(Join-Path $Meta 'bundle-files.json')" `
    --note 'Portable ZIP (no installer, not code-signed; SmartScreen may warn). Extract the whole folder and start aterm_client.exe.' `
    --note 'Includes the embedded RDP engine atermius_rdp.dll (FreeRDP 3.33.0 + OpenSSL/zlib from vcpkg, versions in the evidence) with licenses under data/licenses/desktop.' `
    --note 'Needs the Microsoft Visual C++ x64 runtime on the target machine.' | Out-Null
Get-ChildItem -LiteralPath $Out | Format-Table Name, Length
Write-Host '::endgroup::'
