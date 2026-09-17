# Codex Dual Usage Dashboard

Windows desktop quota monitor for two ChatGPT/Codex accounts: Personal + Work.

Current version: **v0.4.2**

## v0.4.2: adjustable compact transparency and one-minute refresh

The compact strip defaults to **20% transparency** (80% opacity). Right-click **紧凑小窗透明度** and move the slider to choose **0–60% transparency**. Changes apply immediately and are remembered after restart. Windows opacity affects the entire compact window, including its text; hovering to expand restores full opacity for readability. The detail panel remains fully opaque.

Automatic quota refresh now runs every **60 seconds**. If a read is still running, the next tick is skipped rather than starting an overlapping worker.

## v0.4.1: compact mode, edge snapping, optional alerts

The monitor now starts as a **244 × 44 logical-pixel strip**. Each account shows its lowest meaningful remaining quota. Hover to expand the full 5-hour/long-term view; move away for about half a second to collapse. It stays expanded while the detail panel or context menu is open, and never changes size during a drag. Right-click **紧凑模式（悬停展开）** to keep the full monitor visible instead.

**贴边吸附** is enabled by default. Release the monitor within 20 logical pixels of a screen's working-area edge to snap to it. Taskbars and negative-coordinate monitors are supported. A bottom-docked strip expands upward and returns to the same resting position. Drag away to detach, or turn snapping off in the right-click menu.

**低额度通知 → 启用通知** is off by default. Threshold presets are **20% / 10%**, **10% only**, or **30% / 15%**. Notifications identify the account and quota window; clicking a notification opens the detail panel. Windows notification settings / Do Not Disturb may suppress delivery.

- Only fresh, successful reads crossing a threshold can notify. Failed, missing, stale, or already-expired quota data never triggers an alert.
- The first successful sample after startup, enabling notifications, or changing thresholds establishes a baseline without notifying.
- Each threshold is notified at most once per account and quota window/reset cycle. Crossing two thresholds in one read produces one message for that window.
- The deduplication ledger is retained locally in `logs/notification-state.json` across restarts. No credentials are stored in it.
- A new reset timestamp starts a new cycle. If no timestamp is available, recovery above all configured thresholds rearms alerts. A gap of ten minutes or more establishes a new comparison baseline without notifying.
- Compact/expanded preference, snapping, resting position, and notification preferences are saved in `ui-settings.json`. Collapsed values marked **!** are stale or unavailable; hover for details.

## Floating monitor

Run `start.bat` to open a compact rounded panel. Aligned columns show the remaining **5-hour** and **long-term** quotas for each account, with a visible update timestamp or stale-data warning.

| Account | 5-hour remaining | Long-term remaining |
| --- | ---: | ---: |
| Personal | 100% | 95% |
| Work | 49% | 21% |

*Example values, not live account data.*

- **长周期 (long-term)** is the lower remaining percentage of Weekly and a meaningful monthly/workspace limit. It is not a sum or a shared balance. Hover over it to see the source and individual values.
- **—** means the quota was not provided; **0%** means the reported quota is exhausted.
- Drag anywhere on the monitor to move it; click to expand/collapse the detail panel.
- Right-click for refresh, visibility, always-on-top, reset position, account login/switch, logs, and exit.
- Low remaining values are highlighted individually: amber at 35% or below, red at 15% or below. Old/unknown values are muted.

## Detail panel

The movable, resizable panel uses a neutral dark theme, consistent Chinese typography, larger primary numbers, rounded quota bars, and direct account login actions. All percentages represent **remaining** quota.

Quota order:

1. 5-hour remaining
2. Workspace/monthly remaining, when a meaningful limit is provided
3. Weekly remaining

Hover over reset times for the exact local timestamp and monthly used/limit details. Smaller windows scroll vertically; refreshes preserve the scroll position. Layout dimensions scale with the Windows system DPI when the app starts. Moving between monitors with different DPI settings may require restarting the app for crisp sizing; per-monitor dynamic DPI is not implemented.

## Refresh and data freshness

- Refresh runs silently every **1 minute** and can also be triggered manually.
- Both manual and automatic failures retain the last successful values and show **数据未更新**.
- One account can continue updating while the other retains its last successful data. Profiles are matched by ID, not array order.
- Data older than ten minutes is marked stale even if there is no explicit refresh error.
- A read taking longer than 150 seconds is timed out so refresh does not remain permanently disabled.
- Retained values are in-memory only. Restarting the app waits for a fresh read.

## Persistent UI settings

`ui-settings.json` remembers monitor position, detail-panel position/size, visibility, and always-on-top preference. Existing v0.3.x settings remain compatible. Settings are ignored by Git.

## Requirements

- Windows 10/11
- Windows PowerShell 5.1+
- Codex CLI
- The dashboard itself has no Node.js dependency

## First run

Run `first-run-setup.bat` to set up and log in two independent Codex homes:

- Personal: `%USERPROFILE%\.codex-personal`
- Work: `%USERPROFILE%\.codex-work`

Run `start.bat` normally, or `start-debug.bat` for startup diagnostics. Quit the existing tray instance before starting an updated version.

If startup fails, check `logs/startup.log`, `logs/startup-error.log`, `logs/tray.log`, and `logs/worker.log`.

## Validation

Quota selection, missing values, stale-data retention, recovery, and account ordering are tested without account access:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/ui-model.tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/ui-behavior.tests.ps1
```

On Windows, exercise the actual WinForms controls, resizing, and failure/loading states with fixture data:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tray.ps1 -SmokeTest
```

The smoke test does not start a quota worker, log in, or modify saved UI settings. It writes fixture screenshots to the ignored `artifacts/` directory. GitHub Actions runs both checks using Windows PowerShell 5.1 and publishes screenshots/logs in the `windows-ui-preview` artifact.

## Project files

- `tray.ps1` — floating monitor, detail panel, tray actions, refresh lifecycle
- `ui-model.ps1` — quota selection and account-specific freshness rules
- `ui-behavior.ps1` — edge snapping and notification crossing/deduplication rules
- `ui-controls.cs` — small native WinForms drawing controls compiled by PowerShell at startup
- `usage-reader.ps1` / `usage-worker.ps1` — existing quota reader and background worker
- `codex-tools.ps1` / `setup-account.ps1` — CLI discovery and account login
- `profiles.json` — account labels and local profile paths
- `launcher.ps1` — encoding normalization, syntax check, startup watchdog
- `tests/` — presentation-rule regressions and Windows UI smoke test

The v0.3.9 runtime display patch has been removed. The launcher runs the checked-in UI directly.

## Security

Authentication stays in the user's local Codex profile directories. Never commit login credentials. Logs, runtime results, UI preferences, test screenshots, and local Codex profiles are ignored by Git.

## GitHub ZIP downloads

Extract **Code → Download ZIP** completely before running `start.bat`. The launcher normalizes PowerShell encoding for Windows PowerShell 5.1 and checks `tray.ps1` syntax before starting the UI. Keep `ui-controls.cs`, `ui-model.ps1`, and `ui-behavior.ps1` next to `tray.ps1`.
