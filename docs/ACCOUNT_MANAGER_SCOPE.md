# Codenotch Accounts

This community fork builds directly on [vinzdg/codenotch](https://github.com/vinzdg/codenotch), under its MIT license. Preserve the notch and usage presentation while adding unlimited local account profiles for Claude Code and Codex.

## Connection model

Each account has a UUID, human label, vendor, and a stable configuration directory inside this app's Application Support folder. Only metadata is persisted by the account catalog. The unmodified vendor CLI owns browser authentication, credential persistence and token refresh. No browser cookies, password capture, custom OAuth client, token proxy, or credential export.

Claude Code uses `CLAUDE_CONFIG_DIR`, `claude auth login --claudeai`, and `claude auth status --json`. Managed profile quota snapshots come from the documented status-line payload, not an undocumented subscription endpoint. Codex uses `CODEX_HOME`, its browser login and app-server account/read and account/rateLimits/read APIs; configure its official macOS keyring storage.

Selection changes future sessions launched from this manager. Existing processes retain their original account and must never be killed or falsely described as switched. Automatic selection uses only fresh, verified usage from connected accounts of the same vendor and affects future launches. Unknown, stale, blocked or disconnected accounts are not automatic candidates. Existing default CLI configuration and authentication remain untouched.

## Acceptance

- Connect, name, rename, select, launch, refresh and remove six or more profiles per vendor.
- Serial browser login, visible pending/cancel/error states, no secrets in logs or UI.
- Per-profile quota and reset information, explicit unknown/stale states.
- One selected account per vendor; deterministic, testable automatic account choice.
- New sessions launch using the chosen profile and project folder.
- Preserve original app alongside the independently identified fork.
- Unit tests use fake subprocesses and temporary directories, never live credentials.
- Public repository retains upstream attribution; marketing describes shipped behavior honestly.

## Primary references

- https://code.claude.com/docs/en/authentication
- https://code.claude.com/docs/en/env-vars
- https://code.claude.com/docs/en/statusline
- https://code.claude.com/docs/en/legal-and-compliance
- https://developers.openai.com/codex/auth/
- https://developers.openai.com/codex/app-server/
