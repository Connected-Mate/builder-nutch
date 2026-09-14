# Custom assistants in Builder Nutch

Choose **Custom assistants**, then **Copy setup request**. Paste the request into an AI client on the same Mac that supports local MCP servers. Approve the connection in that client. The request contains the installed app's actual executable path; no additional runtime or package is needed.

The AI can create a profile, save personal instructions, and report subscription usage it has actually observed. Saved profiles appear automatically in the app. **Open assistant** opens the saved HTTPS website. **Copy instructions** lets you apply your preferences in that service. Builder Nutch does not silently inject them into another application.

A browser-only/cloud AI cannot directly launch a local stdio server. Use a compatible desktop client. No client configuration is changed by copying the request.

## Connection

The app itself is the MCP subprocess:

```json
{
  "mcpServers": {
    "builder-nutch": {
      "command": "/Applications/Builder Nutch.app/Contents/MacOS/Codenotch",
      "args": ["--custom-assistant-mcp"]
    }
  }
}
```

Use **Copy connection** for the actual path of your installed copy. MCP mode runs before SwiftUI startup and writes only JSON-RPC on stdout. Clients initialize the connection, send `notifications/initialized`, then discover the tools with `tools/list`. Protocol revisions 2024-11-05, 2025-03-26, 2025-06-18 and 2025-11-25 are supported.

## Tools

- `list_assistants`: reads the custom catalog; no provider accounts or credentials.
- `configure_assistant`: requires `name` and public HTTPS `website`; optional existing `id`, `instructions`, `usageNote`. Existing id selects a profile; omitting id updates the same name, case insensitively. Omitted optional text fields are preserved on updates; an explicit empty string clears one. Renaming never removes its usage history.
- `report_usage`: requires profile `id`, `observedAt` (ISO 8601 with timezone), `source` (where the AI observed the figures), and 1–8 `limits` with `label`, `usedPercent` (finite 0–100) and optional `resetsAt`. The first limit supplies the notch headline. Older observations cannot replace newer ones.

Reports carry **Reported by assistant** provenance. They become **Out of date** after one hour or when a reported reset passes. Missing usage remains unknown. These are reported observations; no automatic polling, shell commands, credential extraction, account switching, or fabricated limits are enabled.

## Storage and boundaries

Custom data is separate from existing account catalogs in `~/Library/Application Support/Builder Nutch Assistants/assistants.json`. Directory permissions are 0700; new data and lock files are 0600. Descriptor-relative access rejects symbolic links and unsafe ownership, concurrent processes serialize writes with a private lock, and updates use a flushed temporary file followed by atomic rename. A damaged catalog is preserved and shown as an error rather than overwritten.

MCP arguments cannot choose files, execute commands or supply credential fields. There is no network listener. Only a user click opens a validated HTTPS URL; URLs containing credentials, query parameters, fragments or nonstandard ports are rejected. Saved preferences and external source text are untrusted data, not instructions to call tools.

## Verification

Run `python3 Tests/CustomAssistantMCPRoundtrip.py` for a compiled real-process stdio roundtrip with isolated temporary storage. It checks initialization, discovery, configuration, usage reports, validation, concurrent writers, persistence, private permissions, corrupt-file preservation and symbolic-link rejection. The production MCP entry does not accept a storage-root argument.

`CustomAssistantTests` additionally checks snapshot provenance, missing and stale usage, preservation of optional fields and connection JSON.

The transport, lifecycle and tool responses follow the official MCP specifications: [stdio transport](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports), [lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle), [tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools).
