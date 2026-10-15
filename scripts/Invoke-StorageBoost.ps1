# Frees tens of gigabytes by removing preinstalled toolchains that a desktop
# session never uses (XyRDP reports 45-75 GB on the same image family; this
# script measures and reports the real number). Conservative targets only:
# SDKs, toolchains, and package caches - nothing the Windows session depends on.
$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force

Write-Step 'Storage boost'

function Get-FreeGB {
    return [Math]::Round((Get-PSDrive -Name 'C').Free / 1GB, 1)
}

$before = Get-FreeGB
Write-Host "Free space before: $before GB"

# Preinstalled toolchains and SDKs on the hosted runner image.
$targets = @(
    "${env:ProgramFiles(x86)}\Android",
    "$env:ANDROID_HOME",
    "$env:ANDROID_SDK_ROOT",
    (Join-Path $env:ProgramFiles 'Go'),
    'C:\hostedtoolcache\windows\go',
    'C:\hostedtoolcache\windows\CodeQL',
    'C:\hostedtoolcache\windows\haskell',
    'C:\hostedtoolcache\windows\julia',
    'C:\hostedtoolcache\windows\Ruby'
)
foreach ($target in $targets) {
    if ([string]::IsNullOrWhiteSpace($target)) { continue }
    if (Test-Path $target) {
        try {
            Remove-Item -Path $target -Recurse -Force -ErrorAction SilentlyContinue
            Write-Ok "Removed $target"
        } catch {
            Write-Warn "Could not remove $target : $($_.Exception.Message)"
        }
    }
}

# Docker images (the service itself stays; only cached layers go).
try {
    docker system prune -af --volumes *> $null
    Write-Ok 'Docker images and build cache pruned'
} catch { Write-Warn 'Docker prune skipped.' }

# Package-manager caches.
try { pip cache purge *> $null } catch { }
try { npm cache clean --force *> $null } catch { }
try { dotnet nuget locals all --clear *> $null } catch { }
Write-Ok 'Package caches cleared'

$after = Get-FreeGB
$freed = [Math]::Round($after - $before, 1)
Write-Ok "Storage boost complete: freed $freed GB ($before GB -> $after GB free)."
Add-GithubEnv -Name 'STORAGE_BOOST_FREED_GB' -Value "$freed"

exit 0
