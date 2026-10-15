# Publishes the session summary, sends the credentials to the user's private
# channels (Telegram/Discord when configured), then keeps the session alive
# with health checks that also REPAIR a dropped Tailscale connection. Ending
# this script ends the job, which destroys the environment - the intended
# graceful shutdown.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force

$sessionHours = 5.9
if (-not [double]::TryParse($env:SESSION_HOURS_EFFECTIVE, [ref]$sessionHours) -or $sessionHours -le 0) {
    $sessionHours = 5.9
}
$deadline = (Get-Date).AddHours($sessionHours)
$endsAt = $deadline.ToString('yyyy-MM-dd HH:mm') + ' UTC'
$currentIp = $env:TAILSCALE_IP
$notifyScript = Join-Path $PSScriptRoot 'Notify-Session.ps1'

function Get-SessionMessage {
    param([string]$Ip)
    return @"
🟢 LazyRDP session is ready

Host (Tailscale IP): $Ip
Username 1: runneradmin
Password 1: $($env:RDP_ADMIN_PASS)
Username 2: lazyuser
Password 2: $($env:RDP_SESSION_PASS)

Ends: $endsAt (UTC). Environment is destroyed afterwards - store nothing in the session.
Connect: sign in to Tailscale, then open any RDP client (Windows: mstsc) to the host above.
"@
}

# --- Private credential delivery ------------------------------------------------
# If at least one channel delivered, the Summary hides the passwords (private
# delivery wins). If nothing was delivered - secrets missing or all sends
# failed - the Summary falls back to showing them so they can never be lost.
$delivered = @(& $notifyScript -Message (Get-SessionMessage -Ip $currentIp))

# --- Session summary ------------------------------------------------------------
$failedApps = $env:APPS_FAILED
if ($env:APP_BUNDLE -eq 'clean') {
    $appsStatus = 'No applications installed (clean bundle).'
} elseif ([string]::IsNullOrWhiteSpace($failedApps)) {
    $appsStatus = "All applications from the '$($env:APP_BUNDLE)' bundle are installed."
} else {
    $appsStatus = "Bundle '$($env:APP_BUNDLE)' installed, but these failed: $failedApps. Check the install step log."
}
$timeZoneNote = ''
if (-not [string]::IsNullOrWhiteSpace($env:TIMEZONE_VALID)) { $timeZoneNote = "`n- **Timezone:** $($env:TIMEZONE_VALID)" }
$storageNote = ''
if (-not [string]::IsNullOrWhiteSpace($env:STORAGE_BOOST_FREED_GB)) { $storageNote = "`n- **Storage boost:** freed $($env:STORAGE_BOOST_FREED_GB) GB" }

if ($delivered.Count -gt 0) {
    $credsSection = @"
| Property | Value |
|----------|-------|
| **Address (Tailscale IP)** | ``$currentIp`` |
| **Username 1** | ``runneradmin`` |
| **Username 2** | ``lazyuser`` |

📬 **Passwords were sent to your private channel(s): $($delivered -join ', ')** - they are intentionally not shown here.
"@
} else {
    $credsSection = @"
| Property | Value |
|----------|-------|
| **Address (Tailscale IP)** | ``$currentIp`` |
| **Username 1** | ``runneradmin`` |
| **Password 1** | ``$($env:RDP_ADMIN_PASS)`` |
| **Username 2** | ``lazyuser`` |
| **Password 2** | ``$($env:RDP_SESSION_PASS)`` |

> ⚠️ **Privacy note:** no notification channel was configured or reachable, so
> the credentials are shown here - visible to anyone who can view this
> repository's Actions runs. Configure ``TELEGRAM_BOT_TOKEN`` + ``TELEGRAM_CHAT_ID``
> or ``DISCORD_WEBHOOK_URL`` secrets for private delivery.
"@
    Write-Host '::notice::Credentials were not delivered to any private channel - showing them in the Summary as a fallback.'
}

$summary = @"
# ✅ Your LazyRDP session is live

### Connect in three steps
1. Install the **Tailscale client** on your device and sign in to the same tailnet used for this workflow.
2. Open your RDP client (Windows: ``mstsc``) and connect to the address below.
3. Sign in with one of the accounts below.

$credsSection
### Session details
- **Theme:** $($env:THEME)$timeZoneNote
- **Applications:** $appsStatus$storageNote
- **Ends at:** $endsAt - the environment is destroyed shortly after; store nothing here.

> ⚠️ **Concurrency warning:** starting a NEW run of this workflow cancels this
> session immediately. Cancel from the Actions tab when you are done.

### Common issues
| Symptom | Fix |
|---------|-----|
| Connection timed out | Confirm your Tailscale client is connected, and use the ``100.x.x.x`` IP above |
| No IP in the table | Reopen this Summary after the "Fetch Tailscale IP" step finishes |
| Session ended early | The chosen session lifetime elapsed, or a newer run replaced this one |
| Blank or slow desktop | First logon applies the profile; reconnect once, and expect 4 vCPU / 16 GB-class performance |
| Desktop black but pointer visible | Press Ctrl+Alt+End > Task Manager > Run new task > ``explorer.exe`` |
"@
Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $summary -Encoding utf8
Write-Ok 'Session summary published (see the Summary tab).'

# --- Health-checked, self-repairing keep-alive ----------------------------------
$tailscaleExe = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
$repairAttempts = 0
Write-Host "`nSession is live. Health checks run every 5 minutes (with Tailscale auto-repair)." -ForegroundColor Green
while ($true) {
    $now = Get-Date
    if ($now -ge $deadline) { break }

    $tailscaleService = Get-Service -Name 'Tailscale' -ErrorAction SilentlyContinue
    $serviceOk = ($null -ne $tailscaleService -and $tailscaleService.Status -eq 'Running')
    $connectedOk = $false
    if ($serviceOk) {
        & $tailscaleExe status *> $null
        $connectedOk = ($LASTEXITCODE -eq 0)
    }
    $rdpListener = Get-NetTCPConnection -LocalPort 3389 -State Listen -ErrorAction SilentlyContinue
    $rdpOk = ($null -ne $rdpListener)

    if ($serviceOk -and -not $connectedOk -and $repairAttempts -lt 3) {
        # The node dropped off the tailnet (network blip, control-plane hiccup).
        # Re-join with the same ephemeral key; the IP may change afterwards.
        $repairAttempts++
        Write-Host "::notice::Tailscale reported disconnected - repair attempt $repairAttempts/3 at $($now.ToString('HH:mm:ss'))"
        & $tailscaleExe up --authkey=$env:TAILSCALE_AUTH_KEY --hostname="winrdp-$env:GITHUB_RUN_ID" *> $null
        Start-Sleep -Seconds 10
        $newIp = (& $tailscaleExe ip -4 2>$null | Select-Object -First 1)
        if ($newIp -and $newIp -ne $currentIp) {
            $oldIp = $currentIp
            $currentIp = $newIp
            $ipUpdate = "`n---`n## ⚠️ IP UPDATED`n`nThe session reconnected and its Tailscale address changed: ``$oldIp`` -> ``$newIp``. Use the new address; credentials are unchanged.`n"
            Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $ipUpdate -Encoding utf8
            & $notifyScript -Message "⚠️ LazyRDP reconnected with a NEW Tailscale IP: $newIp (was $oldIp). Credentials unchanged. Ends: $endsAt UTC."
            Write-Host "::notice::Tailscale IP changed to $newIp - the Summary and your channels were updated."
        }
    } elseif ($serviceOk -and -not $connectedOk) {
        Write-Host "::notice::Tailscale still disconnected after $repairAttempts repair attempts (at $($now.ToString('HH:mm:ss')))."
    }

    if (-not $rdpOk) {
        Write-Host "::notice::Health deviation at $($now.ToString('HH:mm:ss')) - RDP listener on 3389: $rdpOk"
    }
    $remaining = $deadline - $now
    Write-Host ("[{0:HH:mm:ss}] Session healthy - {1:00}h {2:00}m remaining." -f $now, [int][Math]::Floor($remaining.TotalHours), $remaining.Minutes)
    Start-Sleep -Seconds 300
}

Write-Host "`nSession window complete. Ending this job destroys the environment." -ForegroundColor Yellow
exit 0
