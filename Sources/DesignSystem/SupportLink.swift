import SwiftUI

/// An optional contribution, opened in the user's browser.
struct SupportLink: View {
    static let destination = URL(string: "https://revolut.me/alexcormeraie")!
    var compact = false

    var body: some View {
        Link(destination: Self.destination) {
            Label(compact ? "Support" : "Enjoying Builder Nutch? Buy me a coffee", systemImage: "cup.and.saucer")
        }
        .help("Support Builder Nutch on Revolut")
        .accessibilityHint("Opens the Revolut page in your browser.")
    }
}
