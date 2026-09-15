import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum UsageShareExporter {
    enum ExportError: LocalizedError {
        case rendering, clipboard

        var errorDescription: String? {
            switch self {
            case .rendering: NSLocalizedString("The image could not be created. Try again.", comment: "Usage export error")
            case .clipboard: NSLocalizedString("The image could not be copied. Try saving it instead.", comment: "Usage export error")
            }
        }
    }

    static func pngData(snapshot: UsageShareSnapshot, locale: Locale = .current) throws -> Data {
        let renderer = ImageRenderer(content: UsageShareCard(snapshot: snapshot)
            .environment(\.locale, locale)
            .environment(\.colorScheme, .dark))
        renderer.scale = 2
        renderer.isOpaque = true
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ExportError.rendering
        }
        return data
    }

    static func filename(for snapshot: UsageShareSnapshot) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = snapshot.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let scope = snapshot.isProject ? "project-" : ""
        return "Builder-Nutch-\(scope)\(snapshot.period.rawValue)-tokens-\(formatter.string(from: snapshot.today)).png"
    }

    static func copy(_ data: Data, to pasteboard: NSPasteboard = .general) throws {
        pasteboard.clearContents()
        guard pasteboard.setData(data, forType: .png) else { throw ExportError.clipboard }
    }

    static func save(_ data: Data, snapshot: UsageShareSnapshot,
                     completion: @escaping @MainActor (Result<URL?, Error>) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = filename(for: snapshot)
        let finished: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { completion(.success(nil)); return }
            do {
                try data.write(to: url, options: .atomic)
                completion(.success(url))
            } catch { completion(.failure(error)) }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: finished) }
        else { panel.begin(completionHandler: finished) }
    }
}
