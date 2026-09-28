# Mobile security review

The v0.8.0 mobile channel was reviewed against the following boundaries.

| Question | Control |
| --- | --- |
| Can a pairing key enter Git? | `remote-notifications.json` and all mobile runtime files are ignored; tests use a public fixture-only key. |
| Can a pairing key enter a URL? | The app derives the topic locally and never adds the key to query strings or fragments. Relay URL validation rejects query strings, fragments, and embedded credentials. |
| Can a pairing key enter logs or the Pages bundle? | Neither PowerShell nor JavaScript logs it. The static bundle contains no runtime key. |
| Can the snapshot read `auth.json` or tokens? | Snapshot generation receives the already-built display model and copies only explicit fields. It has no credential-reader code. |
| Are account IDs, Codex homes, absolute paths, logs, or conversation data exported? | The allowlist excludes them. Regression tests inject sentinel secrets and verify absence. Completion summaries remain on the separate completion channel. |
| Is the ntfy topic guessable? | It is the first 192 bits of SHA-256 over a domain-separated prefix and the pairing key. The completion topic is separate and unchanged. |
| Is ciphertext authenticated before parsing? | Browser and PowerShell split the package, verify HMAC-SHA256 in constant-time/subtle crypto, then decrypt AES-256-CBC and parse JSON. |
| Can errors expose plaintext or secrets? | Errors use fixed UI text. No decrypted payload or key is written to console, DOM error details, telemetry, or worker logs. |
| Does the service worker cache sensitive data? | It caches a fixed same-origin shell allowlist only and ignores all cross-origin ntfy traffic. Decrypted quota data is memory-only. |
| Can mobile failure break desktop refresh? | Desktop only performs a guarded atomic local write. All HTTPS calls and retry backoff run in `remote-worker.ps1`. |

Security model: a device possessing the pairing key can derive the topic and decrypt future snapshots. There is no server-side user account or revocation list. Rotating the pairing key on Windows revokes an old device for future snapshots.
