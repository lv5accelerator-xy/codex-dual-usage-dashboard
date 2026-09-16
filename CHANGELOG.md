# Changelog

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
