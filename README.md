# Codex Dual Usage Dashboard

Windows tray dashboard for viewing ChatGPT/Codex usage limits for two separate accounts (Personal + Work).

Current version: **v0.3.6**

## What it shows

- Personal account: 5-hour limit and weekly limit
- Work account: monthly workspace limit (when provided), 5-hour limit, and weekly limit
- Remaining percentage for each quota window
- Time remaining until reset
- Independent Personal / Work Codex profiles
- Windows system tray access and manual refresh

## v0.3.6

- Fixed the Windows PowerShell 5.1 `Path.GetFullPath` startup error introduced in v0.3.5.
- Removed use of `$MyInvocation.MyCommand.Path` from inside the source-normalization function.
- Replaced `Start-Process` with `System.Diagnostics.ProcessStartInfo` for tray startup.
- Added a syntax check for `tray.ps1` before the tray process launches.
- Preserved automatic UTF-8 BOM normalization for GitHub ZIP downloads.

## v0.3.5

- Hardened startup for GitHub ZIP downloads.
- `start.bat` no longer depends on Windows Script Host / VBS for normal startup.
- Added `launcher.ps1` with startup health checks and persistent startup logs.
- GitHub-downloaded PowerShell files are normalized locally for Windows PowerShell 5.1 before launch.
- Early startup failures write `logs/startup-error.log` instead of silently disappearing.

## v0.3.4

- Dark technology-style UI.
- Larger adaptive popup window.
- Automatically returns the quota panel to the top when opened/refreshed.
- Improved quota card hierarchy and progress bars.

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

Run:

```text
start.bat
```

For visible diagnostics:

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

## Diagnostics

```text
diagnose.bat
test-usage.bat
```

Runtime logs are written to `logs/` and are intentionally ignored by Git.

## Security

The repository does not contain ChatGPT/Codex login credentials. Authentication files remain in the user's local Codex profile directories and should never be committed.

## Project files

- `tray.ps1` — tray UI and dashboard rendering
- `usage-reader.ps1` — Codex app-server quota reader
- `usage-worker.ps1` — background refresh worker
- `codex-tools.ps1` — Codex CLI discovery/helpers
- `setup-account.ps1` — account setup/login logic
- `profiles.json` — profile labels and local Codex home paths
- `start.bat` / `launcher.ps1` — hardened normal startup
- `start-hidden.vbs` — legacy launcher retained for compatibility
- `start-debug.bat` — debug startup

## GitHub ZIP note

If you download the repository using **Code → Download ZIP**, extract the ZIP completely before running `start.bat`. v0.3.6 includes a Windows PowerShell 5.1-compatible startup launcher and persistent startup diagnostics.
