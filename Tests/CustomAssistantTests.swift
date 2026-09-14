import XCTest
@testable import Codenotch

final class CustomAssistantTests: XCTestCase {
    func testUnknownUsageDoesNotInventAQuota() throws {
        let assistant = try CustomAssistantConfiguration.validated(name: "My assistant", website: "https://example.com")
        let snapshot = assistant.snapshot()
        XCTAssertNil(snapshot.usedFraction)
        XCTAssertFalse(snapshot.hasReading)
        XCTAssertEqual(snapshot.fidelity, .manual)
        XCTAssertTrue(snapshot.id.hasPrefix("custom:"))
    }

    func testReportedUsageHasProvenanceAndBecomesStale() throws {
        let now = Date()
        var assistant = try CustomAssistantConfiguration.validated(name: "My assistant", website: "https://example.com")
        assistant.usage = CustomAssistantUsage(limits: [.init(label: "Session", usedPercent: 42.5, resetsAt: nil)],
                                                observedAt: now, source: "Subscription page")
        let snapshot = assistant.snapshot(now: now)
        XCTAssertEqual(snapshot.usedFraction, 0.425)
        XCTAssertEqual(snapshot.fidelity, .manual)
        XCTAssertFalse(snapshot.status.isStale)
        XCTAssertTrue(snapshot.headline?.label.contains("Reported by assistant") == true)
        XCTAssertTrue(assistant.snapshot(now: now.addingTimeInterval(3600)).status.isStale)
        assistant.usage?.limits[0].resetsAt = now.addingTimeInterval(20)
        XCTAssertTrue(assistant.snapshot(now: now.addingTimeInterval(21)).status.isStale)
    }

    func testUnsafeWebsitesAndUnboundedInputAreRejected() throws {
        for website in ["http://example.com", "file:///tmp/read", "https://localhost", "https://host.local",
                        "https://example.com?token=secret", "https://username:password@example.com"] {
            XCTAssertThrowsError(try CustomAssistantConfiguration.validated(name: "Test", website: website))
        }
        XCTAssertThrowsError(try CustomAssistantConfiguration.validated(name: " ", website: "https://example.com"))
        XCTAssertThrowsError(try CustomAssistantConfiguration.validated(name: "Test", website: "https://example.com", instructions: String(repeating: "a", count: 8001)))
    }

    func testInvalidUsageNeverReachesTheCatalog() {
        let now = Date()
        for percent in [-1.0, 100.1, .infinity, .nan] {
            let usage = CustomAssistantUsage(limits: [.init(label: "Session", usedPercent: percent)], observedAt: now, source: "Usage page")
            XCTAssertThrowsError(try usage.validate(now: now))
        }
        let future = CustomAssistantUsage(limits: [.init(label: "Session", usedPercent: 20)],
                                          observedAt: now.addingTimeInterval(301), source: "Usage page")
        XCTAssertThrowsError(try future.validate(now: now))
    }

    func testConfigurationPreservesFieldsUnlessExplicitlyCleared() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = CustomAssistantRepository(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = try repository.configure(id: nil, name: "My assistant", website: "https://example.com",
                                                instructions: "Respond in French", usageNote: "Notes")
        let updated = try repository.configure(id: initial.id, name: "Renamed", website: "https://example.com")
        XCTAssertEqual(updated.instructions, initial.instructions)
        XCTAssertEqual(updated.usageNote, initial.usageNote)
        let cleared = try repository.configure(id: initial.id, name: "Renamed", website: "https://example.com", instructions: "")
        XCTAssertEqual(cleared.instructions, "")
        XCTAssertEqual(cleared.usageNote, initial.usageNote)
    }

    func testEncodedCatalogLimitKeepsExistingProfilesReadable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = CustomAssistantRepository(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        // JSON escapes each control character into six bytes. The input character
        // limit alone cannot guarantee that a persisted catalog stays readable.
        let instructions = String(repeating: "\u{0001}", count: 8000)
        var saved = 0
        var rejected = false
        for index in 0..<100 {
            do {
                try repository.configure(id: nil, name: "Assistant \(index)", website: "https://example.com", instructions: instructions)
                saved += 1
            } catch {
                rejected = true
                break
            }
        }
        XCTAssertTrue(rejected)
        XCTAssertGreaterThan(saved, 0)
        XCTAssertEqual(try repository.list().count, saved)
        let size = try Data(contentsOf: root.appendingPathComponent("assistants.json")).count
        XCTAssertLessThanOrEqual(size, 4_000_000)
    }

    func testConnectionQuotesTheActualExecutableAndDoesNotInstallAnything() throws {
        let connection = CustomAssistantConnection(executable: "/Applications/Builder Nutch.app/Contents/MacOS/Codenotch")
        let data = Data(connection.configurationJSON.utf8)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let servers = try XCTUnwrap(json["mcpServers"] as? [String: [String: Any]])
        XCTAssertEqual(servers["builder-nutch"]?["command"] as? String, connection.executable)
        XCTAssertEqual(servers["builder-nutch"]?["args"] as? [String], [CustomAssistantMCPServer.flag])
        XCTAssertTrue(connection.prompt().contains("Never guess percentages"))
    }
}
