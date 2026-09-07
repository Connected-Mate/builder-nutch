import Foundation

/// Which side of a percentage the interface puts first.
enum UsageDisplayMode: String, CaseIterable, Identifiable {
    case remaining
    case used

    var id: Self { self }
    var title: String { self == .remaining ? "Remaining" : "Used" }
    var columnTitle: String { self == .remaining ? "REMAINING" : "USED" }
    var unit: String { self == .remaining ? "left" : "used" }
    var explanation: String {
        self == .remaining
            ? "See what you can still use. Rings empty as quota runs out."
            : "See what you have used. Rings fill as quota runs out."
    }

    func percentage(fromUsedFraction usedFraction: Double) -> Int {
        let used = Int((usedFraction * 100).rounded())
        return self == .remaining ? max(0, 100 - used) : used
    }

    func fraction(fromUsedFraction usedFraction: Double) -> Double {
        let clamped = min(max(usedFraction, 0), 1)
        return self == .remaining ? 1 - clamped : clamped
    }
}
