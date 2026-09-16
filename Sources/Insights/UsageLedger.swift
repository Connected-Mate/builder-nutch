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
        let resumeIndex = cache.scanCursor.flatMap { cursor in sources.firstIndex { $0.projectsRoot.path == cursor.sourceRoot } }
        let startIndex = resumeIndex ?? 0
        var seenPaths = resumeIndex != nil ? (cache.scanSeenPaths ?? []) : []
        var lastCursor = resumeIndex != nil ? cache.scanCursor : nil
        var interrupted = false

        sourceLoop: for sourceIndex in startIndex..<sources.count {
            let source = sources[sourceIndex]
            if Task.isCancelled { interrupted = true; break }
            let afterPath = sourceIndex == resumeIndex ? cache.scanCursor?.filePath : nil
            let batch = transcripts(in: source.projectsRoot, after: afterPath,
                                    limit: max(0, limits.maxFiles - summary.filesSeen), deadline: started + budget)
            for file in batch.files {
                if Task.isCancelled || ProcessInfo.processInfo.systemUptime - started > budget {
                    interrupted = true
                    break sourceLoop
                }
                summary.filesSeen += 1
                seenPaths.insert(file.path)
                lastCursor = UsageLedgerScanCursor(sourceRoot: source.projectsRoot.path, filePath: file.path)

                guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                      let size = (attributes[.size] as? NSNumber)?.uint64Value,
                      let modified = attributes[.modificationDate] as? Date else {
                    summary.filesSkipped += 1
                    continue
                }

                let cached = cache.entries[file.path]
                if let cached, cached.size == size, cached.modified == modified, !cached.truncated {
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
                    if cached != nil { summary.filesFromCache += 1 }
                    else { summary.filesSkipped += 1 }
                    continue
                }

                // A growing file, or a previously bounded read of the same
                // file, resumes at a complete-line checkpoint. Rewrites start
                // over. A continuation refresh can consume more bounded slices,
                // up to a byte and time budget, so it keeps making useful
                // progress without turning one refresh into an unbounded read.
                let grew = cached.map { size > $0.size } ?? false
                let continuesPartial = cached.map {
                    $0.truncated && size == $0.size && modified == $0.modified
                } ?? false
                let resumable = (grew || continuesPartial) && cached?.resumeFingerprint != nil
                    && cached?.resumeFingerprint == UsageLedgerCache.resumeFingerprint(for: file, offset: cached?.offset ?? 0)
                var nextOffset = resumable ? (cached?.offset ?? 0) : 0
                var checkpoint = resumable ? (cached?.checkpoint ?? UsageTranscriptCheckpoint())
                                           : UsageTranscriptCheckpoint()
                var incremental: UsageSessionDigest?
                var finalTruncated = false
                var parsedSlice = false
                let continuesWithinRefresh = cached?.truncated == true
                let continuationByteBudget = max(limits.maxFileBytes, 1024 * 1024)
                var continuationBytesRead = 0

                while true {
                    if Task.isCancelled { summary.hitLimit = true; break }
                    let before = nextOffset
                    guard var outcome = try? scanner.scan(file: file, from: nextOffset,
                                                          sessionIDHint: resumable ? (cached?.digest.sessionID ?? Self.sessionIDHint(for: file)) : Self.sessionIDHint(for: file),
                                                          managedAccountID: source.managedAccountID,
                                                          format: source.format,
                                                          checkpoint: checkpoint) else { break }
                    parsedSlice = true
                    if outcome.consumed >= size { outcome.truncated = false }
                    if var accumulated = incremental {
                        accumulated.merge(outcome.digest)
                        incremental = accumulated
                    } else {
                        // Keep the canonical thread/session identifier learned
                        // from the transcript instead of the filename hint.
                        incremental = outcome.digest
                    }
                    nextOffset = outcome.consumed
                    checkpoint = outcome.checkpoint
                    finalTruncated = outcome.truncated
                    continuationBytesRead += outcome.bytesRead
                    summary.bytesRead += outcome.bytesRead
                    summary.malformedLines += outcome.malformedLines
                    summary.oversizedLines += outcome.oversizedLines
                    guard continuesWithinRefresh, outcome.truncated, nextOffset > before,
                          continuationBytesRead < continuationByteBudget,
                          ProcessInfo.processInfo.systemUptime - started <= budget else { break }
                }

                guard parsedSlice else {
                    summary.filesSkipped += 1
                    continue
                }

                guard let incremental else { continue }
                var digest: UsageSessionDigest
                if resumable, var previous = cached?.digest {
                    // The canonical identifier may exist only before the resume
                    // offset. Preserve it while adding the new slice.
                    previous.merge(incremental)
                    digest = previous
                } else {
                    digest = incremental
                }
                cache.entries[file.path] = UsageLedgerCacheEntry(size: size, modified: modified,
                                                                 offset: nextOffset, digest: digest,
                                                                 truncated: finalTruncated, checkpoint: checkpoint,
                                                                 resumeFingerprint: UsageLedgerCache.resumeFingerprint(for: file, offset: nextOffset))
                summary.filesParsed += 1
                if finalTruncated { summary.hitLimit = true }
            }
            if !batch.reachedEnd {
                interrupted = true
                break
            }
        }

        if interrupted {
            summary.hitLimit = true
            cache.scanCursor = lastCursor
            cache.scanSeenPaths = seenPaths
        } else {
            // A full sweep can span several bounded passes. Only its complete
            // inventory is allowed to prune the disposable cache.
            cache.prune(keeping: seenPaths)
            cache.scanCursor = nil
            cache.scanSeenPaths = nil
        }
        summary.hitLimit = summary.hitLimit || cache.entries.values.contains(where: \.truncated)
        summary.duration = ProcessInfo.processInfo.systemUptime - started
        // Unvisited files retain their last known digest during a partial sweep.
        return (Self.merge(cache.entries.values.map(\.digest)), summary)
    }

    private struct TranscriptBatch {
        var files: [URL] = []
        var reachedEnd = true
    }

    /// Resume a bounded depth-first enumeration after its last visited file.
    /// If that file disappeared, restart this source so deletion cannot leave
    /// the cursor permanently stuck. Cancellation/time bounds also cover skips.
    private func transcripts(in root: URL, after path: String?, limit: Int, deadline: TimeInterval) -> TranscriptBatch {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return TranscriptBatch()
        }
        var batch = TranscriptBatch()
        var waitingForCursor = path != nil
        while let url = walker.nextObject() as? URL {
            if Task.isCancelled || ProcessInfo.processInfo.systemUptime > deadline {
                batch.reachedEnd = false
                break
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { walker.skipDescendants(); continue }
            if values?.isDirectory == true {
                if url.lastPathComponent == "tool-results" { walker.skipDescendants() }
                continue
            }
            if waitingForCursor {
                if url.path == path { waitingForCursor = false }
                continue
            }
            guard url.pathExtension == "jsonl" else { continue }
            guard batch.files.count < limit else { batch.reachedEnd = false; break }
            batch.files.append(url)
        }
        if waitingForCursor, batch.reachedEnd {
            return transcripts(in: root, after: nil, limit: limit, deadline: deadline)
        }
        return batch
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
                                 accounts: shares, timeline: timelineSlices, scan: summary, calendar: calendar)
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
        if let attribution = session.archivedAttribution {
            if let account = session.archivedAccountID {
                return AccountKey(key: "profile:\(account)", managedAccountID: account,
                                  vendorAccountID: nil, attribution: attribution, provider: .claude)
            }
            return AccountKey(key: "unknown", managedAccountID: nil, vendorAccountID: nil,
                              attribution: .unknown, provider: .claude)
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

private struct UsageLedgerState {
    private var engine: UsageLedgerEngine
    private let cacheURL: URL
    private var cache: UsageLedgerCache?
    private let archiveURL: URL
    private var lastArchive: UsageLedgerArchive?
    private var migratedCache = false
    private var lastCapture = UsageCaptureResult(scan: UsageScanSummary(), persistence: .notCaptured)

    init(sources: [UsageLedgerSource], cacheURL: URL, limits: UsageLedgerLimits = .default,
         calendar: Calendar = .current, timeline: UsageAccountTimeline = UsageAccountTimeline(),
         archiveURL: URL? = nil) {
        self.engine = UsageLedgerEngine(sources: sources, limits: limits, calendar: calendar, timeline: timeline)
        self.cacheURL = cacheURL
        self.archiveURL = archiveURL ?? UsageLedger.defaultArchiveURL(catalogRoot: cacheURL.deletingLastPathComponent().deletingLastPathComponent())
    }

    mutating func updateSources(_ sources: [UsageLedgerSource], timeline: UsageAccountTimeline) {
        engine.sources = sources
        engine.timeline = timeline
    }

    /// The default week view: today plus the six preceding local dates.
    mutating func report(days: Int = 7, now: Date = Date()) -> UsageLedgerReport {
        _ = capture(now: now)
        return cachedReport(days: days, now: now)
    }

    /// Change the viewing window using only the last saved in-memory snapshot.
    /// Scan coverage and persistence failures remain those of the last capture.
    func cachedReport(days: Int = 7, now: Date = Date()) -> UsageLedgerReport {
        let captured = lastCapture
        var sessions = lastArchive?.digests ?? []
        // Titles remain disposable cache metadata, never permanent history.
        let titles = (cache?.entries.values.map(\.digest) ?? []).reduce(into: [String: String]()) { result, digest in
            if let title = digest.title { result[digest.sessionID] = title }
        }
        for index in sessions.indices { sessions[index].title = titles[sessions[index].sessionID] }
        var report = UsageLedgerEngine.report(sessions: sessions, summary: captured.scan, days: days, now: now,
                                              calendar: engine.calendar, timeline: engine.timeline)
        report.persistence = captured.persistence
        if lastArchive != nil {
            report.milestones = UsageMilestoneProgress(sessions: sessions, now: now, calendar: engine.calendar)
        }
        return report
    }

    /// Bounded background collection across all ages. It commits the old cache
    /// before scanning can prune anything, then commits new observations before
    /// replacing the disposable cache. Failures remain visible to the caller.
    mutating func capture(now: Date = Date()) -> UsageCaptureResult {
        let result = performCapture(now: now)
        lastCapture = result
        return result
    }

    private mutating func performCapture(now: Date) -> UsageCaptureResult {
        var summary = UsageScanSummary()
        do {
            try Task.checkCancellation()
            var current = cache ?? UsageLedgerCache.load(from: cacheURL)
            if !migratedCache {
                let migration = try UsageLedgerCache.loadForArchive(from: cacheURL)
                lastArchive = try UsageLedgerArchiveStore.update(at: archiveURL, now: now) { archive in
                    archive.absorb(Array(migration.entries.values.map(\.digest)) + Array(current.entries.values.map(\.digest)),
                                   timeline: engine.timeline)
                }
                migratedCache = true
            }
            try Task.checkCancellation()
            var boundedEngine = engine
            boundedEngine.limits.initialTimeBudget = min(engine.limits.initialTimeBudget, engine.limits.timeBudget)
            let scanned = boundedEngine.scan(cache: &current)
            summary = scanned.summary
            try Task.checkCancellation()
            lastArchive = try UsageLedgerArchiveStore.update(at: archiveURL, now: now) { archive in
                archive.absorb(current.entries.values.map(\.digest), timeline: engine.timeline,
                               completeReplays: current.entries.values.filter { !$0.truncated && $0.digest.recordedEventsComplete == true }.map(\.digest))
            }
            guard current.save(to: cacheURL) else { throw UsageArchiveError.checkpointUnavailable }
            cache = current
            return UsageCaptureResult(scan: summary, persistence: UsagePersistenceStatus(state: .saved, savedAt: lastArchive?.savedAt))
        } catch {
            // Keep the last successfully decoded archive available in this
            // process; never claim pending observations have been saved.
            if lastArchive == nil { lastArchive = try? UsageLedgerArchiveStore.read(from: archiveURL) }
            return UsageCaptureResult(scan: summary,
                                      persistence: UsagePersistenceStatus(state: .failed, savedAt: lastArchive?.savedAt,
                                                                          message: error.localizedDescription))
        }
    }

}

/// App-facing actor: all collection and disk work stays off the main thread.
actor UsageLedger {
    private var state: UsageLedgerState

    init(sources: [UsageLedgerSource], cacheURL: URL, limits: UsageLedgerLimits = .default,
         calendar: Calendar = .current, timeline: UsageAccountTimeline = UsageAccountTimeline(),
         archiveURL: URL? = nil) {
        state = UsageLedgerState(sources: sources, cacheURL: cacheURL, limits: limits,
                                 calendar: calendar, timeline: timeline, archiveURL: archiveURL)
    }

    func updateSources(_ sources: [UsageLedgerSource], timeline: UsageAccountTimeline) {
        state.updateSources(sources, timeline: timeline)
    }

    func capture(now: Date = Date()) -> UsageCaptureResult { state.capture(now: now) }

    func report(days: Int = 7, now: Date = Date()) -> UsageLedgerReport { state.report(days: days, now: now) }

    func cachedReport(days: Int = 7, now: Date = Date()) -> UsageLedgerReport { state.cachedReport(days: days, now: now) }

    /// The diagnostic command uses exactly the same transaction as the app,
    /// under the same cross-process archive lock, without a SwiftUI run loop.
    static func persistentReport(sources: [UsageLedgerSource], cacheURL: URL, days: Int = 7,
                                 now: Date = Date(), limits: UsageLedgerLimits = .default,
                                 calendar: Calendar = .current, timeline: UsageAccountTimeline = .init(),
                                 archiveURL: URL? = nil) -> UsageLedgerReport {
        var state = UsageLedgerState(sources: sources, cacheURL: cacheURL, limits: limits,
                                     calendar: calendar, timeline: timeline, archiveURL: archiveURL)
        return state.report(days: days, now: now)
    }

    /// Where transcripts live on this Mac: Claude's shared and isolated homes,
    /// plus Codex's local rollout sessions.
    static func defaultSources(home: URL, catalogRoot: URL) -> [UsageLedgerSource] {
        var sources = [UsageLedgerSource(projectsRoot: home.appendingPathComponent(".claude/projects", isDirectory: true),
                                         managedAccountID: nil, format: .claude),
                       UsageLedgerSource(projectsRoot: home.appendingPathComponent(".codex/sessions", isDirectory: true),
                                         managedAccountID: nil, format: .codex),
                       UsageLedgerSource(projectsRoot: home.appendingPathComponent(".codex/archived_sessions", isDirectory: true),
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

    static func defaultArchiveURL(catalogRoot: URL) -> URL {
        catalogRoot.appendingPathComponent("history", isDirectory: true)
            .appendingPathComponent("token-history-v1.json")
    }

    static func defaultCacheURL(catalogRoot: URL) -> URL {
        catalogRoot.appendingPathComponent("insights", isDirectory: true)
            .appendingPathComponent("usage-ledger.json")
    }
}
