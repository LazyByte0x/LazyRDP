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
# Anchor the deadline to UTC. Timezone redirection can move the machine's
# local clock the moment a device connects via RDP, so Get-Date wall-clock
# values would be unstable for math or labeling. UtcNow is timezone-proof.
$deadlineUtc = [DateTimeOffset]::UtcNow.AddHours($sessionHours)
$endsAt = $deadlineUtc.ToString('yyyy-MM-dd HH:mm') + ' UTC'
$currentIp = $env:TAILSCALE_IP
$notifyScript = Join-Path $PSScriptRoot 'Notify-Session.ps1'

function Get-SessionMessage {
    param([string]$Ip)
    $passwordLines = if ($env:PASSWORD_MODE -eq 'user') {
        "Password (runneradmin + lazyuser): $($env:RDP_PASSWORD)"
    } else {
        "Password (runneradmin): $($env:RDP_ADMIN_PASS)`nPassword (lazyuser): $($env:RDP_SESSION_PASS)"
    }
    return @"
🟢 LazyRDP session is ready

Host (Tailscale IP): $Ip
Username 1: runneradmin
Username 2: lazyuser
$passwordLines

Ends: $endsAt (UTC). Environment is destroyed afterwards - store nothing in the session.
Connect: sign in to Tailscale, then open any RDP client (Windows: mstsc) to the host above.
Terminal (SSH): ssh runneradmin@$Ip - same password, PowerShell 7 shell.
"@
}

# --- Credential display: ALWAYS masked in the Summary ---------------------------
# Passwords travel to the user's private channels only. The Summary never
# displays them, in any mode, regardless of delivery outcome - per the owner's
# standing directive. If no channel delivered and no RDP_PASSWORD is set, the
# generated values are not recoverable from this run at all (they are masked
# in logs too) - the pre-flight step warns about this before any setup runs.
$delivered = @(& $notifyScript -Message (Get-SessionMessage -Ip $currentIp))
# Prefer the file verdict Notify-Session published (robust across scopes);
# fall back to the output capture if the file is missing.
$deliveryStateFile = Join-Path ($env:RUNNER_TEMP) 'lazyrdp-delivery.txt'
if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { $deliveryStateFile = Join-Path $env:TEMP 'lazyrdp-delivery.txt' }
if (Test-Path $deliveryStateFile) {
    $raw = Get-Content -Path $deliveryStateFile -Raw -ErrorAction SilentlyContinue
    if ($null -eq $raw) { $raw = '' }
    $delivered = @($raw.Trim() -split ',' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

# --- Session summary ------------------------------------------------------------
$failedApps = $env:APPS_FAILED
if ($env:APP_BUNDLE -eq 'clean') {
    $appsStatus = 'No applications installed (clean bundle).'
} elseif ([string]::IsNullOrWhiteSpace($failedApps)) {
    $appsStatus = "All applications from the '$($env:APP_BUNDLE)' bundle are installed."
} else {
    $appsStatus = "Bundle '$($env:APP_BUNDLE)' installed, but these failed: $failedApps. Check the install step log."
}
$storageNote = ''
if (-not [string]::IsNullOrWhiteSpace($env:STORAGE_BOOST_FREED_GB)) { $storageNote = "`n- **Storage boost:** freed $($env:STORAGE_BOOST_FREED_GB) GB" }
$debloatNote = 'standard (default)'
if (-not [string]::IsNullOrWhiteSpace($env:DEBLOAT_LEVEL_APPLIED)) {
    $debloatNote = "$($env:DEBLOAT_LEVEL_APPLIED) - $($env:DEBLOAT_PACKAGES_REMOVED) packages, $($env:DEBLOAT_SERVICES_DISABLED) services disabled"
}

$credsSection = @"
| Property | Value |
|----------|-------|
| **Address (Tailscale IP)** | ``$currentIp`` |
| **Username 1** | ``runneradmin`` |
| **Username 2** | ``lazyuser`` |
| **Passwords** | ``••••••••`` - never displayed in the Summary |
"@

if ($delivered.Count -eq 0 -and $env:PASSWORD_MODE -ne 'user') {
    Write-Host '::notice::No private channel delivered - the Summary stays masked and the passwords are not recoverable from this run. Configure notification secrets and start a new run.'
}
$credsHint = if ($delivered.Count -gt 0) {
    "📬 **Passwords were sent to your private channel(s): $($delivered -join ', ')**"
} elseif ($env:PASSWORD_MODE -eq 'user') {
    "🔒 **Passwords:** the value of your ``RDP_PASSWORD`` secret (you set it yourself)"
} else {
    "⚠️ **Passwords:** no channel delivered this run and they are never displayed here - configure ``TELEGRAM_BOT_TOKEN`` + ``TELEGRAM_CHAT_ID`` or ``DISCORD_WEBHOOK_URL`` and start a new run to receive them."
}

$summary = @"
# ✅ Your LazyRDP session is live

### Connect in three steps
1. Install the **Tailscale client** on your device and sign in to the same tailnet used for this workflow.
2. Open your RDP client (Windows: ``mstsc``) and connect to the address below.
3. Sign in with one of the accounts below.

4. *(Optional)* Terminal access: ``ssh runneradmin@<ip>`` - port 22, same credentials, PowerShell 7 shell.

$credsSection

$credsHint

### Session details
- **Theme:** $($env:THEME)
- **Wallpaper:** $(if (-not [string]::IsNullOrWhiteSpace($env:WALLPAPER_NOTE)) { $env:WALLPAPER_NOTE } else { 'system default' })
- **Applications:** $appsStatus$storageNote
- **Debloat:** $debloatNote
- **Ends at:** $endsAt - the environment is destroyed shortly after; store nothing here. (The session clock automatically follows the connecting device's time zone once you connect via RDP.)

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
    $nowUtc = [DateTimeOffset]::UtcNow
    if ($nowUtc -ge $deadlineUtc) { break }

    $tailscaleService = Get-Service -Name 'Tailscale' -ErrorAction SilentlyContinue
    $serviceOk = ($null -ne $tailscaleService -and $tailscaleService.Status -eq 'Running')
    $connectedOk = $false
    if ($serviceOk) {
        & $tailscaleExe status *> $null
        $connectedOk = ($LASTEXITCODE -eq 0)
    }
    $rdpListener = Get-NetTCPConnection -LocalPort 3389 -State Listen -ErrorAction SilentlyContinue
    $rdpOk = ($null -ne $rdpListener)

    # Repair covers BOTH failure shapes: the node dropping off the tailnet
    # while the service runs, AND the service itself having stopped (start it,
    # then re-join with the same ephemeral key; the IP may change afterwards).
    if (-not $connectedOk -and $repairAttempts -lt 3) {
        $repairAttempts++
        Write-Host "::notice::Tailscale unhealthy (service running: $serviceOk; connected: $connectedOk) - repair attempt $repairAttempts/3 at $($nowUtc.ToString('HH:mm:ss'))"
        if (-not $serviceOk) {
            try {
                Start-Service -Name 'Tailscale' -ErrorAction Stop
                Start-Sleep -Seconds 5
                Write-Ok 'Tailscale service started'
            } catch {
                Write-Warn "Could not start the Tailscale service: $($_.Exception.Message)"
            }
        }
        & $tailscaleExe up --authkey=$env:TAILSCALE_AUTH_KEY --hostname="winrdp-$env:GITHUB_RUN_ID" *> $null
        Start-Sleep -Seconds 10
        $newIp = (& $tailscaleExe ip -4 2>$null | Select-Object -First 1)
        if ($newIp -and $newIp -ne $currentIp) {
            $oldIp = $currentIp
            $currentIp = $newIp
            $ipUpdate = "`n---`n## ⚠️ IP UPDATED`n`nThe session reconnected and its Tailscale address changed: ``$oldIp`` -> ``$newIp``. Use the new address; credentials are unchanged.`n"
            Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $ipUpdate -Encoding utf8
            & $notifyScript -Message "⚠️ LazyRDP reconnected with a NEW Tailscale IP: $newIp (was $oldIp). Credentials unchanged. Ends: $endsAt."
            Write-Host "::notice::Tailscale IP changed to $newIp - the Summary and your channels were updated."
        }
    } elseif (-not $connectedOk) {
        Write-Host "::notice::Tailscale still unhealthy after $repairAttempts repair attempts (service running: $serviceOk; connected: $connectedOk) at $($nowUtc.ToString('HH:mm:ss'))."
    }

    if (-not $rdpOk) {
        Write-Host "::notice::Health deviation at $($nowUtc.ToString('HH:mm:ss')) - RDP listener on 3389: $rdpOk"
    }
    if ($serviceOk -and $connectedOk -and $rdpOk) {
        $remaining = $deadlineUtc - $nowUtc
        Write-Host ("[{0}] Session healthy - {1:00}h {2:00}m remaining." -f $nowUtc.LocalDateTime.ToString('HH:mm:ss'), [int][Math]::Floor($remaining.TotalHours), $remaining.Minutes)
    }
    Start-Sleep -Seconds 300
}

Write-Host "`nSession window complete. Ending this job destroys the environment." -ForegroundColor Yellow
exit 0
