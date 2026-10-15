# Shared helpers for the LazyRDP workflow scripts.
# Target runtime: PowerShell 7 (workflow steps use shell: pwsh).

Set-StrictMode -Version Latest

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "    OK: $Message" -ForegroundColor Green
}

function Write-Warn {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "    WARN: $Message" -ForegroundColor Yellow
}

function Add-GithubEnv {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )
    # Add-Content with explicit UTF-8: the ">>" operator in Windows PowerShell writes UTF-16,
    # which corrupts GITHUB_ENV parsing. Keep this helper the only writer.
    Add-Content -Path $env:GITHUB_ENV -Value "$Name=$Value" -Encoding utf8
}

function Grant-RegistryKeyAccess {
    # Last-resort ladder step: some runner-image keys (e.g. CurrentVersion) are
    # owned by TrustedInstaller and deny value writes even to Administrators.
    # Take ownership of the key and grant the current user FullControl.
    param([Parameter(Mandatory)][string]$Path)
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $key = Get-Item -LiteralPath $Path -ErrorAction Stop
    $acl = $key.GetAccessControl()
    $acl.SetOwner([System.Security.Principal.NTAccount]$identity)
    Set-Acl -Path $Path -AclObject $acl
    $acl = (Get-Item -LiteralPath $Path).GetAccessControl()
    $rule = New-Object System.Security.AccessControl.RegistryAccessRule($identity, 'FullControl', 'ContainerInherit', 'None', 'Allow')
    $acl.SetAccessRule($rule)
    Set-Acl -Path $Path -AclObject $acl
}

function Set-RegistryValue {
    # Borrowed from XyRDP's documented 2026-10-03 finding: "New-ItemProperty
    # -Force" on an EXISTING value can be denied ("unauthorized operation") on
    # TrustedInstaller-owned keys, while Set-ItemProperty on an existing value
    # only needs "Set Value". Ladder: exists -> Set-ItemProperty; missing ->
    # New-ItemProperty -> reg.exe add /f -> take key ownership -> retry.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowNull()]$Value,
        [ValidateSet('String', 'DWord', 'QWord', 'ExpandString')][string]$Type = 'String'
    )
    $exists = $null -ne (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue)
    if ($exists) {
        try { Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force -ErrorAction Stop; return } catch { }
    } else {
        try { New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null; return } catch { }
    }

    # reg.exe exercises a different write path; convert HKLM:\... to HKLM\...
    $regTypes = @{ String = 'REG_SZ'; DWord = 'REG_DWORD'; QWord = 'REG_QWORD'; ExpandString = 'REG_EXPAND_SZ' }
    $regPath = $Path -replace '^HKLM:\\', 'HKLM\' -replace '^HKCU:\\', 'HKCU\' -replace '^Registry::', ''
    $regValue = if ($Type -eq 'DWord') { [string][int]$Value } else { [string]$Value }
    reg.exe add "$regPath" /v $Name /t $regTypes[$Type] /d $regValue /f *> $null
    if ($LASTEXITCODE -eq 0) { return }

    Grant-RegistryKeyAccess -Path $Path
    if ($exists) {
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force -ErrorAction Stop
    } else {
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
    }
}

function New-RandomPassword {
    param([int]$Length = 20)
    # Ambiguous characters (l, I, 1, O, 0) are excluded because session users type these by hand.
    # The first character comes from letters only so the value can never start with '-' or '/'
    # and be mistaken for a flag by command-line tools such as net.exe.
    $letters = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ'
    $chars = "$letters" + '23456789!@#%^*-_=+'
    $bytes = [byte[]]::new($Length)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $first = $letters[$bytes[0] % $letters.Length]
    $rest = -join ($bytes | Select-Object -Skip 1 | ForEach-Object { $chars[$_ % $chars.Length] })
    return -join ($first, $rest)
}

function ConvertTo-SecurePassword {
    # The session password starts its life as plaintext by design: it is
    # generated here, displayed in the run Summary (the credential delivery
    # channel), and must be handed to the LocalAccounts cmdlets. The rule is
    # suppressed for this single, documented conversion point only.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '')]
    param([Parameter(Mandatory)][string]$Password)
    return ConvertTo-SecureString $Password -AsPlainText -Force
}

function Invoke-DownloadWithRetry {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile,
        [int]$Attempts = 3,
        [int]$TimeoutSec = 60
    )
    $response = $null
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            $response = Invoke-WebRequest -Uri $Uri -OutFile $OutFile -TimeoutSec $TimeoutSec `
                -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) UltimateRDP/7.4' -PassThru
            return $response
        } catch {
            Write-Warn "Download attempt $attempt/$Attempts for '$Uri' failed: $($_.Exception.Message)"
            if ($attempt -lt $Attempts) { Start-Sleep -Seconds (10 * $attempt) }
        }
    }
    return $null
}

function Test-ImageResponse {
    param([Parameter(Mandatory)]$Response)
    $contentType = ''
    if ($Response.Headers['Content-Type']) {
        $contentType = ($Response.Headers['Content-Type'] -join ';')
    }
    return ($contentType -match '^image/')
}

function Test-ImageFile {
    # Authoritative image check by file signature (magic bytes). Some CDNs
    # serve real images with a wrong or missing Content-Type, and hotlink
    # protection returns HTML - headers alone are not trustworthy.
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return $false }
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            $count = [Math]::Min(12, $stream.Length)
            if ($count -lt 3) { return $false }
            $b = [byte[]]::new($count)
            [void]$stream.Read($b, 0, $count)
        } finally { $stream.Dispose() }
        if ($b[0] -eq 0xFF -and $b[1] -eq 0xD8 -and $b[2] -eq 0xFF) { return $true }                                     # JPEG
        if ($b[0] -eq 0x89 -and $b[1] -eq 0x50 -and $b[2] -eq 0x4E -and $b[3] -eq 0x47) { return $true }                 # PNG
        if ($b[0] -eq 0x47 -and $b[1] -eq 0x49 -and $b[2] -eq 0x46) { return $true }                                     # GIF
        if ($b[0] -eq 0x42 -and $b[1] -eq 0x4D) { return $true }                                                         # BMP
        if ($count -ge 12 -and $b[0] -eq 0x52 -and $b[1] -eq 0x49 -and $b[2] -eq 0x46 -and $b[3] -eq 0x46 -and `
            $b[8] -eq 0x57 -and $b[9] -eq 0x45 -and $b[10] -eq 0x42 -and $b[11] -eq 0x50) { return $true }               # WEBP (RIFF....WEBP)
        return $false
    } catch { return $false }
}

Export-ModuleMember -Function @(
    'Write-Step',
    'Write-Ok',
    'Write-Warn',
    'Add-GithubEnv',
    'Set-RegistryValue',
    'New-RandomPassword',
    'ConvertTo-SecurePassword',
    'Invoke-DownloadWithRetry',
    'Test-ImageResponse',
    'Test-ImageFile'
)
