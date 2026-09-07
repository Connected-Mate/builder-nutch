import SwiftUI

/// An optional contribution, opened in the user's browser.
struct SupportLink: View {
    static let destination = URL(string: "https://revolut.me/alexcormeraie")!

    var body: some View {
        Link(destination: Self.destination) {
            Label("Offrez-moi un café", systemImage: "cup.and.saucer")
        }
        .help("Soutenir Builder Nutch sur Revolut")
        .accessibilityHint("Ouvre la page Revolut dans votre navigateur.")
    }
}
