# Mole - Safe File Operations Module
# Provides safe file deletion and manipulation functions with protection checks

#Requires -Version 5.1
Set-StrictMode -Version Latest

# Prevent multiple sourcing
if ((Get-Variable -Name 'MOLE_FILEOPS_LOADED' -Scope Script -ErrorAction SilentlyContinue) -and $script:MOLE_FILEOPS_LOADED) { return }
$script:MOLE_FILEOPS_LOADED = $true

# Import dependencies
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\base.ps1"
. "$scriptDir\log.ps1"

# ============================================================================
# Global State
# ============================================================================

$script:MoleDryRunMode = $env:MOLE_DRY_RUN -eq "1"
$script:TotalSizeCleaned = 0
$script:FilesCleaned = 0
$script:TotalItems = 0

# ============================================================================
# Safety Validation Functions
# ============================================================================

function Test-SafePath {
    <#
    .SYNOPSIS
        Validate that a path is safe to operate on
    .DESCRIPTION
        Checks against protected paths and whitelist
    .OUTPUTS
        $true if safe, $false if protected
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    
    # Must have a path
    if ([string]::IsNullOrWhiteSpace($Path)) {
        Write-Debug "Empty path rejected"
        return $false
    }
    
    # Resolve to full path
    $fullPath = Resolve-SafePath -Path $Path
    if (-not $fullPath) {
        Write-Debug "Could not resolve path: $Path"
        return $false
    }
    
    # Check protected paths
    if (Test-ProtectedPath -Path $fullPath) {
        Write-Debug "Protected path rejected: $fullPath"
        return $false
    }
    
    # Check whitelist
    if (Test-Whitelisted -Path $fullPath) {
        Write-Debug "Whitelisted path rejected: $fullPath"
        return $false
    }
    
    return $true
}

function Get-PathSize {
    <#
    .SYNOPSIS
        Get the size of a file or directory in bytes
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    
    if (-not (Test-Path $Path)) {
        return 0
    }
    
    try {
        if (Test-Path $Path -PathType Container) {
            $size = (Get-ChildItem -Path $Path -Recurse -Force -ErrorAction SilentlyContinue | 
                     Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
            if ($null -eq $size) { return 0 }
            return [long]$size
        }
        else {
            return (Get-Item $Path -Force -ErrorAction SilentlyContinue).Length
        }
    }
    catch {
        return 0
    }
}

function Get-PathSizeKB {
    <#
    .SYNOPSIS
        Get the size of a file or directory in kilobytes
    #>
    param([string]$Path)
    
    $bytes = Get-PathSize -Path $Path
    return [Math]::Ceiling($bytes / 1024)
}

# ============================================================================
# Safe Removal Functions
# ============================================================================

function Remove-SafeItem {
    <#
    .SYNOPSIS
        Safely remove a file or directory with all protection checks
    .DESCRIPTION
        This is the main safe deletion function. It:
        - Validates the path is not protected
        - Checks against whitelist
        - Supports dry-run mode
        - Tracks cleanup statistics
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        
        [string]$Description = "",
        
        [switch]$Force,
        
        [switch]$Recurse
    )
    
    # Validate path safety
    if (-not (Test-SafePath -Path $Path)) {
        Write-Debug "Skipping protected/whitelisted path: $Path"
        return $false
    }
    
    # Check if path exists
    if (-not (Test-Path $Path)) {
        Write-Debug "Path does not exist: $Path"
        return $false
    }
    
    # Get size before removal
    $size = Get-PathSize -Path $Path
    $sizeKB = [Math]::Ceiling($size / 1024)
    $sizeHuman = Format-ByteSize -Bytes $size
    
    # Handle dry run
    if ($script:MoleDryRunMode) {
        $name = if ($Description) { $Description } else { Split-Path -Leaf $Path }
        Write-DryRun "$name $($script:Colors.Yellow)($sizeHuman dry)$($script:Colors.NC)"
        Set-SectionActivity
        return $true
    }
    
    # Perform removal
    try {
        $isDirectory = Test-Path $Path -PathType Container
        
        if ($isDirectory) {
            Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
        }
        else {
            Remove-Item -Path $Path -Force -ErrorAction Stop
        }
        
        # Update statistics
        $script:TotalSizeCleaned += $sizeKB
        $script:FilesCleaned++
        $script:TotalItems++
        
        # Log success
        $name = if ($Description) { $Description } else { Split-Path -Leaf $Path }
        Write-Success "$name $($script:Colors.Green)($sizeHuman)$($script:Colors.NC)"
        Set-SectionActivity
        
        return $true
    }
    catch {
        Write-Debug "Failed to remove $Path : $_"
        return $false
    }
}

function Remove-SafeItems {
    <#
    .SYNOPSIS
        Safely remove multiple items with a collective description
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$Paths,
        
        [string]$Description = "Items"
    )
    
    $totalSize = 0
    $removedCount = 0
    $failedCount = 0
    
    foreach ($path in $Paths) {
        if (-not (Test-SafePath -Path $path)) {
            continue
        }
        
        if (-not (Test-Path $path)) {
            continue
        }
        
        $size = Get-PathSize -Path $path
        
        if ($script:MoleDryRunMode) {
            $totalSize += $size
            $removedCount++
            continue
        }
        
        try {
            $isDirectory = Test-Path $path -PathType Container
            if ($isDirectory) {
                Remove-Item -Path $path -Recurse -Force -ErrorAction Stop
            }
            else {
                Remove-Item -Path $path -Force -ErrorAction Stop
            }
            $totalSize += $size
            $removedCount++
        }
        catch {
            $failedCount++
            Write-Debug "Failed to remove: $path - $_"
        }
    }
    
    if ($removedCount -gt 0) {
        $sizeKB = [Math]::Ceiling($totalSize / 1024)
        $sizeHuman = Format-ByteSize -Bytes $totalSize
        
        if ($script:MoleDryRunMode) {
            Write-DryRun "$Description $($script:Colors.Yellow)($removedCount items, $sizeHuman dry)$($script:Colors.NC)"
        }
        else {
            $script:TotalSizeCleaned += $sizeKB
            $script:FilesCleaned += $removedCount
            $script:TotalItems++
            Write-Success "$Description $($script:Colors.Green)($removedCount items, $sizeHuman)$($script:Colors.NC)"
        }
        Set-SectionActivity
    }
    
    return @{
        Removed = $removedCount
        Failed  = $failedCount
        Size    = $totalSize
    }
}

# ============================================================================
# Pattern-Based Cleanup Functions
# ============================================================================

function Remove-OldFiles {
    <#
    .SYNOPSIS
        Remove files older than specified days
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        
        [int]$DaysOld = 7,
        
        [string]$Filter = "*",
        
        [string]$Description = "Old files"
    )
    
    if (-not (Test-Path $Path)) {
        return @{ Removed = 0; Size = 0 }
    }
    
    $cutoffDate = (Get-Date).AddDays(-$DaysOld)
    
    $oldFiles = Get-ChildItem -Path $Path -Filter $Filter -File -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt $cutoffDate }
    
    if ($oldFiles) {
        $paths = $oldFiles | ForEach-Object { $_.FullName }
        return Remove-SafeItems -Paths $paths -Description "$Description (>${DaysOld}d old)"
    }
    
    return @{ Removed = 0; Size = 0 }
}

function Remove-EmptyDirectories {
    <#
    .SYNOPSIS
        Remove empty directories recursively
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        
        [string]$Description = "Empty directories"
    )
    
    if (-not (Test-Path $Path)) {
        return @{ Removed = 0 }
    }
    
    $removedCount = 0
    $maxIterations = 5
    
    for ($i = 0; $i -lt $maxIterations; $i++) {
        $emptyDirs = Get-ChildItem -Path $Path -Directory -Recurse -Force -ErrorAction SilentlyContinue |
                     Where-Object { 
                         (Get-ChildItem -Path $_.FullName -Force -ErrorAction SilentlyContinue | Measure-Object).Count -eq 0
                     }
        
        if (-not $emptyDirs -or $emptyDirs.Count -eq 0) {
            break
        }
        
        foreach ($dir in $emptyDirs) {
            if (Test-SafePath -Path $dir.FullName) {
                if (-not $script:MoleDryRunMode) {
                    try {
                        Remove-Item -Path $dir.FullName -Force -ErrorAction Stop
                        $removedCount++
                    }
                    catch {
                        Write-Debug "Could not remove empty dir: $($dir.FullName)"
                    }
                }
                else {
                    $removedCount++
                }
            }
        }
    }
    
    if ($removedCount -gt 0) {
        if ($script:MoleDryRunMode) {
            Write-DryRun "$Description $($script:Colors.Yellow)($removedCount dirs dry)$($script:Colors.NC)"
        }
        else {
            Write-Success "$Description $($script:Colors.Green)($removedCount dirs)$($script:Colors.NC)"
        }
        Set-SectionActivity
    }
    
    return @{ Removed = $removedCount }
}

function Clear-DirectoryContents {
    <#
    .SYNOPSIS
        Clear all contents of a directory but keep the directory itself
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        
        [string]$Description = ""
    )
    
    if (-not (Test-Path $Path)) {
        return @{ Removed = 0; Size = 0 }
    }
    
    if (-not (Test-SafePath -Path $Path)) {
        return @{ Removed = 0; Size = 0 }
    }
    
    $items = Get-ChildItem -Path $Path -Force -ErrorAction SilentlyContinue
    if ($items) {
        $paths = $items | ForEach-Object { $_.FullName }
        $desc = if ($Description) { $Description } else { Split-Path -Leaf $Path }
        return Remove-SafeItems -Paths $paths -Description $desc
    }
    
    return @{ Removed = 0; Size = 0 }
}

# ============================================================================
# Statistics Functions
# ============================================================================

function Get-CleanupStats {
    <#
    .SYNOPSIS
        Get current cleanup statistics
    #>
    return @{
        TotalSizeKB   = $script:TotalSizeCleaned
        TotalSizeHuman = Format-ByteSize -Bytes ($script:TotalSizeCleaned * 1024)
        FilesCleaned  = $script:FilesCleaned
        TotalItems    = $script:TotalItems
    }
}

function Reset-CleanupStats {
    <#
    .SYNOPSIS
        Reset cleanup statistics
    #>
    $script:TotalSizeCleaned = 0
    $script:FilesCleaned = 0
    $script:TotalItems = 0
}

function Set-DryRunMode {
    <#
    .SYNOPSIS
        Enable or disable dry-run mode
    #>
    param([bool]$Enabled)
    $script:MoleDryRunMode = $Enabled
}

function Test-DryRunMode {
    <#
    .SYNOPSIS
        Check if dry-run mode is enabled
    #>
    return $script:MoleDryRunMode
}

# ============================================================================
# Exports (functions are available via dot-sourcing)
# ============================================================================
# Functions: Test-SafePath, Get-PathSize, Remove-SafeItem, etc.
