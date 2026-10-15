# Enables RDP and provisions the two session accounts with per-run random passwords.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force

Write-Step 'Configuring the RDP service and session users'

Set-RegistryValue -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0 -Type DWord
try {
    Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction Stop
} catch {
    # The group display name is locale-dependent; fall back to the rule names
    # used on the English runner image.
    Get-NetFirewallRule -Name 'RemoteDesktop-*' -ErrorAction SilentlyContinue | Enable-NetFirewallRule
}
# Network Level Authentication is the platform default; make it explicit so the
# listener never regresses to pre-authentication access.
Set-RegistryValue -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name 'UserAuthentication' -Value 1 -Type DWord
# Timezone redirection: the connecting RDP client (mstsc) sends its own time
# zone at connect time, so the session clock automatically matches the user's
# device - no manual timezone configuration needed, for any country.
Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -Name 'fEnableTimeZoneRedirection' -Value 1 -Type DWord
Write-Ok 'RDP listener enabled with Network Level Authentication and timezone redirection'

function Set-LocalUserPassword {
    param(
        [Parameter(Mandatory)][string]$UserName,
        [Parameter(Mandatory)][securestring]$Password
    )
    if (Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue) {
        Set-LocalUser -Name $UserName -Password $Password
    } else {
        New-LocalUser -Name $UserName -Password $Password -AccountNeverExpires
        Set-LocalUser -Name $UserName -PasswordNeverExpires $true
    }
}

function Add-LocalGroupMemberSafe {
    param(
        [Parameter(Mandatory)][string]$GroupName,
        [Parameter(Mandatory)][string]$MemberName
    )
    $isMember = Get-LocalGroupMember -Group $GroupName -Member $MemberName -ErrorAction SilentlyContinue
    if (-not $isMember) {
        Add-LocalGroupMember -Group $GroupName -Member $MemberName
    }
}

# Per-run random credentials, rotated through the LocalAccounts cmdlets instead
# of net.exe: "net user /add" asks for Y/N confirmation on passwords longer than
# 14 characters (a legacy LM-hash prompt) and cannot get an answer in a
# non-interactive shell. The cmdlets have no such limit, so the 20-character
# passwords work as designed.
#
# The passwords are deliberately NOT registered with ::add-mask::: masking
# redacts the value everywhere it would be printed, including the job Summary
# page, which is the intended delivery channel for these credentials. The
# exposure model (visible to anyone who can view this repository's Actions
# runs, random per run, destroyed with the session) is documented in the README
# and in the Summary privacy note.

# Credential mode. If the user set the RDP_PASSWORD secret, both accounts use
# it and nothing displays or transmits it anywhere (XyRDP-style masking - the
# user knows their own password). Otherwise a random password is generated per
# account and delivered through the private channels, with the Summary as the
# last-resort fallback. In both modes the values are deliberately NOT masked
# with ::add-mask:: - masking also redacts the job Summary, which must stay
# able to show generated credentials when nothing was delivered.
if (-not [string]::IsNullOrWhiteSpace($env:RDP_PASSWORD)) {
    if ($env:RDP_PASSWORD.Length -lt 8) {
        Write-Warn 'RDP_PASSWORD is shorter than 8 characters - consider a stronger one.'
    }
    $adminPassword = $env:RDP_PASSWORD
    $sessionPassword = $env:RDP_PASSWORD
    Add-GithubEnv -Name 'PASSWORD_MODE' -Value 'user'
    Write-Ok 'Using the user-provided password from the RDP_PASSWORD secret (never displayed or transmitted)'
} else {
    $adminPassword = New-RandomPassword
    $sessionPassword = New-RandomPassword
    Add-GithubEnv -Name 'PASSWORD_MODE' -Value 'generated'
    Write-Ok 'Generated random per-run passwords'
}

# Rotate the built-in runner admin password for this run only.
$adminPasswordSecure = ConvertTo-SecurePassword $adminPassword
Set-LocalUserPassword -UserName 'runneradmin' -Password $adminPasswordSecure
Add-GithubEnv -Name 'RDP_ADMIN_PASS' -Value $adminPassword
Write-Ok 'runneradmin password rotated'

# Dedicated session account with admin and RDP group membership.
$sessionPasswordSecure = ConvertTo-SecurePassword $sessionPassword
Set-LocalUserPassword -UserName 'lazyuser' -Password $sessionPasswordSecure
Add-LocalGroupMemberSafe -GroupName 'Administrators' -MemberName 'lazyuser'
Add-LocalGroupMemberSafe -GroupName 'Remote Desktop Users' -MemberName 'lazyuser'
Add-GithubEnv -Name 'RDP_SESSION_PASS' -Value $sessionPassword
Write-Ok "Session user 'lazyuser' provisioned (Administrators + Remote Desktop Users)"

exit 0
