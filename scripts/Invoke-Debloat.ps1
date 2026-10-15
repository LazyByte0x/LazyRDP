# Debloat and tuning in three intensity levels, chosen by the debloat_level
# input: light = performance tuning only (power plan + mouse acceleration,
# nothing removed), standard = the historical behavior (consumer bloatware +
# telemetry services + tuning), deep = standard plus removals vetted as safe
# for a short-lived RDP session (more AppX packages, more services, Windows
# Update held for the session, Compatibility Appraiser task disabled).
# Session-critical components (Tailscale, the RDP listener, OpenSSH, Remote
# Desktop Services, networking) are never touched at any level.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force

Write-Step 'Debloating and optimizing Windows'

$level = 'standard'
if (-not [string]::IsNullOrWhiteSpace($env:DEBLOAT_LEVEL)) { $level = $env:DEBLOAT_LEVEL.Trim().ToLowerInvariant() }
if ($level -notin @('light', 'standard', 'deep')) {
    Write-Warn "Unknown debloat level '$($env:DEBLOAT_LEVEL)' - falling back to 'standard'."
    $level = 'standard'
}
Write-Ok "Debloat level: $level"

$packagesRemoved = 0
$servicesDisabled = 0

if ($level -ne 'light') {
    # Consumer bloatware. Missing packages are not an error - the image changes
    # over time. The deep tier adds the larger consumer apps a desktop session
    # never launches (GameBar overlays would only fight OBS for capture anyway).
    $packagePatterns = @(
        '*Microsoft.People*',
        '*Microsoft.Wallet*',
        '*Microsoft.ZuneMusic*',
        '*Microsoft.ZuneVideo*',
        '*Microsoft.XboxApp*',
        '*Microsoft.YourPhone*',
        '*Microsoft.WindowsFeedbackHub*',
        '*Microsoft.GetHelp*'
    )
    if ($level -eq 'deep') {
        $packagePatterns += @(
            '*Microsoft.Copilot*',
            '*MSTeams*',
            '*MicrosoftTeams*',
            '*Microsoft.XboxGamingOverlay*',
            '*Microsoft.XboxGameOverlay*',
            '*Microsoft.GamingApp*',
            '*Microsoft.Xbox.TCUI*',
            '*Microsoft.Clipchamp*',
            '*Microsoft.OutlookForWindows*',
            '*Microsoft.PowerAutomateDesktop*',
            '*Microsoft.549981C3F5F10*',
            '*Microsoft.windowscommunicationsapps*'
        )
    }
    foreach ($pattern in $packagePatterns) {
        foreach ($package in @(Get-AppxPackage -Name $pattern -ErrorAction SilentlyContinue)) {
            Remove-AppxPackage -Package $package.PackageFullName -ErrorAction SilentlyContinue
            $packagesRemoved++
        }
    }
    Write-Ok "$packagesRemoved preinstalled packages matched and removed (failures suppressed)"

    # Telemetry services at both levels. The deep tier adds services a
    # headless desktop session never benefits from: search indexing (constant
    # disk churn for a 6-hour box), the print spooler (printer redirection
    # into a VM is a feature nobody uses here), SysMain prefetching, the Xbox
    # stack (OBS does the recording), and error reporting. wuauserv/DoSvc hold
    # Windows Update for the session so no mid-use update steals CPU or
    # reboots the machine; nothing later in the workflow needs them (winget
    # installs from its own source, Chrome comes as a direct MSI).
    $serviceNames = @('DiagTrack', 'dmwappushservice')
    if ($level -eq 'deep') {
        $serviceNames += @('WSearch', 'Spooler', 'SysMain', 'XblAuthManager', 'XblGameSave', 'XboxNetApiSvc', 'XboxGipSvc', 'WerSvc', 'wuauserv', 'DoSvc')
    }
    foreach ($serviceName in $serviceNames) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($null -eq $service) { continue }
        Set-Service -Name $serviceName -StartupType Disabled -ErrorAction SilentlyContinue
        if ($service.Status -eq 'Running') { Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue }
        $servicesDisabled++
    }
    Write-Ok "$servicesDisabled services disabled (level: $level)"

    if ($level -eq 'deep') {
        # Compatibility Appraiser is the inventory/telemetry task that
        # periodically burns noticeable CPU on idle systems.
        Disable-ScheduledTask -TaskPath '\Microsoft\Windows\Application Experience\' -TaskName 'Microsoft Compatibility Appraiser' -ErrorAction SilentlyContinue | Out-Null
        Write-Ok 'Compatibility Appraiser scheduled task disabled'
    }
}

# Performance tuning applies at every level. The Ultimate Performance GUID is
# extracted with a regex because powercfg output formatting varies across
# images and locales.
powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 | Out-Null
$schemeLine = (powercfg /list) | Where-Object { $_ -like '*Ultimate*' } | Select-Object -First 1
if ($null -eq $schemeLine) { throw 'Ultimate Performance power plan not found after duplication.' }
$guidMatch = [regex]::Match($schemeLine, '[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}')
if (-not $guidMatch.Success) { throw "Could not parse the Ultimate Performance plan GUID from: $schemeLine" }
powercfg /setactive $guidMatch.Value | Out-Null
Write-Ok "Ultimate Performance plan active ($($guidMatch.Value))"

# Disable mouse acceleration for raw pointer input (the workflow user's
# profile, which is the account the session personalizes).
Set-RegistryValue -Path 'HKCU:\Control Panel\Mouse' -Name 'MouseSpeed' -Value '0'
Set-RegistryValue -Path 'HKCU:\Control Panel\Mouse' -Name 'MouseThreshold1' -Value '0'
Set-RegistryValue -Path 'HKCU:\Control Panel\Mouse' -Name 'MouseThreshold2' -Value '0'
Write-Ok 'Mouse acceleration disabled'

Add-GithubEnv -Name 'DEBLOAT_LEVEL_APPLIED' -Value $level
Add-GithubEnv -Name 'DEBLOAT_PACKAGES_REMOVED' -Value "$packagesRemoved"
Add-GithubEnv -Name 'DEBLOAT_SERVICES_DISABLED' -Value "$servicesDisabled"

exit 0
