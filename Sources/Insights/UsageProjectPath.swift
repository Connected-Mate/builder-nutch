import Foundation

/// Turns a working directory into the project a person would name.
///
/// Agents run in throwaway git worktrees, and their directories are named after
/// the agent, not the work: `…/Citizen Creators Porgramme/.claude/worktrees/agent-a266d14b`.
/// Left alone, a week's work fragments into a dozen projects nobody recognises,
/// each one named after a hash. Folding a worktree back onto the project it was
/// cut from is what makes the ranking readable.
enum UsageProjectPath {
    /// The two shapes worktrees take on this Mac:
    ///
    /// - `<project>/.claude/worktrees/<agent>` — a worktree inside the project,
    ///   so the project is the directory holding `.claude`.
    /// - `<anywhere>/worktrees/<project>/<instance>` — a pool of worktrees kept
    ///   outside the checkout, where the directory named after the project is
    ///   one level below `worktrees`.
    ///
    /// Anything else is already a project and is returned untouched.
    static func normalize(_ path: String) -> String {
        var components = (path as NSString).pathComponents
        guard let index = components.lastIndex(of: "worktrees"), index > 0,
              index + 1 < components.count else { return path }

        if components[index - 1] == ".claude" || components[index - 1] == ".git" {
            guard index >= 2 else { return path }
            components = Array(components.prefix(index - 1))
        } else {
            components = Array(components.prefix(index + 2))
        }
        let normalized = NSString.path(withComponents: components)
        return normalized.isEmpty ? path : normalized
    }
}
