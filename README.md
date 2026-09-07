# Builder Nutch

**Big ideas. Lean R&D. Keep building.**

Put the AI subscriptions you already pay for to work: more experiments, ambitious R&D and real products. Builder Nutch is a native macOS account manager built directly on [Codenotch by Vinz](https://github.com/vinzdg/codenotch). Keep the screen-edge notch and usage rings; add separate assistant accounts, official browser sign-in, and one-click selection for your next session.

[Website](https://connected-mate.github.io/builder-nutch/) · [Releases](https://github.com/Connected-Mate/builder-nutch/releases)

## What it does

- Manage six or more accounts per provider. There is no six-account cap.
- Choose a service with **Add assistant**, then sign in on its official page. No name or email field blocks sign-in.
- Automatically detect signed-in Claude Code, Codex and Kimi Code profiles already on this Mac; add more through their official tools.
- Open separate browser accounts for Grok, ChatGPT, Gemini, Perplexity, DeepSeek, Mistral and the Cursor dashboard. Web profiles use Google Chrome, Brave or Microsoft Edge; the Cursor editor keeps its own login.
- Add an optional nickname and emoji after sign-in; edit them whenever you like.
- See connection state, available usage windows and reset times, and choose a project folder.
- Select an account in one click and launch a new Claude Code, Codex or Kimi Code terminal session with it.
- Enable automatic selection to choose an available account from fresh readings before a new launch.
- Keep selected assistants in Codenotch's familiar notch, with the full list in a neutral white-and-gray window.
- Choose **Auto-hide** for an invisible notch that appears when the pointer reaches the selected screen edge. **Show on hover** keeps a small pill; **Off** disables the notch.

**A selection applies to new sessions launched from this manager. It does not change an already-running process, switch Claude.ai/ChatGPT browser sessions, or sign the separate desktop apps into another account. Running work is never killed to switch an account.** Each subscription keeps its own limits and terms; this app does not create unlimited usage.

## Connect your first account

1. Open Builder Nutch. Existing signed-in coding accounts appear automatically. To add another, click **Add assistant** (or press ⌘N).
2. Choose the service you want: Claude, Codex, Kimi, Grok, Cursor or another listed assistant.
3. Complete the official sign-in in the browser. For web profiles, return and choose **I've finished signing in**.
4. Optionally choose a nickname and emoji, then **Finish**. Repeat for your other accounts.
5. Use **Launch** for a coding assistant or **Open** for a browser account.

Coding assistants require their official [Claude Code](https://code.claude.com/docs/en/quickstart), [Codex CLI](https://developers.openai.com/codex/cli/) or [Kimi Code](https://www.kimi.com/code/docs/en/kimi-code-cli/) tool. Web assistants require [Google Chrome](https://www.google.com/chrome/), Brave or Microsoft Edge; they never reuse your default browser's shared account.

Existing coding profiles are checked through the official tools and linked automatically when signed in. Confirmed duplicate identities are skipped. Credentials stay in their original vendor storage, and existing configuration is not rewritten by the manager. New isolated profiles start disconnected. Browser login is performed by you, and each provider remains responsible for its credentials and token refresh.

## Updating from Codenotch Accounts

Builder Nutch is the new name for this fork. Install **Builder Nutch.app** and keep using your existing profiles. The application identity, preferences and profile locations remain stable, so the rename does not invalidate saved sign-ins. Close the old application before opening the new version.

## How account isolation works

Each new isolated profile has a stable UUID directory under `~/Library/Application Support/Codenotch Accounts/profiles/`. Claude Code runs with that profile's `CLAUDE_CONFIG_DIR`; Codex runs with its `CODEX_HOME` and its official `keyring` credential storage; Kimi Code runs with its `KIMI_CODE_HOME`. Credential/provider environment overrides are excluded from launched processes so another account or API key cannot silently take precedence.

Discovered profiles instead keep a reference to their original directory. Default Claude preserves its unsuffixed Keychain identity; discovered Codex preserves its original credential-store configuration; discovered Kimi preserves its original home. Removing a discovered profile records that choice so background discovery does not add it again.

Browser accounts each get a private `browser/` directory, and the browser chosen on first launch stays pinned to that profile. Browser authentication is confirmed by you, not inferred from cookies. A fixed managed `UserDataDir` policy blocks browser launch rather than sharing a company profile.

The app stores nicknames, emoji, identifiers, browser confirmation dates and selection locally. Profile folders have owner-only permissions. The official tools may also keep their configuration and conversation history there. Do not sync, publish or share these folders. Removing a profile from the list leaves the vendor's local profile intact, as the confirmation explains.

### Usage accuracy

- **Codex:** read from the official app-server `account/read` and `account/rateLimits/read` methods.
- **Claude Code:** recent official CLI versions provide the SDK `get_usage` control request, so subscription limits can be read before sending a model prompt. The reader sends only initialize and usage controls, disables user customizations, tools and MCP servers, and requests no session persistence. Five-hour, weekly and model-scoped constraints are included. This [official SDK interface is experimental](https://github.com/anthropics/claude-agent-sdk-typescript/releases/tag/v0.3.169); unsupported or unavailable responses remain unavailable. Older status-line readings may stay visible but a failed live check cannot mark them fresh for automatic selection.
- **Kimi Code:** subscription status and usage are read from an authenticated, temporary loopback instance of the official local web server. Its credentials remain vendor-owned.
- **Web profiles:** usage is available on each service’s website. Builder Nutch does not claim to verify browser sign-in or use these profiles for automatic quota selection.
- Unknown or old readings remain unknown or stale. They are excluded from automatic selection; a weekly or session limit at 100% also makes an account unavailable.

The upstream provider adapters remain in the source history for attribution and reference. This fork's composition root does not start those token-reading adapters.

## Build and install

Requires macOS 26+, Xcode 26+, and an internet connection for the initial dependency download. Apple Silicon and Intel are supported.

```sh
./Scripts/build-accounts.sh build
open "build/AccountsDerivedData/Build/Products/Release/Builder Nutch.app"
```

The build script downloads a pinned XcodeGen release and verifies its SHA-256. Homebrew is not required. Local builds use ad-hoc signing; distributed builds use this fork maintainer's own Developer ID.

To install your local build, copy **Builder Nutch.app** into Applications. It retains the independent bundle identifier `com.connectedmate.codenotch-accounts` and can coexist with upstream Codenotch.

### Tests

```sh
./Scripts/build-accounts.sh test
```

The test host skips application startup. Account tests use temporary directories, fake commands and synthetic status-line payloads, never your real credentials. The upstream notch, layout, usage-model and interaction tests are retained.

## Website

The public introduction is hosted on [GitHub Pages](https://connected-mate.github.io/builder-nutch/). Its complete source is in `website/`. From that directory, run `npm ci`, `npm run dev`, `npm run check`, or `npm run build`. The static build uses the `/builder-nutch/` base path and writes to `website/dist`. The website workflow checks pull requests and publishes successful builds from `main` through GitHub Actions. The website shows real screenshots captured from the running Mac app with personal details hidden. It never accesses local accounts.

Maintainers distributing a Developer ID build must run `Scripts/sign-release.sh APP_PATH 'Developer ID Application: …'`, notarize the resulting archive, and staple the accepted ticket before publishing. The signing helper signs each embedded Sparkle executable with a secure timestamp and strips development-only entitlements from the application.

## Updates and privacy

This fork never installs updates from upstream Codenotch's feed. Releases are distributed from this repository; no automatic updater is enabled until the fork has its own signed feed. There is no account backend, telemetry, credential proxy or cloud synchronization in the account manager.

## Attribution and license

Based on [vinzdg/codenotch](https://github.com/vinzdg/codenotch), copyright © 2026 Vinz, under the MIT license. Upstream design, notch implementation, icon and tests are credited to their author. Account management and this community distribution are maintained by Connected Mate. The original [LICENSE](LICENSE) is preserved.

Independent project; not affiliated with or endorsed by Anthropic or OpenAI.
