import AppKit
import Foundation
import UniformTypeIdentifiers

/// A portable statement from saved local history, without account or project data.
/// This is deliberately unsigned: it does not certify identity or independent verification.
struct UsageGenGenCertificate: Encodable {
    static let maximumSafeTokens = 9_007_199_254_740_991
    static let studioURL = URL(string: "https://connected-mate.github.io/gengen/studio/")!
    let id: UUID
    let issuedAt: Date
    let totalTokens: Int
    let route: String
    let graphiteReachedAt: Date?
    let eligibleAt: Date?
    let timeZone: String

    enum CertificateError: LocalizedError {
        case ineligible, unsafeTotal, invalidDate, invalidTimeZone
        var errorDescription: String? {
            switch self {
            case .ineligible:
                NSLocalizedString("GenGen requires Obsidian or two calendar months at Graphite in your saved history.", comment: "GenGen certificate error")
            case .unsafeTotal:
                NSLocalizedString("This token total is too large for a portable certificate.", comment: "GenGen certificate error")
            case .invalidDate:
                NSLocalizedString("The saved history dates cannot be used for a certificate.", comment: "GenGen certificate error")
            case .invalidTimeZone:
                NSLocalizedString("Choose a city time zone on your Mac before exporting this certificate.", comment: "GenGen certificate error")
            }
        }
    }

    init(report: UsageLedgerReport, issuedAt: Date = Date(), id: UUID = UUID()) throws {
        guard let progress = report.milestones else { throw CertificateError.ineligible }
        guard progress.totalTokens >= 0, progress.totalTokens <= Self.maximumSafeTokens else {
            throw CertificateError.unsafeTotal
        }
        guard issuedAt.timeIntervalSince1970.isFinite,
              report.generatedAt.timeIntervalSince1970.isFinite, report.generatedAt <= issuedAt else {
            throw CertificateError.invalidDate
        }
        let reportCalendar = report.calendar ?? Calendar.current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = reportCalendar.timeZone
        let zone = calendar.timeZone.identifier
        guard TimeZone.knownTimeZoneIdentifiers.contains(zone) || ["GMT", "UTC"].contains(zone) else {
            throw CertificateError.invalidTimeZone
        }
        // Require the actual frozen report to be eligible. Gregorian arithmetic
        // also ensures a web importer can reproduce calendar-month eligibility.
        let achievement = progress.genGen(at: report.generatedAt, calendar: calendar)
        guard progress.genGen(at: report.generatedAt, calendar: reportCalendar).reached,
              achievement.reached else { throw CertificateError.ineligible }
        let graphiteDate = progress.stamps.first { $0.level == UsagePodiumTier.graphite.rawValue }?.reachedAt
        for date in [graphiteDate, achievement.reachedAt].compactMap({ $0 }) {
            guard date.timeIntervalSince1970.isFinite, date <= report.generatedAt else {
                throw CertificateError.invalidDate
            }
        }
        self.id = id
        self.issuedAt = issuedAt
        self.totalTokens = progress.totalTokens
        self.route = progress.totalTokens >= UsagePodiumTier.obsidian.threshold ? "obsidian" : "graphite-duration"
        self.graphiteReachedAt = graphiteDate
        self.eligibleAt = achievement.reachedAt
        self.timeZone = zone
    }

    private enum CodingKeys: String, CodingKey {
        case schema, version, id, issuer, achievement, issuedAt, totalTokens, route
        case graphiteReachedAt, eligibleAt, timeZone, verification
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try container.encode("gengen-certificate", forKey: .schema)
        try container.encode(1, forKey: .version)
        try container.encode(id.uuidString, forKey: .id)
        try container.encode("Builder Nutch", forKey: .issuer)
        try container.encode("GenGen", forKey: .achievement)
        try container.encode(formatter.string(from: issuedAt), forKey: .issuedAt)
        try container.encode(totalTokens, forKey: .totalTokens)
        try container.encode(route, forKey: .route)
        if let graphiteReachedAt {
            try container.encode(formatter.string(from: graphiteReachedAt), forKey: .graphiteReachedAt)
        } else { try container.encodeNil(forKey: .graphiteReachedAt) }
        if let eligibleAt {
            try container.encode(formatter.string(from: eligibleAt), forKey: .eligibleAt)
        } else { try container.encodeNil(forKey: .eligibleAt) }
        try container.encode(timeZone, forKey: .timeZone)
        try container.encode("local-history", forKey: .verification)
    }

    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    @MainActor
    static func save(_ data: Data, completion: @escaping @MainActor (Result<URL?, Error>) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "GenGen-certificate.json"
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
