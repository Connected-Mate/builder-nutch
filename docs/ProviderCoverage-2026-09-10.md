# Provider usage coverage — verified 10 September 2026

Read-only audit of what Builder Nutch actually reads today, what was verified live
on this Mac, and what is feasible next. No source file was modified to produce it.

## The headline finding

The shipping app has **two provider stacks, and only one is wired**.

| Stack | Files | Wired into the running app? |
|---|---|---|
| `AccountManager` + `AccountQuotas` + `KimiAccountIntegration` | `Sources/Accounts/*` | **Yes.** `Sources/App/AppDelegate.swift:51` builds it, `AppDelegate.swift:175` fills the notch from `AccountProvider.allCases`. |
| `UsageProvider` adapters (Cursor, Antigravity, GLM, Perplexity, Claude OAuth, Codex local) | `Sources/Providers/*` | **No.** `UsageStore` is the only consumer and `UsageStore(` is never called anywhere in `Sources/`. Tests exercise the parsers directly. |

`grep -rn "UsageStore("` over `Sources/` returns nothing. The README already says the
upstream adapters "remain in the source history for attribution and reference"; this
report confirms that literally — **Cursor, Antigravity, GLM and Perplexity usage is not
read by the running app at all**, however good those parsers are.

In the live app, `AccountProvider.isBrowserProfile` (`Sources/Accounts/AccountModels.swift:20`)
is true for everything except `claude`, `codex`, `kimi`. Browser profiles are launchers
only — they open an isolated Chrome/Brave/Edge profile and read no quota.

So the honest answer to "does the app really get the limits?" is:

- **Yes, live and official:** Claude Code, Codex, Kimi Code.
- **No, nothing is read:** Cursor, Grok, ChatGPT, Gemini/Antigravity, Perplexity, DeepSeek, Mistral, GLM.

---

## Claude Code

| | |
|---|---|
| **Today** | `GET https://api.anthropic.com/api/oauth/usage`, header `anthropic-beta: oauth-2025-04-20`, OAuth token read non-interactively from the vendor Keychain. `Sources/Accounts/ClaudeQuietUsageReader.swift:17` (live path) and `Sources/Providers/ClaudeOAuthProvider.swift:22` (dead adapter, same endpoint). |
| **Windows yielded** | `five_hour`, `seven_day`, `seven_day_oauth_apps`, `seven_day_opus`, `seven_day_sonnet`, plus `model_scoped` rows and any unknown key carrying `utilization` — `Sources/Accounts/ClaudeAccountUsage.swift:54-73`. Each carries `utilization` (0-100) and `resets_at`. |
| **Verified on this Mac** | Not re-probed. Doing so needs a Keychain read, and the mission forbids interactive Keychain use. Nine Claude accounts are registered in `accounts.json`, one of them the discovered `~/.claude` profile. |
| **Fidelity** | Official. Anthropic's own numbers, same endpoint as `/usage` in the CLI. |
| **Rotation** | Already implemented and proven: the Keychain login plus `oauthAccount` identity are swapped in place, live sessions follow on their next request (`docs/ClaudeLiveRotationProof.json`). |
| **Risk** | Undocumented endpoint. A shape change degrades to "unavailable", never to a wrong number. |

## Codex

| | |
|---|---|
| **Today** | Spawns `codex app-server` and speaks JSON-RPC: `initialize`, `initialized`, then `account/rateLimits/read`. `Sources/Accounts/AccountManager.swift:585` for the live path, `Sources/Providers/CodexBridge.swift:62-108` for the dead adapter. Discovered profiles run `app-server` bare; isolated ones add `--config cli_auth_credentials_store="keyring"`. |
| **Windows yielded** | `rateLimitsByLimitId` → per-bucket `primary`/`secondary`, each with `usedPercent`, `windowDurationMins`, `resetsAt`. 300 min is labelled "5h limit", 10080 min "Weekly limit". Bucket `codex` is labelled "All Codex models" so a shared allowance is not mistaken for one model's. Also reads `rateLimitReachedType` and marks the account unavailable for automatic selection. `Sources/Accounts/AccountQuotas.swift:52-89`. |
| **Verified on this Mac** | `codex` present at `~/.agentation/bin/codex`; `~/.codex/auth.json` exists. Not probed live (spawning `app-server` while other agents build was avoided). |
| **Fidelity** | Official. |
| **Fallback (dead adapter only)** | `Sources/Providers/CodexLocalProvider.swift` parses `rate_limits` out of the newest rollout JSONL. Not used by the app. |

## Kimi Code — **verified live today**

| | |
|---|---|
| **Today** | Launches the vendor's own local web server in a throwaway instance: `kimi web --no-open --host 127.0.0.1 --port <ephemeral>` with `KIMI_CODE_PASSWORD` set to a fresh UUID pair, then `GET /api/v1/auth` and `GET /api/v1/oauth/usage` with `Authorization: Bearer <that password>`. `Sources/Accounts/KimiAccountIntegration.swift:44-122`. Startup banner is redirected to `/dev/null` because it can contain the CLI's persistent bearer token (`:66-70`). |
| **Verified on this Mac** | **Yes.** Reproduced the exact read path against `~/.kimi-code`. `/api/v1/auth` → `{"ready":true,"managed_provider":{"name":"managed:kimi-code","status":"authenticated"}}`. `/api/v1/oauth/usage` → `summary` = *Weekly limit, used 1, limit 100, "resets in 2d 6h 36m"*; `limits[0]` = *5h limit, used 3, limit 100, "resets in 36m"*; `extra_usage` null. |
| **Windows yielded** | Weekly + 5h, both as percentages of 100. |
| **Gap found, since fixed** | The server returns **`reset_hint` only, never `reset_at`**, so Kimi rings had no reset time while Claude and Codex did. Fixed the same day: `KimiAccountIntegration.swift:202` now falls back to `ResetHint.date(from:now:)` and stamps `derivedReset: true` on the window (`Sources/Model/UsageModel.swift:49-50`), so the countdown can be shown as approximate. Both live shapes parse (`resets in 2d 6h 36m`, `resets in 36m`); anything not fully understood yields no date rather than a guess. |
| **Version note** | `isSubscriptionAuthenticated` accepts both `models_ready` and `ready` (`:147`). This install answers `ready`. Correct as written. |
| **Fidelity** | Official — Moonshot's own server, the same numbers `/usage` shows in the CLI. |

### The duplicate row, explained

Both rows are real accounts in `accounts.json`, and they hold the **same Moonshot
subscription**:

| Row | Kind | Directory |
|---|---|---|
| `Kimi` (`7B434B44…`) | isolated profile created in the app | `~/Library/Application Support/Codenotch Accounts/profiles/7b434b44-…/` |
| `Kimi · on this Mac` (`8E6927BA…`) | discovered profile | `~/.kimi-code` |

Decoding the JWT in each profile's `credentials/kimi-code.json` (payload claims only,
no secret printed) gives:

| Profile | `user_id` / `sub` | `device_id` | `token_id` |
|---|---|---|---|
| `~/.kimi-code` | `sha1:02f9fc585189` | `sha1:4e5a9e3367ef` | distinct |
| isolated `7b434b44…` | `sha1:02f9fc585189` | `sha1:1c515a85d3ae` | distinct |
| legacy `~/.kimi` | `sha1:02f9fc585189` | `sha1:283263a255a9` | distinct |

**Same `user_id`, same `sub`, same `iss`, same `client_id`. Different device and token
ids.** One subscription, three device registrations. The two rings will always move
together, and rotation between them buys nothing.

**Why the app does not catch it.** `discoverExistingAccounts` dedupes on exactly one
signal — a verified email (`Sources/Accounts/AccountManager.swift:737-738`):

```swift
if let email = state.email?.lowercased(), !email.isEmpty,
   accounts.contains(where: { $0.provider == candidate.provider && … == email }) { continue }
```

`KimiAccountIntegration.state(...)` never sets `email`; the local server exposes no
`userinfo` route (`GET /api/v1/oauth/userinfo` → 404, confirmed today). So the guard is
vacuous for Kimi. The two directory guards do not help either: the isolated profile is
under the app's own storage root and the discovered one is `~/.kimi-code`, so the paths
genuinely differ.

**Rule proposed here, and shipped the same day by `nutch-health`.** Verified in the
tree at the time of writing:

1. `ExistingAccountProfile.kimiSubscriptionFingerprint()` (`ExistingAccountProfile.swift:82-93`)
   reuses the credentials file `kimiAuthenticationStatus()` already opens, base64url-decodes
   the JWT payload, takes `user_id` and falls back to `sub`, and returns
   `SHA256("kimi:" + subject)` as hex. The raw claim is never stored or logged.
2. `ManagedAccountState.identity: String?` sits beside `email` (`AccountModels.swift:122`),
   stamped for Kimi on both the isolated and the discovered read paths.
3. The discovery guard (`AccountManager.swift:735-745`) now skips a candidate when a
   connected account of the same provider matches on **email or identity**.
4. Fail open as asked: an unreadable token or a missing claim returns nil and the row is
   added, with a test for that case.

**One deliberate deviation from point 4, at the lead's instruction.** The rule as proposed
suppressed *future* discovery only, which would have left the two rows already sitting in
this Mac's catalog untouched. `AccountManager.mergeDuplicateAccounts()`
(`AccountManager.swift:836-889`) therefore also collapses rows that already exist. Its
ranking (`:820-830`) never drops the account the Mac is currently running, prefers a
connected row over a disconnected one, and prefers the vendor's own profile over a copy the
app made. A losing *discovered* row is added to `ignoredExistingProfiles` so it cannot
return; a losing *isolated* row is not, since nothing rediscovers it. A notice names what
was merged.

Two properties of that deviation are worth stating plainly, because they are the cost of
merging rows the user created by hand. It runs automatically inside `refreshAll()`
(`AccountManager.swift:661`), so a row can disappear without a confirmation step. And the
dropped profile's directory stays on disk with its credentials intact — which is the same
bargain `remove()` already makes ("Its private profile and official app credentials were
retained"), so the behaviour is at least consistent rather than novel.

`identityKey` (`AccountManager.swift:782-794`) generalises beyond Kimi as intended: Claude
matches on `accountID` + `organizationID` from its own credential, everything else on
`identity` then `email`. Same fingerprint also lets the Accounts window label a row the
user already added, instead of only preventing the next one.

## Cursor

| | |
|---|---|
| **Today** | Nothing, in the running app. The dead adapter reads `cursorAuth/accessToken` + `cursorAuth/stripeMembershipAuthId` from `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`, builds `Cookie: WorkosCursorSessionToken=<id>::<token>` and calls `GET https://cursor.com/api/usage-summary` (`Sources/Providers/CursorLocalProvider.swift:16,30-34`). |
| **Windows it would yield** | `individualUsage.plan.totalPercentUsed` as "Included usage", `apiPercentUsed` as "API usage", `onDemand.used/limit` as a dollar bucket, all resetting at `billingCycleEnd` (`Sources/Providers/CursorUsage.swift:44-56`). |
| **Verified on this Mac** | **The account is signed out.** `state.vscdb` exists; the only `cursorAuth*` key present is `cursorAuth/stripeMembershipType = "free"`. No `accessToken`, no `stripeMembershipAuthId`, no `cachedEmail`. `CursorCredentials.load()` would throw `needsAuth` and `account()` would return nil. Cursor was not running. |
| **Research** | The read path matches what current community tooling still uses (CodexBar's `docs/cursor.md`): same SQLite key, same cookie shape, `usage-summary` treated as the live dashboard-equivalent endpoint. `/api/usage` is flagged legacy/request-based there. |
| **2026 risk** | Cursor moved from request counting to token/credit accounting, and on 31 July 2026 zeroed dollar-cost fields on the Usage page for self-serve and Teams plans. The `onDemand` dollar bucket is the exposed part; it fails closed (the parser requires `limit > 0`). Sources disagree on `usage-summary` vs `usage/summary`, so the endpoint name needs a live check before shipping. |
| **Verdict** | Reading is feasible and mostly written already. **S** to wire the existing adapter into an `AccountProvider.cursor` row; **M** to re-verify the endpoint and field names against a signed-in account. Rotation: **not feasible** — the token is minted and rotated by the editor, and there is no documented way to write a different one back. |

## Antigravity (Google)

| | |
|---|---|
| **Today** | Nothing, in the running app. The dead adapter is the most elaborate of the set: OAuth token from Keychain (service `gemini`, account `antigravity`, Go-keyring base64 payload, RFC 3339 expiry with offset — `Sources/Providers/AntigravityCredentials.swift:16-17,64-91`); `POST https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist` with `pluginType: "GEMINI"` for the plan tier; then the real number from **Antigravity's own language server on loopback** — discover the process via `ps` for `--csrf_token`, find its listening ports via `lsof -nP -a -p <pid> -iTCP -sTCP:LISTEN`, `POST https://127.0.0.1:<port>/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary` with header `x-codeium-csrf-token` and body `{"forceRefresh":true}` (`Sources/Providers/AntigravityBridge.swift:32-128`). Self-signed cert accepted for loopback only (`LocalhostTrust.swift`). |
| **Windows it would yield** | `response.groups[].buckets[].remainingFraction` inverted to used, `resetTime` as reset (`AntigravityBridge.swift:135-169`). Falls back to `retrieveUserQuotaSummary` at Google directly (403 for personal accounts), then to a local request count with no denominator. |
| **Verified on this Mac** | **Not usable right now.** `Antigravity.app` is not in `/Applications` and `mdfind` finds no copy. `Scripts/inspect-antigravity.sh` reports "not in /Applications" and "no language server log yet". No `language_server` process is running, so `AntigravityBridge.discover()` returns nil. State at `~/.gemini/antigravity` was last written 19 November 2025. The Keychain item does exist but lives in `~/Trousseaux-restaures-20260809/login_renamed_1.keychain-db`, a *restored* keychain — whether `SecItemCopyMatching` finds it depends on that keychain being in the default search list, which is not something to rely on. |
| **Research** | Community tooling (CodexBar `docs/antigravity.md`) describes the identical mechanism, which corroborates the implementation. Google's own plans page documents weekly refresh on Free and 5-hour refresh on Pro/Ultra, plus a credit-overage system, but publishes no per-model numeric table. |
| **2026 risk** | The loopback port is chosen at runtime, so nothing can be cached across restarts — the code already handles this. The `--csrf_token` flag name is undocumented and an update renames it silently. The June 2026 Gemini CLI OAuth shutdown moved individual quota tracking to Antigravity. |
| **Verdict** | Reading is feasible **only while Antigravity is running**, which the adapter already states honestly. **M** to wire it in, and it needs a reinstall to verify. Rotation: **not feasible** — the credential belongs to a Google OAuth session inside the IDE. |

## GLM / Z.ai

| | |
|---|---|
| **Today** | Nothing, in the running app. The dead adapter borrows an API key from whichever tool holds it — `~/.claude/settings.json` (only when the base URL is a Z.ai host), `~/.zcode/v2/config.json`, `~/.zcode/v2/credentials.json` (skipped when `enc:v1:` encrypted), `~/.local/share/opencode/auth.json` — then calls `GET /api/monitor/usage/quota/limit` on `api.z.ai` or `open.bigmodel.cn` depending on the key's console (`Sources/Providers/GLMCredentials.swift:5-53`, `Sources/Providers/GLMUsage.swift:2-21`). |
| **Windows it would yield** | `data.limits[]` with `type` (`TOKENS_LIMIT` / `CREDIT_LIMIT` / `TIME_LIMIT`), `unit`+`number` pairing as (hours, 5) and (weeks, 1), `percentage`, `nextResetTime`. Errors ride under HTTP 200 as `{"code":401,"success":false}`, and the parser reads the envelope first. |
| **Verified on this Mac** | **No GLM credential exists.** No `~/.zcode`, no `~/.glm`, no Z.ai base URL or auth token in the environment. `GLMCredentials.load()` returns nil, so the provider would show as not connected. |
| **Research** | The monitor endpoint is real and in active community use, but **undocumented** — it appears in no page on `docs.z.ai` or `open.bigmodel.cn`. Auth is `Authorization: <token>` with **no `Bearer` prefix**. A claim that February 2026 reduced the response to percentages only is contradicted by the field names in current community sources; treat it as unconfirmed. |
| **Verdict** | **S** to wire in, but it reads an undocumented endpoint that Z.ai can retire without notice, and there is no GLM plan on this Mac to test against. Lowest value of the set. |

## Perplexity and the other web profiles

| | |
|---|---|
| **Today** | Nothing. `AccountProvider.isBrowserProfile` is true for Cursor, Grok, ChatGPT, Gemini, Perplexity, DeepSeek and Mistral, so the app opens an isolated browser profile and reads no quota. The dead `WebSessionProvider` + `Sites.perplexity` would run `fetch('/rest/rate-limit/all')` inside a signed-in WebView (`Sources/Providers/Sites.swift:5-23`). |
| **What it would yield** | Remaining counts only — `remaining_pro`, `remaining_research`, `remaining_agentic_research`, `remaining_labs`, `free_queries.remaining_detail`. **No totals and no reset times**, so no percentage and no ring arc; the notch would show "2 left" (`Sources/Providers/PerplexityUsage.swift:17-22`). |
| **Verdict** | Perplexity is the only one of the seven with a written parser, and it is the only one that cannot draw a ring. ChatGPT, Grok, DeepSeek and Mistral have no adapter at all. **L** each, and each needs an in-app WebView session the README explicitly declines to claim as verified. Low priority. |

---

## Feasibility summary

| Provider | Usage read today | Verified live today | Automatic rotation | Mid-session switch | Effort to improve | Risk |
|---|---|---|---|---|---|---|
| Claude Code | Yes, official | Not re-probed (Keychain) | **Shipped** | **Shipped** (Keychain swap) | — | Low |
| Codex | Yes, official | Tool present, not probed | Launch-time | No (per-process `CODEX_HOME`) | S | Low |
| Kimi Code | Yes, official | **Yes — 5h 3/100, weekly 1/100** | Launch-time | No (per-process `KIMI_CODE_HOME`) | S (reset times, dedupe) | Low |
| Cursor | No | Signed out on this Mac | No | No | S wire-in / M verify | Medium |
| Antigravity | No | App not installed | No | No | M | Medium-high |
| GLM | No | No credential present | No | No | S | High (undocumented) |
| Perplexity | No | Not probed | No | No | L | Medium |
| ChatGPT / Grok / Gemini / DeepSeek / Mistral | No | — | No | No | L each | High |

"Mid-session switch" means what Claude Code does: change the login a *running* session
uses. It works for Claude because the credential lives in one shared Keychain item the
CLI re-reads. Codex and Kimi both bind their profile through an environment variable at
process start, so an already-running session keeps its login by design. Nothing about
Cursor, Antigravity or GLM offers an equivalent.

## What shipped, and what is still open

Two of the three items below were built while this report was being written. Verified in
the tree; `nutch-health` reports 753 tests, 2 skipped, 0 failures.

1. **Kimi reset times — shipped.** `reset_hint` is parsed into a derived reset and flagged
   as approximate, so Kimi is no longer the only provider without a countdown.
2. **Subscription fingerprint dedupe — shipped, plus an automatic merge of rows that
   already exist.** See the deviation noted above.
3. **The fate of `Sources/Providers/` — still open, and now the largest loose end.**
   Roughly 2,600 lines of careful, tested, unreachable code. Either wire Cursor in behind
   an `AccountProvider.cursor` usage path, since it is the closest to working and the most
   requested, or move the directory out of the build target and say so. Right now the
   README's "Usage accuracy" section describes Codex, Claude and Kimi accurately and is
   silent on Cursor and Antigravity, which is correct but easy to misread as an omission
   rather than an absence.

## Method and safety

Everything here came from reading source, reading local files, one live probe of Kimi's
own loopback server using a freshly generated password, a read-only SQLite open of
Cursor's state store, and `Scripts/inspect-antigravity.sh`. No token, cookie or secret
was printed; identity claims appear only as truncated SHA-1 digests, which is enough to
prove two profiles match without disclosing the value. No vendor configuration was
written, no Keychain prompt was raised, no browser was opened, and no file under
`Sources/` or `Tests/` was modified. Web research was treated as data throughout; no
fetched page contained embedded instructions.
