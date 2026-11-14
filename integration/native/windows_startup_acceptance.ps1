# A bounded read-only UI Automation probe of this task's Session 0 window.
# No SendInput, clipboard, desktop switching, RDP or machine settings are used.
$ErrorActionPreference = 'Stop'
$current = [System.Diagnostics.Process]::GetCurrentProcess()
if ($current.SessionId -ne 0) { throw 'Startup probe requires Session 0.' }
$current.PriorityClass = 'BelowNormal'
if ($env:ATERMIUS_PROCESSOR_AFFINITY) {
    $current.ProcessorAffinity = [IntPtr][long]$env:ATERMIUS_PROCESSOR_AFFINITY
}
if ($env:ATERMIUS_SOFTWARE_RENDERING -eq '1') {
    # Official Flutter desktop engine environment switches; process-local only.
    $env:FLUTTER_ENGINE_SWITCHES = '2'
    $env:FLUTTER_ENGINE_SWITCH_1 = 'enable-software-rendering=true'
    $env:FLUTTER_ENGINE_SWITCH_2 = 'enable-impeller=false'
}
$bundle = $env:ATERMIUS_WINDOWS_BUNDLE
$evidence = $env:ATERMIUS_EVIDENCE_ROOT
if (!$bundle -or !$evidence) { throw 'Set bundle and evidence paths.' }
$exe = Join-Path $bundle 'aterm_client.exe'
if (!(Test-Path $exe)) { throw 'Release executable is missing.' }
New-Item -ItemType Directory -Force -Path $evidence | Out-Null
$app = $null
$probe = $null
$result = [ordered]@{
    SessionId = $current.SessionId
    Bundle = $bundle
    BuildMode = $env:ATERMIUS_WINDOWS_BUILD_MODE
    ExeSha256 = (Get-FileHash $exe -Algorithm SHA256).Hash.ToLowerInvariant()
    WindowObserved = $false
    ChooserObserved = $false
    StartupRecoveryObserved = $false
    ReadOnlyAutomation = $true
    SoftwareRendering = ($env:ATERMIUS_SOFTWARE_RENDERING -eq '1')
    EngineSwitches = @($env:FLUTTER_ENGINE_SWITCH_1, $env:FLUTTER_ENGINE_SWITCH_2)
    Cleanup = 'not-started'
}
$exitCode = 1
try {
    $app = Start-Process -FilePath $exe -WorkingDirectory $bundle -PassThru `
        -RedirectStandardOutput (Join-Path $evidence 'startup-stdout.log') `
        -RedirectStandardError (Join-Path $evidence 'startup-stderr.log')
    if ($app.SessionId -ne 0) { throw 'Unexpected nonzero application session.' }
    $app.PriorityClass = 'BelowNormal'
    if ($env:ATERMIUS_PROCESSOR_AFFINITY) {
        $app.ProcessorAffinity = [IntPtr][long]$env:ATERMIUS_PROCESSOR_AFFINITY
    }
    $result.AppProcessId = $app.Id
    $result.AppSessionId = $app.SessionId
    $deadline = (Get-Date).AddSeconds(25)
    while ((Get-Date) -lt $deadline) {
        $app.Refresh()
        if ($app.HasExited) { throw "Application exited with code $($app.ExitCode)." }
        if ($app.MainWindowHandle -ne [IntPtr]::Zero) { break }
        Start-Sleep -Milliseconds 250
    }
    $app.Refresh()
    if ($app.MainWindowHandle -eq [IntPtr]::Zero) { throw 'No application window within 25 seconds.' }
    $result.WindowObserved = $true
    $result.WindowTitle = $app.MainWindowTitle
    $probeCode = @'
$ErrorActionPreference = 'Stop'
if ([System.Diagnostics.Process]::GetCurrentProcess().SessionId -ne 0) { throw 'Probe is outside Session 0.' }
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$target = Get-Process -Id __PID__
if ($target.SessionId -ne 0) { throw 'Target is outside Session 0.' }
$root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]__HWND__)
if ($root.Current.ProcessId -ne __PID__) { throw 'UI Automation target PID changed.' }
$names = @('Choose a workspace','Server account and sync','Local-only profile','Continue','Open locally','Atermius','无法初始化安全工作区','正在准备安全工作区')
$until = (Get-Date).AddSeconds(15)
do {
    $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
    $found = @($all | Where-Object { $_.Current.ProcessId -eq __PID__ -and $_.Current.Name -in $names } | ForEach-Object {$_.Current.Name} | Sort-Object -Unique)
    if (($found -contains 'Choose a workspace' -and $found -contains 'Open locally') -or $found -contains '无法初始化安全工作区') { break }
    Start-Sleep -Milliseconds 500
} while ((Get-Date) -lt $until)
[ordered]@{RootProcessId=$root.Current.ProcessId;NodeCount=$all.Count;AllowedNames=$found;ChooserObserved=($found -contains 'Choose a workspace' -and $found -contains 'Open locally');StartupRecoveryObserved=($found -contains '无法初始化安全工作区')} | ConvertTo-Json -Compress
'@
    $probeCode = $probeCode.Replace('__PID__', [string]$app.Id).Replace('__HWND__', [string]$app.MainWindowHandle.ToInt64())
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probeCode))
    $probeOut = Join-Path $evidence 'startup-uia.json'
    $probeErr = Join-Path $evidence 'startup-uia-error.log'
    $probe = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded
    ) -RedirectStandardOutput $probeOut -RedirectStandardError $probeErr -PassThru
    if ($probe.SessionId -ne 0) { throw 'UI probe is outside Session 0.' }
    if (!$probe.WaitForExit(20000)) { throw 'UI Automation probe exceeded 20 seconds.' }
    if ($probe.ExitCode -ne 0) { throw 'UI Automation probe failed; see probe error log.' }
    $observed = Get-Content $probeOut -Raw -Encoding UTF8 | ConvertFrom-Json
    $result.ChooserObserved = [bool]$observed.ChooserObserved
    $result.StartupRecoveryObserved = [bool]$observed.StartupRecoveryObserved
    $result.Automation = $observed
    if (!$result.ChooserObserved) { throw 'Mode chooser was not observed; startup is not accepted.' }
    $exitCode = 0
} catch {
    $result.Error = $_.Exception.Message
} finally {
    if ($probe -and !$probe.HasExited -and $probe.SessionId -eq 0) {
        $probe.Kill()
        $null = $probe.WaitForExit(3000)
    }
    if ($app -and !$app.HasExited -and $app.SessionId -eq 0) {
        $null = $app.CloseMainWindow()
        if (!$app.WaitForExit(5000)) {
            $app.Kill()
            $null = $app.WaitForExit(3000)
            $result.Cleanup = 'owned-process-killed'
        } else { $result.Cleanup = 'owned-window-closed' }
    } elseif ($app) { $result.Cleanup = 'owned-process-already-exited' }
    $result.ExitCode = $exitCode
    $result | ConvertTo-Json -Depth 6 |
        Set-Content (Join-Path $evidence 'startup-result.json') -Encoding UTF8
}
Get-Content (Join-Path $evidence 'startup-result.json') -Raw
exit $exitCode
