#Requires -RunAsAdministrator

param(
    [Parameter(Mandatory=$true)]
    [string]$Project,

    [string]$Backup,
    [switch]$ListBackups,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$RollbackStart = Get-Date
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# Works in both layouts: flat install ($PSScriptRoot = install dir) and
# repo layout ($PSScriptRoot = scripts/, parent = project root)
$RootDir = if ((Split-Path $PSScriptRoot -Leaf) -eq 'scripts') { Split-Path $PSScriptRoot -Parent } else { $PSScriptRoot }

# ------------------------------------------------
# LOGGING
# ------------------------------------------------

function LogInfo($msg)  { Write-Host "$(Get-Date -Format HH:mm:ss) [INFO ] $msg" }
function LogWarn($msg)  { Write-Host "$(Get-Date -Format HH:mm:ss) [WARN ] $msg" -ForegroundColor Yellow }
function LogOk($msg)    { Write-Host "$(Get-Date -Format HH:mm:ss) [ OK  ] $msg" -ForegroundColor Green }
function LogError($msg) { Write-Host "$(Get-Date -Format HH:mm:ss) [ERROR] $msg" -ForegroundColor Red }

function Ensure($cond, $msg) { if (-not $cond) { throw $msg } }

# ------------------------------------------------
# LOAD CONFIG
# ------------------------------------------------

$ConfigFile = Join-Path $RootDir "configs\deploy-config-$Project.json"
if (!(Test-Path $ConfigFile)) { throw "Config file not found: $ConfigFile" }

$config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
LogInfo "Loaded config: $ConfigFile"

# ------------------------------------------------
# CONFIG SCHEMA VALIDATION
# ------------------------------------------------

foreach ($field in @('BackupRoot', 'Sites')) {
    Ensure ($null -ne $config.$field -and "$($config.$field)" -ne '') "Config missing required field: '$field'"
}
Ensure ($config.Sites.Count -gt 0) "Config 'Sites' array is empty"
foreach ($s in $config.Sites) {
    Ensure ($s.Name)    "A site entry is missing 'Name'"
    Ensure ($s.Path)    "A site entry is missing 'Path'"
    Ensure ($s.AppPool) "A site entry is missing 'AppPool'"
}
LogOk "Config schema valid"

$BackupRoot = $config.BackupRoot
$Sites      = $config.Sites

try {
    Import-Module WebAdministration -ErrorAction Stop
} catch {
    throw "Failed to import WebAdministration module. Ensure IIS management tools are installed. $_"
}

# ------------------------------------------------
# LIST BACKUPS (early exit)
# ------------------------------------------------

if ($ListBackups) {
    $backups = Get-ChildItem $BackupRoot -Filter "${Project}_bkp_*.zip" |
               Sort-Object LastWriteTime -Descending

    Write-Host ""
    if ($backups.Count -eq 0) {
        Write-Host "No backups found for '$Project' in: $BackupRoot"
    } else {
        Write-Host "Available backups for '$Project' in: $BackupRoot"
        Write-Host ("-" * 72)
        foreach ($b in $backups) {
            $age    = (Get-Date) - $b.LastWriteTime
            $ageStr = "{0}h {1}m" -f [int]$age.TotalHours, $age.Minutes
            $sizeMB = [math]::Round($b.Length / 1MB, 1)
            $flag   = if ($age.TotalHours -gt 24) { " [OLD]" } else { "" }
            Write-Host ("  {0,-46} {1,6} MB   {2} old{3}" -f $b.Name, $sizeMB, $ageStr, $flag)
        }
        Write-Host ""
        Write-Host "To restore, run:"
        Write-Host "  rollback-deploy.cmd -Project $Project -Backup <name-without-.zip>"
    }
    Write-Host ""
    exit 0
}

# ------------------------------------------------
# TRANSCRIPT
# ------------------------------------------------

$LogDir  = Join-Path $RootDir "logs"
if (-not (Test-Path $LogDir)) { New-Item $LogDir -ItemType Directory -Force | Out-Null }
$LogFile = Join-Path $LogDir ("rollback_{0}_{1}.log" -f $Project, $RollbackStart.ToString("yyyyMMdd_HHmmss"))
Start-Transcript -Path $LogFile

# ------------------------------------------------
# LOCK FILE
# ------------------------------------------------

$LockFile     = Join-Path $RootDir "rollback.lock"
$lockAcquired = $false

try {

    try {
        $lockStream = [System.IO.File]::Open($LockFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    } catch [System.IO.IOException] {
        $lockInfo = try { Get-Content $LockFile -Raw } catch { '<unreadable>' }
        throw "Another rollback is already in progress.`nLock info: $lockInfo`nDelete '$LockFile' manually if no rollback is running."
    }
    try {
        $lockText  = "$env:USERNAME @ $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - PID $PID - Project: $Project"
        $lockBytes = [System.Text.Encoding]::UTF8.GetBytes($lockText)
        $lockStream.Write($lockBytes, 0, $lockBytes.Length)
    } finally {
        $lockStream.Dispose()
    }
    $lockAcquired = $true

    # ------------------------------------------------
    # SELECT BACKUP
    # ------------------------------------------------

    LogInfo "================ SELECT BACKUP ================"

    if ($Backup) {
        $backupZip = Join-Path $BackupRoot "$Backup.zip"
    } else {
        $backupZip = Get-ChildItem $BackupRoot -Filter "${Project}_bkp_*.zip" |
                     Sort-Object LastWriteTime -Descending |
                     Select-Object -First 1 |
                     Select-Object -ExpandProperty FullName
    }

    Ensure (Test-Path $backupZip) "Backup not found: $backupZip"

    $backupAge = (Get-Date) - (Get-Item $backupZip).LastWriteTime
    $ageStr    = "{0}h {1}m" -f [int]$backupAge.TotalHours, $backupAge.Minutes
    if ($backupAge.TotalHours -gt 24) {
        LogWarn "Backup is $ageStr old - verify this is the correct restore point"
    } else {
        LogInfo "Backup age: $ageStr"
    }

    LogOk "Using backup: $backupZip"

    # ------------------------------------------------
    # CONFIRMATION PROMPT
    # ------------------------------------------------

    if (-not $Force) {
        Write-Host ""
        LogWarn "You are about to OVERWRITE the live site(s) with backup data."
        Write-Host "  Sites affected:"
        foreach ($s in $Sites) {
            Write-Host "    $($s.Name) => $($s.Path)"
        }
        Write-Host "  Backup: $backupZip ($ageStr old)"
        Write-Host ""
        $confirm = Read-Host "Type 'YES' to confirm rollback"
        if ($confirm -ne 'YES') { throw "Rollback cancelled by user." }
        Write-Host ""
    }

    # ------------------------------------------------
    # EXTRACT BACKUP
    # ------------------------------------------------

    LogInfo "================ EXTRACT BACKUP ================"

    $temp = Join-Path $env:TEMP "rollback_extract_$Project"
    if (Test-Path $temp) { Remove-Item $temp -Recurse -Force }

    Expand-Archive $backupZip $temp

    $root = Get-ChildItem $temp | Where-Object { $_.PSIsContainer } | Select-Object -First 1
    Ensure $root "Invalid backup structure: root folder not found"

    $restoreRoot = $root.FullName
    LogOk "Restore root: $restoreRoot"

    # ------------------------------------------------
    # EMPTY BACKUP CHECK
    # ------------------------------------------------

    $emptySites = @()
    foreach ($s in $Sites) {
        $src = Join-Path $restoreRoot $s.Name
        if (Test-Path $src) {
            $fileCount = (Get-ChildItem $src -Recurse -File -ErrorAction SilentlyContinue).Count
            if ($fileCount -eq 0) {
                $emptySites += $s.Name
            }
        }
    }

    if ($emptySites.Count -gt 0) {
        Write-Host ""
        LogWarn "The following site(s) in this backup contain NO files:"
        foreach ($name in $emptySites) { Write-Host "    $name" }
        LogWarn "This backup was likely taken before any files were ever deployed to that site."
        LogWarn "Proceeding will EMPTY the live site(s) listed above."
        Write-Host ""
        if (-not $Force) {
            $confirm2 = Read-Host "Type 'YES' to confirm you want to restore an empty backup"
            if ($confirm2 -ne 'YES') { throw "Rollback cancelled - empty backup not confirmed." }
            Write-Host ""
        }
    }

    # ------------------------------------------------
    # ROLLBACK
    # ------------------------------------------------

    $healthChecksPassed = $true

    try {

        LogInfo "================ STOP SERVICES ================"

        foreach ($s in $Sites) {
            $state = (Get-WebAppPoolState $s.AppPool).Value
            if ($state -ne "Stopped") {
                LogInfo "Stopping AppPool: $($s.AppPool)"
                Stop-WebAppPool $s.AppPool
                $timeout = 10; $elapsed = 0
                while ((Get-WebAppPoolState $s.AppPool).Value -ne "Stopped" -and $elapsed -lt $timeout) {
                    Start-Sleep -Seconds 1; $elapsed++
                }
                if ((Get-WebAppPoolState $s.AppPool).Value -ne "Stopped") {
                    LogWarn "AppPool $($s.AppPool) did not stop within $timeout seconds - files may be locked"
                }
            } else {
                LogWarn "AppPool already stopped: $($s.AppPool)"
            }
        }

        # Kill only worker processes belonging to the target app pools,
        # plus their dotnet child processes (out-of-process hosting).
        LogInfo "Killing remaining worker processes for target app pools..."
        $uniquePools = $Sites | ForEach-Object { $_.AppPool } | Select-Object -Unique
        foreach ($poolName in $uniquePools) {
            try {
                $wps = Get-CimInstance -Namespace 'root\WebAdministration' -ClassName WorkerProcess -ErrorAction SilentlyContinue |
                       Where-Object { $_.AppPoolName -eq $poolName }
                foreach ($wp in $wps) {
                    $children = Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId=$($wp.ProcessId)" -ErrorAction SilentlyContinue |
                                Where-Object { $_.Name -eq 'dotnet.exe' }
                    foreach ($child in $children) {
                        Stop-Process -Id $child.ProcessId -Force -ErrorAction SilentlyContinue
                    }
                    Stop-Process -Id $wp.ProcessId -Force -ErrorAction SilentlyContinue
                    LogInfo "  Killed worker PID $($wp.ProcessId) for pool '$poolName'"
                }
            } catch {
                LogWarn "Could not kill worker processes for '$poolName': $($_.Exception.Message)"
            }
        }
        Start-Sleep -Seconds 5

        LogInfo "================ RESTORE FILES ================"

        $i     = 1
        $total = $Sites.Count

        foreach ($s in $Sites) {

            $src = Join-Path $restoreRoot $s.Name
            Ensure (Test-Path $src) "Backup missing site folder: $($s.Name)"

            LogInfo "[$i/$total] Restoring $($s.Name) - FULL REPLACE"

            Get-ChildItem $s.Path -Recurse -Force -File -ErrorAction SilentlyContinue |
                ForEach-Object { $_.IsReadOnly = $false }

            Get-ChildItem $s.Path -Force -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force

            Copy-Item "$src\*" $s.Path -Recurse -Force

            LogOk "$($s.Name) restored"
            $i++
        }

        LogInfo "================ START SERVICES ================"

        foreach ($s in $Sites) {
            $state = (Get-WebAppPoolState $s.AppPool).Value
            if ($state -ne "Started") {
                LogInfo "Starting AppPool: $($s.AppPool)"
                Start-WebAppPool $s.AppPool
                $timeout = 15; $elapsed = 0
                while ((Get-WebAppPoolState $s.AppPool).Value -ne "Started" -and $elapsed -lt $timeout) {
                    Start-Sleep -Seconds 1; $elapsed++
                }
                if ((Get-WebAppPoolState $s.AppPool).Value -ne "Started") {
                    LogError "AppPool $($s.AppPool) failed to start within $timeout seconds - check Event Viewer"
                } else {
                    LogOk "AppPool $($s.AppPool) started"
                }
            }
        }

        LogInfo "================ HEALTH CHECKS ================"

        foreach ($s in $Sites) {
            if ($s.PSObject.Properties.Name -contains "HealthUrl" -and $s.HealthUrl) {
                LogInfo "Health check: $($s.HealthUrl)"
                $maxRetries = 5
                $retryDelay = 5
                $success    = $false
                for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
                    try {
                        $resp = Invoke-WebRequest $s.HealthUrl -TimeoutSec 20 -UseBasicParsing
                        if ($resp.StatusCode -eq 200) { $success = $true; break }
                    } catch {
                        LogWarn "Health check attempt $attempt/$maxRetries failed: $($_.Exception.Message)"
                    }
                    if ($attempt -lt $maxRetries) {
                        LogInfo "Retrying in $retryDelay seconds..."
                        Start-Sleep -Seconds $retryDelay
                    }
                }
                if ($success) {
                    LogOk "$($s.Name) is responding"
                } else {
                    LogError "Health check failed for $($s.Name) after $maxRetries attempts"
                    $healthChecksPassed = $false
                }
            }
        }

        $sw.Stop()
        LogOk "ROLLBACK COMPLETED SUCCESSFULLY"
        LogInfo "Total duration: $($sw.Elapsed.ToString('mm\:ss'))"
        LogInfo "Log file: $LogFile"
    }
    catch {

        Write-Host ""
        LogError "================ ROLLBACK FAILED ================"
        LogError "Automatic rollback could not complete."
        LogError $_.Exception.Message
        Write-Host ""

        LogWarn "BACKUP DETAILS:"
        Write-Host "  ZIP FILE : $backupZip"
        Write-Host "  EXTRACTED: $restoreRoot"
        Write-Host ""

        LogWarn "MANUAL RECOVERY STEPS:"
        Write-Host "1. Open IIS Manager and STOP these App Pools:"
        foreach ($s in $Sites) { Write-Host "   - $($s.AppPool)" }

        Write-Host ""
        Write-Host "2. Open Task Manager and END processes:"
        Write-Host "   - w3wp.exe"
        Write-Host "   - dotnet.exe"

        Write-Host ""
        Write-Host "3. For each site, DELETE target folder contents and COPY backup:"
        foreach ($s in $Sites) {
            Write-Host ""
            Write-Host "   SITE: $($s.Name)"
            Write-Host "   FROM: $restoreRoot\$($s.Name)"
            Write-Host "   TO  : $($s.Path)"
        }

        Write-Host ""
        Write-Host "4. Start the App Pools again from IIS."
        Write-Host ""
        LogError "================================================="

        throw
    }
    finally {
        if (Test-Path $temp) { Remove-Item $temp -Recurse -Force }
    }

    # Evaluated after file restoration is complete so a health check failure
    # does not trigger the manual recovery message (files are already back).
    if (-not $healthChecksPassed) {
        throw "Rollback file restoration succeeded but one or more health checks failed - manual verification required"
    }

}
finally {
    if ($lockAcquired -and (Test-Path $LockFile)) { Remove-Item $LockFile -Force }
    try { Stop-Transcript } catch {}
}

