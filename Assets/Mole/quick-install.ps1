#!/usr/bin/env pwsh
# Mole Quick Installer for Windows
# One-liner install: iwr -useb https://raw.githubusercontent.com/tw93/Mole/windows/quick-install.ps1 | iex

#Requires -Version 5.1

param(
    [string]$InstallDir = "$env:LOCALAPPDATA\Mole"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# Colors
$ESC = [char]27
$Colors = @{
    Green  = "$ESC[32m"
    Yellow = "$ESC[33m"
    Cyan   = "$ESC[36m"
    Red    = "$ESC[31m"
    NC     = "$ESC[0m"
}

function Write-Step {
    param([string]$Message)
    Write-Host "  $($Colors.Cyan)→$($Colors.NC) $Message"
}

function Write-Success {
    param([string]$Message)
    Write-Host "  $($Colors.Green)✓$($Colors.NC) $Message"
}

function Write-ErrorMsg {
    param([string]$Message)
    Write-Host "  $($Colors.Red)✗$($Colors.NC) $Message"
}

function Test-SourceInstall {
    param([string]$Path)

    return (Test-Path (Join-Path $Path ".git"))
}

function Invoke-GitCommand {
    param(
        [string]$WorkingDirectory,
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $previousNativeErrorPreference = $null
    $hasNativeErrorPreference = $false

    if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
        $previousNativeErrorPreference = $PSNativeCommandUseErrorActionPreference
        $PSNativeCommandUseErrorActionPreference = $false
        $hasNativeErrorPreference = $true
    }

    try {
        $gitArguments = @()
        if ($WorkingDirectory) {
            $gitArguments += @("-C", $WorkingDirectory)
        }
        $gitArguments += $Arguments

        $output = & git @gitArguments 2>&1
        $exitCode = $LASTEXITCODE

        return [pscustomobject]@{
            ExitCode = $exitCode
            Text = ((@($output) | ForEach-Object { "$_" }) -join [Environment]::NewLine).Trim()
        }
    }
    finally {
        if ($hasNativeErrorPreference) {
            $PSNativeCommandUseErrorActionPreference = $previousNativeErrorPreference
        }
    }
}

function Get-PowerShellCommand {
    if (Get-Command powershell.exe -ErrorAction SilentlyContinue) {
        return "powershell.exe"
    }

    if (Get-Command pwsh -ErrorAction SilentlyContinue) {
        return "pwsh"
    }

    throw "PowerShell executable not found"
}

# Main installation
try {
    Write-Host ""
    Write-Host "  $($Colors.Cyan)Mole Quick Installer$($Colors.NC)"
    Write-Host "  $($Colors.Yellow)Installing experimental Windows source channel...$($Colors.NC)"
    Write-Host ""

    # Check prerequisites
    Write-Step "Checking prerequisites..."

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-ErrorMsg "Git is not installed. Please install Git first:"
        Write-Host "    https://git-scm.com/download/win"
        exit 1
    }

    Write-Success "Git found"

    if (Test-Path $InstallDir) {
        if (Test-SourceInstall -Path $InstallDir) {
            Write-Step "Existing source install found, refreshing..."

            $fetchResult = Invoke-GitCommand -WorkingDirectory $InstallDir -Arguments @("fetch", "--quiet", "origin", "windows")
            if ($fetchResult.ExitCode -ne 0) {
                Write-ErrorMsg "Failed to fetch latest source"
                if ($fetchResult.Text) {
                    Write-Host "    $($fetchResult.Text)"
                }
                exit 1
            }

            $pullResult = Invoke-GitCommand -WorkingDirectory $InstallDir -Arguments @("pull", "--ff-only", "origin", "windows")
            if ($pullResult.ExitCode -ne 0) {
                Write-ErrorMsg "Failed to fast-forward source install"
                if ($pullResult.Text) {
                    Write-Host "    $($pullResult.Text)"
                }
                exit 1
            }
        }
        else {
            Write-ErrorMsg "Install directory already exists and is not a source install: $InstallDir"
            Write-Host "    Remove it first or reinstall with the latest quick installer."
            exit 1
        }
    }
    else {
        Write-Step "Cloning Mole source..."

        $cloneResult = Invoke-GitCommand -Arguments @("clone", "--quiet", "--depth", "1", "--branch", "windows", "https://github.com/tw93/Mole.git", $InstallDir)
        if ($cloneResult.ExitCode -ne 0) {
            Write-ErrorMsg "Failed to clone source installer"
            if ($cloneResult.Text) {
                Write-Host "    $($cloneResult.Text)"
            }
            exit 1
        }

        if (-not (Test-Path (Join-Path $InstallDir "install.ps1"))) {
            Write-ErrorMsg "Failed to clone source installer"
            exit 1
        }

        Write-Success "Cloned source to $InstallDir"
    }

    # Run installer
    Write-Step "Running installer..."
    Write-Host ""

    $powerShellCommand = Get-PowerShellCommand
    & $powerShellCommand -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $InstallDir "install.ps1") -InstallDir $InstallDir -AddToPath
    if ($LASTEXITCODE -ne 0) {
        throw "Installer exited with code $LASTEXITCODE"
    }

    Write-Host ""
    Write-Success "Installation complete!"
    Write-Host ""
    Write-Host "  Run $($Colors.Green)mole$($Colors.NC) to get started"
    Write-Host "  Run $($Colors.Green)mo update$($Colors.NC) to pull the latest windows source later"
    Write-Host ""

} catch {
    Write-ErrorMsg "Installation failed: $_"
    exit 1
}
