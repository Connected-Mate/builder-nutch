import Foundation

/// What one release changed, in the app's own words.
struct ReleaseNote: Equatable {
    /// Matched against `CFBundleShortVersionString`, so it has to be exactly
    /// the string `MARKETING_VERSION` is set to.
    let version: String
    /// One line under the title. What this release is *about*.
    let headline: String
    let changes: [Change]

    /// A title carries the change; the detail is optional, so a small fix can
    /// be a single line rather than a line padded out to match its neighbours.
    struct Change: Equatable {
        let title: String
        let detail: String

        init(title: String, detail: String = "") {
            self.title = title
            self.detail = detail
        }
    }
}

/// The release history the app ships with.
///
/// Written here rather than fetched from the appcast: it has to be there on a
/// first launch with no network, and it belongs to the build it describes.
/// Bumping `MARKETING_VERSION` without adding an entry is caught by
/// `testTheCurrentVersionHasANote`.
enum ReleaseNotes {
    static let all: [ReleaseNote] = [
        ReleaseNote(
            version: "0.5.0",
            headline: "Already connected. Ready to build.",
            changes: [
                .init(title: "Find your existing accounts", detail: "Signed-in Claude Code, Codex and Kimi Code profiles on this Mac appear automatically. Existing sign-ins stay in place."),
                .init(title: "Claude limits before your first message", detail: "Recent Claude Code versions can check subscription limits without starting a conversation. Unavailable usage stays clearly marked."),
                .init(title: "A clearer icon, real app screenshots", detail: "A bold neutral icon stays readable at small sizes. Hide personal details with the eye button; the website now shows the actual Mac app.")
            ]
        ),
        ReleaseNote(
            version: "0.4.1",
            headline: "The workspace you saw on the website.",
            changes: [
                .init(title: "One familiar layout", detail: "The assistant sidebar, account rows, remaining-quota rings and next-session controls follow the website’s product preview."),
                .init(title: "Choose an assistant in place", detail: "The service catalog opens inside your workspace. Official sign-in and optional nicknames follow."),
                .init(title: "Room for the details", detail: "A wider workspace keeps account names readable. Detailed limits remain available without crowding every row.")
            ]
        ),
        ReleaseNote(
            version: "0.4.0",
            headline: "The same calm workspace, on your Mac.",
            changes: [
                .init(title: "White, gray and room to build", detail: "The account manager, sign-in screens and settings now share the website’s neutral design and Bricolage Grotesque typography."),
                .init(title: "The real provider logos", detail: "Recognize every assistant at a glance, with the same service marks as the website."),
                .init(title: "Your accounts stay yours", detail: "Existing accounts, nicknames, sign-ins and auto-hide settings are preserved.")
            ]
        ),
        ReleaseNote(
            version: "0.3.1",
            headline: "Your assistants, one place.",
            changes: [
                .init(title: "Release history included", detail: "This update includes the in-app notes for the new assistant experience."),
                .init(title: "A distinct Gemini mark", detail: "Gemini browser accounts use their own symbol, separate from the upstream Antigravity integration.")
            ]
        ),
        ReleaseNote(
            version: "0.3.0",
            headline: "Choose a service. Sign in. Make it yours.",
            changes: [
                .init(title: "Add an assistant before naming it", detail: "Choose the service and complete its official sign-in, then add an optional nickname and emoji."),
                .init(title: "More assistants, separate accounts", detail: "Claude, Codex and Kimi Code use their official tools. Grok, ChatGPT, Gemini, Perplexity, DeepSeek, Mistral and Cursor dashboards open in separate browser profiles."),
                .init(title: "One visual language", detail: "The manager and appearance settings now match the notch’s black surfaces and green accents."),
                .init(title: "Invisible until you need it", detail: "Auto-hide reveals the notch when your pointer reaches the selected screen edge and hides it again when you leave.")
            ]
        ),
        ReleaseNote(
            version: "0.2.0",
            headline: "Builder Nutch, for builders running more than one AI account.",
            changes: [
                .init(title: "One clear name across the app",
                      detail: "Codenotch Accounts is now Builder Nutch. Existing profiles, selected accounts and official sign-ins stay exactly where they are."),
                .init(title: "Built for multiple AI subscriptions",
                      detail: "Keep Claude Code and Codex accounts separate, see fresh limits, and choose the right account before opening a new project session."),
                .init(title: "The notch remains the working view",
                      detail: "Builder Nutch keeps the original at-a-glance quota experience. Based on Codenotch by vinzdg.")
            ]
        ),
        ReleaseNote(
            version: "0.1.1",
            headline: "A clearer first connection.",
            changes: [
                .init(title: "New Claude profiles show their connection step",
                      detail: "An account that has not signed in yet now asks you to connect instead of displaying an operational error.")
            ]
        ),
        ReleaseNote(
            version: "0.1.0",
            headline: "Your accounts, together in Codenotch.",
            changes: [
                .init(title: "Separate Claude Code and Codex accounts",
                      detail: "Add named profiles and sign in through each assistant's official browser flow."),
                .init(title: "Choose the account for your next session",
                      detail: "Launch in your project folder with a selected account, or let verified, fresh quota guide the choice. Running sessions keep their current account."),
                .init(title: "The original Codenotch experience",
                      detail: "Selected accounts appear in the notch. This independent fork builds on Codenotch by vinzdg.")
            ]
        ),
        ReleaseNote(
            version: "1.4.0",
            headline: "Two more accounts, four community fixes, and honest duplicates.",
            changes: [
                ReleaseNote.Change(
                    title: "Multiple Claude Code accounts",
                    detail: "Keep a work login apart with CLAUDE_CONFIG_DIR? It "
                          + "now gets its own ring, its own limits, and its own "
                          + "row in Settings, beside your personal one."
                ),
                ReleaseNote.Change(
                    title: "GLM added",
                    detail: "Z.ai's Coding Plan reads live now too, with a key "
                          + "borrowed from whichever tool already holds one."
                ),
                ReleaseNote.Change(
                    title: "A stuck Claude ring recovers on its own",
                    detail: "One momentary failure — the Mac waking from sleep, "
                          + "most often — used to lock the ring until the app "
                          + "restarted. It now clears itself on the next check."
                ),
                ReleaseNote.Change(
                    title: "Cursor sessions stop reporting work that already ended",
                    detail: "A crashed or abandoned chat could read as \"still "
                          + "working\" for a day or more. It now notices when "
                          + "the writing has actually stopped."
                ),
                ReleaseNote.Change(
                    title: "A months-old duplicate can no longer win",
                    detail: "Claude Code files a new keychain entry on every "
                          + "token rotation. An account signed in for a while "
                          + "could pick an old, expired one at random and show "
                          + "\"waiting for the first reading\" forever."
                ),
                ReleaseNote.Change(
                    title: "A stray click no longer pins the notch open",
                    detail: "Clicking near the screen edge before the notch had "
                          + "even opened could leave it stuck open with nothing "
                          + "on screen explaining why."
                )
            ]
        ),
        ReleaseNote(
            version: "1.3.0",
            headline: "Codex reads live, and Always show stays on.",
            changes: [
                ReleaseNote.Change(
                    title: "Codex is read live instead of from a log",
                    detail: "The figure came from a file Codex writes during a "
                          + "turn, so it was as old as the last time you used "
                          + "it — three days stale in one case. Codenotch now "
                          + "asks Codex itself, and matches its own panel."
                ),
                ReleaseNote.Change(
                    title: "The Codex ring notices the desktop app",
                    detail: "It only ever watched the files the CLI and the VS "
                          + "Code extension write, so work done in the desktop "
                          + "app never made it spin."
                ),
                ReleaseNote.Change(
                    title: "Always show no longer turns itself off",
                    detail: "Clicking the notch toggled the same flag the "
                          + "setting used, so a stray click quietly put it back "
                          + "to showing on hover."
                ),
                ReleaseNote.Change(
                    title: "Far fewer keychain prompts",
                    detail: "Once a token expired, every check went back to the "
                          + "keychain — a prompt a minute. It now reads the "
                          + "secret only when the owning app has changed it, and "
                          + "never retries a refusal on a timer."
                ),
                ReleaseNote.Change(
                    title: "A paused limit is shown as paused",
                    detail: "Some limits are reached while the headline still "
                          + "shows room. The ring reads as spent and says when "
                          + "it lifts."
                ),
                ReleaseNote.Change(
                    title: "Long messages are no longer cut off",
                    detail: "A tooltip with something to explain reserved one "
                          + "line for it however much it said."
                )
            ]
        ),
        ReleaseNote(
            version: "1.2.0",
            headline: "Every session, and a tooltip that fits on the screen.",
            changes: [
                ReleaseNote.Change(
                    title: "Tooltips are no longer cut off",
                    detail: "A card is centred on the ring it belongs to, so the "
                          + "first and last providers threw half of it past the "
                          + "end of the panel — and what fell off was the title. "
                          + "The panel now keeps room for it."
                ),
                ReleaseNote.Change(
                    title: "As many sessions as your screen can hold",
                    detail: "The list was capped at four whatever you were "
                          + "running on. It is now solved for the display: ten on "
                          + "a large one, and \"and N more\" only when there is "
                          + "genuinely no room for the rest."
                ),
                ReleaseNote.Change(
                    title: "The ones that need you come first",
                    detail: "Waiting, then busy, then idle — so if anything is "
                          + "summarised away, it is what matters least."
                )
            ]
        ),
        ReleaseNote(
            version: "1.1.0",
            headline: "Antigravity's real numbers, and a switch that stays off.",
            changes: [
                ReleaseNote.Change(
                    title: "Antigravity shows its actual quota",
                    detail: "Google will not answer Codenotch directly, so it asks "
                          + "Antigravity's own language server instead — the same "
                          + "place Antigravity's usage panel gets its figure."
                ),
                ReleaseNote.Change(
                    title: "Usage reads both ways",
                    detail: "\"12% used · 88% left\", so a reading lines up with "
                          + "whichever end your vendor happens to show."
                ),
                ReleaseNote.Change(
                    title: "A way back from a declined keychain prompt",
                    detail: "Declining no longer looks like being signed out, and "
                          + "Allow access… asks macOS again."
                ),
                ReleaseNote.Change(
                    title: "Switching a provider off now sticks",
                    detail: "It stopped being read but its last reading was kept, "
                          + "so the ring came back at the next launch."
                ),
                ReleaseNote.Change(
                    title: "Distant resets show a date",
                    detail: "A limit renewing in four weeks said \"Mon\", which read "
                          + "as this Monday. It says \"28 Sep\"."
                )
            ]
        ),
        ReleaseNote(
            version: "1.0.0",
            headline: "The first release.",
            changes: [
                ReleaseNote.Change(
                    title: "Put the notch anywhere",
                    detail: "Right, left, top or bottom. It keeps clear of the Dock "
                          + "and the menu bar, and follows when the Dock moves."
                ),
                ReleaseNote.Change(
                    title: "It joins your Mac's own notch",
                    detail: "On the top edge it takes the hardware's shape, so the "
                          + "two read as one rather than as a bar parked underneath."
                ),
                ReleaseNote.Change(
                    title: "Claude, Cursor, Codex and Gemini",
                    detail: "Each read from the tool already signed in on this Mac. "
                          + "Codenotch never asks for a password."
                ),
                ReleaseNote.Change(
                    title: "Choose where Codenotch appears",
                    detail: "In the Dock, in the menu bar, or nowhere at all."
                )
            ]
        )
    ]

    static func note(for version: String) -> ReleaseNote? {
        all.first { $0.version == version }
    }

    /// The note worth showing on this launch, if there is one.
    ///
    /// `notes` is a parameter so the rule can be tested against a fixed history
    /// rather than against whatever the app happens to ship this week.
    static func unseen(in version: String,
                       lastSeen: String?,
                       notes: [ReleaseNote] = ReleaseNotes.all) -> ReleaseNote? {
        guard lastSeen != version else { return nil }
        return notes.first { $0.version == version }
    }
}
