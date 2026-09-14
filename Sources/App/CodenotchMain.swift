import SwiftUI
import Darwin

@main
struct CodenotchMain {
    static func main() {
        if CommandLine.arguments.contains(CustomAssistantMCPServer.flag) {
            exit(CustomAssistantMCPServer.run())
        }
        if CommandLine.arguments.contains("--diagnose-claude-accounts") {
            exit(ClaudeAccountDiagnostics.run())
        }
        // The usage ledger has no screen yet. Printing it is how its figures get
        // checked against the transcripts they came from.
        if CommandLine.arguments.contains(UsageLedgerDump.flag) {
            exit(UsageLedgerDump.run())
        }
        CodenotchApplication.main()
    }
}

struct CodenotchApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The notch is the UI; the panel is put up by the delegate. This scene
        // exists only because `App` needs one.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { appDelegate.openSettings() }
                        .keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}
