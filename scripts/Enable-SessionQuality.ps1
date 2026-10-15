# Session quality experiments: run the Windows audio stack so Remote Audio
# playback/microphone redirection can work, and prefer the H.264/AVC 444
# graphics mode for sharper text and color fidelity. Audio may be a no-op on
# audio-less VMs; AVC444 is a preference that unsupported clients fall back
# from automatically.
$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force

Write-Step 'Session quality (audio + graphics)'

foreach ($serviceName in @('AudioEndpointBuilder', 'Audiosrv')) {
    try {
        Set-Service -Name $serviceName -StartupType Automatic -ErrorAction Stop
        Start-Service -Name $serviceName -ErrorAction Stop
        Write-Ok "$serviceName running"
    } catch {
        Write-Warn "$serviceName could not start (expected on audio-less VMs): $($_.Exception.Message)"
    }
}

# The policy "Prioritize H.264/AVC 444 graphics mode" maps to the registry
# value AVC444ModePreferred (no underscore) - per the ADMX-derived policy
# reference. Unsupported clients fall back automatically.
Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -Name 'AVC444ModePreferred' -Value 1 -Type DWord
Write-Ok 'AVC 444 graphics mode preferred (clients fall back automatically when unsupported)'

exit 0
