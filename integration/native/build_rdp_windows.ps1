param(
  [Parameter(Mandatory=$true)][string]$VcpkgRoot,
  [string]$BuildDirectory,
  [string]$SourceDirectory,
  [ValidateRange(1,8)][int]$Workers=8,
  # Extra -D options, e.g. '-DATERMIUS_RDP_CAMERA=OFF' or '-DATERMIUS_RDP_USB=ON'.
  [string[]]$CMakeOptions=@(),
  # Dynamic libusb prefix (vcpkg install libusb:x64-windows), enables USB.
  [string]$LibusbRoot
)
$ErrorActionPreference='Stop'
$source=$SourceDirectory
if(!$source){$source=Join-Path $PSScriptRoot '..\..\apps\client\native\desktop'}
if(!$BuildDirectory){$BuildDirectory=Join-Path $source 'build\windows'}
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs=& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if(!$vs){throw 'Visual Studio C++ build tools are required'}
$cmake=Join-Path $vs 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
$toolchain=Join-Path $VcpkgRoot 'scripts\buildsystems\vcpkg.cmake'
if(!(Test-Path $toolchain)){throw 'vcpkg checkout not found'}
if($LibusbRoot){
  $LibusbRoot=(Resolve-Path $LibusbRoot).Path
  $CMakeOptions+=@('-DATERMIUS_RDP_USB=ON',"-DATERMIUS_LIBUSB_ROOT=$($LibusbRoot -replace '\\','/')")
}
$ErrorActionPreference='Continue' # Native stderr contains CMake warnings; check exit codes explicitly.
& $cmake -S $source -B $BuildDirectory -G 'Visual Studio 17 2022' -A x64 `
  "-DCMAKE_TOOLCHAIN_FILE=$toolchain" '-DVCPKG_TARGET_TRIPLET=x64-windows-static-md' `
  '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL' '-DCMAKE_BUILD_TYPE=Release' @CMakeOptions
if($LASTEXITCODE -ne 0){throw 'Native RDP configure failed'}
& $cmake --build $BuildDirectory --target atermius_rdp --config Release --parallel $Workers
if($LASTEXITCODE -ne 0){throw 'Native RDP build failed'}
$ErrorActionPreference='Stop'
$bundle=Join-Path $BuildDirectory 'bundle'
$licenses=Join-Path $bundle 'licenses\desktop'
New-Item -ItemType Directory -Force $licenses|Out-Null
Copy-Item (Join-Path $BuildDirectory 'Release\atermius_rdp.dll') $bundle
Copy-Item (Join-Path $BuildDirectory '_deps\freerdp-src\LICENSE') (Join-Path $licenses 'FreeRDP.txt')
$installed=Join-Path $VcpkgRoot 'installed\x64-windows-static-md\share'
Copy-Item (Join-Path $installed 'openssl\copyright') (Join-Path $licenses 'OpenSSL.txt')
Copy-Item (Join-Path $installed 'zlib\copyright') (Join-Path $licenses 'zlib.txt')
$usbDll=Join-Path $BuildDirectory 'Release\libusb-1.0.dll'
if($LibusbRoot){
  # An engine built with USB cannot load without its libusb DLL.
  if(!(Test-Path $usbDll)){throw 'USB engine built but libusb-1.0.dll was not produced'}
  Copy-Item $usbDll $bundle
  Copy-Item (Join-Path $LibusbRoot 'share\libusb\copyright') (Join-Path $licenses 'libusb-LGPL-2.1.txt')
  Set-Content (Join-Path $licenses 'libusb-NOTICE.txt') -Encoding UTF8 -Value @(
    'libusb-1.0.dll is dynamically linked and replaceable (LGPL-2.1).',
    'Source: https://github.com/libusb/libusb (version as built by vcpkg; see build-manifest.json).',
    'Atermius installs no USB driver; only devices already bound to WinUSB/libusbK/usbdk can be redirected.')
}
[ordered]@{
  freerdp='3.33.0'
  freerdp_source_sha256='80cbcf17a7de00909f2be805c7d93764596cd712046addc18c30594137c0b879'
  engine_sha256=(Get-FileHash (Join-Path $bundle 'atermius_rdp.dll') -Algorithm SHA256).Hash.ToLowerInvariant()
  options=$CMakeOptions
  libusb_sha256=$(if($LibusbRoot){(Get-FileHash (Join-Path $bundle 'libusb-1.0.dll') -Algorithm SHA256).Hash.ToLowerInvariant()}else{$null})
}|ConvertTo-Json|Set-Content (Join-Path $bundle 'build-manifest.json') -Encoding UTF8
Write-Output "Bundled RDP engine: $bundle"
