# ============================================================================
# IIS Deploy Tool - unified CLI
#
#   deploy <project>                       deploy a project
#   deploy <project> --dry-run             show what would happen, no changes
#   deploy <project> --skip-backup         deploy without taking a backup
#   deploy <project> --keep-backups N      keep the N newest backups (default 10)
#   deploy <project> --keep-history N      retain N history entries (default 100)
#   deploy <project> --rollback            rollback to the latest backup
#   deploy <project> --rollback --backup <name>
#   deploy <project> --rollback --force    skip confirmation prompt
#   deploy <project> --rollback --list-backups
#   deploy --list-projects                 list configured projects
#   deploy --setup-config                  add or edit a project config
#   deploy --help                          show usage
#
# PowerShell-native flags also accepted (-Project, -DryRun, -SkipBackup,
# -KeepBackups, -KeepHistory, -Rollback, -Backup, -Force, -ListBackups,
# -ListProjects, -SetupConfig, -Help) for backward compatibility.
# ============================================================================

# ---- arg parsing -----------------------------------------------------------

$ProjectName = $null
$Action      = 'deploy'
$DryRun      = $false
$SkipBackup  = $false
$KeepBackups = 10
$KeepHistory = 100
$BackupName  = $null
$ListBackups = $false
$Force       = $false
$NoRestart   = $false
$NoAutoRollback = $false

function Show-DeployHelp {
@"

  IIS Deploy Tool

    deploy <project>                            deploy
    deploy <project> --dry-run                  preview, no changes
    deploy <project> --skip-backup              skip backup (no auto-rollback)
    deploy <project> --no-restart               file copy only - do not stop/start AppPool or run health check
    deploy <project> --no-auto-rollback         keep backup but do not auto-rollback on failure
    deploy <project> --keep-backups N           backup retention (default 10)
    deploy <project> --keep-history N           history retention (default 100)
    deploy <project> --rollback                 rollback to latest backup
    deploy <project> --rollback --backup <name> rollback to a specific backup
    deploy <project> --rollback --force         skip confirm prompt
    deploy <project> --rollback --list-backups  list backups for a project
    deploy --list-projects                      list configured projects
    deploy --setup-config                       add or edit a project config
    deploy --help                               this help

"@ | Write-Host
}

function _NormFlag([string]$flag) { ($flag -replace '^-+','').ToLower() }

$rawArgs = @($args)
$ai = 0
while ($ai -lt $rawArgs.Count) {
    $a = [string]$rawArgs[$ai]

    if ($a.StartsWith('-')) {
        switch (_NormFlag $a) {
            'h'             { Show-DeployHelp; exit 0 }
            'help'          { Show-DeployHelp; exit 0 }
            'list-projects' { $Action      = 'list-projects' }
            'listprojects'  { $Action      = 'list-projects' }
            'setup-config'  { $Action      = 'setup-config' }
            'setupconfig'   { $Action      = 'setup-config' }
            'rollback'      { $Action      = 'rollback' }
            'dry-run'       { $DryRun      = $true }
            'dryrun'        { $DryRun      = $true }
            'skip-backup'   { $SkipBackup  = $true }
            'skipbackup'    { $SkipBackup  = $true }
            'list-backups'  { $ListBackups = $true }
            'listbackups'   { $ListBackups = $true }
            'force'         { $Force       = $true }
            'no-restart'    { $NoRestart   = $true }
            'norestart'     { $NoRestart   = $true }
            'no-auto-rollback' { $NoAutoRollback = $true }
            'noautorollback'   { $NoAutoRollback = $true }
            'project'       { $ai++; $ProjectName  = [string]$rawArgs[$ai] }
            'p'             { $ai++; $ProjectName  = [string]$rawArgs[$ai] }
            'backup'        { $ai++; $BackupName   = [string]$rawArgs[$ai] }
            'keep-backups'  { $ai++; $KeepBackups  = [int]$rawArgs[$ai] }
            'keepbackups'   { $ai++; $KeepBackups  = [int]$rawArgs[$ai] }
            'keep-history'  { $ai++; $KeepHistory  = [int]$rawArgs[$ai] }
            'keephistory'   { $ai++; $KeepHistory  = [int]$rawArgs[$ai] }
            default         { throw "Unknown option: $a (try 'deploy --help')" }
        }
    } else {
        if ($null -eq $ProjectName) { $ProjectName = $a }
        else { throw "Unexpected positional argument: '$a' (project already set to '$ProjectName')" }
    }
    $ai++
}

# ---- common setup ----------------------------------------------------------

$ErrorActionPreference = "Stop"

# Works in both layouts: flat install ($PSScriptRoot = install dir) and
# repo layout ($PSScriptRoot = scripts/, parent = project root)
$RootDir = if ((Split-Path $PSScriptRoot -Leaf) -eq 'scripts') { Split-Path $PSScriptRoot -Parent } else { $PSScriptRoot }

function _IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}
function _RequireAdmin([string]$what) {
    if (-not (_IsAdmin)) {
        throw "$what requires an elevated PowerShell session. Right-click and 'Run as administrator', or launch deploy.cmd from an elevated prompt."
    }
}

# ---- subcommand: list projects --------------------------------------------

if ($Action -eq 'list-projects') {
    $configsDir = Join-Path $RootDir 'configs'
    Write-Host ""
    if (-not (Test-Path $configsDir)) {
        Write-Host "No configs directory: $configsDir"
        Write-Host ""
        exit 0
    }
    $files = @(Get-ChildItem $configsDir -Filter 'deploy-config-*.json' -ErrorAction SilentlyContinue |
               Sort-Object Name)
    if ($files.Count -eq 0) {
        Write-Host "No projects configured in: $configsDir"
        Write-Host "Run 'deploy --setup-config' to add one."
    } else {
        Write-Host "Configured projects in: $configsDir"
        Write-Host ("-" * 72)
        foreach ($f in $files) {
            $name = $f.BaseName -replace '^deploy-config-', ''
            try {
                $cfg     = Get-Content $f.FullName -Raw | ConvertFrom-Json
                $sites   = if ($cfg.Sites) { @($cfg.Sites).Count } else { 0 }
                $zip     = if ($cfg.PublishZipPath) { $cfg.PublishZipPath } else { '<missing>' }
                Write-Host ("  {0,-24} sites: {1,-3}  zip: {2}" -f $name, $sites, $zip)
            } catch {
                Write-Host ("  {0,-24} <invalid JSON: $($_.Exception.Message)>" -f $name) -ForegroundColor Yellow
            }
        }
    }
    Write-Host ""
    exit 0
}

# ---- subcommand: setup-config (delegates to interactive editor) -----------

if ($Action -eq 'setup-config') {
    $configScript = Join-Path $PSScriptRoot 'deploy-config.ps1'
    if (-not (Test-Path $configScript)) { throw "Config script not found: $configScript" }
    & $configScript
    exit 0
}

# ---- subcommand: rollback (delegates to rollback-deploy.ps1) --------------

if ($Action -eq 'rollback') {
    if (-not $ProjectName) {
        throw "Project name required. Usage: deploy <project> --rollback [--backup <name>]"
    }
    _RequireAdmin 'Rollback'

    $rbScript = Join-Path $PSScriptRoot 'rollback-deploy.ps1'
    if (-not (Test-Path $rbScript)) { throw "Rollback script not found: $rbScript" }

    $rbParams = @{ Project = $ProjectName }
    if ($BackupName)  { $rbParams['Backup']      = $BackupName }
    if ($Force)       { $rbParams['Force']        = $true }
    if ($ListBackups) { $rbParams['ListBackups']  = $true }

    & $rbScript @rbParams
    exit 0
}

# ---- default: deploy -------------------------------------------------------

if (-not $ProjectName) {
    throw "Project name required. Usage: deploy <project> [--dry-run] [--skip-backup]    (try 'deploy --help')"
}
_RequireAdmin 'Deploy'

# Map parsed values to the names the rest of the script uses
$Project     = $ProjectName
$DeployStart = Get-Date
$sw          = [System.Diagnostics.Stopwatch]::StartNew()

# ------------------------------------------------
# LOGGING
# ------------------------------------------------

function LogInfo($msg)  { Write-Host "$(Get-Date -Format HH:mm:ss) [INFO ] $msg" }
function LogWarn($msg)  { Write-Host "$(Get-Date -Format HH:mm:ss) [WARN ] $msg" -ForegroundColor Yellow }
function LogOk($msg)    { Write-Host "$(Get-Date -Format HH:mm:ss) [ OK  ] $msg" -ForegroundColor Green }
function LogError($msg) { Write-Host "$(Get-Date -Format HH:mm:ss) [ERROR] $msg" -ForegroundColor Red }

function Ensure($cond, $msg) { if (-not $cond) { throw $msg } }

# ------------------------------------------------
# JSON MERGE
# ------------------------------------------------

function Merge-JsonFile($targetPath, $patchPath) {
    try {
        $target = Get-Content $targetPath -Raw | ConvertFrom-Json
        $patch  = Get-Content $patchPath  -Raw | ConvertFrom-Json
    } catch {
        throw "Failed to parse JSON for merge: $($_.Exception.Message)"
    }

    function Merge-Object($base, $overlay) {
        foreach ($prop in $overlay.PSObject.Properties) {
            if ($null -ne $base.PSObject.Properties[$prop.Name] -and
                $prop.Value -is [PSCustomObject] -and
                $base.($prop.Name) -is [PSCustomObject]) {
                Merge-Object $base.($prop.Name) $prop.Value
            } else {
                $base | Add-Member -MemberType NoteProperty -Name $prop.Name -Value $prop.Value -Force
            }
        }
    }

    Merge-Object $target $patch
    $target | ConvertTo-Json -Depth 20 | Set-Content $targetPath -Encoding UTF8
    LogOk "Merged updateSettings.json into $(Split-Path $targetPath -Leaf)"
}

# ------------------------------------------------
# HISTORY LOG
# ------------------------------------------------

function Write-DeployHistory([string]$result, [string]$errorMsg = $null, [string]$zipPath = 'unknown', $backupPath = $null) {
    try {
        $historyFile = Join-Path $RootDir "deploy-history.json"
        $props = [ordered]@{
            Timestamp   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            Project     = $Project
            Result      = $result
            DurationSec = [int]$sw.Elapsed.TotalSeconds
            Zip         = $zipPath
            Backup      = $backupPath
            User        = $env:USERNAME
            Machine     = $env:COMPUTERNAME
        }
        if ($errorMsg) { $props['Error'] = $errorMsg }
        $entry   = [PSCustomObject]$props
        $history = @()
        if (Test-Path $historyFile) { $history = @(Get-Content $historyFile -Raw | ConvertFrom-Json) }
        $history = $history + $entry
        if ($KeepHistory -gt 0 -and $history.Count -gt $KeepHistory) {
            $history = $history | Select-Object -Last $KeepHistory
        }
        $history | ConvertTo-Json -Depth 5 | Set-Content $historyFile -Encoding UTF8
        LogInfo "History updated: $historyFile"
    } catch {
        LogWarn "Could not write deploy history: $($_.Exception.Message)"
    }
}

# ------------------------------------------------
# TRANSCRIPT — always captured, dry-run gets its own suffix
# ------------------------------------------------

$LogDir  = Join-Path $RootDir "logs"
if (-not (Test-Path $LogDir)) { New-Item $LogDir -ItemType Directory -Force | Out-Null }
$drySuffix = if ($DryRun) { "_dryrun" } else { "" }
$LogFile = Join-Path $LogDir ("deploy_{0}_{1}{2}.log" -f $Project, $DeployStart.ToString("yyyyMMdd_HHmmss"), $drySuffix)
Start-Transcript -Path $LogFile

# ------------------------------------------------
# LOCK FILE
# ------------------------------------------------

$LockFile     = Join-Path $RootDir "deploy.lock"
$lockAcquired = $false

try {

    if (-not $DryRun) {
        try {
            $lockStream = [System.IO.File]::Open($LockFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        } catch [System.IO.IOException] {
            $lockInfo = try { Get-Content $LockFile -Raw } catch { '<unreadable>' }
            throw "Another deployment is already in progress.`nLock info: $lockInfo`nDelete '$LockFile' manually if no deploy is running."
        }
        try {
            $lockText  = "$env:USERNAME @ $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - PID $PID - Project: $Project"
            $lockBytes = [System.Text.Encoding]::UTF8.GetBytes($lockText)
            $lockStream.Write($lockBytes, 0, $lockBytes.Length)
        } finally {
            $lockStream.Dispose()
        }
        $lockAcquired = $true
    }

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

    foreach ($field in @('BackupRoot', 'PublishZipPath', 'Sites')) {
        Ensure ($null -ne $config.$field -and "$($config.$field)" -ne '') "Config missing required field: '$field'"
    }
    Ensure ($config.Sites.Count -gt 0) "Config 'Sites' array is empty"
    foreach ($s in $config.Sites) {
        Ensure ($s.Name)    "A site entry is missing 'Name'"
        Ensure ($s.Path)    "A site entry is missing 'Path'"
        Ensure ($s.AppPool) "A site entry is missing 'AppPool'"
        # Normalize so the rest of the script can always check .Count without a property guard
        if (-not $s.PSObject.Properties['ExcludedFiles'] -or $null -eq $s.ExcludedFiles) {
            $s | Add-Member -MemberType NoteProperty -Name 'ExcludedFiles' -Value @() -Force
        }
    }
    LogOk "Config schema valid"

    $BackupRoot     = $config.BackupRoot
    $PublishZipPath = $config.PublishZipPath
    $Sites          = $config.Sites

    try {
        Import-Module WebAdministration -ErrorAction Stop
    } catch {
        throw "Failed to import WebAdministration module. Ensure IIS management tools are installed. $_"
    }

    # ------------------------------------------------
    # PREFLIGHT
    # ------------------------------------------------

    LogInfo "================ PREFLIGHT CHECKS ================"

    Ensure (Test-Path $BackupRoot)     "BackupRoot not found: $BackupRoot"
    Ensure (Test-Path $PublishZipPath) "Publish ZIP not found: $PublishZipPath"

    $zipFullPath = (Resolve-Path $PublishZipPath).Path
    Ensure ($zipFullPath.ToLower().EndsWith(".zip")) "Publish artifact must be .zip"

    foreach ($s in $Sites) {
        Ensure (Test-Path $s.Path)                       "Site path not found: $($s.Path)"
        Ensure (Test-Path "IIS:\AppPools\$($s.AppPool)") "AppPool not found: $($s.AppPool)"
    }

    # ZIP content pre-validation — check before touching anything live
    LogInfo "Validating ZIP contents..."
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($zipFullPath)
    try {
        $zipTopFolders = $zip.Entries |
            ForEach-Object { $_.FullName -replace '\\','/' } |
            Where-Object { $_ -match '^[^/]+/' } |
            ForEach-Object { $_.Split('/')[0] } |
            Sort-Object -Unique
        foreach ($s in $Sites) {
            Ensure ($zipTopFolders -contains $s.Name) "ZIP is missing expected site folder: '$($s.Name)'"
        }
    } finally {
        $zip.Dispose()
    }

    LogOk "Preflight validation successful"
    if ($DryRun)     { LogWarn "DRY-RUN MODE ENABLED - no changes will be made." }
    if ($SkipBackup) { LogWarn "SKIP-BACKUP enabled - no backup will be created. Auto-rollback is disabled." }
    if ($NoRestart)  { LogWarn "NO-RESTART enabled - AppPools will not be stopped/started and health checks will be skipped. Files held open by w3wp.exe may fail to copy." }
    if ($NoAutoRollback) { LogWarn "NO-AUTO-ROLLBACK enabled - backup will be created but rollback will NOT fire automatically on failure. Manual rollback command will be printed." }

    # ------------------------------------------------
    # EXTRACT
    # ------------------------------------------------

    LogInfo "================ STAGING PACKAGE ================"

    $staging = Join-Path $env:TEMP "deploy_staging_$Project"
    if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }

    if (-not $DryRun) {
        LogInfo "Extracting publish package..."
        Expand-Archive $zipFullPath $staging
        LogOk "Publish package extracted to: $staging"
    } else {
        LogWarn "DRY-RUN: Would extract publish package"
    }

    # ------------------------------------------------
    # BACKUP
    # ------------------------------------------------

    LogInfo "================ BACKUP ================"

    $timestamp     = $DeployStart.ToString("dd_MMM_yyyy_HH_mm_ss").ToLower()
    $backupName    = "{0}_bkp_{1}" -f $Project, $timestamp
    $backupFolder  = Join-Path $BackupRoot $backupName
    $backupZip     = "$backupFolder.zip"
    $backupCreated = $false

    if (-not $DryRun -and -not $SkipBackup) {

        LogInfo "Creating backup: $backupName"
        New-Item $backupFolder -ItemType Directory -Force | Out-Null

        foreach ($s in $Sites) {
            LogInfo "Backing up $($s.Name)"
            Copy-Item $s.Path (Join-Path $backupFolder $s.Name) -Recurse -Force
        }

        Compress-Archive $backupFolder $backupZip
        Remove-Item $backupFolder -Recurse -Force
        $backupCreated = $true

        LogOk "Backup stored: $backupZip"

    } elseif ($DryRun) {
        LogWarn "DRY-RUN: Would create backup $backupName"
    } else {
        LogWarn "SKIP-BACKUP: Skipped"
    }

    # ------------------------------------------------
    # DEPLOY
    # ------------------------------------------------

    try {

        LogInfo "================ DEPLOY ================"

        if ($NoRestart) {
            LogWarn "NO-RESTART: skipping stop of AppPool(s)"
        } else {
            foreach ($s in $Sites) {
                if ($DryRun) {
                    LogWarn "DRY-RUN: Would stop AppPool $($s.AppPool)"
                } else {
                    LogInfo "Stopping AppPool: $($s.AppPool)"
                    Stop-WebAppPool $s.AppPool -ErrorAction SilentlyContinue
                    $timeout = 10; $elapsed = 0
                    while ((Get-WebAppPoolState $s.AppPool).Value -ne "Stopped" -and $elapsed -lt $timeout) {
                        Start-Sleep -Seconds 1; $elapsed++
                    }
                    if ((Get-WebAppPoolState $s.AppPool).Value -ne "Stopped") {
                        LogWarn "AppPool $($s.AppPool) did not stop within $timeout seconds - files may be locked"
                    }
                }
            }
        }

        if (-not $DryRun -and -not $NoRestart) {
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
        }

        $i = 1
        $total = $Sites.Count

        foreach ($s in $Sites) {

            LogInfo "[$i/$total] Deploying $($s.Name)"

            if (-not $DryRun) {

                $source = Join-Path $staging $s.Name
                Ensure (Test-Path $source) "Publish folder missing: $source"

                if ($s.ExcludedFiles.Count -gt 0) {
                    LogInfo "Excluded files: $($s.ExcludedFiles -join ', ')"
                    foreach ($pattern in $s.ExcludedFiles) {
                        Get-ChildItem $source -Recurse -Include $pattern -File -ErrorAction SilentlyContinue |
                            Remove-Item -Force -ErrorAction SilentlyContinue
                    }
                }

                $patchFile      = Join-Path $source "updateSettings.json"
                $targetSettings = Join-Path $s.Path "appsettings.json"

                if (Test-Path $patchFile) {
                    LogInfo "Applying updateSettings.json"
                    Ensure (Test-Path $targetSettings) "Missing appsettings.json in $($s.Path)"
                    Merge-JsonFile $targetSettings $patchFile
                    Remove-Item $patchFile -Force
                }

                Copy-Item "$source\*" $s.Path -Recurse -Force

            } else {
                if ($s.ExcludedFiles.Count -gt 0) {
                    LogWarn "DRY-RUN: Would exclude files: $($s.ExcludedFiles -join ', ')"
                }
                LogWarn "DRY-RUN: Would apply updateSettings.json if present, then remove it from staging"
                LogWarn "DRY-RUN: Would copy files to $($s.Path)"
            }

            LogOk "$($s.Name) deployed successfully"
            $i++
        }

        if ($NoRestart) {
            LogWarn "NO-RESTART: skipping start of AppPool(s)"
        } else {
            foreach ($s in $Sites) {
                if ($DryRun) {
                    LogWarn "DRY-RUN: Would start AppPool $($s.AppPool)"
                } else {
                    LogInfo "Starting AppPool: $($s.AppPool)"
                    Start-WebAppPool $s.AppPool
                    $timeout = 15; $elapsed = 0
                    while ((Get-WebAppPoolState $s.AppPool).Value -ne "Started" -and $elapsed -lt $timeout) {
                        Start-Sleep -Seconds 1; $elapsed++
                    }
                    if ((Get-WebAppPoolState $s.AppPool).Value -ne "Started") {
                        throw "AppPool $($s.AppPool) failed to start within $timeout seconds - check Event Viewer"
                    }
                    LogOk "AppPool $($s.AppPool) started"
                }
            }
        }

        # health checks
        if ($NoRestart) {
            LogWarn "NO-RESTART: skipping health checks"
        } else {
            foreach ($s in $Sites) {
                if ($s.PSObject.Properties.Name -contains "HealthUrl" -and $s.HealthUrl) {
                    LogInfo "Health check: $($s.HealthUrl)"
                    if (-not $DryRun) {
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
                        Ensure $success "Health check failed for $($s.Name) after $maxRetries attempts"
                    }
                }
            }
        }

        $sw.Stop()
        LogOk "ALL SITES DEPLOYED SUCCESSFULLY"
        LogInfo "Total duration: $($sw.Elapsed.ToString('mm\:ss'))"
        LogInfo "Log file: $LogFile"

        # backup retention cleanup
        if (-not $DryRun -and -not $SkipBackup -and $KeepBackups -gt 0) {
            $allBackups = Get-ChildItem $BackupRoot -Filter "${Project}_bkp_*.zip" |
                          Sort-Object LastWriteTime -Descending
            if ($allBackups.Count -gt $KeepBackups) {
                $toDelete = $allBackups | Select-Object -Skip $KeepBackups
                LogInfo "Pruning $($toDelete.Count) old backup(s) (keeping newest $KeepBackups)..."
                foreach ($old in $toDelete) {
                    LogInfo "  Removing: $($old.Name)"
                    Remove-Item $old.FullName -Force
                }
            }
        }

        if (-not $DryRun) {
            $histBackup = if ($backupCreated) { $backupZip } else { $null }
            Write-DeployHistory "Success" -zipPath $zipFullPath -backupPath $histBackup
        }
    }
    catch {

        Write-Host ""
        LogError "DEPLOYMENT FAILED"
        LogError $_.Exception.Message

        if (-not $DryRun) {
            $histBackup = if ($backupCreated) { $backupZip } else { $null }
            Write-DeployHistory "Failed" $_.Exception.Message -zipPath $zipFullPath -backupPath $histBackup
            if ($backupCreated -and -not $NoAutoRollback) {
                LogError "Starting auto-rollback..."
                & "$PSScriptRoot\rollback-deploy.ps1" -Project $Project -Backup $backupName -Force
            } elseif ($backupCreated -and $NoAutoRollback) {
                LogError "Auto-rollback is disabled (--no-auto-rollback). The site is in a partially-deployed state."
                LogError "A backup was created: $backupName"
                LogError "To rollback manually, run:"
                LogError "    deploy $Project --rollback --backup $backupName --force"
            } else {
                LogError "No backup was created - skipping auto-rollback. Manual intervention required."
            }
        }

        throw
    }
    finally {
        if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
    }

}
finally {
    if ($lockAcquired -and (Test-Path $LockFile)) { Remove-Item $LockFile -Force }
    try { Stop-Transcript } catch {}
}
