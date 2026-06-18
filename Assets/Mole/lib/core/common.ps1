# Mole - Common Functions Library
# Main entry point that loads all core modules

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Prevent multiple sourcing
if ((Get-Variable -Name 'MOLE_COMMON_LOADED' -Scope Script -ErrorAction SilentlyContinue) -and $script:MOLE_COMMON_LOADED) {
    return
}
$script:MOLE_COMMON_LOADED = $true

# Get the directory containing this script
$script:MOLE_CORE_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:MOLE_LIB_DIR = Split-Path -Parent $script:MOLE_CORE_DIR
$script:MOLE_ROOT_DIR = Split-Path -Parent $script:MOLE_LIB_DIR

# Version helpers are standalone and safe to load before the other core modules.
. "$script:MOLE_CORE_DIR\version.ps1"

# ============================================================================
# Load Core Modules
# ============================================================================

# Base definitions (colors, icons, constants)
. "$script:MOLE_CORE_DIR\base.ps1"

# Logging functions
. "$script:MOLE_CORE_DIR\log.ps1"

# Safe file operations
. "$script:MOLE_CORE_DIR\file_ops.ps1"

# UI components
. "$script:MOLE_CORE_DIR\ui.ps1"

# ============================================================================
# Version Information
# ============================================================================

$script:MOLE_VERSION = Get-MoleVersionString -RootDir $script:MOLE_ROOT_DIR
$script:MOLE_BUILD_DATE = "2026-01-07"

function Get-MoleVersion {
    <#
    .SYNOPSIS
        Get Mole version information
    #>
    return @{
        Version   = $script:MOLE_VERSION
        BuildDate = $script:MOLE_BUILD_DATE
        PowerShell = $PSVersionTable.PSVersion.ToString()
        Windows    = (Get-WindowsVersion).Version
    }
}

# ============================================================================
# Initialization
# ============================================================================

function Initialize-Mole {
    <#
    .SYNOPSIS
        Initialize Mole environment
    #>

    # Ensure config directory exists
    $configPath = Get-ConfigPath

    # Ensure cache directory exists
    $cachePath = Get-CachePath

    # Set up cleanup trap
    $null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
        Clear-TempFiles
    }

    Write-Debug "Mole initialized"
    Write-Debug "Config: $configPath"
    Write-Debug "Cache: $cachePath"
}

# ============================================================================
# Admin Elevation
# ============================================================================

function Request-AdminPrivileges {
    <#
    .SYNOPSIS
        Request admin privileges if not already running as admin
    .DESCRIPTION
        Restarts the script with elevated privileges using UAC
    #>
    if (-not (Test-IsAdmin)) {
        Write-MoleWarning "Some operations require administrator privileges."

        if (Read-Confirmation -Prompt "Restart with admin privileges?" -Default $true) {
            $scriptPath = $MyInvocation.PSCommandPath
            if ($scriptPath) {
                Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -File `"$scriptPath`"" -Verb RunAs
                exit
            }
        }
        return $false
    }
    return $true
}

function Invoke-AsAdmin {
    <#
    .SYNOPSIS
        Run a script block with admin privileges
    #>
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock
    )

    if (Test-IsAdmin) {
        & $ScriptBlock
    }
    else {
        $command = $ScriptBlock.ToString()
        Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -Command `"$command`"" -Verb RunAs -Wait
    }
}

# ============================================================================
# Exports (functions are available via dot-sourcing)
# ============================================================================
# All functions from base.ps1, log.ps1, file_ops.ps1, and ui.ps1 are
# automatically available when this file is dot-sourced.
