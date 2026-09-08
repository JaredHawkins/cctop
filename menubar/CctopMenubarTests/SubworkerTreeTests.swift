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
        // The test process is alive by definition, so structure tests are not accidentally
        // testing liveness. Liveness tests below inject their own probe.
        data.pid = UInt32(ProcessInfo.processInfo.processIdentifier)
        data.pidStartTime = SessionData.processStartTime(pid: data.pid!)
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

    private func agent(_ id: String, startedAt: Date = Date()) -> SubagentInfo {
        SubagentInfo(agentId: id, agentType: "Explore", startedAt: startedAt)
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

        let tree = SubworkerTree.build(roots: [ccRoot], delegated: [codexChild, ccGrandchild])

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

        let tree = SubworkerTree.build(roots: [codexRoot], delegated: [ccChild])

        XCTAssertEqual(tree.groups.count, 1)
        XCTAssertEqual(delegatedIDs(tree.groups[0].nodes), ["cc-child"])
        XCTAssertEqual(tree.groups[0].nodes.map(\.depth), [1])
    }

    func testRootWithoutChildrenIsOmitted() {
        let lonely = root(harnessSessionId: "cc-lonely")
        XCTAssertTrue(SubworkerTree.build(roots: [lonely], delegated: []).isEmpty)
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

        let tree = SubworkerTree.build(roots: [ccRoot], delegated: [wrongHarness, wrongReference])

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

        let tree = SubworkerTree.build(roots: [ccRoot], delegated: [attached, orphan, orphanChild])

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

        let withRoot = SubworkerTree.build(roots: [dropped], delegated: [child])
        XCTAssertEqual(withRoot.groups[0].root?.identity, dropped.identity)

        let withoutRoot = SubworkerTree.build(roots: [], delegated: [child])
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

        let tree = SubworkerTree.build(roots: [ccRoot], delegated: chain)

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

        let tree = SubworkerTree.build(roots: [], delegated: [first, second])

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

        let tree = SubworkerTree.build(roots: [ccRoot], delegated: [child])
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

        let tree = SubworkerTree.build(roots: [ccRoot], delegated: [], now: now)

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

        let tree = SubworkerTree.build(roots: [ccRoot], delegated: [], now: now)

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

        XCTAssertEqual(SubworkerTree.build(roots: [ccRoot], delegated: [], now: now).childCount, 1)
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

        let tree = SubworkerTree.build(
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
            SubworkerTree.build(
                roots: [ccRoot], delegated: [justExited], now: now,
                isProcessAlive: { _ in true }
            ).childCount,
            1
        )

        let tree = SubworkerTree.build(
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

        let tree = SubworkerTree.build(
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
            SubworkerTree.build(
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
            SubworkerTree.build(roots: [], delegated: [orphan], now: now, isProcessAlive: { _ in true })
                .childCount,
            1
        )
        XCTAssertTrue(
            SubworkerTree.build(roots: [], delegated: [orphan], now: now, isProcessAlive: { _ in false })
                .isEmpty
        )
    }

    func testInProcessSubagentsAreHiddenUnderADormantRoot() {
        let now = Date()
        let active = root(harnessSessionId: "cc-1", subagents: [agent("a1")])
        XCTAssertEqual(SubworkerTree.build(roots: [active], delegated: [], now: now).childCount, 1)

        let tree = SubworkerTree.build(roots: [dormant(active)], delegated: [], now: now)
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

        let tree = SubworkerTree.build(
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

        let tree = SubworkerTree.build(roots: [ccRoot, otherRoot], delegated: [], now: now)

        XCTAssertEqual(tree.groups.count, 1)
        XCTAssertEqual(tree.groups[0].root?.identity, otherRoot.identity)
        XCTAssertEqual(tree.childCount, 1)
    }

    // MARK: - Group summary

    private func summaryText(
        roots: [UserSession], delegated: [SessionData], now: Date = Date()
    ) -> String? {
        let tree = SubworkerTree.build(roots: roots, delegated: delegated)
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

        let tree = SubworkerTree.build(roots: [ccRoot], delegated: [])
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
