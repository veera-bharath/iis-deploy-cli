# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A PowerShell-based CLI for deploying ASP.NET / IIS sites on Windows from a publish ZIP, with automatic backup, auto-rollback on failure, dry-run, and an interactive per-project config editor. Three originally-separate scripts (`deploy`, `rollback-deploy`, `deploy-config`) have been unified under one entry point: `deploy.ps1`.

## Common commands

All commands run from the repo root in PowerShell (most need an elevated shell).

```
# Help / discovery — these work from any shell, no admin needed
deploy.cmd --help
deploy.cmd --list-projects
deploy.cmd --setup-config           # interactive config editor

# Deploy / rollback (require admin)
deploy.cmd <project>
deploy.cmd <project> --dry-run
deploy.cmd <project> --skip-backup
deploy.cmd <project> --no-restart                      # file-copy only, no IIS touch
deploy.cmd <project> --keep-backups N --keep-history N
deploy.cmd <project> --rollback                        # latest backup
deploy.cmd <project> --rollback --backup <name>
deploy.cmd <project> --rollback --force --list-backups

# Install to flat dir + add to system PATH
install.bat                                            # then enter install dir
```

PowerShell-native flag forms are accepted alongside the npm-style ones (`-Project x`, `-DryRun`, `-SkipBackup`, `-KeepBackups`, `-KeepHistory`, `-Rollback`, `-Backup`, `-Force`, `-ListBackups`, `-NoRestart`, `-ListProjects`, `-SetupConfig`).

## Architecture

### Unified entry point with delegation

`scripts/deploy.ps1` is a custom-parsed CLI dispatcher. After parsing args it branches:

- `--list-projects` → reads `configs/deploy-config-*.json`, prints summary, exits.
- `--setup-config` → invokes `scripts/deploy-config.ps1` (interactive menu: add or edit a project).
- `--rollback` → invokes `scripts/rollback-deploy.ps1` with translated args.
- default → runs deploy logic inline (the bulk of the file).

`#Requires -RunAsAdministrator` is intentionally absent. Admin is enforced inside the deploy and rollback paths only via `_RequireAdmin`, so help/list/setup work non-elevated.

### Two layouts (important for any path code)

Scripts run unchanged in two layouts:

- **Repo layout**: scripts live under `scripts/`, project root is the parent directory.
- **Flat install layout**: `install-deploy-setup.ps1` copies the three `.ps1` files into a single dir (default `C:\Tools\Deploy`), generates `.bat` wrappers, and adds the dir to system PATH.

Resolution idiom (in every script):

```powershell
$RootDir = if ((Split-Path $PSScriptRoot -Leaf) -eq 'scripts') {
    Split-Path $PSScriptRoot -Parent
} else { $PSScriptRoot }
```

`$RootDir` is where `configs/`, `logs/`, and `deploy-history.json` live. New code that touches paths must follow this idiom or it will break under the install layout.

### Auto-rollback path

If the deploy `try` block throws after a backup was created, deploy.ps1's catch invokes `rollback-deploy.ps1 -Project ... -Backup ... -Force` directly. Rollback is therefore both a user command and an internal recovery step. Keep its CLI surface stable.

### Lock files

`deploy.lock` and `rollback.lock` are written via atomic `[System.IO.File]::Open(..., CreateNew, ...)` to avoid TOCTOU. They are **independent** — a manual rollback is not blocked by an in-flight deploy. Known gap.

### Config schema

`configs/deploy-config-<project>.json`:

```
BackupRoot      (string, required)   directory for backup ZIPs
PublishZipPath  (string, required)   path to the publish .zip
Sites[]         (array, required)
  Name           (string, required)  must equal a top-level folder in the ZIP
  Path           (string, required)  IIS physical site path
  AppPool        (string, required)  IIS App Pool name
  ExcludedFiles  (string[], optional) glob patterns deleted from staging before copy
  HealthUrl      (string, optional)   GET probed after pool restart, retried 5x
```

The publish ZIP must contain one top-level folder per `Site.Name`; preflight rejects mismatches.

### Deploy pipeline

1. Validate config + ZIP contents (preflight).
2. Extract ZIP → `%TEMP%\deploy_staging_<project>`.
3. Backup live site dirs → `<BackupRoot>\<project>_bkp_<dd_MMM_yyyy_HH_mm_ss>.zip` (single ZIP containing all sites).
4. Stop AppPools, kill leftover `w3wp` + child `dotnet.exe` (CIM, not WMI).
5. Per site: apply `updateSettings.json` overlay (deep-merged into `appsettings.json`, then removed from staging), then `Copy-Item -Recurse -Force` into the live path.
6. Start AppPools, run health checks.
7. Append entry to `deploy-history.json`, prune backups beyond `--keep-backups`.

`--no-restart` skips steps 4, the AppPool start in 6, and the health check — files-only overlay. `--skip-backup` skips step 3 and disables auto-rollback.

Note: step 5 overlays files but does **not** delete files in the live path that are absent from the new ZIP — orphan files persist. Known.
