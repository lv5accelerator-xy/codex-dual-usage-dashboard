# Codex Dual Usage Dashboard

Windows desktop floating quota monitor for two ChatGPT/Codex accounts (Personal + Work).

Current version: **v0.3.8**

## Main experience

After `start.bat`, the app now starts as a small always-available **desktop floating ball** instead of opening the full quota window.

The ball displays compact Personal / Work quota summaries:

```text
P 95%
W 21%
CODEX
```

- Drag the ball anywhere on the desktop.
- Left-click the ball to expand/collapse the full quota panel.
- Right-click the ball for refresh, visibility, always-on-top, reset position, account login/switch, logs, and exit.
- The ball ring changes color according to the lowest meaningful remaining quota.

## Resizable detail panel

The expanded quota panel is now a normal resizable tool window:

- Move it anywhere.
- Resize width and height freely.
- The account cards and progress bars adapt to the current width.
- Closing the panel only hides it; the floating ball keeps running.
- The fixed header and quota area use separate layout rows, so the Personal card is no longer rendered underneath the header.

## Persistent UI settings

The app saves local UI preferences to:

```text
ui-settings.json
```

It remembers:

- Floating ball X/Y position
- Detail panel X/Y position
- Detail panel width/height
- Floating ball visibility
- Always-on-top preference

`ui-settings.json` is ignored by Git and is never uploaded to the repository.

## Quotas shown

- Personal account: 5-hour limit and weekly limit
- Work account: monthly workspace limit (when provided), 5-hour limit, and weekly limit
- Remaining percentage
- Time until reset

The floating ball uses the meaningful 5-hour/weekly limits and only includes a monthly limit in its summary when that monthly limit has a positive limit value.

## Automatic refresh

The app refreshes in the background every **5 minutes**.

Automatic refresh is silent in v0.3.8: the existing panel stays visible while new data is loaded. If a background refresh fails, the previous successful data remains on screen.

You can also refresh immediately from:

- The panel's **刷新** button
- Right-click floating ball → **立即刷新**
- Right-click tray icon → **立即刷新**

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

The floating ball appears near the lower-right area of the primary display the first time. After you drag it, its position is remembered.

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

## Tray / floating-ball menu

- 展开 / 收起额度面板
- 立即刷新
- 显示悬浮球
- 始终置顶
- 重置界面位置
- 账号登录 / 切换
  - 个人账号
  - 工作账号
- 打开日志文件夹
- 退出

If you hide the floating ball, the system-tray icon remains available so you can show it again.

## Diagnostics

```text
diagnose.bat
test-usage.bat
```

Runtime logs are written to `logs/` and are intentionally ignored by Git.

## Security

The repository does not contain ChatGPT/Codex login credentials. Authentication files remain in the user's local Codex profile directories and should never be committed.

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

- `tray.ps1` — floating ball, resizable panel, tray icon, rendering, refresh timers
- `usage-reader.ps1` — Codex app-server quota reader
- `usage-worker.ps1` — background refresh worker
- `codex-tools.ps1` — Codex CLI discovery/helpers
- `setup-account.ps1` — account setup/login logic
- `profiles.json` — profile labels and local Codex home paths
- `launcher.ps1` — Windows PowerShell 5.1 source normalization, syntax check, startup watchdog
- `start.bat` — normal hidden startup
- `start-debug.bat` — visible/debug startup through the same launcher

## GitHub ZIP note

If you download the repository using **Code → Download ZIP**, extract the ZIP completely before running `start.bat`. The launcher normalizes PowerShell files for Windows PowerShell 5.1 and validates `tray.ps1` before starting the floating UI.
