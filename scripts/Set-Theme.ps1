# Applies the requested desktop theme and the pre-validated wallpaper.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force

Write-Step 'Applying desktop personalization'

$personalize = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
if ($env:THEME -eq 'dark') {
    Set-RegistryValue -Path $personalize -Name 'AppsUseLightTheme' -Value 0 -Type DWord
    Set-RegistryValue -Path $personalize -Name 'SystemUsesLightTheme' -Value 0 -Type DWord
    Write-Ok 'Dark mode applied'
} else {
    Set-RegistryValue -Path $personalize -Name 'AppsUseLightTheme' -Value 1 -Type DWord
    Set-RegistryValue -Path $personalize -Name 'SystemUsesLightTheme' -Value 1 -Type DWord
    Write-Ok 'Light mode applied'
}

# Optional session timezone, validated during pre-flight (empty keeps UTC).
if (-not [string]::IsNullOrWhiteSpace($env:TIMEZONE_VALID)) {
    try {
        Set-TimeZone -Id $env:TIMEZONE_VALID -ErrorAction Stop
        Write-Ok "Timezone set to $($env:TIMEZONE_VALID)"
    } catch {
        Write-Warn "Could not set the timezone: $($_.Exception.Message)"
    }
}

# The wallpaper was downloaded and content-type-validated during pre-flight;
# this step only wires it into the desktop.
$wallpaperFile = $env:WALLPAPER_FILE
if (-not [string]::IsNullOrWhiteSpace($wallpaperFile) -and (Test-Path $wallpaperFile)) {
    Set-RegistryValue -Path 'HKCU:\Control Panel\Desktop' -Name 'Wallpaper' -Value $wallpaperFile
    RUNDLL32.EXE user32.dll,UpdatePerUserSystemParameters 1, True
    Write-Ok 'Custom wallpaper applied'
} else {
    Write-Warn 'No validated wallpaper available - keeping the default desktop background.'
}

exit 0
