# Mole - Cache Cleanup Module
# Cleans Windows and application caches

#Requires -Version 5.1
Set-StrictMode -Version Latest

# Prevent multiple sourcing
if ((Get-Variable -Name 'MOLE_CLEAN_CACHES_LOADED' -Scope Script -ErrorAction SilentlyContinue) -and $script:MOLE_CLEAN_CACHES_LOADED) { return }
$script:MOLE_CLEAN_CACHES_LOADED = $true

# Import dependencies
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\..\core\base.ps1"
. "$scriptDir\..\core\log.ps1"
. "$scriptDir\..\core\file_ops.ps1"

# ============================================================================
# Windows System Caches
# ============================================================================

function Clear-WindowsUpdateCache {
    <#
    .SYNOPSIS
        Clean Windows Update cache (requires admin)
    #>
    
    if (-not (Test-IsAdmin)) {
        Write-Debug "Skipping Windows Update cache - requires admin"
        return
    }
    
    $wuPath = "$env:WINDIR\SoftwareDistribution\Download"
    
    if (Test-Path $wuPath) {
        # Stop Windows Update service first
        if (Test-DryRunMode) {
            Write-DryRun "Windows Update cache"
            Set-SectionActivity
            return
        }
        
        try {
            Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
            Clear-DirectoryContents -Path $wuPath -Description "Windows Update cache"
            Start-Service -Name wuauserv -ErrorAction SilentlyContinue
        }
        catch {
            Write-Debug "Could not clear Windows Update cache: $_"
            Start-Service -Name wuauserv -ErrorAction SilentlyContinue
        }
    }
}

function Clear-DeliveryOptimizationCache {
    <#
    .SYNOPSIS
        Clean Windows Delivery Optimization cache (requires admin)
    #>
    
    if (-not (Test-IsAdmin)) {
        Write-Debug "Skipping Delivery Optimization cache - requires admin"
        return
    }
    
    $doPath = "$env:WINDIR\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization"
    
    if (Test-Path $doPath) {
        if (Test-DryRunMode) {
            Write-DryRun "Delivery Optimization cache"
            Set-SectionActivity
            return
        }
        
        try {
            Stop-Service -Name DoSvc -Force -ErrorAction SilentlyContinue
            Clear-DirectoryContents -Path "$doPath\Cache" -Description "Delivery Optimization cache"
            Start-Service -Name DoSvc -ErrorAction SilentlyContinue
        }
        catch {
            Write-Debug "Could not clear Delivery Optimization cache: $_"
            Start-Service -Name DoSvc -ErrorAction SilentlyContinue
        }
    }
}

function Clear-FontCache {
    <#
    .SYNOPSIS
        Clean Windows font cache (requires admin)
    #>
    
    if (-not (Test-IsAdmin)) {
        return
    }
    
    $fontCachePath = "$env:LOCALAPPDATA\Microsoft\Windows\Fonts\FontCache"
    
    if (Test-Path $fontCachePath) {
        Remove-SafeItem -Path $fontCachePath -Description "Font cache"
    }
}

# ============================================================================
# Browser Caches
# ============================================================================

function Clear-BrowserCaches {
    <#
    .SYNOPSIS
        Clean browser cache directories
    #>
    
    Start-Section "Browser caches"
    
    # Chrome
    $chromeCachePaths = @(
        "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache"
        "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Code Cache"
        "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\GPUCache"
        "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Service Worker\CacheStorage"
        "$env:LOCALAPPDATA\Google\Chrome\User Data\ShaderCache"
        "$env:LOCALAPPDATA\Google\Chrome\User Data\GrShaderCache"
    )
    
    foreach ($path in $chromeCachePaths) {
        if (Test-Path $path) {
            Clear-DirectoryContents -Path $path -Description "Chrome $(Split-Path -Leaf $path)"
        }
    }
    
    # Edge
    $edgeCachePaths = @(
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache"
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Code Cache"
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\GPUCache"
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Service Worker\CacheStorage"
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data\ShaderCache"
    )
    
    foreach ($path in $edgeCachePaths) {
        if (Test-Path $path) {
            Clear-DirectoryContents -Path $path -Description "Edge $(Split-Path -Leaf $path)"
        }
    }
    
    # Firefox
    $firefoxProfiles = "$env:APPDATA\Mozilla\Firefox\Profiles"
    if (Test-Path $firefoxProfiles) {
        $profiles = Get-ChildItem -Path $firefoxProfiles -Directory -ErrorAction SilentlyContinue
        foreach ($profile in $profiles) {
            $firefoxCachePaths = @(
                "$($profile.FullName)\cache2"
                "$($profile.FullName)\startupCache"
                "$($profile.FullName)\shader-cache"
            )
            foreach ($path in $firefoxCachePaths) {
                if (Test-Path $path) {
                    Clear-DirectoryContents -Path $path -Description "Firefox cache"
                }
            }
        }
    }
    
    # Brave
    $braveCachePath = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\Default\Cache"
    if (Test-Path $braveCachePath) {
        Clear-DirectoryContents -Path $braveCachePath -Description "Brave cache"
    }
    
    # Opera
    $operaCachePath = "$env:APPDATA\Opera Software\Opera Stable\Cache"
    if (Test-Path $operaCachePath) {
        Clear-DirectoryContents -Path $operaCachePath -Description "Opera cache"
    }
    
    Stop-Section
}

# ============================================================================
# Application Caches
# ============================================================================

function Clear-AppCaches {
    <#
    .SYNOPSIS
        Clean common application caches
    #>
    
    Start-Section "Application caches"
    
    # Spotify
    $spotifyCachePaths = @(
        "$env:LOCALAPPDATA\Spotify\Data"
        "$env:LOCALAPPDATA\Spotify\Storage"
    )
    foreach ($path in $spotifyCachePaths) {
        if (Test-Path $path) {
            Clear-DirectoryContents -Path $path -Description "Spotify cache"
        }
    }
    
    # Discord
    $discordCachePaths = @(
        "$env:APPDATA\discord\Cache"
        "$env:APPDATA\discord\Code Cache"
        "$env:APPDATA\discord\GPUCache"
    )
    foreach ($path in $discordCachePaths) {
        if (Test-Path $path) {
            Clear-DirectoryContents -Path $path -Description "Discord cache"
        }
    }
    
    # Slack
    $slackCachePaths = @(
        "$env:APPDATA\Slack\Cache"
        "$env:APPDATA\Slack\Code Cache"
        "$env:APPDATA\Slack\GPUCache"
        "$env:APPDATA\Slack\Service Worker\CacheStorage"
    )
    foreach ($path in $slackCachePaths) {
        if (Test-Path $path) {
            Clear-DirectoryContents -Path $path -Description "Slack cache"
        }
    }
    
    # Teams
    $teamsCachePaths = @(
        "$env:APPDATA\Microsoft\Teams\Cache"
        "$env:APPDATA\Microsoft\Teams\blob_storage"
        "$env:APPDATA\Microsoft\Teams\databases"
        "$env:APPDATA\Microsoft\Teams\GPUCache"
        "$env:APPDATA\Microsoft\Teams\IndexedDB"
        "$env:APPDATA\Microsoft\Teams\Local Storage"
        "$env:APPDATA\Microsoft\Teams\tmp"
    )
    foreach ($path in $teamsCachePaths) {
        if (Test-Path $path) {
            Clear-DirectoryContents -Path $path -Description "Teams cache"
        }
    }
    
    # VS Code
    $vscodeCachePaths = @(
        "$env:APPDATA\Code\Cache"
        "$env:APPDATA\Code\CachedData"
        "$env:APPDATA\Code\CachedExtensions"
        "$env:APPDATA\Code\CachedExtensionVSIXs"
        "$env:APPDATA\Code\Code Cache"
        "$env:APPDATA\Code\GPUCache"
    )
    foreach ($path in $vscodeCachePaths) {
        if (Test-Path $path) {
            Clear-DirectoryContents -Path $path -Description "VS Code cache"
        }
    }
    
    # Zoom
    $zoomCachePath = "$env:APPDATA\Zoom\data"
    if (Test-Path $zoomCachePath) {
        Clear-DirectoryContents -Path $zoomCachePath -Description "Zoom cache"
    }
    
    # Adobe Creative Cloud
    $adobeCachePaths = @(
        "$env:LOCALAPPDATA\Adobe\*\Cache"
        "$env:APPDATA\Adobe\Common\Media Cache Files"
        "$env:APPDATA\Adobe\Common\Peak Files"
    )
    foreach ($pattern in $adobeCachePaths) {
        $paths = Resolve-Path $pattern -ErrorAction SilentlyContinue
        foreach ($path in $paths) {
            if (Test-Path $path) {
                Clear-DirectoryContents -Path $path.Path -Description "Adobe cache"
            }
        }
    }
    
    # Steam (download cache, not games)
    $steamCachePath = "${env:ProgramFiles(x86)}\Steam\appcache"
    if (Test-Path $steamCachePath) {
        Clear-DirectoryContents -Path $steamCachePath -Description "Steam app cache"
    }
    
    # Epic Games Launcher
    $epicCachePath = "$env:LOCALAPPDATA\EpicGamesLauncher\Saved\webcache"
    if (Test-Path $epicCachePath) {
        Clear-DirectoryContents -Path $epicCachePath -Description "Epic Games cache"
    }
    
    Stop-Section
}

# ============================================================================
# Windows Store / UWP App Caches
# ============================================================================

function Clear-StoreAppCaches {
    <#
    .SYNOPSIS
        Clean Windows Store and UWP app caches
    #>
    
    # Microsoft Store cache
    $storeCache = "$env:LOCALAPPDATA\Microsoft\Windows\WCN"
    if (Test-Path $storeCache) {
        Clear-DirectoryContents -Path $storeCache -Description "Windows Store cache"
    }
    
    # Store app temp files
    $storeTemp = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsStore_*\LocalCache"
    $storePaths = Resolve-Path $storeTemp -ErrorAction SilentlyContinue
    foreach ($path in $storePaths) {
        if (Test-Path $path.Path) {
            Clear-DirectoryContents -Path $path.Path -Description "Store LocalCache"
        }
    }
}

# ============================================================================
# .NET / Runtime Caches
# ============================================================================

function Clear-DotNetCaches {
    <#
    .SYNOPSIS
        Clean .NET runtime caches
    #>
    
    # .NET temp files
    $dotnetTemp = "$env:LOCALAPPDATA\Temp\Microsoft.NET"
    if (Test-Path $dotnetTemp) {
        Clear-DirectoryContents -Path $dotnetTemp -Description ".NET temp files"
    }
    
    # NGen cache (don't touch - managed by Windows)
    # Assembly cache (don't touch - managed by CLR)
}

# ============================================================================
# GPU Shader Caches
# ============================================================================

function Clear-GPUShaderCaches {
    <#
    .SYNOPSIS
        Clean GPU shader caches (NVIDIA, AMD, Intel, DirectX)
    .DESCRIPTION
        GPU drivers cache compiled shaders to improve game/app load times.
        These caches can grow very large (10GB+) and are safe to delete.
        They will be rebuilt automatically when needed.
    #>
    
    Start-Section "GPU shader caches"
    
    # NVIDIA shader caches
    $nvidiaCachePaths = @(
        "$env:LOCALAPPDATA\NVIDIA\DXCache"
        "$env:LOCALAPPDATA\NVIDIA\GLCache"
        "$env:LOCALAPPDATA\NVIDIA Corporation\NV_Cache"
        "$env:TEMP\NVIDIA Corporation\NV_Cache"
    )
    foreach ($path in $nvidiaCachePaths) {
        if (Test-Path $path) {
            Clear-DirectoryContents -Path $path -Description "NVIDIA shader cache"
        }
    }
    
    # AMD shader caches
    $amdCachePaths = @(
        "$env:LOCALAPPDATA\AMD\DXCache"
        "$env:LOCALAPPDATA\AMD\GLCache"
        "$env:LOCALAPPDATA\AMD\VkCache"
    )
    foreach ($path in $amdCachePaths) {
        if (Test-Path $path) {
            Clear-DirectoryContents -Path $path -Description "AMD shader cache"
        }
    }
    
    # Intel shader caches
    $intelCachePaths = @(
        "$env:LOCALAPPDATA\Intel\ShaderCache"
        "$env:APPDATA\Intel\ShaderCache"
    )
    foreach ($path in $intelCachePaths) {
        if (Test-Path $path) {
            Clear-DirectoryContents -Path $path -Description "Intel shader cache"
        }
    }
    
    # DirectX shader cache (system-wide)
    $dxCachePath = "$env:LOCALAPPDATA\D3DSCache"
    if (Test-Path $dxCachePath) {
        Clear-DirectoryContents -Path $dxCachePath -Description "DirectX shader cache"
    }
    
    # DirectX pipeline cache
    $dxPipelinePath = "$env:LOCALAPPDATA\Microsoft\DirectX Shader Cache"
    if (Test-Path $dxPipelinePath) {
        Clear-DirectoryContents -Path $dxPipelinePath -Description "DirectX pipeline cache"
    }
    
    # Vulkan pipeline cache (common location)
    $vulkanCachePath = "$env:LOCALAPPDATA\VulkanCache"
    if (Test-Path $vulkanCachePath) {
        Clear-DirectoryContents -Path $vulkanCachePath -Description "Vulkan pipeline cache"
    }
    
    Stop-Section
}

# ============================================================================
# Main Cache Cleanup Function
# ============================================================================

function Invoke-CacheCleanup {
    <#
    .SYNOPSIS
        Run all cache cleanup tasks
    #>
    param(
        [switch]$IncludeWindowsUpdate,
        [switch]$IncludeBrowsers,
        [switch]$IncludeApps,
        [switch]$IncludeGPU
    )
    
    Start-Section "System caches"
    
    # Windows system caches (if admin)
    if (Test-IsAdmin) {
        if ($IncludeWindowsUpdate) {
            Clear-WindowsUpdateCache
            Clear-DeliveryOptimizationCache
        }
        Clear-FontCache
    }
    
    Clear-StoreAppCaches
    Clear-DotNetCaches
    
    Stop-Section
    
    # GPU shader caches
    if ($IncludeGPU) {
        Clear-GPUShaderCaches
    }
    
    # Browser caches
    if ($IncludeBrowsers) {
        Clear-BrowserCaches
    }
    
    # Application caches
    if ($IncludeApps) {
        Clear-AppCaches
    }
}

# ============================================================================
# Exports
# ============================================================================
# Functions: Clear-WindowsUpdateCache, Clear-BrowserCaches, Clear-AppCaches, etc.
