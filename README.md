# iis-deploy-cli

A PowerShell CLI for deploying ASP.NET / IIS sites on Windows from a publish ZIP.  
Handles backup, auto-rollback on failure, dry-run preview, and an interactive per-project config editor  -  all from a single `deploy` command.

## Features

- **Zero-touch deploy**  -  stop pools, copy files, start pools, run health checks
- **Auto-backup**  -  ZIP snapshot of every live site before each deploy
- **Auto-rollback**  -  if deploy fails, the previous backup is automatically restored
- **Dry-run**  -  preview every action without touching anything live
- **updateSettings.json overlay**  -  deep-merge environment-specific settings into `appsettings.json` at deploy time (file is removed from the package after merge)
- **Excluded files**  -  glob patterns stripped from the staging package before copy
- **Backup retention**  -  keep the N newest backups, prune the rest automatically
- **Deploy history**  -  `deploy-history.json` log of every deploy and rollback
- **Lock files**  -  atomic lock prevents concurrent deploys or rollbacks
- **Works installed or from the repo**  -  flat install adds `deploy` to system PATH

## Installation

```bat
install.bat
```

Copies the three `.ps1` scripts to a flat directory (default `C:\Tools\Deploy`), generates `.bat` wrappers, and adds the directory to the system PATH.  
Run from an **elevated** command prompt or PowerShell.

## Quick Start

### 1. Configure a project

```
deploy --setup-config
```

Interactive wizard  -  enter the project name, backup root, publish ZIP path, and one or more IIS sites.

For each site the wizard:
1. Asks for the **IIS site name**, physical path, and app pool, then checks they exist in IIS.
2. If anything is missing, offers to **create** the folder, app pool, and IIS site on the spot (requires an elevated shell)  -  prompts for app pool runtime (`NoCLR` for .NET Core/5+, `v4.0` for classic ASP.NET), HTTP port, and optional hostname. These creation details are not saved to the config.
3. Asks for the **ZIP folder name** (the top-level folder inside your publish ZIP that maps to this site; defaults to the IIS site name).
4. Optionally sets excluded file patterns and a health check URL.

Configs are stored as `configs/deploy-config-<project>.json`.

### 2. Validate before deploying

```
deploy <project> --validate-config
```

Checks the config file, all required fields, whether the publish ZIP (or pre-extracted folder) exists and contains the expected site folders, and whether each site's physical path and app pool exist in IIS. Exits 0 if everything is ready, 1 if anything fails. No changes are made.

### 3. Deploy

```
deploy <project>
deploy <project> --dry-run
deploy <project> --skip-backup
deploy <project> --no-restart
deploy <project> --no-auto-rollback
deploy <project> --keep-backups 5
```

### 4. Rollback

```
deploy <project> --rollback
deploy <project> --rollback --backup <backup-name>
deploy <project> --rollback --list-backups
deploy <project> --rollback --force
```

### 5. Utilities

```
deploy --status                    # all projects
deploy <project> --status          # one project
deploy --list-projects
deploy --help
```

`--status` prints a summary table  -  app pool state, last deploy result and timestamp, backup count and age  -  for one project or all configured projects.

## All Flags

| Flag | Description |
|---|---|
| `--dry-run` | Preview all actions, make no changes |
| `--skip-backup` | Deploy without taking a backup (disables auto-rollback) |
| `--no-restart` | File copy only - do not stop/start app pools or run health checks |
| `--no-auto-rollback` | Take a backup but do not auto-rollback on failure; prints the manual rollback command instead |
| `--keep-backups N` | Retain N newest backups per project (default: 10) |
| `--keep-history N` | Retain N history entries in deploy-history.json (default: 100) |
| `--validate-config` | Check config, paths, ZIP contents, and IIS resources without deploying |
| `--status` | Show app pool state, last deploy result, and backup count for one or all projects |
| `--rollback` | Restore the latest backup |
| `--backup <name>` | Used with `--rollback` - restore a specific backup |
| `--list-backups` | Used with `--rollback` - list available backups |
| `--force` | Used with `--rollback` - skip the confirmation prompt |
| `--list-projects` | List all configured projects |
| `--setup-config` | Open the interactive config editor |
| `--help` | Show usage |

PowerShell-native forms are also accepted: `-DryRun`, `-SkipBackup`, `-NoRestart`, `-NoAutoRollback`, `-KeepBackups`, `-KeepHistory`, `-ValidateConfig`, `-Status`, `-Rollback`, `-Backup`, `-Force`, `-ListBackups`, `-ListProjects`, `-SetupConfig`.

## Config Schema

`configs/deploy-config-<project>.json`

```json
{
  "BackupRoot": "C:\\Backups\\myapp",
  "PublishZipPath": "C:\\Publish\\myapp.zip",
  "Sites": [
    {
      "Name": "MyApp",
      "Path": "C:\\inetpub\\wwwroot\\MyApp",
      "AppPool": "MyAppPool",
      "ExcludedFiles": [
        "appsettings.*.json",
        "web.config",
        ".env",
        "*.pfx",
        "*.key"
      ],
      "HealthUrl": "http://localhost/api/health"
    }
  ]
}
```

| Field | Required | Description |
|---|---|---|
| `BackupRoot` | Yes | Directory where backup ZIPs are stored |
| `PublishZipPath` | Yes | Path to the publish `.zip` |
| `Sites[].Name` | Yes | **ZIP folder name**  -  must match the top-level folder inside the ZIP |
| `Sites[].Path` | Yes | IIS physical site path |
| `Sites[].AppPool` | Yes | IIS App Pool name |
| `Sites[].ExcludedFiles` | No | Glob patterns removed from staging before copy |
| `Sites[].HealthUrl` | No | GET-probed after pool restart, retried 5x with 5 s delay |

`Sites[].Name` is the ZIP folder name, which can differ from the IIS site name shown in IIS Manager. The publish ZIP must contain one top-level folder per site whose name matches `Sites[].Name`.

## Deploy Pipeline

1. Validate config + publish source contents (preflight)
2. Extract ZIP -> `%TEMP%\deploy_staging_<project>` (skipped if a pre-extracted folder is used)
3. Backup live site dirs -> `<BackupRoot>\<project>_bkp_<timestamp>.zip` (skipped for empty sites)
4. Stop app pools, kill lingering `w3wp.exe` and child `dotnet.exe` processes (scoped to target pools)
5. Per site: apply `updateSettings.json` overlay if present, then `Copy-Item` files
6. Start app pools, run health checks
7. Write entry to `deploy-history.json`, prune old backups

`--no-restart` skips steps 4, the pool start in step 6, and health checks  -  files only.  
`--skip-backup` skips step 3 and disables auto-rollback.  
`--no-auto-rollback` keeps the backup but skips automatic rollback on failure; prints the manual command instead.

**Publish source fallback**: if `PublishZipPath` does not exist as a `.zip`, the deploy looks for a same-named folder without the extension (e.g. `app` next to `app.zip`). Useful when the CI system extracts the package before handing off to the deploy step.

## Requirements

- Windows with IIS installed
- PowerShell 5.1+
- `WebAdministration` module (`Install-WindowsFeature Web-Scripting-Tools`)
- Elevated (Administrator) shell for deploy and rollback

## Project Structure

```
install.bat                        # Runs the installer
scripts/
  deploy.ps1                       # Unified entry point + deploy logic
  rollback-deploy.ps1              # Rollback logic
  deploy-config.ps1                # Interactive config editor (add / update projects)
  install-deploy-setup.ps1         # Installer (copies scripts, generates .bat wrappers, adds to PATH)
  deploy.cmd                       # Batch wrapper for deploy.ps1
  rollback-deploy.cmd              # Batch wrapper for rollback-deploy.ps1
  deploy-config.bat                # Batch wrapper for deploy-config.ps1
tests/
  configs/
    deploy-config-testapp.json.example   # Example config for reference
  publish1.zip                     # Test publish package v1
  publish2.zip                     # Test publish package v2
configs/                           # Per-project JSON configs (git-ignored)
logs/                              # Transcript logs per deploy/rollback (git-ignored)
deploy-history.json                # Append-only deploy log (git-ignored)
```

## License

MIT
