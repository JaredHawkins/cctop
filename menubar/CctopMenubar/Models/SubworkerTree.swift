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
    let stale: Int
    let waiting: Int

    /// Nil when "N running" is the whole story, since the row count already says that.
    var text: String? {
        guard stale > 0 || waiting > 0 else { return nil }
        var parts: [String] = []
        if running > 0 { parts.append("\(running) running") }
        if stale > 0 { parts.append("\(stale) stale") }
        if waiting > 0 { parts.append("\(waiting) waiting") }
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

    /// A sub-worker with no observed activity for this long is rendered as stale rather
    /// than deleted: the parent may simply not have reported a Stop yet.
    static let staleInterval: TimeInterval = 1_800

    /// Past this, a sub-worker leaves the view entirely. The Agents tab answers "what is
    /// running under my sessions right now", not "what ran this week": a dormant Codex
    /// delegate survives its 14-day lifecycle retention, and an in-process entry survives
    /// until its parent's next SessionStart, so without this the list fills with records
    /// days old. Nothing is deleted — the records stay on disk and in their own surfaces.
    static let visibilityWindow: TimeInterval = 3 * 3_600

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
    ///   - now: the clock the caller is already ticking on, so rows age out between reloads.
    static func build(roots: [UserSession], delegated: [SessionData], now: Date = Date()) -> Snapshot {
        // Filtered before anything else is derived, so an aged-out record becomes neither a
        // node nor an Unattributed entry. Its children are judged on their own recency, so a
        // still-running grandchild of an idle delegate surfaces as unattributed rather than
        // disappearing with its parent.
        let recent = delegated.filter { isWithinVisibilityWindow($0, now: now) }
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

    /// One line of "what is this group doing" under its header. Categories are exclusive and
    /// ranked waiting > stale > running, so the counts always add up to the group's node count.
    static func summary(for group: Group, now: Date) -> SubworkerGroupSummary {
        var running = 0
        var stale = 0
        var waiting = 0
        for node in group.nodes {
            switch node.kind {
            case .inProcess(let info):
                if info.waitingMessage != nil { waiting += 1 } else if isStale(info, now: now) { stale += 1 } else { running += 1 }
            case .delegated(let data):
                // A delegated record has its own lifecycle and status, so cctop never has to
                // guess staleness from silence the way it does for an in-process subagent.
                if data.status == .waitingPermission { waiting += 1 } else { running += 1 }
            }
        }
        return SubworkerGroupSummary(running: running, stale: stale, waiting: waiting)
    }

    static func isStale(_ info: SubagentInfo, now: Date) -> Bool {
        now.timeIntervalSince(info.effectiveActivity) > staleInterval
    }

    static func isWithinVisibilityWindow(_ info: SubagentInfo, now: Date) -> Bool {
        now.timeIntervalSince(info.effectiveActivity) <= visibilityWindow
    }

    /// A delegated record reports its own `last_activity`, so recency needs no inference.
    static func isWithinVisibilityWindow(_ data: SessionData, now: Date) -> Bool {
        now.timeIntervalSince(data.lastActivity) <= visibilityWindow
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
        var nodes = (owner.activeSubagents ?? [])
            .filter { isWithinVisibilityWindow($0, now: now) }
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

        var orphan = SessionData.mock(
            id: "orphan", harnessSessionId: "orphan-uuid", project: "geolab",
            branch: "main", status: .idle, source: SessionData.codexSource
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
