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

function _IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Read-Site {
    param([int]$Index, [string]$Total, $Existing = $null)

    Write-Host ""
    Write-Host ("  ---- Site {0} of {1} --------------------------------" -f $Index, $Total) -ForegroundColor DarkCyan
    Write-Host ""

    # ---- seed defaults from existing config ---------------------------------

    $zipNameDef     = if ($Existing) { $Existing.Name    } else { "" }
    $pathDef        = if ($Existing) { $Existing.Path    } else { "" }
    $poolDef        = if ($Existing) { $Existing.AppPool } else { "" }
    $iisSiteNameDef = if ($Existing -and $Existing.PSObject.Properties['IISSiteName'] -and $Existing.IISSiteName) { $Existing.IISSiteName } else { $zipNameDef }
    $healthDef      = if ($Existing -and $Existing.PSObject.Properties['HealthUrl']   -and $Existing.HealthUrl)   { $Existing.HealthUrl }   else { "" }
    $excDef = ""
    if ($Existing -and $Existing.PSObject.Properties['ExcludedFiles'] -and
        $Existing.ExcludedFiles -and $Existing.ExcludedFiles.Count -gt 0) {
        $excDef = $Existing.ExcludedFiles -join ","
    }

    # ---- 1. IIS identity - loop until check passes or user decides ----------

    $webAdmin = $false
    try { Import-Module WebAdministration -ErrorAction Stop; $webAdmin = $true } catch {}

    $iisSiteName = $iisSiteNameDef
    $path        = $pathDef
    $pool        = $poolDef
    $done        = $false

    while (-not $done) {

        $iisSiteName = Prompt-Value "IIS site name"  $iisSiteNameDef  "name shown in IIS Manager"                             -Required
        $path        = Prompt-Value "Physical path"  $pathDef         "IIS site physical path  e.g. C:\inetpub\wwwroot\MyApp" -Required
        $pool        = Prompt-Value "App pool name"  $poolDef         ""                                                      -Required

        # update defaults so re-entry shows what was just typed
        $iisSiteNameDef = $iisSiteName; $pathDef = $path; $poolDef = $pool

        if (-not $webAdmin) {
            Write-Host ""
            Write-Host "  [i] WebAdministration not available - IIS check skipped." -ForegroundColor DarkGray
            Write-Host "      Ensure the app pool and site exist before running deploy." -ForegroundColor DarkGray
            $done = $true
            break
        }

        $poolExists   = Test-Path "IIS:\AppPools\$pool"
        $siteExists   = $null -ne (Get-Website -Name $iisSiteName -ErrorAction SilentlyContinue)
        $folderExists = Test-Path $path

        if ($poolExists -and $siteExists -and $folderExists) {
            Write-Ok "Folder found   : $path"
            Write-Ok "App pool found : $pool"
            Write-Ok "IIS site found : $iisSiteName"
            $done = $true
            break
        }

        # report what is missing
        Write-Host ""
        if (-not $folderExists) { Write-Fail "Folder not found   : $path" }
        if (-not $poolExists)   { Write-Fail "App pool not found : $pool" }
        if (-not $siteExists)   { Write-Fail "IIS site not found : $iisSiteName" }
        Write-Host ""
        Write-Host "   1.  Re-enter details" -ForegroundColor Cyan
        Write-Host "   2.  Create them now" -ForegroundColor Cyan
        Write-Host "   3.  I'll set them up manually" -ForegroundColor Cyan
        Write-Host ""

        $opt = ""
        while ($opt -notin @("1","2","3")) {
            $raw = (Read-Host "  Choice [2]").Trim()
            $opt = if ($raw -eq "") { "2" } else { $raw }
        }

        if ($opt -eq "1") { Write-Host ""; continue }

        if ($opt -eq "3") {
            Write-Host ""
            Write-Hint "Create the folder, app pool, and IIS site manually in IIS Manager."
            Write-Hint "Then run 'deploy --setup-config' again if you need to update settings."
            $done = $true
            break
        }

        # Option 2 - create now (runtime/port/hostname used only for creation, not saved)
        if (-not (_IsAdmin)) {
            Write-Host ""
            Write-Fail "Creating IIS resources requires an elevated (Administrator) session."
            Write-Hint "Re-run 'deploy --setup-config' from an elevated prompt and choose option 2,"
            Write-Hint "or create the folder, app pool, and site manually in IIS Manager."
            $done = $true
            break
        }

        Write-Host ""
        Write-Host "  ---- IIS Binding (used for creation only, not saved to config) --------" -ForegroundColor DarkCyan
        Write-Host ""

        $rtStr   = Prompt-Value "App pool runtime"  "NoCLR"  "NoCLR for .NET Core / 5+   or   v4.0 for classic ASP.NET"
        $portStr = Prompt-Value "Site port"         "80"     "HTTP binding port  e.g. 80, 8080, 8022"
        $hostStr = Prompt-Value "Site hostname"     ""       "optional host header  e.g. myapp.local  (blank = any)"

        $createRuntime    = if ($rtStr   -ne '') { $rtStr } else { 'NoCLR' }
        $createPort       = if ($portStr -match '^\d+$') { [int]$portStr } else { 80 }
        $createHostname   = $hostStr
        $createClrVersion = if ($createRuntime -eq 'NoCLR') { '' } else { $createRuntime }

        Write-Host ""

        if (-not $folderExists) {
            try   { New-Item $path -ItemType Directory -Force | Out-Null; Write-Ok "Created folder   : $path" }
            catch { Write-Fail "Could not create folder : $($_.Exception.Message)" }
        }

        if (-not $poolExists) {
            try {
                New-WebAppPool $pool | Out-Null
                Set-ItemProperty "IIS:\AppPools\$pool" managedRuntimeVersion $createClrVersion
                Write-Ok "Created app pool : $pool  (runtime: $createRuntime)"
            } catch { Write-Fail "Could not create app pool : $($_.Exception.Message)" }
        }

        if (-not $siteExists) {
            try {
                New-Website -Name $iisSiteName -PhysicalPath $path -ApplicationPool $pool -Port $createPort -HostHeader $createHostname | Out-Null
                Write-Ok "Created IIS site : '$iisSiteName'  binding: *:${createPort}:${createHostname}"
            } catch { Write-Fail "Could not create IIS site : $($_.Exception.Message)" }
        }

        $done = $true
    }

    # ---- 2. Deploy settings -------------------------------------------------

    Write-Host ""
    Write-Host "  ---- Deploy Settings --------" -ForegroundColor DarkCyan
    Write-Host ""

    # Default zip folder name to IIS site name when creating a new site
    if ($zipNameDef -eq '') { $zipNameDef = $iisSiteName }

    $zipName = Prompt-Value "ZIP folder name"  $zipNameDef  "top-level folder inside the publish ZIP that maps to this site"  -Required
    $excRaw  = Prompt-Value "Excluded files"   $excDef      "comma-separated glob patterns  e.g. appsettings*.json,web.config"
    $health  = Prompt-Value "Health check URL" $healthDef   "GET-probed after each deploy  e.g. http://localhost:8080/api/health"

    $excluded = @()
    if ($excRaw -ne "") {
        $excluded = @($excRaw.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
    }

    # ---- build site object (IIS creation details are not persisted) ---------

    $site = [ordered]@{
        Name    = $zipName
        Path    = $path
        AppPool = $pool
    }
    if ($excluded.Count -gt 0) { $site['ExcludedFiles'] = $excluded }
    if ($health -ne "")        { $site['HealthUrl']     = $health }

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

