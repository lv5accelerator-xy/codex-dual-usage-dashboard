# Codex Dual Usage Dashboard

Windows desktop floating quota monitor for two ChatGPT/Codex accounts (Personal + Work).

Current version: **v0.3.9**

## Main experience

After `start.bat`, the app starts as a small always-available desktop floating monitor instead of opening the full quota window.

In v0.3.9 the floating monitor explicitly shows **5H first, total quota second** for each account:

```text
   5H / 总
P 100% / 95%
W  49% / 21%
```

- `5H` = current 5-hour limit remaining.
- `总` = the lower meaningful long-window quota remaining. For Personal this is normally Weekly; for Work it also considers a valid workspace/monthly limit when one is returned.
- Drag the floating monitor anywhere on the desktop.
- Left-click it to expand/collapse the full quota panel.
- Right-click for refresh, visibility, always-on-top, reset position, account login/switch, logs, and exit.
- The outer ring changes color according to the lowest meaningful remaining quota.

## Resizable detail panel

The expanded quota panel is movable and freely resizable. Quota order is now consistent:

1. 5 小时限额
2. 工作空间/月度总额度（when provided）
3. 每周限额

The Personal account continues to show 5-hour first and Weekly second.

## Persistent UI settings

The app saves local UI preferences to:

```text
ui-settings.json
```

It remembers floating position, panel position/size, floating monitor visibility, and always-on-top preference. `ui-settings.json` is ignored by Git.

## Automatic refresh

The app refreshes silently in the background every **5 minutes**. If a background refresh fails, the previous successful data remains visible.

Manual refresh is available from the panel, floating-monitor right-click menu, or system-tray menu.

## Requirements

- Windows 10/11
- Windows PowerShell 5.1+
- Codex CLI
- Node.js is **not required**

## First run

Run:

```text
first-run-setup.bat
```

This creates and logs in two independent Codex homes:

- Personal: `%USERPROFILE%\.codex-personal`
- Work: `%USERPROFILE%\.codex-work`

## Start

```text
start.bat
```

For visible startup diagnostics:

```text
start-debug.bat
```

If startup fails, check:

```text
logs\startup.log
logs\startup-error.log
logs\tray.log
logs\worker.log
```

## Security

The repository does not contain ChatGPT/Codex login credentials. Authentication remains in the user's local Codex profile directories and should never be committed.

Ignored local data includes:

```text
logs/
usage-result.json
ui-settings.json
.codex/
.codex-personal/
.codex-work/
```

## Project files

- `tray.ps1` — floating UI, resizable panel, tray icon, rendering, refresh timers
- `patch-v039.ps1` — v0.3.9 display/order migration applied by the launcher for fresh GitHub ZIP downloads
- `usage-reader.ps1` — Codex app-server quota reader
- `usage-worker.ps1` — background refresh worker
- `codex-tools.ps1` — Codex CLI discovery/helpers
- `setup-account.ps1` — account setup/login logic
- `profiles.json` — profile labels and local Codex home paths
- `launcher.ps1` — encoding normalization, v0.3.9 display migration, syntax check, startup watchdog
- `start.bat` — normal hidden startup
- `start-debug.bat` — visible/debug startup

## GitHub ZIP note

If you download the repository using **Code → Download ZIP**, extract the ZIP completely before running `start.bat`. The launcher normalizes PowerShell files for Windows PowerShell 5.1, applies the current display migration when required, validates `tray.ps1`, and then starts the floating UI.
