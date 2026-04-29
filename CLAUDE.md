# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A PowerShell-based CLI for deploying ASP.NET / IIS sites on Windows from a publish ZIP, with automatic backup, auto-rollback on failure, dry-run, and an interactive per-project config editor. Three originally-separate scripts (`deploy`, `rollback-deploy`, `deploy-config`) have been unified under one entry point: `deploy.ps1`.

## Common commands

All commands run from the repo root in PowerShell (most need an elevated shell).

```
# Help / discovery  -  no admin needed
deploy.cmd --help
deploy.cmd --list-projects
deploy.cmd --setup-config                              # interactive config editor
deploy.cmd <project> --validate-config                 # check config + IIS without deploying
deploy.cmd --status                                    # pool state, last deploy, backup count (all projects)
deploy.cmd <project> --status                          # same, one project only

# Deploy / rollback (require admin)
deploy.cmd <project>
deploy.cmd <project> --dry-run
deploy.cmd <project> --skip-backup
deploy.cmd <project> --no-restart                      # file-copy only, no IIS touch
deploy.cmd <project> --no-auto-rollback                # keep backup but skip auto-rollback on failure
deploy.cmd <project> --keep-backups N --keep-history N
deploy.cmd <project> --rollback                        # latest backup
deploy.cmd <project> --rollback --backup <name>
deploy.cmd <project> --rollback --force --list-backups

# Install to flat dir + add to system PATH
install.bat                                            # then enter install dir
```

PowerShell-native flag forms are accepted alongside the npm-style ones (`-Project x`, `-DryRun`, `-SkipBackup`, `-NoRestart`, `-NoAutoRollback`, `-KeepBackups`, `-KeepHistory`, `-ValidateConfig`, `-Status`, `-Rollback`, `-Backup`, `-Force`, `-ListBackups`, `-ListProjects`, `-SetupConfig`).

## Architecture

### Unified entry point with delegation

`scripts/deploy.ps1` is a custom-parsed CLI dispatcher (not a `param()` block  -  uses a manual `$args` loop so npm-style `--flags` and PowerShell `-Flags` are both accepted). After parsing it branches:

- `--list-projects` -> reads `configs/deploy-config-*.json`, prints summary, exits.
- `--setup-config` -> invokes `scripts/deploy-config.ps1` (interactive menu: add or edit a project).
- `--validate-config` -> checks config schema, file paths, ZIP contents, and IIS resources; exits 0/1. No deploy.
- `--status` -> prints a table (pool state, last deploy result, backup count/age) for one or all projects; exits 0.
- `--rollback` -> invokes `scripts/rollback-deploy.ps1` with translated args.
- default -> runs deploy logic inline (the bulk of the file).

`#Requires -RunAsAdministrator` is intentionally absent. Admin is enforced inside the deploy and rollback paths only via `_RequireAdmin`, so help/list/validate/status/setup all work non-elevated.

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

`deploy.lock` and `rollback.lock` are written via atomic `[System.IO.File]::Open(..., CreateNew, ...)` to avoid TOCTOU. They are **independent**  -  a manual rollback is not blocked by an in-flight deploy. Known gap.

### Config schema

`configs/deploy-config-<project>.json`:

```
BackupRoot      (string, required)   directory for backup ZIPs
PublishZipPath  (string, required)   path to the publish .zip
Sites[]         (array, required)
  Name           (string, required)  ZIP folder name  -  must equal the top-level folder in the ZIP
  Path           (string, required)  IIS physical site path
  AppPool        (string, required)  IIS App Pool name
  ExcludedFiles  (string[], optional) glob patterns deleted from staging before copy
  HealthUrl      (string, optional)   GET probed after pool restart, retried 5x
```

The publish ZIP must contain one top-level folder per `Site.Name`; preflight rejects mismatches.

**Important**: `Name` is the ZIP folder name, which may differ from the IIS site name shown in IIS Manager. The IIS site name is only used during `deploy-config` setup for validation/creation and is not saved to the config file.

### deploy-config.ps1  -  site input flow

`Read-Site` separates identity into two phases:

1. **IIS identity loop**  -  prompts for IIS site name, physical path, and app pool. If WebAdministration is available it checks all three exist. When something is missing it offers:
   - Re-enter details
   - Create now (requires elevation)  -  creates the folder, `New-WebAppPool`, and `New-Website`. Prompts for app pool runtime (`NoCLR` / `v4.0`), HTTP port, and optional hostname header. These creation-time values are not saved to config.
   - Set them up manually and continue

2. **Deploy settings**  -  prompts for ZIP folder name (defaults to the IIS site name just entered), excluded file patterns, and optional health check URL. Only these are saved.

### Deploy pipeline

1. Validate config + publish source contents (preflight).
2. Resolve publish source: prefers `PublishZipPath` as a `.zip`; if not found, falls back to a same-named folder (e.g. `app/` next to `app.zip`) for pre-extracted packages.
3. Extract ZIP -> `%TEMP%\deploy_staging_<project>` (skipped when using the pre-extracted folder path).
4. Backup live site dirs -> `<BackupRoot>\<project>_bkp_<dd_MMM_yyyy_HH_mm_ss>.zip`. Skipped per-site if the site folder is empty (first deploy); skipped entirely with `--skip-backup`.
5. Stop AppPools, kill leftover `w3wp` + child `dotnet.exe` for target pools only (CIM, scoped by app pool name).
6. Per site: apply `updateSettings.json` overlay (deep-merged into `appsettings.json`, then removed from staging), then `Copy-Item -Recurse -Force` into the live path.
7. Start AppPools, run health checks.
8. Append entry to `deploy-history.json`, prune backups beyond `--keep-backups`.

`--no-restart` skips steps 5, the pool start in 7, and health checks - files-only overlay.  
`--skip-backup` skips step 4 and disables auto-rollback.  
`--no-auto-rollback` keeps the backup but suppresses the automatic rollback call on failure; prints the manual rollback command to the log instead.

Note: step 6 overlays files but does **not** delete files in the live path absent from the new package - orphan files persist. Known.
