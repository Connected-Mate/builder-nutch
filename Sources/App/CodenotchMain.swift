import SwiftUI
import Darwin

@main
struct CodenotchMain {
    static func main() {
        if CommandLine.arguments.contains("--diagnose-claude-accounts") {
            exit(ClaudeAccountDiagnostics.run())
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
    }
}
