// Capture actual, running Builder Nutch windows. Use Hide personal details first.
// xcrun swift Scripts/capture-app.swift <output-directory>
import AppKit
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
guard UserDefaults(suiteName: "com.connectedmate.codenotch-accounts")?.bool(forKey: "accounts.hidePersonalDetails") == true else {
    fatalError("Enable Hide personal details in Builder Nutch before capturing public screenshots.")
}
guard let target = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.path == "/Applications/Builder Nutch.app" }) else {
    fatalError("Open the installed Builder Nutch app first.")
}
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
for window in content.windows where window.owningApplication?.processID == target.processIdentifier && (window.title == "Builder Nutch" || window.title?.contains("Appearance") == true) {
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let config = SCStreamConfiguration()
    config.width = Int(window.frame.width * 2)
    config.height = Int(window.frame.height * 2)
    config.showsCursor = false
    config.ignoreShadowsSingleWindow = true
    let capture: CGImage = try await withCheckedThrowingContinuation { continuation in
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, error in
            if let image { continuation.resume(returning: image) }
            else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
        }
    }
    let name = (window.title?.contains("Appearance") == true) ? "appearance" : (window.title == "Builder Nutch" ? "accounts" : "notch")
    let url = folder.appendingPathComponent("\(name).png")
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { continue }
    CGImageDestinationAddImage(dest, capture, nil)
    guard CGImageDestinationFinalize(dest) else { continue }
    print("\(name): \(capture.width) × \(capture.height)")
}
