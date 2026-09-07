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
        return data
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
