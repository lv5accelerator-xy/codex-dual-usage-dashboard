# Codex Usage Mobile

This directory is a zero-dependency static PWA. It can be served from any HTTPS static host; the repository deploys only this directory to GitHub Pages.

## Data flow

Windows reads local Codex rate limits, builds an allowlisted display snapshot, and writes `mobile-usage-pending.json` atomically under DataRoot. `remote-worker.ps1` encrypts the newest snapshot and posts it to a dedicated ntfy topic. The browser derives the same topic from the user-entered pairing key, verifies HMAC-SHA256, decrypts AES-256-CBC with Web Crypto, validates the schema, and renders it.

The PWA never contacts Codex. It has no account system, analytics, telemetry, framework, build step, or runtime dependency. Node.js is used only for repository tests.

## Local validation

From the repository root:

```powershell
node --check mobile/crypto.js
node --check mobile/model.js
node --check mobile/app.js
node --check mobile/sw.js
node tests/mobile.tests.js
```

Serve `mobile/` from `localhost` to exercise setup and responsive layout. Service workers require HTTPS or localhost. Real relay data requires a Windows client configured with the same relay and pairing key.

## Storage and caching

- Relay URL: `localStorage`.
- Pairing key: `sessionStorage` by default; `localStorage` only after explicit opt-in.
- Decrypted snapshot: memory only.
- Service worker: fixed same-origin app shell allowlist only. ntfy responses, pairing keys, topics, and snapshots are not cached.
