# Rate-limit evidence

Subscription quota windows and request throughput limits are separate measurements. The app does not send model prompts to test capacity, invent RPM/TPM ceilings, or interpret a usage-reader HTTP 429 as an inference block.

* Claude: [official rate-limit documentation](https://platform.claude.com/docs/en/api/rate-limits) describes request/token limits and provider retry headers for API inference. The subscription readers used here expose percentage windows and explicit locks; those do not establish request headroom.
* Codex: the [official app-server protocol](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md) exposes account rate-limit readings. Preserve explicit `rateLimitReachedType`, including workspace restrictions without numerical quotas. A workspace restriction does not inherit an unrelated quota reset.
* Kimi: [official errors](https://www.kimi.com/code/docs/en/kimi-code/error-reference.html) distinguish exhausted quotas, concurrency limits and provider overload. Its current subscription reader supplies quota windows; no numeric throughput ceiling is inferred from these.

Confirmed exhausted windows retain their scope. Multiple applicable exhausted windows use the latest reset only when every reset is known. Passed resets require new evidence; they never imply usage resumed. Polling failures retain the last percentages but invalidate current block claims. Custom MCP reports may separately declare observed rate, concurrency or overload restrictions with source, observation time and optional provider retry time; these remain assistant-reported and expire.
