# Fails fast on missing configuration before any expensive setup work runs.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force

Write-Step 'Pre-flight validation'

# 1. The Tailscale key must exist. Failing here is cheap; failing after the app
#    installs would waste ten minutes of runner time.
if ([string]::IsNullOrWhiteSpace($env:TAILSCALE_AUTH_KEY)) {
    Write-Host '::error::TAILSCALE_AUTH_KEY secret is not set. Add it under Settings > Secrets and variables > Actions.' -ForegroundColor Red
    exit 1
}
Write-Ok 'TAILSCALE_AUTH_KEY secret is present'

# 1b. Credential reachability. The Summary always masks passwords, so a
#    session with no notification channels and no RDP_PASSWORD has no way to
#    surface its generated passwords - warn before any setup time is spent.
$hasTelegram = (-not [string]::IsNullOrWhiteSpace($env:TELEGRAM_BOT_TOKEN)) -and (-not [string]::IsNullOrWhiteSpace($env:TELEGRAM_CHAT_ID))
$hasDiscord = -not [string]::IsNullOrWhiteSpace($env:DISCORD_WEBHOOK_URL)
if (-not $hasTelegram -and -not $hasDiscord -and [string]::IsNullOrWhiteSpace($env:RDP_PASSWORD)) {
    Write-Host '::warning::No notification secrets and no RDP_PASSWORD are configured - generated passwords will be unreachable because the Summary always masks them. Add TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID or DISCORD_WEBHOOK_URL, or set RDP_PASSWORD.' -ForegroundColor Yellow
} else {
    Write-Ok 'Credential delivery path available (notification channels or RDP_PASSWORD)'
}

# 2. Theme must be one of the supported values.
$theme = $env:THEME
if ($theme -notin @('dark', 'light')) {
    Write-Host "::error::Invalid theme '$theme'. Expected 'dark' or 'light'." -ForegroundColor Red
    exit 1
}
Write-Ok "Theme: $theme"

# 3. Clamp the session lifetime to 1-6 hours. Hosted runners cap jobs at 360
#    minutes, so the effective lifetime stops a few minutes short of it to allow
#    a graceful shutdown instead of a timeout failure.
$sessionHours = 5.9
if (-not [double]::TryParse($env:SESSION_HOURS, [ref]$sessionHours)) { $sessionHours = 5.9 }
$sessionHours = [Math]::Max(1, [Math]::Min($sessionHours, 6))
if ($sessionHours -gt 5.9) { $sessionHours = 5.9 }
Add-GithubEnv -Name 'SESSION_HOURS_EFFECTIVE' -Value "$sessionHours"
Write-Ok "Session lifetime: $sessionHours hours"

# 4. Wallpaper: use the custom URL when it really serves an image (verified by
#    headers OR file signature); otherwise fall back to the wallpaper bundled
#    in the repo so the desktop is never bare. The verdict reason is logged.
$defaultWallpaper = Join-Path $env:GITHUB_WORKSPACE 'assets\wallpaper.jpg'
$wallpaperFile = ''
$wallpaperNote = ''
if ([string]::IsNullOrWhiteSpace($env:WALLPAPER_URL)) {
    if (Test-Path $defaultWallpaper) { $wallpaperFile = $defaultWallpaper; $wallpaperNote = 'bundled default (no custom URL provided)' }
    Write-Warn 'No wallpaper URL provided - the bundled default will be applied.'
} else {
    $download = Join-Path $env:PUBLIC 'wallpaper.jpg'
    $response = Invoke-DownloadWithRetry -Uri $env:WALLPAPER_URL -OutFile $download -Attempts 2
    $contentType = ''
    if ($null -ne $response -and $response.Headers['Content-Type']) { $contentType = ($response.Headers['Content-Type'] -join ';') }
    if ($null -ne $response -and (Test-ImageResponse $response)) {
        $wallpaperFile = $download
        $wallpaperNote = 'custom URL'
        Write-Ok 'Wallpaper URL is reachable and serves an image'
    } elseif ($null -ne $response -and (Test-ImageFile $download)) {
        $wallpaperFile = $download
        $wallpaperNote = "custom URL (headers said '$contentType', verified by file signature)"
        Write-Ok "Wallpaper verified by file signature (content-type was '$contentType')"
    } else {
        $reason = if ($null -ne $response) { "server responded with content-type '$contentType'" } else { 'download failed after retries' }
        if (Test-Path $download) { Remove-Item -Path $download -Force }
        if (Test-Path $defaultWallpaper) { $wallpaperFile = $defaultWallpaper; $wallpaperNote = "bundled default - your URL failed ($reason)" }
        Write-Warn "Wallpaper URL rejected: $reason - the bundled default will be applied."
    }
}
Add-GithubEnv -Name 'WALLPAPER_FILE' -Value $wallpaperFile
Add-GithubEnv -Name 'WALLPAPER_NOTE' -Value $wallpaperNote

# 5. Optional timezone - a cosmetic preference, so an invalid value warns and
#    keeps UTC instead of failing the session.
$timeZone = ''
if (-not [string]::IsNullOrWhiteSpace($env:TIMEZONE_INPUT)) {
    $requested = $env:TIMEZONE_INPUT.Trim()
    $known = Get-TimeZone -ListAvailable | Where-Object { $_.Id -eq $requested } | Select-Object -First 1
    if ($null -ne $known) {
        $timeZone = $requested
        Write-Ok "Timezone: $requested"
    } else {
        Write-Warn "Timezone '$requested' is not a valid Windows time zone id - the session keeps UTC."
    }
}
Add-GithubEnv -Name 'TIMEZONE_VALID' -Value $timeZone

exit 0
