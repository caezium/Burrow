# Mole - Logging Module
# Provides consistent logging functions with colors and icons

#Requires -Version 5.1
Set-StrictMode -Version Latest

# Prevent multiple sourcing
if ((Get-Variable -Name 'MOLE_LOG_LOADED' -Scope Script -ErrorAction SilentlyContinue) -and $script:MOLE_LOG_LOADED) { return }
$script:MOLE_LOG_LOADED = $true

# Import base module
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\base.ps1"
Initialize-MoleVisualDefaults

# ============================================================================
# Log Configuration
# ============================================================================

$script:LogConfig = @{
    DebugEnabled = $env:MOLE_DEBUG -eq "1"
    LogFile      = $null
    Verbose      = $false
}

# ============================================================================
# Core Logging Functions
# ============================================================================

function Write-LogMessage {
    <#
    .SYNOPSIS
        Internal function to write formatted log message
    #>
    param(
        [string]$Message,
        [string]$Level,
        [string]$Color,
        [string]$Icon
    )

    $timestamp = Get-Date -Format "HH:mm:ss"
    $colorCode = Get-MoleColor -Name $Color
    $nc = Get-MoleColor -Name "NC"

    $formattedIcon = if ($Icon) { "$Icon " } else { "" }
    $output = "  ${colorCode}${formattedIcon}${nc}${Message}"

    Write-Host $output

    # Also write to log file if configured
    if ($script:LogConfig.LogFile) {
        "$timestamp [$Level] $Message" | Out-File -Append -FilePath $script:LogConfig.LogFile -Encoding UTF8
    }
}

function Write-Info {
    <#
    .SYNOPSIS
        Write an informational message
    #>
    param([string]$Message)
    Write-LogMessage -Message $Message -Level "INFO" -Color "Cyan" -Icon (Get-MoleIcon -Name "List")
}

function Write-Success {
    <#
    .SYNOPSIS
        Write a success message
    #>
    param([string]$Message)
    Write-LogMessage -Message $Message -Level "SUCCESS" -Color "Green" -Icon (Get-MoleIcon -Name "Success")
}


function Write-MoleWarning {
    <#
    .SYNOPSIS
        Write a warning message
    #>
    param([string]$Message)
    Write-LogMessage -Message $Message -Level "WARN" -Color "Yellow" -Icon (Get-MoleIcon -Name "Warning")
}

function Write-MoleError {
    <#
    .SYNOPSIS
        Write an error message
    #>
    param([string]$Message)
    Write-LogMessage -Message $Message -Level "ERROR" -Color "Red" -Icon (Get-MoleIcon -Name "Error")
}


function Write-Debug {
    <#
    .SYNOPSIS
        Write a debug message (only if debug mode is enabled)
    #>
    param([string]$Message)

    if ($script:LogConfig.DebugEnabled) {
        $gray = Get-MoleColor -Name "Gray"
        $nc = Get-MoleColor -Name "NC"
        Write-Host "  ${gray}[DEBUG] $Message${nc}"
    }
}

function Write-DryRun {
    <#
    .SYNOPSIS
        Write a dry-run message (action that would be taken)
    #>
    param([string]$Message)
    Write-LogMessage -Message $Message -Level "DRYRUN" -Color "Yellow" -Icon (Get-MoleIcon -Name "DryRun")
}

# ============================================================================
# Section Functions (for progress indication)
# ============================================================================

$script:CurrentSection = @{
    Active   = $false
    Activity = $false
    Name     = ""
}

function Start-Section {
    <#
    .SYNOPSIS
        Start a new section with a title
    #>
    param([string]$Title)

    $script:CurrentSection.Active = $true
    $script:CurrentSection.Activity = $false
    $script:CurrentSection.Name = $Title

    $purple = Get-MoleColor -Name "PurpleBold"
    $nc = Get-MoleColor -Name "NC"
    $arrow = Get-MoleIcon -Name "Arrow"

    Write-Host ""
    Write-Host "${purple}${arrow} ${Title}${nc}"
}

function Stop-Section {
    <#
    .SYNOPSIS
        End the current section
    #>
    if ($script:CurrentSection.Active -and -not $script:CurrentSection.Activity) {
        Write-Success "Nothing to tidy"
    }
    $script:CurrentSection.Active = $false
}

function Set-SectionActivity {
    <#
    .SYNOPSIS
        Mark that activity occurred in current section
    #>
    if ($script:CurrentSection.Active) {
        $script:CurrentSection.Activity = $true
    }
}

# ============================================================================
# Progress Spinner
# ============================================================================

$script:SpinnerFrames = @('|', '/', '-', '\')
$script:SpinnerIndex = 0
$script:SpinnerJob = $null

function Start-Spinner {
    <#
    .SYNOPSIS
        Start an inline spinner with message
    #>
    param([string]$Message = "Working...")

    $script:SpinnerIndex = 0
    $gray = Get-MoleColor -Name "Gray"
    $nc = Get-MoleColor -Name "NC"

    Write-Host -NoNewline "  ${gray}$($script:SpinnerFrames[0]) $Message${nc}"
}

function Update-Spinner {
    <#
    .SYNOPSIS
        Update the spinner animation
    #>
    param([string]$Message)

    $script:SpinnerIndex = ($script:SpinnerIndex + 1) % $script:SpinnerFrames.Count
    $frame = $script:SpinnerFrames[$script:SpinnerIndex]
    $gray = Get-MoleColor -Name "Gray"
    $nc = Get-MoleColor -Name "NC"

    # Move cursor to beginning of line and clear
    Write-Host -NoNewline "`r  ${gray}$frame $Message${nc}    "
}

function Stop-Spinner {
    <#
    .SYNOPSIS
        Stop the spinner and clear the line
    #>
    Write-Host -NoNewline "`r                                                            `r"
}

# ============================================================================
# Progress Bar
# ============================================================================

function Write-Progress {
    <#
    .SYNOPSIS
        Write a progress bar
    #>
    param(
        [int]$Current,
        [int]$Total,
        [string]$Message = "",
        [int]$Width = 30
    )

    $percent = if ($Total -gt 0) { [Math]::Round(($Current / $Total) * 100) } else { 0 }
    $filled = [Math]::Round(($Width * $Current) / [Math]::Max($Total, 1))
    $empty = $Width - $filled

    $bar = ("[" + ("=" * $filled) + (" " * $empty) + "]")
    $cyan = Get-MoleColor -Name "Cyan"
    $nc = Get-MoleColor -Name "NC"

    Write-Host -NoNewline "`r  ${cyan}$bar${nc} ${percent}% $Message    "
}

function Complete-Progress {
    <#
    .SYNOPSIS
        Clear the progress bar line
    #>
    Write-Host -NoNewline "`r" + (" " * 80) + "`r"
}

# ============================================================================
# Log File Management
# ============================================================================

function Set-LogFile {
    <#
    .SYNOPSIS
        Set a log file for persistent logging
    #>
    param([string]$Path)

    $script:LogConfig.LogFile = $Path
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

function Enable-DebugMode {
    <#
    .SYNOPSIS
        Enable debug logging
    #>
    $script:LogConfig.DebugEnabled = $true
}

function Disable-DebugMode {
    <#
    .SYNOPSIS
        Disable debug logging
    #>
    $script:LogConfig.DebugEnabled = $false
}

# ============================================================================
# Exports (functions are available via dot-sourcing)
# ============================================================================
# Functions: Write-Info, Write-Success, Write-Warning, Write-Error, etc.
