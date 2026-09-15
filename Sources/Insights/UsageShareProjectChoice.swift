import Foundation

/// Selection labels may distinguish folders; exported cards retain only the
/// selected project's display name, never this path or its parent folders.
struct UsageShareProjectChoice: Identifiable, Equatable {
    let path: String
    let name: String
    let displayName: String
    var id: String { path }

    static func make(report: UsageLedgerReport) -> [UsageShareProjectChoice] {
        var byPath: [String: String] = [:]
        for account in report.accounts {
            for project in account.projects { byPath[project.path] = project.name }
        }
        let groups = Dictionary(grouping: byPath.keys, by: { byPath[$0]! })
        return byPath.map { path, name in
            let peers = groups[name] ?? [path]
            let label: String
            if peers.count > 1 {
                let components = path.split(separator: "/").map(String.init)
                var depth = 2
                while depth < components.count {
                    let candidate = components.suffix(depth).joined(separator: "/")
                    let matches = peers.filter { $0.split(separator: "/").suffix(depth).joined(separator: "/") == candidate }
                    if matches.count == 1 { break }
                    depth += 1
                }
                label = components.suffix(depth).joined(separator: "/")
            } else {
                label = name
            }
            return UsageShareProjectChoice(path: path, name: name, displayName: label)
        }.sorted {
            $0.displayName == $1.displayName ? $0.path < $1.path
                : $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }
}
