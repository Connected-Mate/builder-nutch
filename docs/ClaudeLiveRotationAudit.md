# Claude live rotation audit — 8 September 2026

Status: **PASS** — isolated native-keychain fixture proves A → immediate B → A after 37 seconds idle and marker cleanup, all within actual Claude 2.1.263 process PID 60066 and one conversation. Production files unchanged.

## What ran

`Scripts/test-claude-live-rotation.sh` compiles the actual production `ClaudeSystemCredentials`, `ClaudeNativeCredentialKeychain`, `KeychainInteraction`, `KeychainItem`, and `ClaudeProfile` with a standalone fixture. The only model stub is the unused app-shutdown cancellation error. It creates uniquely suffixed synthetic A/B subscription records, then starts one official Claude CLI 2.1.263 process with stream-JSON input/output, no tools, no session persistence, empty settings sources, and a loopback-only mock API. macOS sandbox denies non-loopback network access.

The first real process (PID 40213) completed its initial turn using `Bearer TEST-ONLY-A`. After production `copyLogin` changed its target, the next turn failed. A second fresh fixture failed its initial turn with `Not logged in · Please run /login`. macOS SecurityAgent requested permission for a synthetic item named `Claude Code subscription`. This invalidates the intended A → B and idle-after-35-second assertions; neither passed. Owned CLI, Python, and Swift processes exited. That unsafe initial fixture was stopped. The replacement below uses an explicit disposable keychain.

## Confirmed permission mechanism

Metadata-only disposable-item comparison, with native process interaction disabled:

| Creator | Decrypt trusted apps | Partition IDs |
| --- | --- | --- |
| Native unsigned Swift | fixture + `/usr/bin/security` | creator `cdhash:` only |
| Native product Developer ID | fixture + `/usr/bin/security` | `teamid:523L8BHNF8` only |
| Official `/usr/bin/security` | `/usr/bin/security` + fixture | `apple-tool:` only |

Trusted app ACL membership alone does not satisfy the separate partition check. The Swift process's `SecKeychainSetUserInteractionAllowed(false)` also does not suppress a child `security` process's dialogs.

Two proposed silent repairs were rejected by experiments:

- Adding `apple-tool:` to a newly created item's access using `SecKeychainItemSetAccess` returned `-25293` (`errSecAuthFailed`), even when the signed creator was explicitly included in the owner ACL.
- Supplying a partition ACL before `SecItemAdd` left a second system-generated creator-only partition; it did not produce valid shared access.

All disposable ACL audit items were deleted by their unique service/account selector, with status 0. No user password or real credential payload was read for these audits.

## Actual existing default account differs

A separately authorized, metadata-only read of exactly service `Claude Code-credentials`, account `0104389S`, returned one item:

- Partitions: `teamid:523L8BHNF8`, `apple-tool:`.
- Decrypt trusted app basenames: `Builder Nutch.app`, `Codenotch.app`, `security`.

The current default account already has the intended sharing permissions. The native-create fixture weakness does **not** establish the cause of the user's current existing-account failure. No real ACL was modified.

## Primary sources

- [Apple: SecAccessCreate](https://developer.apple.com/documentation/security/secaccesscreate(_:_:_:)): trusted app list controls the restricted operation ACL.
- [Apple Security source: securityd/src/acls.cpp](https://github.com/apple-oss-distributions/Security/blob/main/securityd/src/acls.cpp): lines 81–87 restrict partition changes without database credentials; lines 109–124 apply partition validation separately; lines 154–168 enforce partition membership and optionally request consent.

## Local evidence

- `/tmp/claude-live-rotation-run.log`, `/tmp/claude-live-rotation-run2.log`.
- `/tmp/claude-dummy-acl-probe.swift`, `/tmp/claude-dummy-acl-probe.log`.
- `/tmp/claude-dummy-acl-probe-signed.log`.
- `/tmp/claude-dummy-acl-owner-probe.swift`, `/tmp/claude-dummy-acl-owner-probe.log`.
- `/tmp/claude-dummy-acl-create-probe.swift`, `/tmp/claude-dummy-acl-create-probe.log`.
- `/tmp/claude-default-acl-metadata.swift`, `/tmp/claude-default-acl-metadata.log`.

## Safe replacement fixture

The final runner creates a disposable private keychain with a known TEST-ONLY password, signs its Swift fixture with the product Developer ID, and injects an adapter whose native Security queries include that exact `SecKeychainRef`. All production `copyLogin` logic remains unchanged. The CLI's PATH starts with a helper that rejects every command except the exact expected service/account lookup and always appends the disposable keychain's absolute path. No user default or search-list lookup is possible through the helper.

Before launching Claude, metadata checks require exactly the signed fixture and `/usr/bin/security` in the decrypt ACL. Modern keychains require exactly the team and `apple-tool:` partitions. A private legacy keychain is accepted only after an explicit metadata dump confirms version 256 and no partition entries; Apple's securityd skips partition checks for that old format. Search lists are compared before setup, before launching, and after cleanup. The fixture never changes the search list.

Run intentionally on this Mac with `Scripts/test-claude-live-rotation.sh`. It needs the installed official CLI, Swift compiler, and the configured product signing identity. It uses synthetic data only and kernel-enforced loopback-only network access.

Final passing evidence: `docs/ClaudeLiveRotationProof.json`; run log `/tmp/claude-live-rotation-isolated-final.log`. Both disposable private keychains were removed after testing. The 35-second marker lifetime did not prevent the next turn from reading the newly selected token.


## Cancellation and current-source compatibility follow-up

The Python driver now owns a separate CLI process session. SIGTERM/SIGINT cleanup terminates the entire process group, including descendants, escalates stubborn processes, and verifies exit. Cancellation during `Popen` is deferred until the returned handle is assigned. Swift waits for the driver and requires its successful cleanup acknowledgment before deleting fixture credentials; uncertain cleanup retains the disposable keychain.

The standalone runner now compiles `ClaudeTokenRefresh.swift` and supplies minimal fixture-only dependencies. An injected renewal callback always throws, preventing token renewal outside the loopback fixture. The updated harness compiled against current product sources without running it. Three synthetic subprocess tests cover a stubborn child, descendants, and cancellation during process creation. No Claude, Security, keychain, or network calls were made during these cancellation tests. The earlier live rotation evidence remains historical; this follow-up did not rerun that live fixture.

## 9 September 2026 — partition loss on the real item, helper fallback

Status: **PASS** with Claude Code 2.1.266 (`docs/ClaudeLiveRotationProof.json`, PID 30450, A → B → A in one conversation).

Root cause of the user-visible "switch never happens": the real `Claude Code-credentials` item's partition list had become `apple-tool:` only (the `teamid:523L8BHNF8` entry seen on 8 September was gone after the CLI's own rewrite that morning). The trusted-application list still named `Builder Nutch.app`, yet every native read returned `-25293`, so the app paused itself and the Mac login stayed on the old subscription. `/usr/bin/security` read the same item silently.

Fix: `ClaudeResilientCredentialKeychain` tries the native path and, only on `errSecAuthFailed` / `errSecInteractionNotAllowed`, routes that service through `ClaudeSecurityToolKeychain` (`security find-generic-password -w` for reads, `security -i` with `add-generic-password -U` on stdin for writes, read-back verification, scrubbed environment, 30 s timeout, no TTY). The choice is sticky per service so every snapshot compared inside one transaction comes from one backend. No ACL or partition is modified.

Real-login proof (production `AccountManager.launch`, opt-in `Tests/LiveClaudeSwitchTests.swift`): Mac login moved from the previous subscription to "Claude 3", `~/.claude.json` identity followed, the Keychain item was updated in place (ACL and partition dump identical before and after), the cache marker was written, and a fresh `claude -p` request succeeded on the new login. An account whose saved refresh token was already revoked ("Claude 2") is correctly reported as needing a new sign-in and is never switched to.

### Evening follow-up — the mirror problem

Clicking **Se connecter** on a saved profile made Claude Code's own `security` call show macOS's password dialog ("security wants to access key Claude Code-credentials-ce59c889"). Every profile item the app had created natively carried the partition `teamid:523L8BHNF8` only, which Apple's helper (partition `apple-tool:`) cannot pass without the login Keychain password.

Fix: new items are always created through the helper (`add-generic-password` without `-U`), and `ClaudeResilientCredentialKeychain.shareWithHelper` moves existing native items once (native ACL inspection → native delete of every app-owned duplicate → helper add → read-back; native restore on failure). It runs at app start and before every profile sign-in or launch. After the installed app restarted, all six profile items showed `apps: security | partitions: apple-tool:`, the diagnostics reported `readableByClaude: true`, and `CLAUDE_CONFIG_DIR=<profile> claude -p` answered without any prompt.
