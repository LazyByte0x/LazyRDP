# Sends a session message to the user's private channels (Telegram and/or
# Discord). Configured-but-failed channels warn; unconfigured channels are
# skipped silently. Outputs the names of the channels that actually delivered;
# Watch-Session uses that list to decide whether the Summary may display the
# credentials (fallback when nothing was delivered).
param(
    [Parameter(Mandatory)][string]$Message
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force

function Send-Telegram {
    # Telegram Bot API. Requires TELEGRAM_BOT_TOKEN (from @BotFather) and
    # TELEGRAM_CHAT_ID. HTML parse mode: escape the three reserved characters.
    if ([string]::IsNullOrWhiteSpace($env:TELEGRAM_BOT_TOKEN) -or [string]::IsNullOrWhiteSpace($env:TELEGRAM_CHAT_ID)) { return $false }
    try {
        $html = $Message.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
        $body = @{ chat_id = $env:TELEGRAM_CHAT_ID; text = $html; parse_mode = 'HTML'; disable_web_page_preview = $true }
        $json = [System.Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json))
        Invoke-RestMethod -Uri "https://api.telegram.org/bot$($env:TELEGRAM_BOT_TOKEN)/sendMessage" -Method Post -ContentType 'application/json; charset=utf-8' -Body $json -TimeoutSec 30 | Out-Null
        return $true
    } catch {
        Write-Warn "Telegram delivery failed: $($_.Exception.Message)"
        return $false
    }
}

function Send-Discord {
    # Discord webhook. Requires DISCORD_WEBHOOK_URL. Plain content payload;
    # Discord rejects bodies over 2000 characters, which this message never reaches.
    if ([string]::IsNullOrWhiteSpace($env:DISCORD_WEBHOOK_URL)) { return $false }
    try {
        $body = @{ content = $Message } | ConvertTo-Json
        Invoke-RestMethod -Uri $env:DISCORD_WEBHOOK_URL -Method Post `
            -ContentType 'application/json; charset=utf-8' `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 30 | Out-Null
        return $true
    } catch {
        Write-Warn "Discord delivery failed: $($_.Exception.Message)"
        return $false
    }
}

$delivered = @()
$telegramState = if ([string]::IsNullOrWhiteSpace($env:TELEGRAM_BOT_TOKEN) -or [string]::IsNullOrWhiteSpace($env:TELEGRAM_CHAT_ID)) { 'NOT_CONFIGURED' } else { 'FAILED' }
if (Send-Telegram -Message $Message) { $delivered += 'Telegram'; $telegramState = 'DELIVERED' }
$discordState = if ([string]::IsNullOrWhiteSpace($env:DISCORD_WEBHOOK_URL)) { 'NOT_CONFIGURED' } else { 'FAILED' }
if (Send-Discord -Message $Message) { $delivered += 'Discord'; $discordState = 'DELIVERED' }

# One unambiguous verdict line per channel, always printed.
Write-Host "NOTIFY: Telegram=$telegramState | Discord=$discordState"
if ($delivered.Count -gt 0) {
    Write-Ok "Notification delivered via: $($delivered -join ', ')"
}

# Publish the verdict to a temp file. This is the most robust cross-scope
# channel: GITHUB_ENV only applies between steps (not within one), and the
# consumer can always re-read a file even if output capture were disturbed.
$stateDir = $env:RUNNER_TEMP
if ([string]::IsNullOrWhiteSpace($stateDir)) { $stateDir = $env:TEMP }
$stateFile = Join-Path $stateDir 'lazyrdp-delivery.txt'
Set-Content -Path $stateFile -Value ($delivered -join ',') -Encoding utf8
$delivered
