# Run only from a noninteractive Windows Session 0 process. Configure the
# checkout/evidence paths in this process's environment; never in machine PATH.
$ErrorActionPreference = 'Stop'
$current = [System.Diagnostics.Process]::GetCurrentProcess()
if ($current.SessionId -ne 0) {
    throw 'This runner requires Session 0 and must not run in an RDP session.'
}
$current.PriorityClass = 'BelowNormal'
if ($env:ATERMIUS_PROCESSOR_AFFINITY) {
    $current.ProcessorAffinity = [IntPtr][long]$env:ATERMIUS_PROCESSOR_AFFINITY
}
$parallelism = 2
if ($env:ATERMIUS_BUILD_PARALLELISM) {
    $parallelism = [int]$env:ATERMIUS_BUILD_PARALLELISM
}
if ($parallelism -lt 1 -or $parallelism -gt 8) {
    throw 'Windows build parallelism must stay between 1 and 8.'
}
$env:CMAKE_BUILD_PARALLEL_LEVEL = "$parallelism"
$env:CI = 'true'
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
if ($env:ATERMIUS_ATL_ROOT) {
    $atlInclude = Join-Path $env:ATERMIUS_ATL_ROOT 'include'
    $atlLib = Join-Path $env:ATERMIUS_ATL_ROOT 'lib\x64'
    if (!(Test-Path "$atlInclude\atlstr.h") -or !(Test-Path "$atlLib\atls.lib")) {
        throw 'The requested private ATL tool files are incomplete.'
    }
    $env:CL = ('/I"{0}" {1}' -f $atlInclude, $env:CL).Trim()
    $env:LINK = ('/LIBPATH:"{0}" {1}' -f $atlLib, $env:LINK).Trim()
}

$checkout = $env:ATERMIUS_CHECKOUT_ROOT
$evidence = $env:ATERMIUS_EVIDENCE_ROOT
$flutter = $env:ATERMIUS_FLUTTER_ROOT
$phase = $env:ATERMIUS_WINDOWS_PHASE
$buildMode = $env:ATERMIUS_WINDOWS_BUILD_MODE
if (!$buildMode) { $buildMode = 'release' }
if ($buildMode -notin @('release', 'profile')) { throw 'Build mode must be release or profile.' }
if (!$checkout -or !$evidence -or !$flutter) {
    throw 'Set ATERMIUS_CHECKOUT_ROOT, ATERMIUS_EVIDENCE_ROOT and ATERMIUS_FLUTTER_ROOT.'
}
if ($phase -notin @('build', 'test')) { throw 'Phase must be build or test.' }
$client = Join-Path $checkout 'apps\client'
if (!(Test-Path "$client\pubspec.yaml")) { throw 'Client checkout is missing.' }
New-Item -ItemType Directory -Force -Path $evidence | Out-Null
Set-Location -LiteralPath $client

$log = Join-Path $evidence "$phase.log"
$exitCode = 1
try {
    if ($phase -eq 'build') {
        $arguments = "build windows --$buildMode --no-pub"
    } else {
        # Native libsodium plus real file-backed SQLite recovery on Windows.
        $arguments = 'test --no-pub --concurrency=1 --reporter expanded ' +
            'test/vault_crypto_test.dart ' +
            'test/account_recovery_vector_test.dart ' +
            'test/sync_record_envelope_vector_test.dart ' +
            'test/local_record_crypto_test.dart ' +
            'test/client_database_persistence_barrier_test.dart ' +
            'test/sync_outbox_recovery_test.dart'
    }
    $command = '""{0}\bin\flutter.bat" {1} > "{2}" 2>&1"' -f $flutter, $arguments, $log
    & cmd.exe /d /s /c $command
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 0 -and $phase -eq 'build') {
        $configuration = $buildMode.Substring(0, 1).ToUpperInvariant() + $buildMode.Substring(1)
        $bundle = Join-Path $client "build\windows\x64\runner\$configuration"
        $exe = Join-Path $bundle 'aterm_client.exe'
        if (!(Test-Path $exe)) { throw 'Windows executable was not produced.' }
        $files = @(Get-ChildItem $bundle -File -Recurse | ForEach-Object {
            [ordered]@{
                Path = $_.FullName.Substring($bundle.Length + 1)
                Length = $_.Length
                Sha256 = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        })
        [ordered]@{Bundle = $bundle; Files = $files} | ConvertTo-Json -Depth 5 |
            Set-Content (Join-Path $evidence "$buildMode-manifest.json") -Encoding UTF8
    }
} catch {
    $exitCode = 1
    throw
} finally {
    [ordered]@{
        Phase = $phase
        BuildMode = $buildMode
        ExitCode = $exitCode
        SessionId = $current.SessionId
        Priority = $current.PriorityClass.ToString()
        CmakeParallelism = $env:CMAKE_BUILD_PARALLEL_LEVEL
    } | ConvertTo-Json -Depth 4 |
        Set-Content (Join-Path $evidence "$phase-result.json") -Encoding UTF8
}
if (Test-Path $log) { Get-Content $log -Tail 30 }
Get-Content (Join-Path $evidence "$phase-result.json") -Raw
exit $exitCode
