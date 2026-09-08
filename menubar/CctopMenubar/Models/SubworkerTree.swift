import Foundation

/// What one row of the Agents view represents.
enum SubworkerKind: Equatable {
    /// A Claude subagent recorded in its parent session's `active_subagents`.
    case inProcess(SubagentInfo)
    /// A whole delegated session record spawned by another harness.
    case delegated(SessionData)
}

/// Counts behind a group's summary line.
struct SubworkerGroupSummary: Equatable {
    let running: Int
    let waiting: Int

    /// Nil when "N running" is the whole story, since the row count already says that.
    var text: String? {
        guard waiting > 0 else { return nil }
        var parts: [String] = []
        if running > 0 { parts.append("\(running) running") }
        parts.append("\(waiting) waiting")
        return parts.joined(separator: " \u{00B7} ")
    }
}

/// Pure model behind the Agents view: which sub-workers each visible session currently owns.
///
/// Two kinds of sub-worker exist and they are deliberately kept separate:
///
/// - **in-process** — a Claude subagent recorded in the parent's own `active_subagents`.
/// - **delegated** — a whole hidden session record (`is_subagent`) that another harness
///   spawned, linked back by `parent_harness` / `parent_harness_session_id`.
///
/// Nothing here reads or writes session files, so the rules stay testable in isolation.
enum SubworkerTree {
    /// Chains deeper than this flatten onto the last supported level instead of indenting
    /// forever. Claude → Codex → Claude is the deepest chain observed in practice.
    static let maxDepth = 3

    /// An in-process subagent with no observed activity for this long leaves the view (not
    /// storage): the view is for work happening now, and a parent that never reports a
    /// `SubagentStop` (the ChatGPT app's Codex `collaboration` agents sat "stale" for 11 h on
    /// 2026-09-08) must not pin finished work on screen. A row blocked on a permission prompt
    /// is exempt; silence is exactly what waiting looks like. A subagent that goes quiet
    /// inside a long tool call comes back on its next event, because nothing is deleted.
    static let staleInterval: TimeInterval = 1_800

    /// Backstop only. Liveness decides what is shown; this catches the cases liveness
    /// cannot see — a missed `SubagentStop`, or a record whose process evidence never
    /// arrived. Nothing is deleted: the records stay on disk and in their own surfaces.
    static let visibilityWindow: TimeInterval = 3 * 3_600

    /// How recently a delegated record with no usable process evidence must have reported
    /// activity to still count as running.
    static let unevidencedActivityWindow: TimeInterval = 600

    /// The app's own process-liveness checks, minus one that does not apply and plus one
    /// extra turn of the screw.
    ///
    /// `SessionData.isRunningOwnedProcess` is the shared definition of "this work is still
    /// running": it rejects a dead or unreachable PID, a *foreign harness's* PID (the
    /// capture-time parent walk can adopt one), and a suspended process. Deliberately not
    /// `isAlive`, which additionally rejects a process reparented to launchd — right for
    /// focus, wrong here, because `nohup codex exec … & disown` is a normal way to start a
    /// long delegated run and it reparents to PID 1 the moment its launching shell exits.
    /// The parent link this view cares about is `parent_harness_session_id`, not the Unix
    /// PPID.
    ///
    /// The generation must then match `pidStartTime` *exactly*, not within
    /// `isRunningOwnedProcess`'s one-second tolerance: that tolerance is right for a session
    /// card that fails open, but here a PID reused inside the same second would keep an
    /// exited delegate on screen until the backstop. Both values come from the same kernel
    /// field and round-trip through JSON losslessly; if they ever disagree the record is
    /// hidden rather than shown, which is the safe direction for this view.
    static let liveProcessEvidence: (SessionData) -> Bool = { data in
        guard data.isRunningOwnedProcess, let pid = data.pid else { return false }
        return data.pidStartTime == SessionData.processStartTime(pid: pid)
    }

    static let unattributedGroupID = "unattributed"
    static let unattributedGroupTitle = "Unattributed"

    struct Node: Identifiable, Equatable {
        let id: String
        /// 1 for a direct child of the group's root, capped at `maxDepth`.
        let depth: Int
        let kind: SubworkerKind
    }

    /// One root session and every sub-worker beneath it, already flattened depth-first.
    struct Group: Identifiable, Equatable {
        let id: String
        /// The visible session this group hangs from. Nil for the trailing Unattributed group.
        let root: UserSession?
        let nodes: [Node]
    }

    struct Snapshot: Equatable {
        let groups: [Group]

        static let empty = Snapshot(groups: [])

        /// Total sub-workers across every group and depth. This is the tab's count.
        var childCount: Int { groups.reduce(0) { $0 + $1.nodes.count } }
        var isEmpty: Bool { groups.isEmpty }

        /// One badge per root, keyed by the root's logical identity, so a session card and
        /// the Agents tab are always reading the same rows.
        var badges: [SessionIdentityPolicy.LogicalIdentity: Badge] {
            var result: [SessionIdentityPolicy.LogicalIdentity: Badge] = [:]
            for group in groups {
                guard let root = group.root else { continue }
                result[root.identity] = SubworkerTree.badge(for: group)
            }
            return result
        }
    }

    /// Matching is an exact byte comparison of the raw harness reference. Codex keys its
    /// files `codex-<id>` but `harness_session_id` holds the raw id, so that is what both
    /// sides of the link use.
    private struct HarnessKey: Hashable {
        let harness: String
        let sessionId: String
    }

    /// - Parameters:
    ///   - roots: the visible user sessions, in canonical order. Dropped sessions are
    ///     already absent from `SessionManager.userSessions`, so no extra filter is needed.
    ///   - delegated: hidden delegated records, in canonical order.
    ///   - now: the clock the caller is already ticking on, so rows drop out between reloads.
    ///   - isProcessAlive: process-liveness probe, injectable so the tree rules stay pure.
    static func build(
        roots: [UserSession],
        delegated: [SessionData],
        now: Date = Date(),
        isProcessAlive: (SessionData) -> Bool = liveProcessEvidence
    ) -> Snapshot {
        // Filtered before anything else is derived, so a finished record becomes neither a
        // node nor an Unattributed entry. Each record is judged on its own liveness, so a
        // still-running grandchild of an exited delegate surfaces as unattributed rather than
        // disappearing with its parent.
        let recent = delegated.filter { isLive($0, now: now, isProcessAlive: isProcessAlive) }
        var childrenByParent: [HarnessKey: [SessionData]] = [:]
        for data in recent {
            guard let key = parentKey(for: data) else { continue }
            childrenByParent[key, default: []].append(data)
        }
        let ownerKeys = Set(
            roots.compactMap { ownKey(for: $0.displayRecord.data) }
                + recent.compactMap { ownKey(for: $0) }
        )

        var consumed: Set<String> = []
        var groups: [Group] = []
        for root in roots {
            let nodes = childNodes(
                of: root.displayRecord.data,
                depth: 1,
                childrenByParent: childrenByParent,
                consumed: &consumed,
                now: now
            )
            guard !nodes.isEmpty else { continue }
            groups.append(Group(id: groupID(for: root), root: root, nodes: nodes))
        }

        let unattributed = unattributedNodes(
            in: recent,
            ownerKeys: ownerKeys,
            childrenByParent: childrenByParent,
            consumed: &consumed,
            now: now
        )
        if !unattributed.isEmpty {
            groups.append(Group(id: unattributedGroupID, root: nil, nodes: unattributed))
        }
        return Snapshot(groups: groups)
    }

    /// One line of "what is this group doing" under its header. Categories are exclusive, so
    /// the counts always add up to the group's node count. Nothing stale can be in a group:
    /// `visibleSubagents(of:now:)` has already dropped it.
    static func summary(for group: Group, now: Date) -> SubworkerGroupSummary {
        var running = 0
        var waiting = 0
        for node in group.nodes {
            switch node.kind {
            case .inProcess(let info):
                if info.waitingMessage != nil { waiting += 1 } else { running += 1 }
            case .delegated(let data):
                if data.status == .waitingPermission { waiting += 1 } else { running += 1 }
            }
        }
        return SubworkerGroupSummary(running: running, waiting: waiting)
    }

    static func isStale(_ info: SubagentInfo, now: Date) -> Bool {
        now.timeIntervalSince(info.effectiveActivity) > staleInterval
    }

    /// The in-process subagents this view would actually show for a session. The parent
    /// card's badge reads from the same function, so it can never advertise rows that are
    /// not there.
    ///
    /// A dormant or finished session cannot be running an in-process subagent, whatever its
    /// file still lists. Inside a live owner an entry shows while it has reported within
    /// `staleInterval`, or while it is blocked on a permission prompt (then the 3-hour
    /// backstop applies). Entries leave the view, never storage: `SubagentStop` still owns
    /// removal, and a quiet subagent reappears on its next event.
    static func visibleSubagents(of data: SessionData, now: Date) -> [SubagentInfo] {
        guard data.lifecycle == .active else { return [] }
        return (data.activeSubagents ?? []).filter { info in
            guard isWithinVisibilityWindow(info, now: now) else { return false }
            return info.waitingMessage != nil || !isStale(info, now: now)
        }
    }

    /// A row whose last tool event is this fresh reads as moving right now.
    static let activityPulseInterval: TimeInterval = 30

    /// True while a row should show the live (pulsing) status dot.
    static func isActivelyWorking(_ kind: SubworkerKind, now: Date) -> Bool {
        switch kind {
        case .inProcess(let info):
            guard let lastActivity = info.lastActivity else { return false }
            return now.timeIntervalSince(lastActivity) < activityPulseInterval
        case .delegated(let data):
            // A delegated record has a real status, so only claim motion when it claims work.
            guard data.status == .working else { return false }
            return now.timeIntervalSince(data.lastActivity) < activityPulseInterval
        }
    }

    /// Ticking elapsed for a live row: "4m 12s" under an hour, "1h 04m" from there. Absolute
    /// and monotonic, unlike the coarse "4m ago" the rest of the panel uses, because these
    /// rows are the ones the user is watching move.
    static func elapsedDescription(since start: Date, asOf now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 3_600 {
            return String(format: "%dm %02ds", seconds / 60, seconds % 60)
        }
        return String(format: "%dh %02dm", seconds / 3_600, (seconds % 3_600) / 60)
    }

    static func isWithinVisibilityWindow(_ info: SubagentInfo, now: Date) -> Bool {
        now.timeIntervalSince(info.effectiveActivity) <= visibilityWindow
    }

    static func isWithinVisibilityWindow(_ data: SessionData, now: Date) -> Bool {
        now.timeIntervalSince(data.lastActivity) <= visibilityWindow
    }

    /// Whether a delegated record is still doing work.
    ///
    /// Codex never sends `SessionEnd`, and its lifecycle policy keeps a record active or
    /// dormant on activity age alone, so an exited `codex exec` run reads "Working" for
    /// hours. The owning process is the only honest signal cctop has, so that is what this
    /// asks. Records that predate PID capture have no such evidence; for those, only a
    /// record that claims to be mid-work *and* reported activity in the last few minutes
    /// counts, which fails closed on anything idle or quiet.
    static func isLive(
        _ data: SessionData, now: Date, isProcessAlive: (SessionData) -> Bool = liveProcessEvidence
    ) -> Bool {
        guard isWithinVisibilityWindow(data, now: now) else { return false }
        guard data.pid != nil, data.pidStartTime != nil else {
            guard data.status == .working || data.status == .waitingPermission else { return false }
            return now.timeIntervalSince(data.lastActivity) <= unevidencedActivityWindow
        }
        return isProcessAlive(data)
    }

    static func groupID(for root: UserSession) -> String {
        root.identity.cctopSessionID.map { "root:\($0)" }
            ?? "root:\(SessionIdentityPolicy.stableKey(for: root.displayRecord.data))"
    }

    // MARK: - Internals

    private static func childNodes(
        of owner: SessionData,
        depth: Int,
        childrenByParent: [HarnessKey: [SessionData]],
        consumed: inout Set<String>,
        now: Date
    ) -> [Node] {
        let nodeDepth = min(depth, maxDepth)
        let ownerNodeKey = nodeKey(for: owner)
        var nodes = visibleSubagents(of: owner, now: now)
            .sorted { $0.startedAt < $1.startedAt }
            .map { info in
                Node(id: "agent:\(ownerNodeKey):\(info.agentId)", depth: nodeDepth, kind: .inProcess(info))
            }

        guard let key = ownKey(for: owner) else { return nodes }
        for child in childrenByParent[key] ?? [] {
            let childKey = nodeKey(for: child)
            // Also the cycle guard: a record already placed can never be placed again.
            guard consumed.insert(childKey).inserted else { continue }
            nodes.append(Node(id: childKey, depth: nodeDepth, kind: .delegated(child)))
            nodes.append(contentsOf: childNodes(
                of: child,
                depth: depth + 1,
                childrenByParent: childrenByParent,
                consumed: &consumed,
                now: now
            ))
        }
        return nodes
    }

    /// Records whose parent is missing, unknown, or itself unreachable. Their own subtrees
    /// still nest so a delegated chain does not fragment just because its top is orphaned.
    private static func unattributedNodes(
        in delegated: [SessionData],
        ownerKeys: Set<HarnessKey>,
        childrenByParent: [HarnessKey: [SessionData]],
        consumed: inout Set<String>,
        now: Date
    ) -> [Node] {
        var nodes: [Node] = []
        func place(_ data: SessionData) {
            guard consumed.insert(nodeKey(for: data)).inserted else { return }
            nodes.append(Node(id: nodeKey(for: data), depth: 1, kind: .delegated(data)))
            nodes.append(contentsOf: childNodes(
                of: data, depth: 2, childrenByParent: childrenByParent, consumed: &consumed, now: now
            ))
        }
        for data in delegated {
            guard let parent = parentKey(for: data) else { place(data); continue }
            if !ownerKeys.contains(parent) { place(data) }
        }
        // Anything still unplaced belongs to a cycle or to an owner that never emitted a
        // group; show it rather than losing it.
        for data in delegated { place(data) }
        return nodes
    }

    private static func ownKey(for data: SessionData) -> HarnessKey? {
        guard let harnessSessionId = data.harnessSessionId, !harnessSessionId.isEmpty else { return nil }
        return HarnessKey(harness: data.source ?? SessionData.ccSource, sessionId: harnessSessionId)
    }

    private static func parentKey(for data: SessionData) -> HarnessKey? {
        guard let harness = data.parentHarness, !harness.isEmpty,
              let sessionId = data.parentHarnessSessionId, !sessionId.isEmpty else { return nil }
        return HarnessKey(harness: harness, sessionId: sessionId)
    }

    private static func nodeKey(for data: SessionData) -> String {
        "session:\(data.cctopSessionId ?? data.harnessSessionId ?? data.sessionId)"
    }
}

// MARK: - Preview fixtures

extension SubworkerTree {
    /// Claude root → in-process subagents + a delegated Codex run → that Codex run's own
    /// delegated Claude run, plus one orphan. Mirrors the deepest real chain.
    private static let previewSessions: (roots: [SessionData], delegated: [SessionData]) = {
        var claude = SessionData.mock(
            id: "cc-root", harnessSessionId: "cc-root-uuid", project: "cctop",
            branch: "jared/agents-view", sessionName: "Add the Agents view",
            status: .working, lastTool: "Agent", lastToolDetail: "Check the shim",
            source: SessionData.ccSource,
            activeSubagents: [
                SubagentInfo(
                    agentId: "a1", agentType: "Explore",
                    startedAt: Date().addingTimeInterval(-95),
                    description: "Find the tab switch",
                    model: "sonnet", subagentType: "Explore",
                    promptExcerpt: "Locate every switch over PopupTab and report the files that would "
                        + "need a new case, including the keyboard cycling path.",
                    lastTool: "Grep", lastToolDetail: "PopupTab",
                    lastActivity: Date().addingTimeInterval(-4),
                    toolCallCount: 12,
                    recentTools: [
                        "Read: PopupNavigation.swift", "Grep: secondaryCases",
                        "Read: PopupView.swift", "Bash: rg -n PopupTab", "Grep: PopupTab"
                    ]
                ),
                SubagentInfo(
                    agentId: "a2", agentType: "expert-review",
                    startedAt: Date().addingTimeInterval(-3_400),
                    description: "Review the delegation contract",
                    toolCallCount: 3
                ),
                SubagentInfo(
                    agentId: "a3", agentType: "general-purpose",
                    startedAt: Date().addingTimeInterval(-140),
                    description: "Rebuild the hook",
                    lastTool: "Bash", lastToolDetail: "make swift-test",
                    lastActivity: Date().addingTimeInterval(-30),
                    toolCallCount: 5,
                    recentTools: ["Bash: make lint", "Bash: make swift-test"],
                    waitingMessage: "Allow Bash: make swift-test"
                )
            ]
        )
        claude.lastActivity = Date().addingTimeInterval(-4)

        var codex = SessionData.mock(
            id: "codex-child", harnessSessionId: "codex-thread-uuid", project: "cctop",
            branch: "jared/agents-view", sessionName: "Second implementation pass",
            status: .waitingPermission, notificationMessage: "Allow Bash: swiftlint lint",
            source: SessionData.codexSource
        )
        codex.isSubagentSession = true
        codex.hidden = true
        codex.parentHarness = SessionData.ccSource
        codex.parentHarnessSessionId = "cc-root-uuid"
        codex.startedAt = Date().addingTimeInterval(-240)

        var grandchild = SessionData.mock(
            id: "cc-grandchild", harnessSessionId: "cc-grandchild-uuid", project: "cctop",
            branch: "jared/agents-view", status: .working,
            lastTool: "Read", lastToolDetail: "/menubar/CctopMenubar/Hook/HookHandler.swift",
            source: SessionData.ccSource
        )
        grandchild.isSubagentSession = true
        grandchild.hidden = true
        grandchild.parentHarness = SessionData.codexSource
        grandchild.parentHarnessSessionId = "codex-thread-uuid"
        grandchild.startedAt = Date().addingTimeInterval(-70)

        // No pid, so these take the no-process-evidence path and must claim live work.
        var orphan = SessionData.mock(
            id: "orphan", harnessSessionId: "orphan-uuid", project: "geolab",
            branch: "main", status: .working, lastTool: "Bash", lastToolDetail: "cargo test",
            source: SessionData.codexSource
        )
        orphan.isSubagentSession = true
        orphan.hidden = true
        orphan.startedAt = Date().addingTimeInterval(-900)

        return ([claude], [codex, grandchild, orphan])
    }()

    static var previewRoots: [UserSession] {
        previewSessions.roots.enumerated().map { index, data in
            let record = SessionRecord(
                data: data, lifecycleRank: data.lifecycle.rawValue,
                mtime: .distantPast, path: "/preview-root-\(index).json"
            )
            return UserSession(
                identity: SessionIdentityPolicy.logicalIdentity(for: data),
                records: [record],
                displayRecord: record
            )
        }
    }

    /// Expands one in-process row and one delegated row so the detail blocks are inspectable.
    static func previewExpandedNodeIDs(in group: Group) -> Set<String> {
        var ids: Set<String> = []
        for node in group.nodes {
            switch node.kind {
            case .inProcess where !ids.contains(where: { $0.hasPrefix("agent:") }):
                ids.insert(node.id)
            case .delegated where !ids.contains(where: { $0.hasPrefix("session:") }):
                ids.insert(node.id)
            default:
                continue
            }
        }
        return ids
    }

    static var previewDelegatedRecords: [SessionRecord] {
        previewSessions.delegated.enumerated().map { index, data in
            SessionRecord(
                data: data, lifecycleRank: data.lifecycle.rawValue,
                mtime: .distantPast, path: "/preview-delegated-\(index).json"
            )
        }
    }
}
