# Changelog

## 0.7.0 - 2026-09-22

- Added opt-in cross-device notifications for completed Codex turns.
- Detects persisted Codex `task_complete` events from local rollout JSONL sessions instead of relying on process exit.
- Added encrypted/authenticated relay messages, hashed pair topics, per-device identities, event deduplication and optional final-response summaries.
- Added a tray configuration dialog with pairing-key generation, custom HTTPS relay support and test notifications.
- Added offline regression coverage for encryption, tamper detection, task parsing, privacy defaults and relay validation.


## 0.5.0 - 2026-09-17

- Added a single Windows EXE with an embedded UI payload, per-user installation, and desktop/Start menu shortcuts.
- Added background stable-release checks, automatic verified downloads, restart-to-update actions, exit-time installation, and a previous-version rollback copy.
- Separated client data from versioned application files and migrated adjacent legacy settings/account configuration on first install.
- Added the dual lavender/mint quota icon to the EXE, shortcuts, window, and system tray.
- Added Windows client build, packaged native UI testing, update integrity/migration tests, and automated versioned GitHub Releases.

## 0.4.2 - 2026-09-17

- Made the compact strip 20% transparent by default, with a persistent 0–60% transparency slider in the right-click menu.
- Restored full opacity while expanded to keep quota details readable.
- Changed automatic quota refresh from five minutes to one minute, preserving the no-overlap worker guard.
- Added native opacity-slider and refresh-interval regression checks.

## 0.4.1 - 2026-09-17

- Added a compact two-account strip with hover expansion and delayed collapse; dragging and open menus never trigger a size change.
- Added optional edge snapping within 20 logical pixels of each monitor's working area, with stable bottom-edge expansion and persistent resting positions.
- Added opt-in Windows low-quota notifications with 20/10, 10-only, and 30/15 percent threshold presets.
- Notifications use only fresh successful reads, establish silent initial baselines, coalesce threshold crossings, and persist per-account/window/reset-cycle deduplication across restarts.
- Added regression coverage for negative monitor coordinates, stale/failed/missing data, threshold crossing, reset cycles, and JSON-restored notification state.
- Extended Windows native smoke tests for compact rendering, hover, drag guards, edge anchoring, and notification menu preferences.

## 0.4.0 - 2026-09-16

- Replaced the crowded circular monitor with a rounded, DPI-scaled two-account panel with aligned 5-hour and long-term quota columns.
- Renamed the ambiguous total label to 长周期 and added tooltips identifying the limiting weekly or meaningful monthly/workspace quota.
- Refined the detail panel with neutral dark surfaces, unified Chinese typography, prominent remaining values, rounded bars, and account-level login actions.
- Preserved last successful data on both manual and automatic refresh failures, including independent account failures matched by account ID.
- Added visible stale-data states to the floating panel and detail cards, a ten-minute freshness check, and a refresh timeout.
- Preserved scrolling across refreshes and moved account content into layout containers with system-DPI scaling.
- Integrated display behavior into the checked-in UI and removed the runtime v0.3.9 source patch.
- Added quota-state regression tests and a Windows PowerShell 5.1 native UI smoke test with fixture screenshots.

## 0.3.9 - 2026-09-16

- Floating monitor now shows the 5-hour quota before the longer-window/total quota for both Personal and Work accounts.
- Floating format changed to `5H / 总`, with separate Personal and Work rows.
- `总` uses the meaningful long-window quota: Weekly, plus a valid workspace/monthly limit when available.
- Enlarged the floating monitor slightly so both values remain readable while keeping the circular floating style.
- Reordered the detailed Work card to show 5-hour first, workspace/monthly total second, and Weekly third.
- Kept the 5-minute silent automatic refresh and saved position/size behavior.

## 0.3.8 - 2026-09-16

- Replaced the always-open dashboard workflow with a desktop floating ball plus on-demand detail panel.
- Floating ball shows Personal and Work remaining quota summaries and changes accent color as the lowest remaining quota drops.
- Added drag-and-drop positioning for the floating ball.
- Made the detailed quota panel freely resizable and movable.
- Added persistent `ui-settings.json` storage for floating-ball position, panel position/size, visibility, and always-on-top preference.
- Added right-click actions for refresh, show/hide floating ball, always-on-top, reset position, account login/switch, logs, and exit.
- Kept the 5-minute automatic refresh, but automatic refresh is now silent and preserves the current panel while new data is loaded.
- Rebuilt the panel with a two-row layout so the fixed header can never cover the Personal account card.
- Simplified `launcher.ps1`; it now normalizes encoding and launches the checked v0.3.8 source directly instead of applying runtime UI patches.

## 0.3.7 - 2026-09-16

- Fixed the Personal account card being rendered underneath the fixed header.
- Replaced the quota content area's `Dock=Fill` layout with an explicit area below the 58px header.
- Increased the minimum client height so both account cards fit without the header covering the first card.
- Kept the existing automatic refresh interval at 5 minutes.

## 0.3.6 - 2026-09-16

- Fixed `Path.GetFullPath` startup failure in `launcher.ps1` on Windows PowerShell 5.1.
- Removed the invalid use of `$MyInvocation.MyCommand.Path` from inside the normalization function.
- Replaced `Start-Process` startup with `System.Diagnostics.ProcessStartInfo`.
- Added a PowerShell syntax check for `tray.ps1` before launch.
- Kept automatic UTF-8 BOM normalization for GitHub ZIP downloads.

## 0.3.5 - 2026-09-16

- Fixed silent startup exits after downloading the repository from GitHub.
- Removed VBS/Windows Script Host from the primary startup path.
- Added `launcher.ps1` startup watchdog and `startup-error.log` diagnostics.
- Normalized GitHub-downloaded PowerShell source files locally for Windows PowerShell 5.1 before launch.
- Updated `start-debug.bat` and version metadata.

## 0.3.4
- Added dark technology-style dashboard UI.
- Fixed initial scroll position so the Personal card is fully visible.
- Added adaptive popup height while preserving scrolling for smaller displays.
- Refined quota colors, typography, cards, and refresh button styling.

## 0.3.3
- Fixed PowerShell `$HOME` read-only automatic-variable collision during result rendering.
- Added checks for other reserved PowerShell automatic variables.

## 0.3.2
- Fixed ambiguous `System.Drawing.Font` overload on Windows PowerShell 5.1.

## 0.3.1
- Reworked startup so the tray initializes before quota I/O.
- Moved account reads into an independent background worker.
- Added persistent tray/worker logs.

## 0.3.0
- Removed Node.js dependency.
- Rebuilt the application as a PowerShell/WinForms tray utility.

## 0.2.x
- Improved Codex CLI discovery and Windows login workflow.
- Added Personal and Work account separation.

## 0.1.0
- Initial dual-account quota dashboard prototype.
