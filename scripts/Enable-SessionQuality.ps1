# Session quality: run the Windows audio stack so Remote Audio playback/
# microphone redirection can work. Best-effort by design - audio-less VMs
# warn instead of failing.
#
# An earlier version also preferred the H.264/AVC 444 graphics mode
# (AVC444ModePreferred=1). It was REVERTED after a live session: this
# runner has no GPU, so 444 encoding runs on the CPU and made the display
# and connection noticeably laggy for little visual gain. Do not re-add
# it unless the runner ever gets hardware encoding.
$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force

Write-Step 'Session quality (audio)'

foreach ($serviceName in @('AudioEndpointBuilder', 'Audiosrv')) {
    try {
        Set-Service -Name $serviceName -StartupType Automatic -ErrorAction Stop
        Start-Service -Name $serviceName -ErrorAction Stop
        Write-Ok "$serviceName running"
    } catch {
        Write-Warn "$serviceName could not start (expected on audio-less VMs): $($_.Exception.Message)"
    }
}

exit 0
