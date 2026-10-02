# Codex Dual Usage Dashboard

Windows desktop quota monitor for two ChatGPT/Codex accounts: Personal + Work.

Current version: **v0.9.0**

## Windows EXE client (recommended)

[Download the latest CodexUsage.exe](https://github.com/lv5accelerator-xy/codex-dual-usage-dashboard/releases/latest/download/CodexUsage.exe)

Double-click the EXE and select **安装并启动** in the installation window. It installs into `%LOCALAPPDATA%\CodexUsage` and creates desktop and Start menu shortcuts without administrator permissions. The client uses Windows .NET Framework 4.8 / Windows PowerShell 5.1; it does not require a separate .NET 8 or Electron runtime. The packaged client now reads quotas through a native C# background process. The PowerShell WinForms UI and login helpers remain embedded.

**Upgrading from the script version:** quit the old tray app, put the EXE in the old app folder, and run it once. If present, `ui-settings.json` and `profiles.json` are copied into the client's separate data directory. Existing `.codex-personal` / `.codex-work` login credentials stay where they are; no credentials are bundled or uploaded.

### Sharing and uninstalling

[中文安装与分享指南](docs/FRIENDS.md) — share the release link with friends; each person logs in with their own account. Do not share local account files or logs.

The client is listed as **Codex 额度** in Windows Settings → Apps. Quit the tray app before uninstalling. Uninstall removes program files and shortcuts while preserving settings and Codex account directories for reinstallation. No administrator privileges are needed.

Version 0.5.1 precompiles the drawing controls during the build. The packaged UI loads a DLL instead of compiling C# source at startup. Since v0.6.0 the packaged quota reader, download updater, window integration and drawing controls are C#. The UI orchestration and login helpers still use PowerShell; this is an incremental migration, not a completed pure C# rewrite or a guarantee against security warnings.

Releases include `READ-ME.txt` and `SHA256SUMS.txt` alongside the EXE and update manifest. Checksums verify consistency, not publisher identity.

### Automatic client updates

- Checks the repository's latest stable GitHub Release after startup and every six hours. This is background polling, not server push.
- Downloads newer versions automatically and verifies the size, SHA-256 checksum, and embedded executable version.
- Right-click **客户端更新 → 重启并更新** to apply a downloaded update immediately. Normal exit also installs it; the next launch uses the new version.
- Right-click **客户端更新 → 立即检查更新** to check manually.
- Installation uses an atomic file replacement and retains the previous EXE. A failed post-update UI startup attempts to restore the previous version.
- Account configuration, UI preferences and notification history are kept under `%LOCALAPPDATA%\CodexUsage\data`, outside the versioned program files. They survive updates.
- If offline or a download fails verification, the running version remains available. Client logs are in `%LOCALAPPDATA%\CodexUsage\client.log`.

The release EXE is **unsigned**; Windows may show a publisher/reputation prompt. SHA-256 checks provide download integrity, not publisher signing. Notifications remain subject to Windows notification settings.

### Building and releasing

Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File desktop/build.ps1` on Windows to create `dist/CodexUsage.exe` and `dist/update.json`.

GitHub Actions validates the source UI, builds the EXE, runs the packaged UI plus migration/integrity tests, and publishes a GitHub Release when `VERSION` is new. Published version assets are immutable: increment `VERSION` for each release. No developer API key or signing secret is required for the current unsigned build.

[Icon design and source assets](assets/README.md)

## iPhone / Mobile Dashboard

v0.8.0 adds **Codex Usage Mobile**, a small installable PWA for viewing Personal and Work quota from an iPhone. Windows remains the only component that reads Codex. It publishes an allowlisted usage snapshot through a separate encrypted ntfy topic; the browser authenticates and decrypts it locally.

### First-time setup

1. On Windows, right-click Codex 额度 and open **远程通知与手机额度**.
2. Check **启用手机额度同步**, generate or enter a pairing key, save, and copy the pairing key.
3. In this repository, enable GitHub Pages with **Settings → Pages → Source → GitHub Actions**. The expected site is `https://lv5accelerator-xy.github.io/codex-dual-usage-dashboard/`.
4. Open that HTTPS address in iPhone Safari, enter the relay address and pairing key, then tap **连接**.
5. In Safari choose **分享 → 添加到主屏幕 → 添加**. Open **Codex 额度** from the new icon.

The iPhone never receives Codex `auth.json`, access/refresh tokens, cookies, account IDs, Codex profile paths, session logs, or conversation content. The pairing key is stored in `localStorage` only when **在此设备记住配对密钥** is selected; otherwise it is kept for the current browser session only. It is never placed in the URL. If a phone is lost, generate a new pairing key on Windows and save it so the old phone cannot decrypt new snapshots.

[面向非开发人员的 iPhone 使用方法](docs/IPHONE.md) · [Mobile security review](docs/MOBILE-SECURITY.md) · [PWA developer notes](mobile/README.md)

The mobile refresh button fetches the latest relay snapshot. It does not remotely command the Windows computer or log in to Codex. The PWA shell works offline, but quota snapshots are not persisted by the service worker.

## v0.8.0: encrypted iPhone quota PWA

- Adds an opt-in, independently controlled mobile usage sync that can run without completion notifications.
- Reuses the v1 AES-256-CBC + HMAC-SHA256 message format while deriving a separate non-guessable usage topic.
- Queues a strictly allowlisted snapshot atomically after desktop refresh; the background worker handles network I/O, duplicate suppression, five-minute heartbeat, and retry backoff.
- Adds a zero-dependency installable PWA with latest-message polling, EventSource updates, foreground recovery, local countdowns, freshness/offline states, and an offline app shell.
- Adds GitHub Pages deployment plus PowerShell/JavaScript compatibility and privacy regressions.

## v0.7.0: cross-device Codex completion notifications

- Adds opt-in **跨电脑 Codex 完成通知** in the tray menu. Two PCs using the same pairing key can notify each other when a persisted Codex turn finishes.
- Watches the official local Codex rollout records under `.codex*/sessions/.../*.jsonl` and reacts to persisted `event_msg / task_complete` records rather than guessing from process exit.
- Sends device name, project folder, completion/error state and finish time. The final assistant response is **off by default** and can be enabled as an optional summary (capped at 800 characters).
- Relay payloads are encrypted and authenticated locally with keys derived from the pairing secret; the public relay topic is a SHA-256-derived identifier and does not contain the secret itself.
- Uses `https://ntfy.sh` as the default relay and supports a custom HTTPS ntfy-compatible endpoint (plain HTTP is allowed only for localhost).
- Deduplicates remote events by device/turn id and keeps a bounded local notification ledger. Existing historical turns are not replayed when the watcher starts.
- Includes offline regression tests for encryption/authentication, tamper rejection, project extraction, task-complete parsing, privacy defaults and relay URL validation.

## v0.6.2: bounded memory during repeated refreshes

- Avoid Windows PowerShell 5.1 `Select-Object -First` repeatedly decorating the same account object's type metadata. Direct account lookup prevents growing type-name strings and binding caches.
- Refresh displayed countdown/status text every 15 seconds; quota requests remain once per minute, and recovery/full-screen checks remain once per second. Manual refresh results still render immediately.
- Stop worker polling when idle, avoid reparsing unchanged updater status, and unregister card handlers/tooltips before disposal.
- Windows CI checks 2,000 idle status updates plus 240 accelerated refresh cycles, retained heap/private memory growth, collectible cards, and bounded process handles. These are accelerated fixture tests, not a claim of a real multi-hour soak or a fixed RAM ceiling on every PC.

## v0.6.1: account settings save fix

Fixes the Windows PowerShell path error when saving account names or enabled accounts. Atomic replacement now uses an explicit backup path. The Windows UI test clicks the actual Save button, reloads the saved JSON, verifies account paths are preserved, and exercises repeated saves.

## v0.6.0: accounts, recovery and desktop integration

- Compact quotas have **independent colors**. Exhausted 5h does not turn a healthy long-term value red. “总量” is renamed **长周期** throughout the current UI.
- At zero 5h quota, the second line shows a live **estimated recovery countdown**. Hover for the exact local reset timestamp. Once the reported reset is due, the UI requests one immediate refresh per account/reset, while regular one-minute polling continues. Missing and stale values never claim replenishment.
- **账号与首次使用** opens automatically on first run and is available from the right-click menu. Enable one or two account slots and edit display names (up to 12 characters). Disabled accounts are hidden and are not queried. Names and enablement are saved atomically in profiles.json; existing profile paths and login data are retained.
- Setup distinguishes missing CLI, missing login, existing credentials awaiting verification, and a fresh successful connection. “安装 CLI” / “登录 / 切换” opens the existing guided setup; “重新检测” rechecks installation and requests a quota refresh. A credential file alone is never labelled connected.
- **开机启动** and **全屏时隐藏悬浮窗** are opt-in, off by default. Startup uses the current user's Run registry entry and is removed on uninstall. Full-screen detection is scoped to the monitor containing the floating window; returning from the full-screen application restores the user's visibility preference.
- The native window layer handles per-monitor DPI changes, rescales controls, and periodically moves off-screen windows into a connected display's working area. Automated tests cover scaling roundtrips and negative-coordinate monitor geometry; mixed-DPI physical monitors still warrant real-device testing.
- Background client downloads show percentages and distinguish network, integrity, permission and disk errors. “立即检查更新” retries after failure; the installed version remains intact.
- The EXE uses a **C# quota reader** with bounded RPC waits, continuously drained stderr, independent per-account errors, and a Windows job object to clean up server children. The source/script launcher retains its PowerShell reader as a fallback. Native-reader tests talk to a local fixture server without account access.

This release advances the C# migration; it does not remove the Windows PowerShell runtime requirement for the UI and login workflow.

## v0.4.2: adjustable compact transparency and one-minute refresh

The compact strip defaults to **20% transparency** (80% opacity). Right-click **紧凑小窗透明度** and move the slider to choose **0–60% transparency**. Changes apply immediately and are remembered after restart. Windows opacity affects the entire compact window, including its text; hovering to expand restores full opacity for readability. The detail panel remains fully opaque.

Automatic quota refresh now runs every **60 seconds**. If a read is still running, the next tick is skipped rather than starting an overlapping worker.

## v0.4.1: compact mode, edge snapping, optional alerts

The monitor now starts as a **360 × 64 logical-pixel strip** (220 pixels wide with one enabled account). Each account shows **5h remaining / long-term remaining** as two independent percentages. “Long-term” means the limiting long-term quota (weekly or meaningful monthly/workspace quota), not the sum of windows. When 5h reaches zero, the second line shows the estimated time until recovery; the tooltip shows the exact local timestamp. Missing reset times remain unknown; expired reset times wait for a fresh reading; stale data asks for confirmation. Hover to expand the full 5-hour/long-term view; move away for about half a second to collapse. It stays expanded while the detail panel or context menu is open, and never changes size during a drag. Right-click **紧凑模式（悬停展开）** to keep the full monitor visible instead.

**贴边吸附** is enabled by default. Release the monitor within 20 logical pixels of a screen's working-area edge to snap to it. Taskbars and negative-coordinate monitors are supported. A bottom-docked strip expands upward and returns to the same resting position. Drag away to detach, or turn snapping off in the right-click menu.

**低额度通知 → 启用通知** is off by default. Threshold presets are **20% / 10%**, **10% only**, or **30% / 15%**. Notifications identify the account and quota window; clicking a notification opens the detail panel. Windows notification settings / Do Not Disturb may suppress delivery.

- Only fresh, successful reads crossing a threshold can notify. Failed, missing, stale, or already-expired quota data never triggers an alert.
- The first successful sample after startup, enabling notifications, or changing thresholds establishes a baseline without notifying.
- Each threshold is notified at most once per account and quota window/reset cycle. Crossing two thresholds in one read produces one message for that window.
- The deduplication ledger is retained locally in `logs/notification-state.json` across restarts. No credentials are stored in it.
- A new reset timestamp starts a new cycle. If no timestamp is available, recovery above all configured thresholds rearms alerts. A gap of ten minutes or more establishes a new comparison baseline without notifying.
- Compact/expanded preference, snapping, resting position, and notification preferences are saved in `ui-settings.json`. Collapsed values marked **!** are stale or unavailable; hover for details.

## Edge ring mode

Right-click **贴边圆环（点击查看详情）** to show each enabled account's **5h** and **long-term** remaining quota as separate rings. Drag the group to an edge: left/right edges use a vertical stack; top/bottom edges use a horizontal row. Click a ring to open details, hover for its full account name and freshness information, or right-click to switch back. The mode and position survive restarts. Compact opacity also applies to rings.

Missing values display **—**, exhausted quota displays **0%**, and stale values are muted and marked **!**. Ring mode stays compact while hovering. It always docks to the nearest working-area edge, independent of the optional snap setting for the other modes.

v0.9.0 also includes the Windows remote-worker HOME-variable fix from PR #4. Install and restart the new desktop build to apply it; a successful build alone does not verify real iPhone synchronization.

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

Hover over reset times for the exact local timestamp and monthly used/limit details. Smaller windows scroll vertically; refreshes preserve the scroll position. Layout dimensions scale with the Windows system DPI when the app starts. The native window layer handles per-monitor DPI changes; physical mixed-DPI monitor combinations have not all been tested.

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

For the source/script distribution, run `start.bat` normally, or `start-debug.bat` for startup diagnostics. Script mode does not install automatic client updates. Quit the existing tray instance before starting an updated version.

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

- `desktop/UsageReader.cs` — native packaged quota reader and child-process lifetime control
- `ui-experience.ps1` — account preferences, onboarding, recovery refresh and desktop options
- `tray.ps1` — floating monitor, detail panel, tray actions, refresh lifecycle
- `ui-model.ps1` — quota selection and account-specific freshness rules
- `ui-behavior.ps1` — edge snapping and notification crossing/deduplication rules
- `ui-controls.cs` — small native WinForms drawing controls compiled by PowerShell at startup
- `usage-reader.ps1` / `usage-worker.ps1` — existing quota reader and background worker
- `remote-crypto.ps1` / `mobile-sync.ps1` — shared message crypto and allowlisted mobile snapshot queue
- `remote-worker.ps1` — completion relay plus asynchronous mobile snapshot publishing
- `mobile/` — static iPhone PWA; no Node.js runtime dependency
- `codex-tools.ps1` / `setup-account.ps1` — CLI discovery and account login
- `profiles.json` — account labels and local profile paths
- `launcher.ps1` — encoding normalization, syntax check, startup watchdog
- `tests/` — presentation-rule regressions and Windows UI smoke test

The v0.3.9 runtime display patch has been removed. The launcher runs the checked-in UI directly.

## Security

Authentication stays in the user's local Codex profile directories. Never commit login credentials. Logs, runtime results, remote settings, pending mobile snapshots, UI preferences, test screenshots, and local Codex profiles are ignored by Git. The public Pages bundle contains only the app shell and no pairing key, topic, account data, or credentials.

## GitHub ZIP downloads

Extract **Code → Download ZIP** completely before running `start.bat`. The launcher normalizes PowerShell encoding for Windows PowerShell 5.1 and checks `tray.ps1` syntax before starting the UI. Keep `ui-controls.cs`, `ui-model.ps1`, and `ui-behavior.ps1` next to `tray.ps1`.

