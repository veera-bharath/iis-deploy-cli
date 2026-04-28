# iis-deploy-cli

A PowerShell CLI for deploying ASP.NET / IIS sites on Windows from a publish ZIP.  
Handles backup, auto-rollback on failure, dry-run preview, and an interactive per-project config editor — all from a single `deploy` command.

## Features

- **Zero-touch deploy** — stop pools, copy files, start pools, run health checks
- **Auto-backup** — ZIP snapshot of every live site before each deploy
- **Auto-rollback** — if deploy fails, the previous backup is automatically restored
- **Dry-run** — preview every action without touching anything live
- **updateSettings.json overlay** — deep-merge environment-specific settings into `appsettings.json` at deploy time (file is removed from the package after merge)
- **Excluded files** — glob patterns stripped from the staging package before copy
- **Backup retention** — keep the N newest backups, prune the rest automatically
- **Deploy history** — `deploy-history.json` log of every deploy and rollback
- **Lock files** — atomic lock prevents concurrent deploys or rollbacks
- **Works installed or from the repo** — flat install adds `deploy` to system PATH

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

Interactive wizard — enter the project name, backup root, publish ZIP path, and one or more IIS sites (name, physical path, app pool, optional health check URL).

Configs are stored as `configs/deploy-config-<project>.json`.

### 2. Deploy

```
deploy <project>
deploy <project> --dry-run
deploy <project> --skip-backup
deploy <project> --no-restart
deploy <project> --no-auto-rollback
deploy <project> --keep-backups 5
```

### 3. Rollback

```
deploy <project> --rollback
deploy <project> --rollback --backup <backup-name>
deploy <project> --rollback --list-backups
deploy <project> --rollback --force
```

### 4. Utilities

```
deploy --list-projects
deploy --help
```

## All Flags

| Flag | Description |
|---|---|
| `--dry-run` | Preview all actions, make no changes |
| `--skip-backup` | Deploy without taking a backup (disables auto-rollback) |
| `--no-restart` | File copy only — do not stop/start app pools or run health checks |
| `--no-auto-rollback` | Take a backup but skip automatic rollback on failure |
| `--keep-backups N` | Retain N newest backups per project (default: 10) |
| `--keep-history N` | Retain N history entries in deploy-history.json (default: 100) |
| `--rollback` | Restore the latest backup |
| `--backup <name>` | Used with `--rollback` — restore a specific backup |
| `--list-backups` | Used with `--rollback` — list available backups |
| `--force` | Used with `--rollback` — skip the confirmation prompt |
| `--list-projects` | List all configured projects |
| `--setup-config` | Open the interactive config editor |

PowerShell-native forms are also accepted: `-DryRun`, `-SkipBackup`, `-NoRestart`, `-KeepBackups`, `-KeepHistory`, `-Rollback`, `-Backup`, `-Force`, `-ListBackups`, `-ListProjects`, `-SetupConfig`.

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
      "ExcludedFiles": ["appsettings.Development.json"],
      "HealthUrl": "http://localhost/api/health"
    }
  ]
}
```

| Field | Required | Description |
|---|---|---|
| `BackupRoot` | Yes | Directory where backup ZIPs are stored |
| `PublishZipPath` | Yes | Path to the publish `.zip` |
| `Sites[].Name` | Yes | Must match the top-level folder name inside the ZIP |
| `Sites[].Path` | Yes | IIS physical site path |
| `Sites[].AppPool` | Yes | IIS App Pool name |
| `Sites[].ExcludedFiles` | No | Glob patterns removed from staging before copy |
| `Sites[].HealthUrl` | No | GET-probed after pool restart, retried 5× with 5 s delay |

The publish ZIP must contain one top-level folder per site whose name matches `Sites[].Name`.

## Deploy Pipeline

1. Validate config + ZIP contents (preflight)
2. Extract ZIP → `%TEMP%\deploy_staging_<project>`
3. Backup live site dirs → `<BackupRoot>\<project>_bkp_<timestamp>.zip`
4. Stop app pools, kill lingering `w3wp.exe` and child `dotnet.exe` processes
5. Per site: apply `updateSettings.json` overlay if present, then `Copy-Item` files
6. Start app pools, run health checks
7. Write entry to `deploy-history.json`, prune old backups

`--no-restart` skips steps 4, the start in 6, and health checks (files only).  
`--skip-backup` skips step 3 and disables auto-rollback.

## Requirements

- Windows with IIS installed
- PowerShell 5.1+
- `WebAdministration` module (`Install-WindowsFeature Web-Scripting-Tools`)
- Elevated (Administrator) shell for deploy and rollback

## Project Structure

```
scripts/
  deploy.ps1               # Unified entry point + deploy logic
  rollback-deploy.ps1      # Rollback logic
  deploy-config.ps1        # Interactive config editor
  install-deploy-setup.ps1 # Installer (copies scripts + adds to PATH)
  deploy.cmd               # Batch wrapper
configs/                   # Per-project JSON configs (git-ignored)
logs/                      # Transcript logs (git-ignored)
tests/
  publish1.zip             # Test package v1 (shows "v1" in browser)
  publish2.zip             # Test package v2 (shows "v2" in browser)
deploy-history.json        # Append-only deploy log (git-ignored)
```

## License

MIT
