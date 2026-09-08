import XCTest
@testable import CctopMenubar

final class SubworkerTreeTests: XCTestCase {

    // MARK: - Fixtures

    private func root(
        harnessSessionId: String,
        source: String = SessionData.ccSource,
        subagents: [SubagentInfo] = []
    ) -> UserSession {
        let data = SessionData.mock(
            id: harnessSessionId,
            harnessSessionId: harnessSessionId,
            source: source,
            activeSubagents: subagents.isEmpty ? nil : subagents
        )
        let record = SessionRecord(
            data: data, lifecycleRank: SessionLifecycle.active.rawValue,
            mtime: .distantPast, path: "/\(harnessSessionId).json"
        )
        return UserSession(
            identity: SessionIdentityPolicy.logicalIdentity(for: data),
            records: [record],
            displayRecord: record
        )
    }

    private func delegated(
        harnessSessionId: String,
        source: String,
        parentHarness: String?,
        parentHarnessSessionId: String?,
        subagents: [SubagentInfo] = []
    ) -> SessionData {
        var data = SessionData.mock(
            id: harnessSessionId,
            harnessSessionId: harnessSessionId,
            source: source,
            activeSubagents: subagents.isEmpty ? nil : subagents
        )
        data.isSubagentSession = true
        data.hidden = true
        data.parentHarness = parentHarness
        data.parentHarnessSessionId = parentHarnessSessionId
        // Synthetic process evidence, so `build` takes the probe branch rather than the
        // no-evidence fallback. `buildTree` supplies the probe.
        data.pid = 424_242
        data.pidStartTime = 1_000
        return data
    }

    private func withoutProcessEvidence(
        _ data: SessionData, status: SessionStatus, lastActivityAgo: TimeInterval, now: Date
    ) -> SessionData {
        var copy = data
        copy.pid = nil
        copy.pidStartTime = nil
        copy.status = status
        copy.lastActivity = now.addingTimeInterval(-lastActivityAgo)
        return copy
    }

    private func dormant(_ session: UserSession) -> UserSession {
        var data = session.displayRecord.data
        data.lifecycle = .dormant
        return session.replacingDisplayData(data)
    }

    private func rootSession(_ data: SessionData) -> UserSession {
        let record = SessionRecord(
            data: data, lifecycleRank: data.lifecycle.rawValue,
            mtime: .distantPast, path: "/root-session.json"
        )
        return UserSession(
            identity: SessionIdentityPolicy.logicalIdentity(for: data),
            records: [record],
            displayRecord: record
        )
    }

    private func agent(_ id: String, startedAt: Date = Date()) -> SubagentInfo {
        SubagentInfo(agentId: id, agentType: "Explore", startedAt: startedAt)
    }

    /// Structure tests assert grouping, not liveness, so the probe defaults to "alive".
    /// Liveness tests pass their own.
    private func buildTree(
        roots: [UserSession] = [],
        delegated: [SessionData] = [],
        now: Date = Date(),
        isProcessAlive: (SessionData) -> Bool = { _ in true }
    ) -> SubworkerTree.Snapshot {
        SubworkerTree.build(roots: roots, delegated: delegated, now: now, isProcessAlive: isProcessAlive)
    }

    private func delegatedIDs(_ nodes: [SubworkerTree.Node]) -> [String] {
        nodes.compactMap { node in
            guard case .delegated(let data) = node.kind else { return nil }
            return data.harnessSessionId
        }
    }

    // MARK: - Structure

    func testCcRootCarriesInProcessAgentsCodexChildAndClaudeGrandchild() {
        let ccRoot = root(harnessSessionId: "cc-1", subagents: [agent("a1")])
        let codexChild = delegated(
            harnessSessionId: "codex-1", source: SessionData.codexSource,
            parentHarness: SessionData.ccSource, parentHarnessSessionId: "cc-1"
        )
        let ccGrandchild = delegated(
            harnessSessionId: "cc-2", source: SessionData.ccSource,
            parentHarness: SessionData.codexSource, parentHarnessSessionId: "codex-1",
            subagents: [agent("a2")]
        )

        let tree = buildTree(roots: [ccRoot], delegated: [codexChild, ccGrandchild])

        XCTAssertEqual(tree.groups.count, 1)
        XCTAssertEqual(tree.childCount, 4)
        let group = tree.groups[0]
        XCTAssertEqual(group.root?.identity, ccRoot.identity)
        XCTAssertEqual(group.nodes.map(\.depth), [1, 1, 2, 3])
        guard case .inProcess(let first) = group.nodes[0].kind else {
            return XCTFail("first child should be the in-process subagent")
        }
        XCTAssertEqual(first.agentId, "a1")
        XCTAssertEqual(delegatedIDs(group.nodes), ["codex-1", "cc-2"])
        guard case .inProcess(let nested) = group.nodes[3].kind else {
            return XCTFail("grandchild's own subagent should nest under it")
        }
        XCTAssertEqual(nested.agentId, "a2")
    }

    func testCodexRootAdoptsItsDelegatedClaudeRun() {
        let codexRoot = root(harnessSessionId: "codex-root", source: SessionData.codexSource)
        let ccChild = delegated(
            harnessSessionId: "cc-child", source: SessionData.ccSource,
            parentHarness: SessionData.codexSource, parentHarnessSessionId: "codex-root"
        )

        let tree = buildTree(roots: [codexRoot], delegated: [ccChild])

        XCTAssertEqual(tree.groups.count, 1)
        XCTAssertEqual(delegatedIDs(tree.groups[0].nodes), ["cc-child"])
        XCTAssertEqual(tree.groups[0].nodes.map(\.depth), [1])
    }

    func testRootWithoutChildrenIsOmitted() {
        let lonely = root(harnessSessionId: "cc-lonely")
        XCTAssertTrue(buildTree(roots: [lonely], delegated: []).isEmpty)
    }

    func testHarnessMatchIsExactAcrossHarnessAndReference() {
        let ccRoot = root(harnessSessionId: "cc-1")
        // Same reference, wrong harness — Codex keys files `codex-<id>` but links by raw id.
        let wrongHarness = delegated(
            harnessSessionId: "codex-x", source: SessionData.codexSource,
            parentHarness: SessionData.codexSource, parentHarnessSessionId: "cc-1"
        )
        // Right harness, near-miss reference.
        let wrongReference = delegated(
            harnessSessionId: "codex-y", source: SessionData.codexSource,
            parentHarness: SessionData.ccSource, parentHarnessSessionId: "cc-1 "
        )

        let tree = buildTree(roots: [ccRoot], delegated: [wrongHarness, wrongReference])

        XCTAssertEqual(tree.groups.count, 1)
        XCTAssertNil(tree.groups[0].root)
        XCTAssertEqual(tree.groups[0].id, SubworkerTree.unattributedGroupID)
        XCTAssertEqual(delegatedIDs(tree.groups[0].nodes), ["codex-x", "codex-y"])
    }

    func testUnresolvedParentsFallIntoATrailingUnattributedGroup() {
        let ccRoot = root(harnessSessionId: "cc-1")
        let attached = delegated(
            harnessSessionId: "codex-1", source: SessionData.codexSource,
            parentHarness: SessionData.ccSource, parentHarnessSessionId: "cc-1"
        )
        let orphan = delegated(
            harnessSessionId: "codex-2", source: SessionData.codexSource,
            parentHarness: nil, parentHarnessSessionId: nil
        )
        let orphanChild = delegated(
            harnessSessionId: "cc-3", source: SessionData.ccSource,
            parentHarness: SessionData.codexSource, parentHarnessSessionId: "codex-2"
        )

        let tree = buildTree(roots: [ccRoot], delegated: [attached, orphan, orphanChild])

        XCTAssertEqual(tree.groups.map(\.id).last, SubworkerTree.unattributedGroupID)
        XCTAssertEqual(delegatedIDs(tree.groups[0].nodes), ["codex-1"])
        let unattributed = tree.groups[1]
        XCTAssertEqual(delegatedIDs(unattributed.nodes), ["codex-2", "cc-3"])
        XCTAssertEqual(unattributed.nodes.map(\.depth), [1, 2])
    }

    func testDroppedSessionsNeverBecomeRoots() {
        // Dropped sessions are already absent from `userSessions`; their delegated children
        // must then surface as unattributed rather than silently disappearing.
        let dropped = root(harnessSessionId: "cc-dropped")
        let child = delegated(
            harnessSessionId: "codex-1", source: SessionData.codexSource,
            parentHarness: SessionData.ccSource, parentHarnessSessionId: "cc-dropped"
        )

        let withRoot = buildTree(roots: [dropped], delegated: [child])
        XCTAssertEqual(withRoot.groups[0].root?.identity, dropped.identity)

        let withoutRoot = buildTree(roots: [], delegated: [child])
        XCTAssertEqual(withoutRoot.groups.count, 1)
        XCTAssertNil(withoutRoot.groups[0].root)
        XCTAssertEqual(withoutRoot.childCount, 1)
    }

    func testDepthIsCappedAtThreeAndDeeperLevelsFlatten() {
        let ccRoot = root(harnessSessionId: "h0")
        let chain = (1...5).map { level in
            delegated(
                harnessSessionId: "h\(level)",
                source: level.isMultiple(of: 2) ? SessionData.ccSource : SessionData.codexSource,
                parentHarness: level.isMultiple(of: 2) ? SessionData.codexSource : SessionData.ccSource,
                parentHarnessSessionId: "h\(level - 1)"
            )
        }

        let tree = buildTree(roots: [ccRoot], delegated: chain)

        XCTAssertEqual(tree.childCount, 5)
        XCTAssertEqual(tree.groups[0].nodes.map(\.depth), [1, 2, 3, 3, 3])
        XCTAssertLessThanOrEqual(tree.groups[0].nodes.map(\.depth).max() ?? 0, SubworkerTree.maxDepth)
    }

    func testParentCycleIsPlacedOnceWithoutRecursingForever() {
        let first = delegated(
            harnessSessionId: "cc-a", source: SessionData.ccSource,
            parentHarness: SessionData.ccSource, parentHarnessSessionId: "cc-b"
        )
        let second = delegated(
            harnessSessionId: "cc-b", source: SessionData.ccSource,
            parentHarness: SessionData.ccSource, parentHarnessSessionId: "cc-a"
        )

        let tree = buildTree(roots: [], delegated: [first, second])

        XCTAssertEqual(tree.childCount, 2)
        XCTAssertEqual(Set(delegatedIDs(tree.groups[0].nodes)), ["cc-a", "cc-b"])
    }

    func testNodeIDsAreUniqueAcrossTheWholeTree() {
        let ccRoot = root(harnessSessionId: "cc-1", subagents: [agent("shared")])
        let child = delegated(
            harnessSessionId: "codex-1", source: SessionData.codexSource,
            parentHarness: SessionData.ccSource, parentHarnessSessionId: "cc-1",
            subagents: [agent("shared")]
        )

        let tree = buildTree(roots: [ccRoot], delegated: [child])
        let ids = tree.groups.flatMap { $0.nodes.map(\.id) }

        XCTAssertEqual(ids.count, Set(ids).count)
    }

    // MARK: - Liveness and the backstop window

    private func aged(_ data: SessionData, by seconds: TimeInterval, now: Date) -> SessionData {
        var copy = data
        copy.lastActivity = now.addingTimeInterval(-seconds)
        copy.startedAt = now.addingTimeInterval(-seconds)
        return copy
    }

    func testInProcessSubagentJustInsideTheWindowStaysAndReadsStale() {
        let now = Date()
        let inside = agent("inside", startedAt: now.addingTimeInterval(-(SubworkerTree.visibilityWindow - 60)))
        let ccRoot = root(harnessSessionId: "cc-1", subagents: [inside])

        let tree = buildTree(roots: [ccRoot], delegated: [], now: now)

        XCTAssertEqual(tree.childCount, 1)
        XCTAssertTrue(SubworkerTree.isStale(inside, now: now), "still marked, not dropped")
        XCTAssertEqual(SubworkerTree.summary(for: tree.groups[0], now: now).stale, 1)
    }

    func testInProcessSubagentPastTheWindowLeavesTheTree() {
        let now = Date()
        let ccRoot = root(
            harnessSessionId: "cc-1",
            subagents: [
                agent("gone", startedAt: now.addingTimeInterval(-(SubworkerTree.visibilityWindow + 60))),
                agent("fresh", startedAt: now.addingTimeInterval(-30))
            ]
        )

        let tree = buildTree(roots: [ccRoot], delegated: [], now: now)

        XCTAssertEqual(tree.childCount, 1)
        guard case .inProcess(let survivor) = tree.groups[0].nodes[0].kind else {
            return XCTFail("expected the fresh subagent")
        }
        XCTAssertEqual(survivor.agentId, "fresh")
    }

    func testInProcessRecencyPrefersLastActivityOverStartedAt() {
        let now = Date()
        var longRunning = agent("long", startedAt: now.addingTimeInterval(-86_400))
        longRunning.lastActivity = now.addingTimeInterval(-30)
        let ccRoot = root(harnessSessionId: "cc-1", subagents: [longRunning])

        XCTAssertEqual(buildTree(roots: [ccRoot], delegated: [], now: now).childCount, 1)
    }

    /// The window is the backstop: even a record whose process is somehow still alive stops
    /// being shown once it has been silent for hours.
    func testLiveDelegatedRecordPastTheWindowStillLeavesTheTreeWithItsChild() {
        let now = Date()
        let ccRoot = root(harnessSessionId: "cc-1")
        let idleParent = aged(
            delegated(
                harnessSessionId: "codex-1", source: SessionData.codexSource,
                parentHarness: SessionData.ccSource, parentHarnessSessionId: "cc-1"
            ),
            by: 4 * 3_600, now: now
        )
        let idleChild = aged(
            delegated(
                harnessSessionId: "cc-2", source: SessionData.ccSource,
                parentHarness: SessionData.codexSource, parentHarnessSessionId: "codex-1"
            ),
            by: 4 * 3_600, now: now
        )

        let tree = buildTree(
            roots: [ccRoot], delegated: [idleParent, idleChild], now: now,
            isProcessAlive: { _ in true }
        )

        XCTAssertTrue(tree.isEmpty, "neither a node nor an unattributed entry")
        XCTAssertEqual(tree.childCount, 0)
    }

    func testDelegatedRecordWithADeadProcessIsExcludedEvenWhenBrandNew() {
        let now = Date()
        let ccRoot = root(harnessSessionId: "cc-1")
        let justExited = delegated(
            harnessSessionId: "codex-1", source: SessionData.codexSource,
            parentHarness: SessionData.ccSource, parentHarnessSessionId: "cc-1"
        )
        XCTAssertEqual(
            buildTree(
                roots: [ccRoot], delegated: [justExited], now: now,
                isProcessAlive: { _ in true }
            ).childCount,
            1
        )

        let tree = buildTree(
            roots: [ccRoot], delegated: [justExited], now: now,
            isProcessAlive: { _ in false }
        )
        XCTAssertTrue(tree.isEmpty, "a minute-old record whose process exited is not running")
    }

    func testDelegatedRecordWithALiveProcessStaysUntilTheBackstop() {
        let now = Date()
        let ccRoot = root(harnessSessionId: "cc-1")
        let longRunning = aged(
            delegated(
                harnessSessionId: "codex-1", source: SessionData.codexSource,
                parentHarness: SessionData.ccSource, parentHarnessSessionId: "cc-1"
            ),
            by: SubworkerTree.visibilityWindow - 60, now: now
        )

        let tree = buildTree(
            roots: [ccRoot], delegated: [longRunning], now: now,
            isProcessAlive: { _ in true }
        )
        XCTAssertEqual(tree.childCount, 1)
    }

    func testDelegatedRecordWithoutProcessEvidenceNeedsRecentWorkingActivity() {
        let now = Date()
        let ccRoot = root(harnessSessionId: "cc-1")
        let base = delegated(
            harnessSessionId: "codex-1", source: SessionData.codexSource,
            parentHarness: SessionData.ccSource, parentHarnessSessionId: "cc-1"
        )
        func childCount(status: SessionStatus, ago: TimeInterval) -> Int {
            buildTree(
                roots: [ccRoot],
                delegated: [withoutProcessEvidence(base, status: status, lastActivityAgo: ago, now: now)],
                now: now,
                isProcessAlive: { _ in XCTFail("no process evidence to probe"); return true }
            ).childCount
        }

        XCTAssertEqual(childCount(status: .working, ago: 300), 1)
        XCTAssertEqual(childCount(status: .waitingPermission, ago: 300), 1)
        XCTAssertEqual(childCount(status: .working, ago: 900), 0, "quiet for 15 minutes")
        XCTAssertEqual(childCount(status: .idle, ago: 60), 0, "idle is not running")
        XCTAssertEqual(childCount(status: .waitingInput, ago: 60), 0)
    }

    func testUnattributedOrphanWithADeadProcessIsExcluded() {
        let now = Date()
        let orphan = delegated(
            harnessSessionId: "codex-orphan", source: SessionData.codexSource,
            parentHarness: nil, parentHarnessSessionId: nil
        )

        XCTAssertEqual(
            buildTree(roots: [], delegated: [orphan], now: now, isProcessAlive: { _ in true })
                .childCount,
            1
        )
        XCTAssertTrue(
            buildTree(roots: [], delegated: [orphan], now: now, isProcessAlive: { _ in false })
                .isEmpty
        )
    }

    func testInProcessSubagentsAreHiddenUnderADormantRoot() {
        let now = Date()
        let active = root(harnessSessionId: "cc-1", subagents: [agent("a1")])
        XCTAssertEqual(buildTree(roots: [active], delegated: [], now: now).childCount, 1)

        let tree = buildTree(roots: [dormant(active)], delegated: [], now: now)
        XCTAssertTrue(tree.isEmpty, "a dormant session cannot be running in-process subagents")
    }

    /// Liveness is judged per record, so work that is still running does not vanish because
    /// the record that spawned it exited.
    func testLiveChildOfAnExitedDelegateSurvivesAsUnattributed() {
        let now = Date()
        let ccRoot = root(harnessSessionId: "cc-1")
        let idleParent = aged(
            delegated(
                harnessSessionId: "codex-1", source: SessionData.codexSource,
                parentHarness: SessionData.ccSource, parentHarnessSessionId: "cc-1"
            ),
            by: 4 * 3_600, now: now
        )
        let freshChild = delegated(
            harnessSessionId: "cc-2", source: SessionData.ccSource,
            parentHarness: SessionData.codexSource, parentHarnessSessionId: "codex-1"
        )

        let tree = buildTree(
            roots: [ccRoot], delegated: [idleParent, freshChild], now: now,
            isProcessAlive: { $0.harnessSessionId == "cc-2" }
        )

        XCTAssertEqual(tree.groups.count, 1)
        XCTAssertNil(tree.groups[0].root)
        XCTAssertEqual(delegatedIDs(tree.groups[0].nodes), ["cc-2"])
    }

    func testRootWhoseOnlyChildAgedOutEmitsNoGroup() {
        let now = Date()
        let ccRoot = root(
            harnessSessionId: "cc-1",
            subagents: [agent("gone", startedAt: now.addingTimeInterval(-(SubworkerTree.visibilityWindow + 1)))]
        )
        let otherRoot = root(harnessSessionId: "cc-2", subagents: [agent("fresh")])

        let tree = buildTree(roots: [ccRoot, otherRoot], delegated: [], now: now)

        XCTAssertEqual(tree.groups.count, 1)
        XCTAssertEqual(tree.groups[0].root?.identity, otherRoot.identity)
        XCTAssertEqual(tree.childCount, 1)
    }

    // MARK: - Group summary

    private func summaryText(
        roots: [UserSession], delegated: [SessionData], now: Date = Date()
    ) -> String? {
        let tree = buildTree(roots: roots, delegated: delegated)
        return SubworkerTree.summary(for: tree.groups[0], now: now).text
    }

    func testGroupSummaryCountsRunningStaleAndWaitingExclusively() {
        let now = Date()
        var waiting = agent("waiting", startedAt: now.addingTimeInterval(-10))
        waiting.waitingMessage = "Allow Bash: make swift-test"
        // Silent long enough to be stale, but a pending prompt outranks staleness.
        var waitingAndSilent = agent("both", startedAt: now.addingTimeInterval(-7_200))
        waitingAndSilent.waitingMessage = "Allow Bash: rm -rf build"
        let stale = agent("stale", startedAt: now.addingTimeInterval(-7_200))
        let running = agent("running", startedAt: now.addingTimeInterval(-20))
        let ccRoot = root(
            harnessSessionId: "cc-1",
            subagents: [waiting, waitingAndSilent, stale, running]
        )

        let tree = buildTree(roots: [ccRoot], delegated: [])
        let summary = SubworkerTree.summary(for: tree.groups[0], now: now)

        XCTAssertEqual(summary.running, 1)
        XCTAssertEqual(summary.stale, 1)
        XCTAssertEqual(summary.waiting, 2)
        XCTAssertEqual(summary.text, "1 running \u{00B7} 1 stale \u{00B7} 2 waiting")
        XCTAssertEqual(summary.running + summary.stale + summary.waiting, tree.groups[0].nodes.count)
    }

    func testGroupSummaryIsOmittedWhenEverythingIsRunning() {
        let ccRoot = root(harnessSessionId: "cc-1", subagents: [agent("a1"), agent("a2")])
        XCTAssertNil(summaryText(roots: [ccRoot], delegated: []))
    }

    func testGroupSummaryTreatsAWaitingDelegatedRecordAsWaitingAndNeverStale() {
        let ccRoot = root(harnessSessionId: "cc-1")
        var child = delegated(
            harnessSessionId: "codex-1", source: SessionData.codexSource,
            parentHarness: SessionData.ccSource, parentHarnessSessionId: "cc-1"
        )
        child.status = .waitingPermission
        // Old enough that an in-process entry would read stale, but still inside the
        // visibility window so the record is present to be counted.
        var old = delegated(
            harnessSessionId: "codex-2", source: SessionData.codexSource,
            parentHarness: SessionData.ccSource, parentHarnessSessionId: "cc-1"
        )
        old.startedAt = Date(timeIntervalSinceNow: -7_200)
        old.lastActivity = Date(timeIntervalSinceNow: -7_200)

        XCTAssertEqual(summaryText(roots: [ccRoot], delegated: [child, old]), "1 running \u{00B7} 1 waiting")
    }

    // MARK: - Row presentation

    func testBadgeLabelNamesTheBusiestInProcessSubagent() {
        let now = Date()
        var quiet = agent("quiet", startedAt: now.addingTimeInterval(-600))
        quiet.lastActivity = now.addingTimeInterval(-300)
        quiet.lastTool = "Read"
        quiet.lastToolDetail = "/old.swift"
        var busy = agent("busy", startedAt: now.addingTimeInterval(-60))
        busy.lastActivity = now.addingTimeInterval(-2)
        busy.lastTool = "Grep"
        busy.lastToolDetail = "PopupTab"

        let session = SessionData.mock(activeSubagents: [quiet, busy])
        let badge = SubworkerTree.badge(for: session, now: now)

        XCTAssertEqual(badge?.count, 2)
        XCTAssertEqual(badge?.waiting, 0)
        XCTAssertEqual(badge?.label, "2 agents", "activity text belongs in the Agents view, not on the card")
    }

    func testBadgeLabelFallsBackToTheCountAloneAndPluralizes() {
        let now = Date()
        XCTAssertNil(SubworkerTree.badge(for: SessionData.mock(), now: now))
        XCTAssertEqual(
            SubworkerTree.badge(for: SessionData.mock(activeSubagents: [agent("a1")]), now: now)?.label,
            "1 agent"
        )

        var blocked = agent("a1")
        blocked.waitingMessage = "Allow Bash: make swift-test"
        let mixed = SessionData.mock(activeSubagents: [blocked, agent("a2"), agent("a3")])
        XCTAssertEqual(SubworkerTree.badge(for: mixed, now: now)?.waiting, 1)
        XCTAssertEqual(
            SubworkerTree.badge(for: mixed, now: now)?.label,
            "3 agents \u{00B7} 1 waiting"
        )
    }

    /// The panel's card badge comes from the group, so delegated children count too and the
    /// accounts they run under surface as monograms.
    func testGroupBadgeCountsDelegatedChildrenAndNamesTheirAccounts() {
        let now = Date()
        var blocked = agent("a1")
        blocked.waitingMessage = "Allow Bash"
        let root = SessionData.mock(
            id: "root", harnessSessionId: "root-h", source: "cc", activeSubagents: [blocked, agent("a2")]
        )
        var klick = SessionData.mock(
            id: "codex-k", harnessSessionId: "k", status: .working, source: "codex", account: "klick"
        )
        klick.isSubagentSession = true
        klick.parentHarness = "cc"
        klick.parentHarnessSessionId = "root-h"
        var personal = SessionData.mock(
            id: "codex-p", harnessSessionId: "p", status: .waitingPermission, source: "codex"
        )
        personal.isSubagentSession = true
        personal.parentHarness = "cc"
        personal.parentHarnessSessionId = "root-h"

        let tree = buildTree(roots: [rootSession(root)], delegated: [klick, personal], now: now)
        let badge = try? XCTUnwrap(tree.badges[SessionIdentityPolicy.logicalIdentity(for: root)])
        XCTAssertEqual(badge?.count, 4, "two in-process + two delegated, same as the tab")
        XCTAssertEqual(badge?.count, tree.childCount)
        XCTAssertEqual(badge?.waiting, 2, "one in-process waiting message + one delegated permission")
        XCTAssertEqual(badge?.accounts, ["klick"], "only delegated children can introduce a login")
        XCTAssertEqual(badge?.accountMonograms, ["K"])
        XCTAssertEqual(badge?.label, "4 agents \u{00B7} 2 waiting")
        XCTAssertEqual(badge?.accessibilityLabel, "Show 4 agents, 2 waiting, some on klick account")
        XCTAssertTrue(buildTree(roots: [rootSession(SessionData.mock(id: "lonely"))]).badges.isEmpty)
    }

    /// The card must never advertise sub-workers the Agents view has already dropped.
    func testBadgeCountsOnlyTheSubagentsTheTreeWouldShow() {
        let now = Date()
        let live = agent("live", startedAt: now.addingTimeInterval(-30))
        let agedOut = agent("gone", startedAt: now.addingTimeInterval(-(SubworkerTree.visibilityWindow + 60)))
        let active = SessionData.mock(activeSubagents: [live, agedOut])

        let badge = try? XCTUnwrap(SubworkerTree.badge(for: active, now: now))
        XCTAssertEqual(badge?.count, 1, "the aged-out entry is not on the card either")
        XCTAssertEqual(
            buildTree(roots: [rootSession(active)], delegated: [], now: now).childCount,
            badge?.count
        )

        var dormant = active
        dormant.lifecycle = .dormant
        XCTAssertNil(
            SubworkerTree.badge(for: dormant, now: now),
            "a dormant session shows no rows, so it shows no badge"
        )
        XCTAssertTrue(
            buildTree(roots: [rootSession(dormant)], delegated: [], now: now).isEmpty
        )

        var allAgedOut = active
        allAgedOut.activeSubagents = [agedOut]
        XCTAssertNil(SubworkerTree.badge(for: allAgedOut, now: now))
    }

    // MARK: - Delegated process liveness

    func testLiveProcessEvidenceAcceptsALiveOwnedProcess() throws {
        let (pid, startTime) = try spawnProcess(named: "sleep")
        var data = SessionData.mock()
        data.pid = pid
        data.pidStartTime = startTime

        XCTAssertTrue(SubworkerTree.liveProcessEvidence(data))
    }

    /// `SessionData.isAlive` tolerates a one-second generation drift, which is right for a
    /// session card but would keep an exited delegate on screen when a PID is reused inside
    /// that second. The Agents view requires an exact match on top.
    func testLiveProcessEvidenceRejectsASubSecondGenerationMismatch() throws {
        let (pid, startTime) = try spawnProcess(named: "sleep")
        var data = SessionData.mock()
        data.pid = pid
        data.pidStartTime = startTime - 0.5

        XCTAssertTrue(data.isAlive, "the shared predicate accepts it")
        XCTAssertFalse(SubworkerTree.liveProcessEvidence(data), "the Agents view does not")
    }

    func testLiveProcessEvidenceRejectsADeadProcess() {
        var data = SessionData.mock()
        data.pid = 0x7FFF_FFFE
        data.pidStartTime = 1_000
        XCTAssertFalse(SubworkerTree.liveProcessEvidence(data))
    }

    /// The capture-time parent walk can adopt another harness's still-running PID. Liveness
    /// must reject it even though the process exists and its generation matches exactly.
    func testLiveProcessEvidenceRejectsAForeignHarnessPID() throws {
        let (pid, startTime) = try spawnProcess(named: "claude")

        var sameHarness = SessionData.mock(source: SessionData.ccSource)
        sameHarness.pid = pid
        sameHarness.pidStartTime = startTime
        XCTAssertTrue(
            SubworkerTree.liveProcessEvidence(sameHarness),
            "a live process whose binary matches the record's harness is accepted"
        )

        var foreign = sameHarness
        foreign.source = SessionData.codexSource
        XCTAssertFalse(
            SubworkerTree.liveProcessEvidence(foreign),
            "a 'claude' process cannot be hosting a codex record"
        )
    }

    /// Jared's standard shape for a long Codex run is `nohup codex exec … & disown` from a
    /// Claude Bash call, which reparents codex to launchd while it keeps working. Focus
    /// liveness rejects an orphan because an interactive session that lost its shell cannot
    /// be reached; the Agents view must not, or the runs most worth watching vanish the
    /// moment their launching shell exits.
    func testOrphanedDelegateIsDeadForFocusButLiveForTheAgentsView() throws {
        let (pid, startTime) = try spawnOrphanedProcess()
        var data = SessionData.mock(source: SessionData.codexSource)
        data.pid = pid
        data.pidStartTime = startTime

        XCTAssertTrue(data.isOrphanedProcess)
        XCTAssertFalse(data.isAlive, "focus-facing liveness still rejects a reparented process")
        XCTAssertTrue(data.isRunningOwnedProcess, "the work itself is still running")
        XCTAssertTrue(SubworkerTree.liveProcessEvidence(data))

        let ccRoot = root(harnessSessionId: "cc-1")
        var child = delegated(
            harnessSessionId: "codex-1", source: SessionData.codexSource,
            parentHarness: SessionData.ccSource, parentHarnessSessionId: "cc-1"
        )
        child.pid = pid
        child.pidStartTime = startTime
        XCTAssertEqual(
            SubworkerTree.build(roots: [ccRoot], delegated: [child]).childCount, 1,
            "parent linkage is parent_harness_session_id, not the Unix PPID"
        )
    }

    /// Backgrounds `sleep` from a shell that then exits, so the sleep reparents to launchd.
    private func spawnOrphanedProcess() throws -> (UInt32, TimeInterval) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cctop-orphan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pidFile = directory.appendingPathComponent("pid")

        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "/bin/sleep 60 & echo $! > \(pidFile.path)"]
        try shell.run()
        shell.waitUntilExit()

        var reparented: UInt32?
        for _ in 0..<200 {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8),
               let candidate = UInt32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
               SessionData.processInfo(pid: candidate)?.kp_eproc.e_ppid == 1 {
                reparented = candidate
                break
            }
            usleep(20_000)
        }
        let pid = try XCTUnwrap(reparented, "the backgrounded sleep never reparented to launchd")
        addTeardownBlock {
            kill(Int32(pid), SIGKILL)
            try? FileManager.default.removeItem(at: directory)
        }
        return (pid, try XCTUnwrap(SessionData.processStartTime(pid: pid)))
    }

    /// Runs a copy of `/bin/sleep` under the given name so the kernel reports that name as
    /// the process's `p_comm`, which is what harness matching reads.
    private func spawnProcess(named name: String) throws -> (UInt32, TimeInterval) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cctop-liveness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent(name)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)

        let process = Process()
        process.executableURL = executable
        process.arguments = ["30"]
        try process.run()
        addTeardownBlock {
            process.terminate()
            process.waitUntilExit()
            try? FileManager.default.removeItem(at: directory)
        }

        let pid = UInt32(process.processIdentifier)
        let startTime = try XCTUnwrap(SessionData.processStartTime(pid: pid))
        return (pid, startTime)
    }

    func testActivelyWorkingTracksTheLastToolEventAndDelegatedStatus() {
        let now = Date()
        var fresh = agent("fresh")
        fresh.lastActivity = now.addingTimeInterval(-5)
        var settled = agent("settled")
        settled.lastActivity = now.addingTimeInterval(-SubworkerTree.activityPulseInterval - 1)

        XCTAssertTrue(SubworkerTree.isActivelyWorking(.inProcess(fresh), now: now))
        XCTAssertFalse(SubworkerTree.isActivelyWorking(.inProcess(settled), now: now))
        XCTAssertFalse(
            SubworkerTree.isActivelyWorking(.inProcess(agent("never")), now: now),
            "a subagent that has run no tool is not moving"
        )

        var working = SessionData.mock(status: .working)
        working.lastActivity = now.addingTimeInterval(-5)
        XCTAssertTrue(SubworkerTree.isActivelyWorking(.delegated(working), now: now))

        var waiting = working
        waiting.status = .waitingPermission
        XCTAssertFalse(
            SubworkerTree.isActivelyWorking(.delegated(waiting), now: now),
            "a blocked delegate is not moving"
        )

        var stalledWork = working
        stalledWork.lastActivity = now.addingTimeInterval(-SubworkerTree.activityPulseInterval)
        XCTAssertFalse(SubworkerTree.isActivelyWorking(.delegated(stalledWork), now: now))
    }

    func testElapsedDescriptionSwitchesFromSecondsToHoursAtOneHour() {
        let now = Date()
        func elapsed(_ seconds: TimeInterval) -> String {
            SubworkerTree.elapsedDescription(since: now.addingTimeInterval(-seconds), asOf: now)
        }

        XCTAssertEqual(elapsed(0), "0m 00s")
        XCTAssertEqual(elapsed(59), "0m 59s")
        XCTAssertEqual(elapsed(60), "1m 00s")
        XCTAssertEqual(elapsed(252), "4m 12s")
        XCTAssertEqual(elapsed(3_599), "59m 59s")
        XCTAssertEqual(elapsed(3_600), "1h 00m")
        XCTAssertEqual(elapsed(3_840), "1h 04m")
        XCTAssertEqual(elapsed(18_000), "5h 00m")
    }

    func testElapsedDescriptionClampsAFutureStart() {
        let now = Date()
        XCTAssertEqual(
            SubworkerTree.elapsedDescription(since: now.addingTimeInterval(30), asOf: now), "0m 00s"
        )
    }

    // MARK: - Staleness

    func testStalenessUsesLastActivityThenFallsBackToStartedAt() {
        let now = Date()
        var reporting = agent("a1", startedAt: now.addingTimeInterval(-7_200))
        reporting.lastActivity = now.addingTimeInterval(-60)
        XCTAssertFalse(SubworkerTree.isStale(reporting, now: now))

        let silent = agent("a2", startedAt: now.addingTimeInterval(-SubworkerTree.staleInterval - 1))
        XCTAssertTrue(SubworkerTree.isStale(silent, now: now))

        let fresh = agent("a3", startedAt: now.addingTimeInterval(-5))
        XCTAssertFalse(SubworkerTree.isStale(fresh, now: now))
    }
}
