# Mole - Developer Tools Cleanup Module
# Cleans development tool caches and build artifacts

#Requires -Version 5.1
Set-StrictMode -Version Latest

# Prevent multiple sourcing
if ((Get-Variable -Name 'MOLE_CLEAN_DEV_LOADED' -Scope Script -ErrorAction SilentlyContinue) -and $script:MOLE_CLEAN_DEV_LOADED) { return }
$script:MOLE_CLEAN_DEV_LOADED = $true

# Import dependencies
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\..\core\base.ps1"
. "$scriptDir\..\core\log.ps1"
. "$scriptDir\..\core\file_ops.ps1"

# ============================================================================
# Node.js / JavaScript Ecosystem
# ============================================================================

function Clear-NpmCache {
    <#
    .SYNOPSIS
        Clean npm, pnpm, yarn, and bun caches
    #>
    
    # npm cache
    if (Get-Command npm -ErrorAction SilentlyContinue) {
        if (Test-DryRunMode) {
            Write-DryRun "npm cache"
        }
        else {
            try {
                $null = npm cache clean --force 2>&1
                Write-Success "npm cache"
                Set-SectionActivity
            }
            catch {
                Write-Debug "npm cache clean failed: $_"
            }
        }
    }
    
    # npm cache directory (fallback)
    $npmCachePath = "$env:APPDATA\npm-cache"
    if (Test-Path $npmCachePath) {
        Clear-DirectoryContents -Path $npmCachePath -Description "npm cache directory"
    }
    
    # pnpm store
    $pnpmStorePath = "$env:LOCALAPPDATA\pnpm\store"
    if (Test-Path $pnpmStorePath) {
        if (Get-Command pnpm -ErrorAction SilentlyContinue) {
            if (Test-DryRunMode) {
                Write-DryRun "pnpm store"
            }
            else {
                try {
                    $null = pnpm store prune 2>&1
                    Write-Success "pnpm store pruned"
                    Set-SectionActivity
                }
                catch {
                    Write-Debug "pnpm store prune failed: $_"
                }
            }
        }
    }
    
    # Yarn cache
    $yarnCachePaths = @(
        "$env:LOCALAPPDATA\Yarn\Cache"
        "$env:USERPROFILE\.yarn\cache"
    )
    foreach ($path in $yarnCachePaths) {
        if (Test-Path $path) {
            Clear-DirectoryContents -Path $path -Description "Yarn cache"
        }
    }
    
    # Bun cache
    $bunCachePath = "$env:USERPROFILE\.bun\install\cache"
    if (Test-Path $bunCachePath) {
        Clear-DirectoryContents -Path $bunCachePath -Description "Bun cache"
    }
}

function Clear-NodeBuildCaches {
    <#
    .SYNOPSIS
        Clean Node.js build-related caches
    #>
    
    # node-gyp
    $nodeGypPath = "$env:LOCALAPPDATA\node-gyp\Cache"
    if (Test-Path $nodeGypPath) {
        Clear-DirectoryContents -Path $nodeGypPath -Description "node-gyp cache"
    }
    
    # Electron cache
    $electronCachePath = "$env:LOCALAPPDATA\electron\Cache"
    if (Test-Path $electronCachePath) {
        Clear-DirectoryContents -Path $electronCachePath -Description "Electron cache"
    }
    
    # TypeScript cache
    $tsCachePath = "$env:LOCALAPPDATA\TypeScript"
    if (Test-Path $tsCachePath) {
        Clear-DirectoryContents -Path $tsCachePath -Description "TypeScript cache"
    }
}

# ============================================================================
# Python Ecosystem
# ============================================================================

function Clear-PythonCaches {
    <#
    .SYNOPSIS
        Clean Python and pip caches
    #>
    
    # pip cache
    if (Get-Command pip -ErrorAction SilentlyContinue) {
        if (Test-DryRunMode) {
            Write-DryRun "pip cache"
        }
        else {
            try {
                $null = pip cache purge 2>&1
                Write-Success "pip cache"
                Set-SectionActivity
            }
            catch {
                Write-Debug "pip cache purge failed: $_"
            }
        }
    }
    
    # pip cache directory
    $pipCachePath = "$env:LOCALAPPDATA\pip\Cache"
    if (Test-Path $pipCachePath) {
        Clear-DirectoryContents -Path $pipCachePath -Description "pip cache directory"
    }
    
    # Python bytecode caches (__pycache__)
    # Note: These are typically in project directories, cleaned by purge command
    
    # pyenv cache
    $pyenvCachePath = "$env:USERPROFILE\.pyenv\cache"
    if (Test-Path $pyenvCachePath) {
        Clear-DirectoryContents -Path $pyenvCachePath -Description "pyenv cache"
    }
    
    # Poetry cache
    $poetryCachePath = "$env:LOCALAPPDATA\pypoetry\Cache"
    if (Test-Path $poetryCachePath) {
        Clear-DirectoryContents -Path $poetryCachePath -Description "Poetry cache"
    }
    
    # conda packages
    $condaCachePaths = @(
        "$env:USERPROFILE\.conda\pkgs"
        "$env:USERPROFILE\anaconda3\pkgs"
        "$env:USERPROFILE\miniconda3\pkgs"
    )
    foreach ($path in $condaCachePaths) {
        if (Test-Path $path) {
            # Only clean index and temp files, not actual packages
            $tempFiles = Get-ChildItem -Path $path -Filter "*.tmp" -ErrorAction SilentlyContinue
            if ($tempFiles) {
                $paths = $tempFiles | ForEach-Object { $_.FullName }
                Remove-SafeItems -Paths $paths -Description "Conda temp files"
            }
        }
    }
    
    # Jupyter runtime
    $jupyterRuntimePath = "$env:APPDATA\jupyter\runtime"
    if (Test-Path $jupyterRuntimePath) {
        Clear-DirectoryContents -Path $jupyterRuntimePath -Description "Jupyter runtime"
    }
    
    # pytest cache
    $pytestCachePath = "$env:USERPROFILE\.pytest_cache"
    if (Test-Path $pytestCachePath) {
        Remove-SafeItem -Path $pytestCachePath -Description "pytest cache" -Recurse
    }
}

# ============================================================================
# .NET / C# Ecosystem
# ============================================================================

function Clear-DotNetDevCaches {
    <#
    .SYNOPSIS
        Clean .NET development caches
    #>
    
    # NuGet cache
    $nugetCachePath = "$env:USERPROFILE\.nuget\packages"
    # Don't clean packages by default - they're needed for builds
    # Only clean http-cache and temp
    
    $nugetHttpCache = "$env:LOCALAPPDATA\NuGet\v3-cache"
    if (Test-Path $nugetHttpCache) {
        Clear-DirectoryContents -Path $nugetHttpCache -Description "NuGet HTTP cache"
    }
    
    $nugetTempPath = "$env:LOCALAPPDATA\NuGet\plugins-cache"
    if (Test-Path $nugetTempPath) {
        Clear-DirectoryContents -Path $nugetTempPath -Description "NuGet plugins cache"
    }
    
    # MSBuild temp files
    $msbuildTemp = "$env:LOCALAPPDATA\Microsoft\MSBuild"
    if (Test-Path $msbuildTemp) {
        $tempDirs = Get-ChildItem -Path $msbuildTemp -Directory -Filter "*temp*" -ErrorAction SilentlyContinue
        foreach ($dir in $tempDirs) {
            Clear-DirectoryContents -Path $dir.FullName -Description "MSBuild temp"
        }
    }
}

# ============================================================================
# Go Ecosystem
# ============================================================================

function Clear-GoCaches {
    <#
    .SYNOPSIS
        Clean Go build and module caches
    #>
    
    if (Get-Command go -ErrorAction SilentlyContinue) {
        if (Test-DryRunMode) {
            Write-DryRun "Go cache"
        }
        else {
            try {
                $null = go clean -cache 2>&1
                Write-Success "Go build cache"
                Set-SectionActivity
            }
            catch {
                Write-Debug "go clean -cache failed: $_"
            }
        }
    }
    
    # Go module cache
    $goModCachePath = "$env:GOPATH\pkg\mod\cache"
    if (-not $env:GOPATH) {
        $goModCachePath = "$env:USERPROFILE\go\pkg\mod\cache"
    }
    if (Test-Path $goModCachePath) {
        Clear-DirectoryContents -Path $goModCachePath -Description "Go module cache"
    }
}

function Get-MiseCachePath {
    <#
    .SYNOPSIS
        Resolve the mise cache directory without touching installs/plugins
    #>

    if (-not [string]::IsNullOrWhiteSpace($env:MISE_CACHE_DIR)) {
        return $env:MISE_CACHE_DIR
    }

    if (-not (Get-Command mise -ErrorAction SilentlyContinue)) {
        return $null
    }

    try {
        $cachePath = (& mise cache path 2>$null | Select-Object -First 1)
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($cachePath)) {
            return $cachePath.Trim()
        }
    }
    catch {
        Write-Debug "mise cache path failed: $_"
    }

    return $null
}

function Clear-MiseCache {
    <#
    .SYNOPSIS
        Clean mise internal cache only
    .DESCRIPTION
        Respects MISE_CACHE_DIR and never removes the installs/plugins data tree.
    #>

    $hasMise = [bool](Get-Command mise -ErrorAction SilentlyContinue)
    $cachePath = Get-MiseCachePath
    $clearedByCommand = $false

    if ($hasMise -and -not (Test-DryRunMode)) {
        try {
            $null = & mise cache clear 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Success "mise cache"
                Set-SectionActivity
                $clearedByCommand = $true
            }
        }
        catch {
            Write-Debug "mise cache clear failed: $_"
        }
    }

    if (-not $clearedByCommand -and $cachePath -and (Test-Path $cachePath)) {
        Clear-DirectoryContents -Path $cachePath -Description "mise cache"
    }
}

# ============================================================================
# Rust Ecosystem
# ============================================================================

function Clear-RustCaches {
    <#
    .SYNOPSIS
        Clean Rust/Cargo caches
    #>
    
    # Cargo registry cache
    $cargoRegistryCache = "$env:USERPROFILE\.cargo\registry\cache"
    if (Test-Path $cargoRegistryCache) {
        Clear-DirectoryContents -Path $cargoRegistryCache -Description "Cargo registry cache"
    }
    
    # Cargo git cache
    $cargoGitCache = "$env:USERPROFILE\.cargo\git\checkouts"
    if (Test-Path $cargoGitCache) {
        Clear-DirectoryContents -Path $cargoGitCache -Description "Cargo git cache"
    }
    
    # Rustup downloads
    $rustupDownloads = "$env:USERPROFILE\.rustup\downloads"
    if (Test-Path $rustupDownloads) {
        Clear-DirectoryContents -Path $rustupDownloads -Description "Rustup downloads"
    }
}

# ============================================================================
# Java / JVM Ecosystem
# ============================================================================

function Clear-JvmCaches {
    <#
    .SYNOPSIS
        Clean JVM ecosystem caches (Gradle, Maven, etc.)
    #>
    
    # Gradle caches
    $gradleCachePaths = @(
        "$env:USERPROFILE\.gradle\caches"
        "$env:USERPROFILE\.gradle\daemon"
        "$env:USERPROFILE\.gradle\wrapper\dists"
    )
    foreach ($path in $gradleCachePaths) {
        if (Test-Path $path) {
            # Only clean temp and old daemon logs
            $tempFiles = Get-ChildItem -Path $path -Recurse -Filter "*.lock" -ErrorAction SilentlyContinue
            if ($tempFiles) {
                $paths = $tempFiles | ForEach-Object { $_.FullName }
                Remove-SafeItems -Paths $paths -Description "Gradle lock files"
            }
        }
    }
    
    # Maven repository (only clean temp files)
    $mavenRepoPath = "$env:USERPROFILE\.m2\repository"
    if (Test-Path $mavenRepoPath) {
        $tempFiles = Get-ChildItem -Path $mavenRepoPath -Recurse -Filter "*.lastUpdated" -ErrorAction SilentlyContinue
        if ($tempFiles) {
            $paths = $tempFiles | ForEach-Object { $_.FullName }
            Remove-SafeItems -Paths $paths -Description "Maven update markers"
        }
    }
}

# ============================================================================
# Docker / Containers
# ============================================================================

function Clear-DockerCaches {
    <#
    .SYNOPSIS
        Clean Docker build caches and unused data
    #>
    
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        return
    }
    
    # Check if Docker daemon is running
    $dockerRunning = $false
    try {
        $null = docker info 2>&1
        $dockerRunning = $true
    }
    catch {
        Write-Debug "Docker daemon not running"
    }
    
    if ($dockerRunning) {
        if (Test-DryRunMode) {
            Write-DryRun "Docker build cache"
        }
        else {
            try {
                $null = docker builder prune -af 2>&1
                Write-Success "Docker build cache"
                Set-SectionActivity
            }
            catch {
                Write-Debug "docker builder prune failed: $_"
            }
        }
    }
    
    # Docker Desktop cache (Windows)
    $dockerDesktopCache = "$env:LOCALAPPDATA\Docker\wsl\data"
    # Note: Don't clean this - it's the WSL2 virtual disk
}

# ============================================================================
# Cloud CLI Tools
# ============================================================================

function Clear-CloudCliCaches {
    <#
    .SYNOPSIS
        Clean cloud CLI tool caches (AWS, Azure, GCP)
    #>
    
    # AWS CLI cache
    $awsCachePath = "$env:USERPROFILE\.aws\cli\cache"
    if (Test-Path $awsCachePath) {
        Clear-DirectoryContents -Path $awsCachePath -Description "AWS CLI cache"
    }
    
    # Azure CLI logs
    $azureLogsPath = "$env:USERPROFILE\.azure\logs"
    if (Test-Path $azureLogsPath) {
        Clear-DirectoryContents -Path $azureLogsPath -Description "Azure CLI logs"
    }
    
    # Google Cloud logs
    $gcloudLogsPath = "$env:APPDATA\gcloud\logs"
    if (Test-Path $gcloudLogsPath) {
        Clear-DirectoryContents -Path $gcloudLogsPath -Description "gcloud logs"
    }
    
    # Kubernetes cache
    $kubeCachePath = "$env:USERPROFILE\.kube\cache"
    if (Test-Path $kubeCachePath) {
        Clear-DirectoryContents -Path $kubeCachePath -Description "Kubernetes cache"
    }
    
    # Terraform plugin cache
    $terraformCachePath = "$env:APPDATA\terraform.d\plugin-cache"
    if (Test-Path $terraformCachePath) {
        Clear-DirectoryContents -Path $terraformCachePath -Description "Terraform plugin cache"
    }
}

# ============================================================================
# Elixir/Erlang Ecosystem
# ============================================================================

function Clear-ElixirCaches {
    <#
    .SYNOPSIS
        Clean Elixir Mix and Hex caches
    #>
    
    # Mix archives - skip auto-cleanup to preserve globally installed Mix tools
    # NOTE: This directory contains globally installed Mix tools and tasks (e.g., phx_new, hex).
    # Clearing it would remove user-installed tools requiring reinstallation.
    $mixArchivesPath = "$env:USERPROFILE\.mix\archives"
    if (Test-Path $mixArchivesPath) {
        Write-Debug "Skipping Mix archives at '$mixArchivesPath' - contains globally installed tools"
    }
    
    # Hex cache
    $hexCachePath = "$env:USERPROFILE\.hex\cache"
    if (Test-Path $hexCachePath) {
        Clear-DirectoryContents -Path $hexCachePath -Description "Hex cache"
    }
    
    # Hex packages - use age-based cleanup to preserve actively used packages
    $hexPackagesPath = "$env:USERPROFILE\.hex\packages"
    if (Test-Path $hexPackagesPath) {
        $cutoffDate = (Get-Date).AddDays(-90)
        $oldHexPackages = Get-ChildItem -Path $hexPackagesPath -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoffDate }
        if ($oldHexPackages) {
            foreach ($pkg in $oldHexPackages) {
                Remove-SafeItem -Path $pkg.FullName -Description "Old Hex package ($($pkg.Name))" -Recurse
            }
        }
    }
}

# ============================================================================
# Haskell Ecosystem
# ============================================================================

function Clear-HaskellCaches {
    <#
    .SYNOPSIS
        Clean Haskell Cabal and Stack caches
    #>
    
    # Cabal packages cache - use age-based cleanup to preserve recently used packages
    $cabalPackagesPath = "$env:USERPROFILE\.cabal\packages"
    if (Test-Path $cabalPackagesPath) {
        $cutoffDate = (Get-Date).AddDays(-90)
        $oldCacheItems = Get-ChildItem -Path $cabalPackagesPath -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoffDate }
        if ($oldCacheItems) {
            $paths = $oldCacheItems | ForEach-Object { $_.FullName }
            Remove-SafeItems -Paths $paths -Description "Cabal old packages cache"
        }
    }
    
    # Cabal store
    $cabalStorePath = "$env:USERPROFILE\.cabal\store"
    if (Test-Path $cabalStorePath) {
        # Only clean old/unused packages - be careful here
        $oldDirs = Get-ChildItem -Path $cabalStorePath -Directory -ErrorAction SilentlyContinue |
                   Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-90) }
        if ($oldDirs) {
            foreach ($dir in $oldDirs) {
                Remove-SafeItem -Path $dir.FullName -Description "Cabal old store ($($dir.Name))" -Recurse
            }
        }
    }
    
    # Stack programs cache - use age-based cleanup (contains GHC installations)
    # These can be large and time-consuming to re-download
    $stackProgramsPath = "$env:USERPROFILE\.stack\programs"
    if (Test-Path $stackProgramsPath) {
        $cutoffDate = (Get-Date).AddDays(-90)
        $oldProgramDirs = Get-ChildItem -Path $stackProgramsPath -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoffDate }
        if ($oldProgramDirs) {
            foreach ($dir in $oldProgramDirs) {
                Remove-SafeItem -Path $dir.FullName -Description "Stack old program ($($dir.Name))" -Recurse
            }
        }
    }
    
    # Stack snapshots (be careful - these are needed for builds)
    $stackSnapshotsPath = "$env:USERPROFILE\.stack\snapshots"
    if (Test-Path $stackSnapshotsPath) {
        # Only clean temp files
        $tempFiles = Get-ChildItem -Path $stackSnapshotsPath -Recurse -Filter "*.tmp" -ErrorAction SilentlyContinue
        if ($tempFiles) {
            $paths = $tempFiles | ForEach-Object { $_.FullName }
            Remove-SafeItems -Paths $paths -Description "Stack temp files"
        }
    }
}

# ============================================================================
# OCaml Ecosystem
# ============================================================================

function Clear-OCamlCaches {
    <#
    .SYNOPSIS
        Clean OCaml Opam caches
    #>
    
    # Opam download cache
    $opamDownloadCache = "$env:USERPROFILE\.opam\download-cache"
    if (Test-Path $opamDownloadCache) {
        Clear-DirectoryContents -Path $opamDownloadCache -Description "Opam download cache"
    }
    
    # Opam repo cache
    $opamRepoCache = "$env:USERPROFILE\.opam\repo"
    if (Test-Path $opamRepoCache) {
        $cacheDirs = Get-ChildItem -Path $opamRepoCache -Directory -Filter "*cache*" -ErrorAction SilentlyContinue
        foreach ($dir in $cacheDirs) {
            Clear-DirectoryContents -Path $dir.FullName -Description "Opam repo cache"
        }
    }
}

# ============================================================================
# Editor Caches (VS Code, Zed, etc.)
# ============================================================================

function Clear-EditorCaches {
    <#
    .SYNOPSIS
        Clean VS Code, Zed, and other editor caches
    #>
    
    # VS Code cached data
    # NOTE: workspaceStorage excluded - contains workspace-specific settings and extension data
    $vscodeCachePaths = @(
        "$env:APPDATA\Code\Cache"
        "$env:APPDATA\Code\CachedData"
        "$env:APPDATA\Code\CachedExtensions"
        "$env:APPDATA\Code\CachedExtensionVSIXs"
        "$env:APPDATA\Code\Code Cache"
        "$env:APPDATA\Code\GPUCache"
        "$env:LOCALAPPDATA\Microsoft\vscode-cpptools"
    )
    foreach ($path in $vscodeCachePaths) {
        if (Test-Path $path) {
            Clear-DirectoryContents -Path $path -Description "VS Code cache"
        }
    }
    
    # VS Code Insiders
    # NOTE: workspaceStorage excluded - contains workspace-specific settings and extension data
    $vscodeInsidersCachePaths = @(
        "$env:APPDATA\Code - Insiders\Cache"
        "$env:APPDATA\Code - Insiders\CachedData"
        "$env:APPDATA\Code - Insiders\CachedExtensions"
        "$env:APPDATA\Code - Insiders\CachedExtensionVSIXs"
        "$env:APPDATA\Code - Insiders\Code Cache"
        "$env:APPDATA\Code - Insiders\GPUCache"
    )
    foreach ($path in $vscodeInsidersCachePaths) {
        if (Test-Path $path) {
            Clear-DirectoryContents -Path $path -Description "VS Code Insiders cache"
        }
    }
    
    # Zed editor cache
    $zedCachePaths = @(
        "$env:LOCALAPPDATA\Zed\cache"
        "$env:APPDATA\Zed\cache"
    )
    foreach ($path in $zedCachePaths) {
        if (Test-Path $path) {
            Clear-DirectoryContents -Path $path -Description "Zed cache"
        }
    }
    
    # Sublime Text cache
    $sublimeCachePath = "$env:APPDATA\Sublime Text\Cache"
    if (Test-Path $sublimeCachePath) {
        Clear-DirectoryContents -Path $sublimeCachePath -Description "Sublime Text cache"
    }
    
    # Atom cache (legacy)
    $atomCachePath = "$env:APPDATA\.atom\compile-cache"
    if (Test-Path $atomCachePath) {
        Clear-DirectoryContents -Path $atomCachePath -Description "Atom compile cache"
    }
}

# ============================================================================
# IDE Caches
# ============================================================================

function Clear-IdeCaches {
    <#
    .SYNOPSIS
        Clean IDE caches (VS, VSCode, JetBrains, etc.)
    #>
    
    # Visual Studio cache
    $vsCachePaths = @(
        "$env:LOCALAPPDATA\Microsoft\VisualStudio\*\ComponentModelCache"
        "$env:LOCALAPPDATA\Microsoft\VisualStudio\*\ImageCache"
    )
    foreach ($pattern in $vsCachePaths) {
        $paths = Resolve-Path $pattern -ErrorAction SilentlyContinue
        foreach ($path in $paths) {
            if (Test-Path $path.Path) {
                Clear-DirectoryContents -Path $path.Path -Description "Visual Studio cache"
            }
        }
    }
    
    # JetBrains IDEs caches
    $jetbrainsBasePaths = @(
        "$env:LOCALAPPDATA\JetBrains"
        "$env:APPDATA\JetBrains"
    )
    foreach ($basePath in $jetbrainsBasePaths) {
        if (Test-Path $basePath) {
            $ideFolders = Get-ChildItem -Path $basePath -Directory -ErrorAction SilentlyContinue
            foreach ($ideFolder in $ideFolders) {
                $cacheFolders = @("caches", "index", "tmp")
                foreach ($cacheFolder in $cacheFolders) {
                    $cachePath = Join-Path $ideFolder.FullName $cacheFolder
                    if (Test-Path $cachePath) {
                        Clear-DirectoryContents -Path $cachePath -Description "$($ideFolder.Name) $cacheFolder"
                    }
                }
            }
        }
    }
}

# ============================================================================
# Git Caches
# ============================================================================

function Clear-GitCaches {
    <#
    .SYNOPSIS
        Clean Git temporary files and lock files
    #>
    
    # Git config locks (stale)
    $gitConfigLock = "$env:USERPROFILE\.gitconfig.lock"
    if (Test-Path $gitConfigLock) {
        Remove-SafeItem -Path $gitConfigLock -Description "Git config lock"
    }
    
    # GitHub CLI cache
    $ghCachePath = "$env:APPDATA\GitHub CLI"
    if (Test-Path $ghCachePath) {
        $cacheFiles = Get-ChildItem -Path $ghCachePath -Filter "*.json" -ErrorAction SilentlyContinue |
                      Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) }
        if ($cacheFiles) {
            $paths = $cacheFiles | ForEach-Object { $_.FullName }
            Remove-SafeItems -Paths $paths -Description "GitHub CLI cache"
        }
    }
}

# ============================================================================
# Main Developer Tools Cleanup Function
# ============================================================================

function Invoke-DevToolsCleanup {
    <#
    .SYNOPSIS
        Run all developer tools cleanup tasks
    #>
    
    Start-Section "Developer tools"
    
    # JavaScript ecosystem
    Clear-NpmCache
    Clear-NodeBuildCaches
    
    # Python ecosystem
    Clear-PythonCaches
    
    # .NET ecosystem
    Clear-DotNetDevCaches
    
    # Go ecosystem
    Clear-GoCaches

    # mise cache
    Clear-MiseCache
    
    # Rust ecosystem
    Clear-RustCaches
    
    # JVM ecosystem
    Clear-JvmCaches
    
    # Elixir/Erlang ecosystem
    Clear-ElixirCaches
    
    # Haskell ecosystem
    Clear-HaskellCaches
    
    # OCaml ecosystem
    Clear-OCamlCaches
    
    # Containers
    Clear-DockerCaches
    
    # Cloud CLI tools
    Clear-CloudCliCaches
    
    # Editor caches (VS Code, Zed, etc.)
    Clear-EditorCaches
    
    # IDEs (JetBrains, Visual Studio)
    Clear-IdeCaches
    
    # Git
    Clear-GitCaches
    
    Stop-Section
}

# ============================================================================
# Exports
# ============================================================================
# Functions: Clear-NpmCache, Clear-PythonCaches, Clear-DockerCaches, etc.
