# Claude Code → connected Codex account relay

The bundled `Sources/Resources/claude-openai-relay.mjs` keeps Claude Code as the conversation UI, session store, permission manager, and **only executor of project tools**. Model inference uses the installed official Codex app-server and its existing ChatGPT sign-in. It never reads authentication files, extracts tokens, or calls private ChatGPT inference endpoints.

## Commands

Node.js 22 or newer and the audited **Codex CLI 0.154.0** are required. Other Codex versions fail closed because this bridge uses experimental app-server fields.

```sh
node /absolute/path/claude-openai-relay.mjs probe --codex /absolute/path/codex
node /absolute/path/claude-openai-relay.mjs launch \
  --codex /absolute/path/codex --claude /absolute/path/claude \
  --model gpt-6-astra --cwd /absolute/project/path --mode openai -- --continue
```

`--mode auto` starts on Claude and switches that session to the selected OpenAI model after an Anthropic HTTP 429 `rate_limit_error`. Authentication failures, overloads, and network errors do not switch providers. All later requests with the same Claude session header stay on OpenAI for the relay lifetime (up to 24 hours). A fallback hash covers older clients without session headers. This does not modify a Claude process that was already running: restart it through this launcher using `--continue` or `--resume [id]`.

`probe` writes one JSON object to stdout: `{ "codexVersion": "0.154.0", "authenticated": true, "models": [{ "id": "gpt-6-astra", "displayName": "GPT-6-Astra" }] }`. The model list is discovered live, never assumed from a hardcoded catalog. Handled probe failures write `authenticated:false`, `models:[]`, and an `errorCode` (`unsupported_codex_version`, `unsupported_node_version`, `not_authenticated`, `probe_failed`). No provider diagnostics or credentials are printed. Launch failures use concise sanitized stderr messages and a nonzero exit.

`CODEX_HOME` is inherited, so the Swift launcher can select a connected account using the application's existing account-home mechanism. Credentials never appear in command arguments. The relay generates a random loopback token and passes it solely through the child environment. In direct mode this replaces Claude's provider credential. In automatic mode a private custom header authenticates the local hop while Claude retains its own OAuth/API credential; the relay strips that private header before forwarding to the fixed `api.anthropic.com` HTTPS origin. Original Anthropic body and `anthropic-*` capability headers remain intact; redirects are never followed.

## Tool isolation

The bridge starts app-server in a fresh, empty temporary working directory, overrides shell/snapshot/app/MCP-plugin/browser/computer/image/web/multi-agent/hooks/memory and related execution features, disables all configured MCP servers by name, and creates every thread and turn with **`environments: []`**. No project directory is supplied to Codex. `sandbox:read-only` and `approvalPolicy:never` are defense in depth, not the isolation boundary. Unexpected server tool/approval requests fail closed.

Source inspected at the matching official `rust-v0.154.0` tag:

- [`core/src/tools/spec_plan.rs`](https://github.com/openai/codex/blob/rust-v0.154.0/codex-rs/core/src/tools/spec_plan.rs): `add_shell_tools` returns without registering shell handlers when there is no environment (around line 1083); apply-patch and view-image registration also require an environment (around lines 1255 and 1269).
- [`core/src/tools/handlers/dynamic.rs`](https://github.com/openai/codex/blob/rust-v0.154.0/codex-rs/core/src/tools/handlers/dynamic.rs): dynamic handlers delegate to the client and await its response.
- The local **code-mode host transport remains enabled**: Astra requires that dispatcher for its dynamic tool calls even with `features.code_mode=false`. Enabling it does not register shell, filesystem, or MCP handlers. The JavaScript tool orchestrator only receives the allowed dynamic tools and harmless runtime utilities. Disabling the host was experimentally verified to break native tool forwarding; the bridge does not conceal that dependency.

Claude tool schemas are mapped to unique dynamic names. The returned `tool_use` retains the original Claude name. Claude executes the operation with its normal permissions and sends the result; the relay returns that result to the exact pending native app-server call. Parallel calls queue without crossing conversations. When a native tool turn completes, its ephemeral thread is discarded. The next model request imports the full Claude transcript; it does not depend on a second persistent conversation store. If tools/system settings change or additional user steering arrives with a tool result, the old turn is cancelled and the complete updated transcript is imported into a new isolated thread.

## Compatibility and bounds

Text, native tool calls/results, embedded images, streaming text/tool blocks, and nonstream Messages are supported. SSE includes keepalive pings during reasoning. Model-reported input/cache/output token counts are translated when available. Early streaming starts and tool-boundary replies may contain zero placeholders until app-server has reported usage; these are **not measurements of zero consumption**. No prices are fabricated. Exact `/v1/messages/count_tokens` returns 404 so Claude uses its own fallback.

`ENABLE_TOOL_SEARCH=false` is scoped to the child: Claude loads all its MCP tools upfront instead of sending unsupported server-side deferred-tool requests. No registered tool is deliberately removed. Images are sent as image inputs, with base64 removed from the text transcript. Existing thinking blocks remain historical data; OpenAI's private reasoning is not exposed as Claude thinking.

Claude Code 2.1.270 can include system messages inside its `messages` array. These retain system-instruction authority when translated, including when a trailing system message follows a tool result. In immediate OpenAI mode, Claude's alternate credential path disables its claude.ai organization connectors; local project tools remain available. Automatic mode retains the selected Claude login. Claude may print an unrecognized-model diagnostic for Astra even while inference works.

This is an explicit compatibility layer, not full Anthropic API parity. Documents, audio, unsupported content blocks, mandatory tool-choice constraints, and custom stop sequences fail with actionable errors. Anthropic `max_tokens`, sampling parameters, cache directives, and extended-thinking controls do not map to identical Codex controls; `max_tokens` is **not a hard OpenAI generation budget**. The model's configured limits and the relay's ten-minute response deadline govern generation. Anthropic does not provide support for routing Claude Code to non-Claude models through third-party gateways.

The listener binds only `127.0.0.1`, requires a constant-time checked random token, rejects browser Origin requests, accepts only Messages endpoints, caps requests at 16 MiB and app-server lines at 32 MiB, limits outstanding conversations to eight, expires waiting tool turns after ten minutes, and interrupts/unsubscribes when clients cancel or exit. The relay never logs prompts, tool results, headers, authentication data, or upstream error bodies.

## Verification

```sh
node --test Scripts/test-claude-openai-relay.mjs
```

Seventeen deterministic tests cover real child-process JSON-RPC framing, native tool roundtrip, text/SSE lifecycle, authentication, Origin rejection, concurrency reservation, cancellation (including a late turn-start reply), model failures, unsupported formats, fixed-origin automatic fallback, credential/header filtering, nonquota errors, exact-count rejection, actual token-usage conversion, inline system instructions, and launching the resource through a symbolic path.

On 14 September 2026, actual Claude Code 2.1.270 with Codex 0.154.0, Node 22.22.3 and Astra passed three acceptance runs: Claude's Read tool returned the exact unseen random contents of a temporary file; resuming the same Claude session recalled that content from history with the normal native tool catalog loaded; a controlled Anthropic 429 caused the real Claude client to continue through Astra and complete another Read operation. The automatic test injected only the Anthropic quota response; Claude, Codex and OpenAI inference were real. It did not consume an Anthropic model request or exhaust a real account. All runs exited successfully and reported nonzero measured usage.

The native macOS suite ran 891 tests with three opt-in checks skipped. Its one initial failure caught the missing release note for the new version; after adding the note, all 16 release-note and relay tests passed on the targeted rerun. An independent verifier also passed 23 quota tests and all 17 relay protocol tests. The French relay sheet was rendered as a native window and checked for clipping and missing controls.

Protocol references: [official Codex app-server](https://learn.chatgpt.com/docs/app-server), [Claude gateway compatibility](https://code.claude.com/docs/en/llm-gateway-protocol), [Claude gateway connection](https://code.claude.com/docs/en/llm-gateway), [Claude MCP tool search configuration](https://code.claude.com/docs/en/mcp#configure-tool-search).
