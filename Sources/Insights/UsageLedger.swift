import Foundation

/// One place transcripts live: a Claude home, or Codex's local session store.
struct UsageLedgerSource: Equatable {
    /// The directory recursively containing transcript JSONL files.
    var projectsRoot: URL
    /// The Builder Nutch account that owns this home, when it is an isolated
    /// profile. Nil for the shared home, where the account has to be deduced.
    var managedAccountID: String?
    var format: UsageTranscriptFormat = .claude
}

/// Reads the transcripts and answers "where did the quota go".
///
/// Synchronous and injectable on purpose: every rule here — which files count,
/// how a session is weighed, how a window is cut — is testable without a clock,
/// a home directory or an app. `UsageLedger` is the thin actor around it.
struct UsageLedgerEngine {
    var sources: [UsageLedgerSource]
    var limits: UsageLedgerLimits = .default
    /// The person's calendar, because "mardi soir" is a local fact.
    var calendar: Calendar = .current
    /// Which account was logged in when, for the shared home.
    var timeline = UsageAccountTimeline()

    // MARK: - Reading

    /// Refreshes the digests, reading only what changed since the last pass.
    ///
    /// `horizon` is the oldest moment the caller cares about. A transcript last
    /// written before it cannot contain an activity minute after it — writing moves
    /// the date — so it is left unopened. On this Mac that turns a 470-file,
    /// half-gigabyte read into a handful of files.
    func scan(cache: inout UsageLedgerCache, horizon: Date? = nil) -> (sessions: [UsageSessionDigest], summary: UsageScanSummary) {
        var summary = UsageScanSummary()
        let started = ProcessInfo.processInfo.systemUptime
        let budget = cache.entries.isEmpty ? limits.initialTimeBudget : limits.timeBudget
        let scanner = UsageTranscriptScanner(limits: limits)
        var digests: [UsageSessionDigest] = []
        var seenPaths: Set<String> = []

        for source in sources {
            for file in transcripts(in: source.projectsRoot, summary: &summary) {
                guard summary.filesSeen < limits.maxFiles else {
                    summary.hitLimit = true
                    break
                }
                summary.filesSeen += 1
                seenPaths.insert(file.path)

                guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                      let size = (attributes[.size] as? NSNumber)?.uint64Value,
                      let modified = attributes[.modificationDate] as? Date else {
                    summary.filesSkipped += 1
                    continue
                }

                let cached = cache.entries[file.path]
                if let cached, cached.size == size, cached.modified == modified, !cached.truncated {
                    digests.append(cached.digest)
                    summary.filesFromCache += 1
                    continue
                }

                if let horizon, modified < horizon {
                    summary.filesOutsideWindow += 1
                    continue
                }

                // Out of time: keep whatever the last pass knew rather than
                // dropping a project off the screen, and say the pass was partial.
                if ProcessInfo.processInfo.systemUptime - started > budget {
                    summary.hitLimit = true
                    if let cached { digests.append(cached.digest); summary.filesFromCache += 1 }
                    else { summary.filesSkipped += 1 }
                    continue
                }

                // A growing file, or a previously bounded read of the same
                // file, resumes at a complete-line checkpoint. Rewrites start
                // over. A continuation refresh gets two bounded slices so a
                // modest over-limit file can finish without an unbounded read.
                let grew = cached.map { size > $0.size } ?? false
                let continuesPartial = cached.map {
                    $0.truncated && size == $0.size && modified == $0.modified
                } ?? false
                let resumable = grew || continuesPartial
                var nextOffset = resumable ? (cached?.offset ?? 0) : 0
                var checkpoint = resumable ? (cached?.checkpoint ?? UsageTranscriptCheckpoint())
                                           : UsageTranscriptCheckpoint()
                var incremental = UsageSessionDigest(sessionID: Self.sessionIDHint(for: file), provider: source.format)
                incremental.managedAccountID = source.managedAccountID
                var finalTruncated = false
                var parsedSlice = false
                let sliceCount = cached?.truncated == true ? 2 : 1

                for _ in 0..<sliceCount {
                    let before = nextOffset
                    guard var outcome = try? scanner.scan(file: file, from: nextOffset,
                                                          sessionIDHint: Self.sessionIDHint(for: file),
                                                          managedAccountID: source.managedAccountID,
                                                          format: source.format,
                                                          checkpoint: checkpoint) else { break }
                    parsedSlice = true
                    if outcome.consumed >= size { outcome.truncated = false }
                    incremental.merge(outcome.digest)
                    nextOffset = outcome.consumed
                    checkpoint = outcome.checkpoint
                    finalTruncated = outcome.truncated
                    summary.bytesRead += outcome.bytesRead
                    summary.malformedLines += outcome.malformedLines
                    summary.oversizedLines += outcome.oversizedLines
                    guard outcome.truncated, nextOffset > before,
                          ProcessInfo.processInfo.systemUptime - started <= budget else { break }
                }

                guard parsedSlice else {
                    summary.filesSkipped += 1
                    if let cached { digests.append(cached.digest) }
                    continue
                }

                var digest = incremental
                if resumable, let previous = cached?.digest { digest.merge(previous) }
                digests.append(digest)
                cache.entries[file.path] = UsageLedgerCacheEntry(size: size, modified: modified,
                                                                 offset: nextOffset, digest: digest,
                                                                 truncated: finalTruncated, checkpoint: checkpoint)
                summary.filesParsed += 1
                if finalTruncated { summary.hitLimit = true }
            }
        }

        // Every file was *listed*, even the ones too old to open, so a missing
        // path really is a deleted transcript. A pass that stopped early listed
        // only part of the tree and is not allowed to forget the rest.
        if !summary.hitLimit { cache.prune(keeping: seenPaths) }
        summary.duration = ProcessInfo.processInfo.systemUptime - started
        return (Self.merge(digests), summary)
    }

    /// Every `.jsonl` under a projects root, subagent transcripts included —
    /// their tokens are as real as anyone else's. Tool results are skipped
    /// wholesale: they are most of the bytes and none of the usage.
    private func transcripts(in root: URL, summary: inout UsageScanSummary) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return []
        }
        var files: [URL] = []
        while let url = walker.nextObject() as? URL {
            guard files.count < limits.maxFiles else {
                summary.hitLimit = true
                break
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            // A symlink could point anywhere, including outside the home this
            // source is supposed to cover. Never follow one.
            if values?.isSymbolicLink == true { walker.skipDescendants(); continue }
            if values?.isDirectory == true {
                if url.lastPathComponent == "tool-results" { walker.skipDescendants() }
                continue
            }
            if url.pathExtension == "jsonl" { files.append(url) }
        }
        return files
    }

    /// The session a file belongs to, before any line is read.
    /// `<slug>/<session>.jsonl` names it directly; a subagent transcript sits in
    /// `<session>/subagents/`, so the session is two levels up.
    static func sessionIDHint(for file: URL) -> String {
        let parent = file.deletingLastPathComponent()
        if parent.lastPathComponent == "subagents" {
            let owner = parent.deletingLastPathComponent().lastPathComponent
            if !owner.isEmpty { return owner }
        }
        return file.deletingPathExtension().lastPathComponent
    }

    /// One session is written across several files; a copied home can even hold
    /// it twice. Adding the files together is right for the first case and would
    /// double-count the second, so identical digests collapse instead of summing.
    static func merge(_ digests: [UsageSessionDigest]) -> [UsageSessionDigest] {
        var bySession: [String: UsageSessionDigest] = [:]
        var seen: Set<String> = []
        for digest in digests {
            // Two files with the same session, the same span and the same totals
            // are the same transcript in two places.
            let tokens = digest.tokens
            let fingerprint = "\(digest.sessionID)|\(digest.messages)|\(tokens.input)|\(tokens.output)|"
                + "\(tokens.cacheCreation)|\(tokens.cacheRead)|\(tokens.thinking)|"
                + "\(tokens.measurements)|\(tokens.claudeMeasurements)|\(tokens.codexMeasurements)|\(Int(digest.weight))|"
                + "\(digest.provider.rawValue)|\(digest.firstActivity?.timeIntervalSince1970 ?? 0)"
            guard seen.insert(fingerprint).inserted else { continue }
            if var existing = bySession[digest.sessionID] {
                existing.merge(digest)
                bySession[digest.sessionID] = existing
            } else {
                bySession[digest.sessionID] = digest
            }
        }
        return Array(bySession.values)
    }

    // MARK: - Reporting

    /// The report the UI will read. `days` means local calendar days including
    /// today, so every observed request belongs wholly inside or outside the
    /// window; token counts are never prorated from elapsed time.
    func report(days: Int, now: Date, cache: inout UsageLedgerCache) -> UsageLedgerReport {
        // A day of slack: a file whose clock or flush lands just before the
        // window opens is still worth reading.
        let horizon = now.addingTimeInterval(-Double(max(1, days)) * 86_400 - 86_400)
        let scanned = scan(cache: &cache, horizon: horizon)
        return Self.report(sessions: scanned.sessions, summary: scanned.summary, days: days, now: now,
                           calendar: calendar, timeline: timeline)
    }

    /// The pure half: digests in, report out. No filesystem, no clock.
    static func report(sessions: [UsageSessionDigest], summary: UsageScanSummary, days: Int, now: Date,
                       calendar: Calendar, timeline: UsageAccountTimeline) -> UsageLedgerReport {
        let boundedDays = max(1, days)
        let today = calendar.startOfDay(for: now)
        let windowStart = calendar.date(byAdding: .day, value: -(boundedDays - 1), to: today) ?? today
        var accounts: [String: AccountAccumulator] = [:]
        var overall = Accumulator()
        var overallDays: [String: Accumulator] = [:]

        for session in sessions {
            guard let window = Self.window(of: session, from: windowStart, to: now, calendar: calendar),
                  window.total.weight > 0 else { continue }

            let key = Self.accountKey(for: session, activeAt: window.lastActivity ?? session.lastActivity, timeline: timeline)
            var account = accounts[key.key] ?? AccountAccumulator(key: key)
            account.absorb(session: session, window: window, attribution: key.attribution)
            accounts[key.key] = account

            overall.add(window.total, first: window.firstActivity, last: window.lastActivity)
            for (day, bucket) in window.byDay {
                overallDays[day, default: Accumulator()].add(bucket, first: nil, last: nil)
            }
        }

        let total = overall.weight
        let shares = accounts.values
            .map { $0.share(totalWeight: total, calendar: calendar) }
            .sorted { $0.weight > $1.weight }
        let timelineSlices = overallDays
            .map { UsageDaySlice(day: $0.key, weight: $0.value.weight, sharePercent: Self.percent($0.value.weight, of: total),
                                 tokens: $0.value.tokens, messages: $0.value.messages) }
            .sorted { $0.day < $1.day }

        return UsageLedgerReport(generatedAt: now, windowStart: windowStart, windowEnd: now, days: boundedDays,
                                 totalWeight: total, tokens: overall.tokens, messages: overall.messages,
                                 sessionCount: shares.reduce(0) { $0 + $1.sessionCount },
                                 accounts: shares, timeline: timelineSlices, scan: summary)
    }

    // MARK: - Window arithmetic

    /// The part of a session that falls inside the report window, cut at the
    /// recorded minute. A session that started last month still counts only for
    /// the activity observed inside this window.
    struct SessionWindow {
        var total = UsageTimeBucket()
        var byDay: [String: UsageTimeBucket] = [:]
        var firstActivity: Date?
        var lastActivity: Date?
        /// How much of the whole session this window represents, used to split
        /// whole-session figures proportionally.
        var fraction: Double = 0
    }

    static func window(of session: UsageSessionDigest, from start: Date, to end: Date,
                       calendar: Calendar) -> SessionWindow? {
        var window = SessionWindow()
        let formatter = Self.dayFormatter(calendar: calendar)
        for (key, bucket) in session.activityMinutes {
            guard let minute = Int(key) else { continue }
            let date = Date(timeIntervalSince1970: Double(minute) * 60)
            guard date >= start, date <= end else { continue }
            window.total = window.total + bucket
            let day = formatter.string(from: date)
            window.byDay[day] = (window.byDay[day] ?? UsageTimeBucket()) + bucket
            window.firstActivity = min(window.firstActivity ?? date, date)
            window.lastActivity = max(window.lastActivity ?? date, date)
        }
        guard window.total.weight > 0 else { return nil }
        window.fraction = session.weight > 0 ? min(1, window.total.weight / session.weight) : 1
        // Exact endpoints refine the minute bucket for display.
        if let first = session.firstActivity, first >= start, first <= end { window.firstActivity = first }
        if let last = session.lastActivity, last >= start, last <= end { window.lastActivity = last }
        return window
    }

    /// Which account paid, and how sure we are. A transcript inside an account's
    /// own home is proof; the vendor identifier in the file is proof of the
    /// subscription; the login timeline is a deduction; after that we say so.
    static func accountKey(for session: UsageSessionDigest, activeAt date: Date?,
                           timeline: UsageAccountTimeline) -> AccountKey {
        if session.provider == .codex {
            // Local Codex telemetry identifies the provider, not the paying
            // Builder Nutch account. Claude's login timeline cannot fill that
            // gap without inventing attribution.
            return AccountKey(key: "codex:unknown", managedAccountID: nil,
                              vendorAccountID: nil, attribution: .unknown, provider: .codex)
        }
        if let managed = session.managedAccountID {
            return AccountKey(key: "profile:\(managed)", managedAccountID: managed,
                              vendorAccountID: session.vendorAccountID, attribution: .explicit, provider: .claude)
        }
        if let vendor = session.vendorAccountID {
            return AccountKey(key: "vendor:\(vendor)", managedAccountID: nil,
                              vendorAccountID: vendor, attribution: .explicit, provider: .claude)
        }
        if let date, let deduced = timeline.accountID(at: date) {
            return AccountKey(key: "profile:\(deduced)", managedAccountID: deduced,
                              vendorAccountID: nil, attribution: .deduced, provider: .claude)
        }
        return AccountKey(key: "unknown", managedAccountID: nil, vendorAccountID: nil,
                          attribution: .unknown, provider: .claude)
    }

    struct AccountKey: Equatable {
        let key: String
        let managedAccountID: String?
        let vendorAccountID: String?
        let attribution: UsageAttribution
        let provider: UsageTranscriptFormat
    }

    static func percent(_ value: Double, of total: Double) -> Double {
        guard total > 0, value.isFinite else { return 0 }
        return (value / total * 1000).rounded() / 10
    }

    static func dayFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    // MARK: - Accumulators

    struct Accumulator {
        var tokens = UsageTokenTotals()
        var weight = 0.0
        var messages = 0
        var firstActivity: Date?
        var lastActivity: Date?

        mutating func add(_ bucket: UsageTimeBucket, first: Date?, last: Date?) {
            tokens += bucket.tokens
            weight += bucket.weight
            messages += bucket.messages
            if let first { firstActivity = min(firstActivity ?? first, first) }
            if let last { lastActivity = max(lastActivity ?? last, last) }
        }
    }

    struct SessionEntry {
        var digest: UsageSessionDigest
        var window: SessionWindow
    }

    struct ProjectAccumulator {
        var path: String
        var totals = Accumulator()
        var days: [String: Accumulator] = [:]
        var sessions: [SessionEntry] = []
    }

    struct AccountAccumulator {
        let key: AccountKey
        var attribution: UsageAttribution
        var vendorAccountID: String?
        var totals = Accumulator()
        var days: [String: Accumulator] = [:]
        var projects: [String: ProjectAccumulator] = [:]

        init(key: AccountKey) {
            self.key = key
            self.attribution = key.attribution
            self.vendorAccountID = key.vendorAccountID
        }

        /// One account bucket can be reached both ways: a transcript in its own
        /// profile is proof, one merely dated while it was logged in is not.
        /// The bucket is only as sure as its least sure session.
        mutating func absorb(session: UsageSessionDigest, window: SessionWindow, attribution: UsageAttribution) {
            if attribution.rank < self.attribution.rank { self.attribution = attribution }
            if session.vendorAccountID != nil { vendorAccountID = vendorAccountID ?? session.vendorAccountID }
            totals.add(window.total, first: window.firstActivity, last: window.lastActivity)
            for (day, bucket) in window.byDay { days[day, default: Accumulator()].add(bucket, first: nil, last: nil) }
            let path = session.resolvedProjectPath
            var project = projects[path] ?? ProjectAccumulator(path: path)
            project.totals.add(window.total, first: window.firstActivity, last: window.lastActivity)
            for (day, bucket) in window.byDay { project.days[day, default: Accumulator()].add(bucket, first: nil, last: nil) }
            project.sessions.append(SessionEntry(digest: session, window: window))
            projects[path] = project
        }

        func share(totalWeight: Double, calendar: Calendar) -> AccountUsageShare {
            let projectSlices = projects.values
                .map { Self.slice($0, accountWeight: totals.weight, totalWeight: totalWeight, calendar: calendar) }
                .sorted { $0.weight > $1.weight }
            let daySlices = days
                .map { UsageDaySlice(day: $0.key, weight: $0.value.weight,
                                     sharePercent: UsageLedgerEngine.percent($0.value.weight, of: totals.weight),
                                     tokens: $0.value.tokens, messages: $0.value.messages) }
                .sorted { $0.day < $1.day }
            return AccountUsageShare(
                accountKey: key.key, managedAccountID: key.managedAccountID, vendorAccountID: vendorAccountID,
                attribution: attribution, provider: key.provider, weight: totals.weight,
                sharePercent: UsageLedgerEngine.percent(totals.weight, of: totalWeight),
                tokens: totals.tokens, messages: totals.messages,
                sessionCount: projects.values.reduce(0) { $0 + $1.sessions.count },
                firstActivity: totals.firstActivity, lastActivity: totals.lastActivity,
                projects: projectSlices, days: daySlices)
        }

        static func slice(_ project: ProjectAccumulator, accountWeight: Double, totalWeight: Double,
                          calendar: Calendar) -> UsageProjectSlice {
            let sessionSlices = project.sessions
                .map { entry -> UsageSessionSlice in
                    UsageSessionSlice(
                        sessionID: entry.digest.sessionID, title: entry.digest.title,
                        weight: entry.window.total.weight,
                        sharePercent: UsageLedgerEngine.percent(entry.window.total.weight, of: project.totals.weight),
                        tokens: entry.window.total.tokens, messages: entry.window.total.messages,
                        firstActivity: entry.window.firstActivity, lastActivity: entry.window.lastActivity,
                        dominantModel: entry.digest.modelWeights.max { $0.value < $1.value }?.key)
                }
                .sorted { $0.weight > $1.weight }

            // Sessions that share a title are one subject. Untitled sessions
            // stay untitled rather than being lumped into a fake "other".
            var topics: [String: (weight: Double, tokens: UsageTokenTotals, ids: [String], last: Date?, count: Int)] = [:]
            for entry in project.sessions {
                guard let title = entry.digest.title else { continue }
                var topic = topics[title] ?? (0, UsageTokenTotals(), [], nil, 0)
                topic.weight += entry.window.total.weight
                topic.tokens += entry.window.total.tokens
                topic.ids.append(entry.digest.sessionID)
                topic.count += 1
                if let last = entry.window.lastActivity { topic.last = max(topic.last ?? last, last) }
                topics[title] = topic
            }
            let topicSlices = topics
                .map { UsageTopicSlice(title: $0.key, weight: $0.value.weight,
                                       sharePercent: UsageLedgerEngine.percent($0.value.weight, of: project.totals.weight),
                                       tokens: $0.value.tokens, sessionCount: $0.value.count,
                                       lastActivity: $0.value.last, sessionIDs: $0.value.ids) }
                .sorted { $0.weight > $1.weight }

            let daySlices = project.days
                .map { UsageDaySlice(day: $0.key, weight: $0.value.weight,
                                     sharePercent: UsageLedgerEngine.percent($0.value.weight, of: project.totals.weight),
                                     tokens: $0.value.tokens, messages: $0.value.messages) }
                .sorted { $0.day < $1.day }

            return UsageProjectSlice(
                path: project.path, name: UsageLedgerEngine.projectName(project.path),
                weight: project.totals.weight,
                sharePercent: UsageLedgerEngine.percent(project.totals.weight, of: accountWeight),
                overallSharePercent: UsageLedgerEngine.percent(project.totals.weight, of: totalWeight),
                tokens: project.totals.tokens, messages: project.totals.messages,
                sessionCount: project.sessions.count,
                firstActivity: project.totals.firstActivity, lastActivity: project.totals.lastActivity,
                topics: topicSlices, sessions: sessionSlices, days: daySlices)
        }
    }

    /// What the person calls the project: the folder's own name. A worktree like
    /// `…/worktrees/citizen-creators-2` keeps its name rather than collapsing
    /// into the checkout it came from — they are separate pieces of work.
    static func projectName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }
}

/// The app-facing ledger. An actor so a refresh — hundreds of files, tens of
/// megabytes — can never run on the main thread and stall the notch.
actor UsageLedger {
    private let engine: UsageLedgerEngine
    private let cacheURL: URL
    private var cache: UsageLedgerCache?

    init(sources: [UsageLedgerSource], cacheURL: URL, limits: UsageLedgerLimits = .default,
         calendar: Calendar = .current, timeline: UsageAccountTimeline = UsageAccountTimeline()) {
        self.engine = UsageLedgerEngine(sources: sources, limits: limits, calendar: calendar, timeline: timeline)
        self.cacheURL = cacheURL
    }

    /// The default week view: today plus the six preceding local dates.
    func report(days: Int = 7, now: Date = Date()) -> UsageLedgerReport {
        var current = cache ?? UsageLedgerCache.load(from: cacheURL)
        let report = engine.report(days: days, now: now, cache: &current)
        cache = current
        current.save(to: cacheURL)
        return report
    }

    /// Where transcripts live on this Mac: Claude's shared and isolated homes,
    /// plus Codex's local rollout sessions.
    static func defaultSources(home: URL, catalogRoot: URL) -> [UsageLedgerSource] {
        var sources = [UsageLedgerSource(projectsRoot: home.appendingPathComponent(".claude/projects", isDirectory: true),
                                         managedAccountID: nil, format: .claude),
                       UsageLedgerSource(projectsRoot: home.appendingPathComponent(".codex/sessions", isDirectory: true),
                                         managedAccountID: nil, format: .codex)]
        let profiles = catalogRoot.appendingPathComponent("profiles", isDirectory: true)
        let contents = (try? FileManager.default.contentsOfDirectory(at: profiles, includingPropertiesForKeys: [.isDirectoryKey],
                                                                     options: [.skipsHiddenFiles])) ?? []
        for directory in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = directory.lastPathComponent
            // Profile directories are named after the account row's own UUID,
            // which is what makes this attribution a fact rather than a guess.
            guard UUID(uuidString: name) != nil else { continue }
            let projects = directory.appendingPathComponent("projects", isDirectory: true)
            guard FileManager.default.fileExists(atPath: projects.path) else { continue }
            sources.append(UsageLedgerSource(projectsRoot: projects, managedAccountID: name.lowercased(), format: .claude))
        }
        return sources
    }

    static func defaultCacheURL(catalogRoot: URL) -> URL {
        catalogRoot.appendingPathComponent("insights", isDirectory: true)
            .appendingPathComponent("usage-ledger.json")
    }
}
