# Extract the two official ATL payloads into this task's private tools directory.
# No installer, registry changes or edits to the installed Visual Studio occur.
$ErrorActionPreference = 'Stop'
$current = [System.Diagnostics.Process]::GetCurrentProcess()
if ($current.SessionId -ne 0) { throw 'Tool preparation requires Session 0.' }
$current.PriorityClass = 'BelowNormal'
if ($env:ATERMIUS_PROCESSOR_AFFINITY) {
    $current.ProcessorAffinity = [IntPtr][long]$env:ATERMIUS_PROCESSOR_AFFINITY
}
$catalogPath = $env:ATERMIUS_VS_CATALOG
$destination = $env:ATERMIUS_ATL_ROOT
$prefix = $env:ATERMIUS_ATL_PACKAGE_PREFIX
if (!$catalogPath -or !$destination -or !$prefix) {
    throw 'Set ATERMIUS_VS_CATALOG, ATERMIUS_ATL_ROOT and ATERMIUS_ATL_PACKAGE_PREFIX.'
}
$destination = [IO.Path]::GetFullPath($destination).TrimEnd('\')
New-Item -ItemType Directory -Force -Path $destination | Out-Null
$catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
Add-Type -AssemblyName System.IO.Compression.FileSystem
$ProgressPreference = 'SilentlyContinue'
$records = @()
foreach ($suffix in @('Headers.base', 'X64.base')) {
    $id = "$prefix.$suffix"
    $packages = @($catalog.packages | Where-Object { $_.id -eq $id })
    if ($packages.Count -ne 1) { throw "Expected one catalog entry for $id." }
    $package = $packages[0]
    if ($package.type -ne 'Vsix' -or @($package.payloads).Count -ne 1) {
        throw 'Unexpected ATL payload format.'
    }
    $payload = $package.payloads[0]
    $uri = [Uri]$payload.url
    if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'download.visualstudio.microsoft.com') {
        throw 'ATL payload is not hosted by the expected Microsoft endpoint.'
    }
    $archive = Join-Path $destination "$suffix.vsix"
    if (!(Test-Path $archive)) {
        Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $archive
    }
    $hash = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -ne $payload.sha256) {
        throw "ATL payload hash mismatch: $id"
    }
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    $count = 0
    try {
        foreach ($entry in $zip.Entries) {
            if ($entry.FullName -notmatch '^Contents/VC/Tools/MSVC/[^/]+/atlmfc/(?<relative>(include|lib/x64)/.+)$') {
                continue
            }
            if ($entry.FullName.EndsWith('/')) { continue }
            $relative = $Matches['relative'].Replace('/', '\')
            $target = [IO.Path]::GetFullPath((Join-Path $destination $relative))
            if (!$target.StartsWith($destination + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw 'ATL payload path escaped the private tools directory.'
            }
            New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($target)) | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
            $count++
        }
    } finally { $zip.Dispose() }
    if ($count -eq 0) { throw "ATL payload contained no expected files: $id" }
    $records += [ordered]@{
        Id = $id; Version = $package.version; Url = $payload.url
        Sha256 = $hash; CatalogSize = $payload.size
        DownloadedSize = (Get-Item $archive).Length; ExtractedFiles = $count
    }
}
if (!(Test-Path "$destination\include\atlstr.h") -or !(Test-Path "$destination\lib\x64\atls.lib")) {
    throw 'Private ATL headers or x64 library are missing.'
}
[ordered]@{
    CatalogSha256 = (Get-FileHash $catalogPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Destination = $destination; Payloads = $records
} | ConvertTo-Json -Depth 6 | Set-Content "$destination\manifest.json" -Encoding UTF8
Get-Content "$destination\manifest.json" -Raw
