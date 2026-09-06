# Codenotch Accounts

**All your AI accounts. More room to ship.**

A native macOS account manager built directly on [Codenotch by Vinz](https://github.com/vinzdg/codenotch). Keep the screen-edge notch and usage rings; add separate Claude Code and Codex accounts, official browser sign-in, and one-click selection for your next session.

[Website](https://codenotch-accounts.alexandre-cormeraie.chatgpt.site) · [Releases](https://github.com/Connected-Mate/codenotch-accounts/releases)

## What it does

- Manage six or more accounts per provider. There is no six-account cap.
- Connect each account using the **unmodified official CLI's browser login**. No passwords, tokens or browser cookies are collected by this app.
- Name accounts, see connection state, usage windows and reset times, and choose a project folder.
- Select an account in one click and launch a new Claude Code or Codex terminal session with it.
- Enable automatic selection to choose an available account from fresh readings before a new launch.
- Keep the selected accounts in Codenotch's familiar notch, with the full list in a resizable native window.

**A selection applies to new sessions launched from this manager. It does not change an already-running process, switch Claude.ai/ChatGPT browser sessions, or sign the separate desktop apps into another account. Running work is never killed to switch an account.** Each subscription keeps its own limits and terms; this app does not create unlimited usage.

## Connect your first account

1. Install the official [Claude Code](https://code.claude.com/docs/en/quickstart) and/or [Codex CLI](https://developers.openai.com/codex/cli/).
2. Open Codenotch Accounts and choose a provider.
3. Add an account with a label and optional email hint, then select **Connect**.
4. Complete the provider's browser login. Repeat for your other accounts.
5. Select an account and a project folder, then launch a session.

The account manager never reads or replaces your existing default Claude Code or Codex login. New managed profiles start disconnected. Browser login is performed by you, and each provider remains responsible for its credentials and token refresh.

## How account isolation works

Each profile has a stable UUID directory under `~/Library/Application Support/Codenotch Accounts/profiles/`. Claude Code runs with that profile's `CLAUDE_CONFIG_DIR`; Codex runs with its `CODEX_HOME` and its official `keyring` credential storage. Credential/provider environment overrides are excluded from launched processes so another account or API key cannot silently take precedence.

The app stores account labels, identifiers and selection locally. Profile folders have owner-only permissions. The official tools may also keep their configuration and conversation history there. Do not sync, publish or share these folders. Removing a profile from the list leaves the vendor's local profile intact, as the confirmation explains.

### Usage accuracy

- **Codex:** read from the official app-server `account/read` and `account/rateLimits/read` methods.
- **Claude Code:** a per-profile status-line helper captures only the documented `rate_limits` fields. Readings appear after you use a managed Claude Code session. No undocumented subscription API is queried by the managed-account runtime.
- Unknown or old readings remain unknown or stale. They are excluded from automatic selection; a weekly or session limit at 100% also makes an account unavailable.

The upstream provider adapters remain in the source history for attribution and reference. This fork's composition root does not start those token-reading adapters.

## Build and install

Requires macOS 26+, Xcode 26+, and an internet connection for the initial dependency download. Apple Silicon and Intel are supported.

```sh
./Scripts/build-accounts.sh build
open build/AccountsDerivedData/Build/Products/Release/Codenotch.app
```

The build script downloads a pinned XcodeGen release and verifies its SHA-256. Homebrew is not required. Local builds use ad-hoc signing; distributed builds use this fork maintainer's own Developer ID.

To install your local build, copy `Codenotch.app` into Applications as **Codenotch Accounts.app**. It uses the independent bundle identifier `com.connectedmate.codenotch-accounts` and can coexist with upstream Codenotch.

### Tests

```sh
./Scripts/build-accounts.sh test
```

The test host skips application startup. Account tests use temporary directories, fake commands and synthetic status-line payloads, never your real credentials. The upstream notch, layout, usage-model and interaction tests are retained.

## Website

The public introduction is at [codenotch-accounts.alexandre-cormeraie.chatgpt.site](https://codenotch-accounts.alexandre-cormeraie.chatgpt.site). Its complete source is in `website/`. Run `npm ci`, `npm run dev`, or `npm run build` from that directory. The interactive account preview uses clearly labeled sample data; it never accesses local accounts.

Maintainers distributing a Developer ID build must run `Scripts/sign-release.sh APP_PATH 'Developer ID Application: …'`, notarize the resulting archive, and staple the accepted ticket before publishing. The signing helper signs each embedded Sparkle executable with a secure timestamp and strips development-only entitlements from the application.

## Updates and privacy

This fork never installs updates from upstream Codenotch's feed. Releases are distributed from this repository; no automatic updater is enabled until the fork has its own signed feed. There is no account backend, telemetry, credential proxy or cloud synchronization in the account manager.

## Attribution and license

Based on [vinzdg/codenotch](https://github.com/vinzdg/codenotch), copyright © 2026 Vinz, under the MIT license. Upstream design, notch implementation, icon and tests are credited to their author. Account management and this community distribution are maintained by Connected Mate. The original [LICENSE](LICENSE) is preserved.

Independent project; not affiliated with or endorsed by Anthropic or OpenAI.
