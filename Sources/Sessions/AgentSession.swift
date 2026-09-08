import Foundation

/// One agent session, whichever tool it belongs to.
///
/// Deliberately a *display* model rather than a mirror of any one tool's file
/// format: Claude Code publishes a session registry, Cursor keeps composer rows
/// in SQLite, and neither shape belongs in the notch. Each monitor does its own
/// parsing and hands back this.
struct AgentSession: Identifiable, Equatable {
    /// What the session is doing right now.
    enum State: Equatable {
        case busy
        case waiting
        case idle
    }

    let id: String
    /// What to call it in the tooltip.
    let name: String
    /// The quieter second line — where it is running, or what it is doing.
    let detail: String
    let state: State
    /// Set while `waiting`: what it wants from you.
    let waitingFor: String?
    /// When it entered its current state.
    let since: Date
    /// Claude-only handoff metadata. Other activity sources leave these nil.
    let processID: Int32?
    let conversationID: String?
    let workingDirectory: String?

    init(id: String, name: String, detail: String, state: State,
         waitingFor: String?, since: Date, processID: Int32? = nil,
         conversationID: String? = nil, workingDirectory: String? = nil) {
        self.id = id
        self.name = name
        self.detail = detail
        self.state = state
        self.waitingFor = waitingFor
        self.since = since
        self.processID = processID
        self.conversationID = conversationID
        self.workingDirectory = workingDirectory
    }
}
