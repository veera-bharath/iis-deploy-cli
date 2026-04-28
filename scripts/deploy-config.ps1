$ErrorActionPreference = "Stop"

$RootDir    = if ((Split-Path $PSScriptRoot -Leaf) -eq 'scripts') { Split-Path $PSScriptRoot -Parent } else { $PSScriptRoot }
$ConfigsDir = Join-Path $RootDir "configs"

# ==============================================================================
# UI helpers
# ==============================================================================

function Write-Banner {
    Write-Host ""
    Write-Host "  ==================================================" -ForegroundColor Cyan
    Write-Host "    IIS Deploy Tool  -  Project Config Manager" -ForegroundColor Cyan
    Write-Host "  ==================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Section([string]$title) {
    Write-Host ""
    Write-Host "  ---- $title" -ForegroundColor DarkCyan
    Write-Host ""
}

function Write-Ok([string]$msg)   { Write-Host "  [OK] $msg" -ForegroundColor Green   }
function Write-Fail([string]$msg) { Write-Host "  [!]  $msg" -ForegroundColor Red     }
function Write-Hint([string]$msg) { Write-Host "       $msg" -ForegroundColor DarkGray }

function Prompt-Value {
    param(
        [string]$Label,
        [string]$Default  = "",
        [string]$Hint     = "",
        [switch]$Required
    )
    Write-Host "  $Label" -ForegroundColor White -NoNewline
    if ($Hint -ne "") {
        Write-Host "  ($Hint)" -ForegroundColor DarkGray
        Write-Host "  " -NoNewline
    } else {
        Write-Host ""
        Write-Host "  " -NoNewline
    }

    while ($true) {
        $val = if ($Default -ne "") { Read-Host "[$Default]" } else { Read-Host }
        if ([string]::IsNullOrWhiteSpace($val)) { $val = $Default }
        $val = $val.Trim()
        if ($Required -and $val -eq "") {
            Write-Host "  [!] This field is required." -ForegroundColor Red
            Write-Host "  " -NoNewline
            continue
        }
        return $val
    }
}

function Prompt-YesNo {
    param([string]$Question, [bool]$Default = $true)
    $hint = if ($Default) { "Y/n" } else { "y/N" }
    Write-Host ""
    Write-Host "  $Question [$hint] " -NoNewline -ForegroundColor White
    $val = Read-Host
    if ([string]::IsNullOrWhiteSpace($val)) { return $Default }
    return ($val.Trim() -imatch '^y')
}

function Prompt-Number {
    param([string]$Label, [int]$Default = 1, [int]$Min = 1)
    Write-Host "  $Label" -ForegroundColor White -NoNewline
    while ($true) {
        $val = if ($Default -ge $Min) { Read-Host "  [$Default]" } else { Read-Host }
        if ([string]::IsNullOrWhiteSpace($val)) { return $Default }
        $n = 0
        if ([int]::TryParse($val.Trim(), [ref]$n) -and $n -ge $Min) { return $n }
        Write-Host "  [!] Enter a whole number (minimum $Min)." -ForegroundColor Red
    }
}

# ==============================================================================
# Config helpers
# ==============================================================================

function Get-Projects {
    if (-not (Test-Path $ConfigsDir)) { return @() }
    @(Get-ChildItem $ConfigsDir -Filter "deploy-config-*.json" |
        ForEach-Object { $_.BaseName -replace '^deploy-config-', '' } |
        Sort-Object)
}

function Get-ConfigPath([string]$project) {
    Join-Path $ConfigsDir "deploy-config-$project.json"
}

function Ensure-ConfigsDir {
    if (-not (Test-Path $ConfigsDir)) {
        New-Item $ConfigsDir -ItemType Directory -Force | Out-Null
    }
}

# ==============================================================================
# Site input
# ==============================================================================

function Read-Site {
    param([int]$Index, [string]$Total, $Existing = $null)

    Write-Host ""
    Write-Host ("  ---- Site {0} of {1} --------------------------------" -f $Index, $Total) -ForegroundColor DarkCyan
    Write-Host ""

    $nameDef = if ($Existing) { $Existing.Name    } else { "" }
    $pathDef = if ($Existing) { $Existing.Path    } else { "" }
    $poolDef = if ($Existing) { $Existing.AppPool } else { "" }

    $excDef = ""
    if ($Existing -and $Existing.PSObject.Properties['ExcludedFiles'] -and
        $Existing.ExcludedFiles -and $Existing.ExcludedFiles.Count -gt 0) {
        $excDef = $Existing.ExcludedFiles -join ","
    }

    $healthDef = ""
    if ($Existing -and $Existing.PSObject.Properties['HealthUrl'] -and $Existing.HealthUrl) {
        $healthDef = $Existing.HealthUrl
    }

    $name   = Prompt-Value "Site name"         $nameDef  ""                                                          -Required
    $path   = Prompt-Value "IIS physical path" $pathDef  "e.g. C:\inetpub\wwwroot\MyApp"                            -Required
    $pool   = Prompt-Value "App pool name"     $poolDef  ""                                                          -Required
    $excRaw = Prompt-Value "Excluded files"    $excDef   "comma-separated patterns  e.g. appsettings*.json,web.config"
    $health = Prompt-Value "Health check URL"  $healthDef "optional  e.g. http://localhost/api/health"

    $excluded = @()
    if ($excRaw -ne "") {
        $excluded = @($excRaw.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
    }

    $site = [ordered]@{
        Name          = $name
        Path          = $path
        AppPool       = $pool
        ExcludedFiles = $excluded
    }
    if ($health -ne "") { $site['HealthUrl'] = $health }

    return [PSCustomObject]$site
}

# ==============================================================================
# Add new project
# ==============================================================================

function Add-Project([string[]]$existing) {
    Write-Section "New Project"

    $name = ""
    while ($true) {
        $name = Prompt-Value "Project name" "" "lowercase, no spaces  e.g. hrms" -Required
        $name = ($name.ToLower() -replace '\s+', '-').Trim('-')
        if ($existing -contains $name) {
            Write-Fail "Project '$name' already exists. Enter a different name."
        } else {
            Write-Ok "Name '$name' is available"
            break
        }
    }

    Write-Section "Backup & Publish Paths"
    $backupRoot = Prompt-Value "Backup root path" "" "e.g. C:\Backups\$name"           -Required
    $zipPath    = Prompt-Value "Publish ZIP path" "" "e.g. C:\Publish\$name\app.zip"   -Required

    Write-Section "Sites"
    $siteCount = Prompt-Number "How many sites?" 1 1

    $sites = @()
    for ($i = 1; $i -le $siteCount; $i++) {
        $sites += Read-Site $i $siteCount
    }

    $cfg = [PSCustomObject][ordered]@{
        BackupRoot     = $backupRoot
        PublishZipPath = $zipPath
        Sites          = $sites
    }

    Write-Section "Preview"
    Write-Host ($cfg | ConvertTo-Json -Depth 10) -ForegroundColor DarkGray

    $save = Prompt-YesNo "Save this config?"
    if (-not $save) {
        Write-Host ""
        Write-Host "  Config not saved." -ForegroundColor Yellow
        return
    }

    Ensure-ConfigsDir
    $cfgPath = Get-ConfigPath $name
    $cfg | ConvertTo-Json -Depth 10 | Set-Content $cfgPath -Encoding UTF8

    Write-Host ""
    Write-Ok "Config saved: $cfgPath"
    Write-Host ""
    Write-Hint "Deploy   : deploy.bat -Project $name"
    Write-Hint "Rollback : rollback-deploy.bat -Project $name"
    Write-Host ""
}

# ==============================================================================
# Update existing project
# ==============================================================================

function Update-Project([string[]]$projects) {
    Write-Section "Select Project to Update"

    for ($i = 0; $i -lt $projects.Count; $i++) {
        Write-Host ("   {0,2}.  {1}" -f ($i + 1), $projects[$i]) -ForegroundColor Cyan
    }
    Write-Host ""

    $choice = 0
    while ($choice -lt 1 -or $choice -gt $projects.Count) {
        $raw = Read-Host "  Project number"
        if ([int]::TryParse($raw.Trim(), [ref]$choice) -and $choice -ge 1 -and $choice -le $projects.Count) { break }
        Write-Host "  [!] Enter a number between 1 and $($projects.Count)." -ForegroundColor Red
        $choice = 0
    }

    $project = $projects[$choice - 1]
    $cfgPath = Get-ConfigPath $project
    $cfg     = Get-Content $cfgPath -Raw | ConvertFrom-Json

    Write-Host ""
    Write-Host "  Editing: " -NoNewline -ForegroundColor White
    Write-Host $project -ForegroundColor Cyan
    Write-Host "  (Press Enter to keep the current value)" -ForegroundColor DarkGray

    Write-Section "Backup & Publish Paths"
    $backupRoot = Prompt-Value "Backup root path" $cfg.BackupRoot     -Required
    $zipPath    = Prompt-Value "Publish ZIP path" $cfg.PublishZipPath -Required

    Write-Section "Sites"
    $existingSites = @($cfg.Sites)
    Write-Host "  Current sites:" -ForegroundColor DarkGray
    for ($i = 0; $i -lt $existingSites.Count; $i++) {
        Write-Host ("   {0,2}.  {1}  ->  {2}" -f ($i + 1), $existingSites[$i].Name, $existingSites[$i].AppPool) -ForegroundColor DarkGray
    }

    $editExisting = Prompt-YesNo "Edit existing sites?" $true

    $sites = @()
    if ($editExisting) {
        for ($i = 0; $i -lt $existingSites.Count; $i++) {
            $sites += Read-Site ($i + 1) $existingSites.Count $existingSites[$i]
        }
    } else {
        $sites = $existingSites
        Write-Hint "Existing sites kept unchanged."
    }

    $addMore = Prompt-YesNo "Add additional sites?" $false
    if ($addMore) {
        $idx = $sites.Count + 1
        while ($true) {
            $sites += Read-Site $idx "?"
            $idx++
            $cont = Prompt-YesNo "Add another site?" $false
            if (-not $cont) { break }
        }
    }

    $updated = [PSCustomObject][ordered]@{
        BackupRoot     = $backupRoot
        PublishZipPath = $zipPath
        Sites          = $sites
    }

    Write-Section "Preview"
    Write-Host ($updated | ConvertTo-Json -Depth 10) -ForegroundColor DarkGray

    $save = Prompt-YesNo "Save changes?"
    if (-not $save) {
        Write-Host ""
        Write-Host "  Changes discarded." -ForegroundColor Yellow
        return
    }

    $updated | ConvertTo-Json -Depth 10 | Set-Content $cfgPath -Encoding UTF8
    Write-Host ""
    Write-Ok "Config updated: $cfgPath"
    Write-Host ""
}

# ==============================================================================
# Main
# ==============================================================================

Write-Banner

$projects = @(Get-Projects)

Write-Host "  Configs : " -NoNewline -ForegroundColor DarkGray
Write-Host $ConfigsDir -ForegroundColor Yellow
Write-Host ""

if ($projects.Count -eq 0) {
    Write-Host "  No projects configured yet." -ForegroundColor DarkGray
} else {
    Write-Host "  Existing projects:" -ForegroundColor White
    Write-Host ("  " + ("-" * 40)) -ForegroundColor DarkGray
    for ($i = 0; $i -lt $projects.Count; $i++) {
        Write-Host ("   {0,2}.  {1}" -f ($i + 1), $projects[$i]) -ForegroundColor Cyan
    }
    Write-Host ("  " + ("-" * 40)) -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "  What would you like to do?" -ForegroundColor White
Write-Host "   1.  Add new project" -ForegroundColor Cyan
if ($projects.Count -gt 0) {
    Write-Host "   2.  Update existing project" -ForegroundColor Cyan
}
Write-Host "   0.  Exit" -ForegroundColor DarkGray
Write-Host ""

$action = ""
while ($true) {
    $raw = Read-Host "  Choice [1]"
    if ([string]::IsNullOrWhiteSpace($raw)) { $raw = "1" }
    $raw = $raw.Trim()

    if ($raw -eq "0")                             { Write-Host ""; exit 0 }
    if ($raw -eq "1")                             { $action = "add";    break }
    if ($raw -eq "2" -and $projects.Count -gt 0) { $action = "update"; break }

    Write-Host "  [!] Invalid choice." -ForegroundColor Red
}

switch ($action) {
    "add"    { Add-Project $projects }
    "update" { Update-Project $projects }
}
