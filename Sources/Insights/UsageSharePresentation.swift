import SwiftUI

/// One presentation for every entry point, including a notification opened
/// while the accounts window is closed. A cancelled request cannot reopen it.
@MainActor
final class UsageSharePresentation: ObservableObject {
    @Published private(set) var isPresented = false
    @Published private(set) var report: UsageLedgerReport?
    @Published private(set) var projectPath: String?
    @Published private(set) var failed = false
    @Published var isSaving = false
    @Published private(set) var requestID = UUID()
    private var task: Task<Void, Never>?

    func open(projectPath: String? = nil,
              load: @escaping @MainActor () async -> UsageLedgerReport?) {
        guard !isSaving else { return }
        task?.cancel()
        let id = UUID()
        requestID = id
        self.projectPath = projectPath
        report = nil
        failed = false
        isPresented = true
        task = Task { [weak self] in
            let report = await load()
            guard let self, !Task.isCancelled, self.requestID == id else { return }
            self.report = report
            self.failed = report == nil
            self.task = nil
        }
    }

    func close() {
        guard !isSaving else { return }
        requestID = UUID()
        task?.cancel()
        task = nil
        isPresented = false
        report = nil
        projectPath = nil
        failed = false
    }
}
