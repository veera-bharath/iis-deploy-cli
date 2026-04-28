$ErrorActionPreference = "Stop"

# ==============================================================================
# UI helpers
# ==============================================================================

function Write-Banner {
    Write-Host ""
    Write-Host "  ==================================================" -ForegroundColor Cyan
    Write-Host "    IIS Deploy Tool  -  Installer" -ForegroundColor Cyan
    Write-Host "  ==================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Write-FileRow([string]$name, [string]$status, [string]$icon, [string]$color) {
    $pad = [Math]::Max(1, 34 - $name.Length)
    Write-Host ("  {0}  {1}{2}" -f $icon, $name, (' ' * $pad)) -NoNewline
    Write-Host $status -ForegroundColor $color
}

function Write-Summary {
    Write-Host ""
    Write-Host "  ==================================================" -ForegroundColor Green
    Write-Host "    Installation complete  [OK]" -ForegroundColor Green
    Write-Host "  ==================================================" -ForegroundColor Green
    Write-Host ""
}

# ==============================================================================
# Install path prompt
# ==============================================================================

Write-Banner

$defaultDir = "C:\Tools\Deploy"
Write-Host "  Install directory " -NoNewline -ForegroundColor White
Write-Host "[$defaultDir]" -NoNewline -ForegroundColor DarkGray
Write-Host ": " -NoNewline
$inputDir   = Read-Host
$InstallDir = if ([string]::IsNullOrWhiteSpace($inputDir)) { $defaultDir } else { $inputDir.Trim() }

Write-Host ""
Write-Host "  Target : " -NoNewline -ForegroundColor DarkGray
Write-Host $InstallDir -ForegroundColor Yellow
Write-Host ""

# ==============================================================================
# Source locations — script is now inside scripts/, so source files are alongside it
# ==============================================================================

$SrcScripts = $PSScriptRoot

# PS1 files are copied as-is (PowerShell handles UTF-8 BOM correctly)
$psFiles = @(
    [PSCustomObject]@{ Src = "deploy.ps1";          Dst = "deploy.ps1"          }
    [PSCustomObject]@{ Src = "rollback-deploy.ps1"; Dst = "rollback-deploy.ps1" }
    [PSCustomObject]@{ Src = "deploy-config.ps1";   Dst = "deploy-config.ps1"   }
)

# BAT files are generated fresh as ASCII — never copied — to avoid BOM issues
$batFiles = @(
    [PSCustomObject]@{ Dst = "deploy.bat";          Cmd = "deploy.ps1"          }
    [PSCustomObject]@{ Dst = "rollback-deploy.bat"; Cmd = "rollback-deploy.ps1" }
    [PSCustomObject]@{ Dst = "deploy-config.bat";   Cmd = "deploy-config.ps1"   }
)

# ==============================================================================
# Create install dir
# ==============================================================================

if (-not (Test-Path $InstallDir)) {
    New-Item $InstallDir -ItemType Directory -Force | Out-Null
    Write-Host "  Created install directory." -ForegroundColor DarkGray
}

$DstConfigs = Join-Path $InstallDir "configs"
if (-not (Test-Path $DstConfigs)) {
    New-Item $DstConfigs -ItemType Directory -Force | Out-Null
}

# ==============================================================================
# Install script files
# ==============================================================================

Write-Host "  Script files:" -ForegroundColor White
Write-Host ""

$counts = @{ Installed = 0; Updated = 0; Skipped = 0; Failed = 0 }
$ascii  = [System.Text.Encoding]::ASCII

# --- Copy PS1 files ---
foreach ($f in $psFiles) {
    $srcPath = Join-Path $SrcScripts $f.Src
    $dstPath = Join-Path $InstallDir $f.Dst

    if (-not (Test-Path $srcPath)) {
        Write-FileRow $f.Dst "source not found - skipped" "[ ! ]" "Red"
        $counts.Failed++
        continue
    }

    $srcContent = Get-Content $srcPath -Raw

    if (Test-Path $dstPath) {
        $dstContent = Get-Content $dstPath -Raw
        if ($srcContent -eq $dstContent) {
            Write-FileRow $f.Dst "up to date" "[ = ]" "DarkGray"
            $counts.Skipped++
        } else {
            Set-Content $dstPath $srcContent -Encoding UTF8
            Write-FileRow $f.Dst "updated" "[ ^ ]" "Yellow"
            $counts.Updated++
        }
    } else {
        Set-Content $dstPath $srcContent -Encoding UTF8
        Write-FileRow $f.Dst "installed" "[ + ]" "Green"
        $counts.Installed++
    }
}

# --- Generate BAT files (ASCII, no BOM) ---
foreach ($b in $batFiles) {
    $dstPath = Join-Path $InstallDir $b.Dst
    $content = "@echo off`r`npowershell -ExecutionPolicy Bypass -File `"%~dp0$($b.Cmd)`" %*`r`n"

    if (Test-Path $dstPath) {
        $existing = [System.IO.File]::ReadAllText($dstPath, $ascii)
        if ($existing -eq $content) {
            Write-FileRow $b.Dst "up to date" "[ = ]" "DarkGray"
            $counts.Skipped++
        } else {
            [System.IO.File]::WriteAllText($dstPath, $content, $ascii)
            Write-FileRow $b.Dst "updated" "[ ^ ]" "Yellow"
            $counts.Updated++
        }
    } else {
        [System.IO.File]::WriteAllText($dstPath, $content, $ascii)
        Write-FileRow $b.Dst "installed" "[ + ]" "Green"
        $counts.Installed++
    }
}

# ==============================================================================
# PATH registration
# ==============================================================================

Write-Host ""
Write-Host "  PATH registration:" -ForegroundColor White
Write-Host ""

$machinePath = [Environment]::GetEnvironmentVariable("PATH", "Machine")
$pathEntries = $machinePath -split ';' | ForEach-Object { $_.Trim() }

if ($pathEntries -contains $InstallDir) {
    Write-Host "  [ = ]  Already in system PATH" -ForegroundColor DarkGray
} else {
    try {
        $newPath = ($machinePath.TrimEnd(';') + ';' + $InstallDir)
        [Environment]::SetEnvironmentVariable("PATH", $newPath, "Machine")
        # Also update the current session so commands work immediately
        $env:PATH = $env:PATH.TrimEnd(';') + ';' + $InstallDir
        Write-Host "  [ + ]  Added to system PATH" -ForegroundColor Green
        Write-Host "         $InstallDir" -ForegroundColor DarkGray
    } catch {
        Write-Host "  [ ! ]  Could not update system PATH (run as Administrator to register PATH)." -ForegroundColor Yellow
        Write-Host "         Add manually: $InstallDir" -ForegroundColor DarkGray
    }
}

# ==============================================================================
# Summary
# ==============================================================================

Write-Summary

Write-Host ("  Installed {0}  |  Updated {1}  |  Skipped {2}" -f `
    $counts.Installed, $counts.Updated, $counts.Skipped) -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Location  : " -NoNewline -ForegroundColor DarkGray
Write-Host $InstallDir -ForegroundColor Yellow
Write-Host "  Deploy    : " -NoNewline -ForegroundColor DarkGray
Write-Host "deploy.bat -Project <name>" -ForegroundColor White
Write-Host "  Rollback  : " -NoNewline -ForegroundColor DarkGray
Write-Host "rollback-deploy.bat -Project <name>" -ForegroundColor White
Write-Host "  Config    : " -NoNewline -ForegroundColor DarkGray
Write-Host "deploy-config.bat" -ForegroundColor White
Write-Host ""

if ($counts.Failed -gt 0) {
    Write-Host "  [!] $($counts.Failed) source file(s) were missing. Check the scripts/ folder." -ForegroundColor Red
    Write-Host ""
}

# ==============================================================================
# Offer to run deploy-config
# ==============================================================================

Write-Host "  Would you like to configure a project now? " -NoNewline -ForegroundColor White
Write-Host "[Y/n]: " -NoNewline -ForegroundColor DarkGray
$yn = Read-Host
$runConfig = [string]::IsNullOrWhiteSpace($yn) -or ($yn.Trim() -imatch '^y')

if ($runConfig) {
    $configScript = Join-Path $InstallDir "deploy-config.ps1"
    if (Test-Path $configScript) {
        Write-Host ""
        & $configScript
    } else {
        Write-Host ""
        Write-Host "  [!] deploy-config.ps1 not found in install dir. Run deploy-config.bat manually." -ForegroundColor Yellow
    }
}
