import SwiftUI

extension PopupView {
    /// Roots are the visible sessions in canonical order. Dropped sessions are already
    /// absent from `userSessions`; acknowledged ones are mirrors of rows that stay there.
    /// `relativeTimeNow` is the panel's shared 10 s tick, so a delegate whose process has
    /// exited leaves on the next tick without waiting for a session reload. The liveness
    /// probe is a `sysctl` per delegated record, so nothing is cached across builds.
    var subworkerTree: SubworkerTree.Snapshot {
        SubworkerTree.build(
            roots: userSessions,
            delegated: delegatedSessionRecords.map(\.data),
            now: relativeTimeNow,
            isProcessAlive: SubworkerTree.liveProcessEvidence
        )
    }

    @ViewBuilder
    var agentsContent: some View {
        let tree = subworkerTree
        if tree.isEmpty {
            emptyPlaceholder(
                systemImage: "point.3.connected.trianglepath.dotted",
                title: "No sub-workers running",
                detail: PopupTab.agents.emptyStateDetail
            )
        } else {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(tree.groups) { group in
                        SubworkerGroupView(
                            group: group,
                            relativeTimeNow: relativeTimeNow,
                            onFocusRoot: { focusSession($0) },
                            onLayoutChanged: notifyLayoutChanged
                        )
                    }
                }
                .padding(.bottom, AppChrome.listVerticalPadding)
            }
            .frame(maxHeight: AppChrome.overlayMinimumContentHeight)
        }
    }
}

/// One root session plus its flattened sub-worker rows. The header reuses the session
/// card's identity vocabulary; the rows are quieter so the parent still reads first.
struct SubworkerGroupView: View {
    let group: SubworkerTree.Group
    var relativeTimeNow = Date()
    /// Focuses the root through the same action the session row uses.
    var onFocusRoot: (SessionData) -> Void = { _ in }
    /// The panel's existing refit path. Expanding a row changes content height, and without
    /// this the NSPanel keeps its collapsed frame and squeezes the detail into the old
    /// viewport. `PopupView.notifyLayoutChanged` already defers to the next main-queue turn,
    /// so the host measures the applied layout, not the pre-toggle one.
    var onLayoutChanged: () -> Void = {}
    /// Seeded expansion, used by previews. Live state lives in `expandedNodeIDs`.
    var initiallyExpandedNodeIDs: Set<String> = []

    @State private var expandedNodeIDs: Set<String>?

    private var expanded: Set<String> { expandedNodeIDs ?? initiallyExpandedNodeIDs }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            if let summaryText = SubworkerTree.summary(for: group, now: relativeTimeNow).text {
                Text(summaryText)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.textMuted)
                    .padding(.horizontal, 9 + AppChrome.rowSelectionHorizontalInset)
                    .accessibilityLabel("Group status: \(summaryText)")
            }
            ForEach(group.nodes) { node in
                SubworkerRowView(
                    node: node,
                    relativeTimeNow: relativeTimeNow,
                    isExpanded: expanded.contains(node.id),
                    onToggle: { toggle(node.id) }
                )
            }
        }
        .padding(.top, 6)
    }

    private func toggle(_ nodeID: String) {
        var next = expanded
        if next.remove(nodeID) == nil { next.insert(nodeID) }
        expandedNodeIDs = next
        onLayoutChanged()
    }

    @ViewBuilder
    private var header: some View {
        if let root = group.root {
            SubworkerGroupHeaderView(root: root, relativeTimeNow: relativeTimeNow)
                .contentShape(Rectangle())
                .onTapGesture { onFocusRoot(root.displayRecord.data) }
                .help("Focus \(root.displayRecord.data.displayName)")
        } else {
            Text(SubworkerTree.unattributedGroupTitle)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.textMuted)
                .padding(.horizontal, 9 + AppChrome.rowSelectionHorizontalInset)
                .padding(.vertical, 3)
                .accessibilityLabel("Unattributed sub-workers")
        }
    }
}

struct SubworkerGroupHeaderView: View {
    let root: UserSession
    var relativeTimeNow = Date()

    @State private var isHovered = false

    private var session: SessionData { root.displayRecord.data }

    var body: some View {
        HStack(spacing: 8) {
            Text(session.displayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(session.status == .idle ? Color.textSecondary : Color.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            SourceBadgeView(badge: session.agentBadge)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
            SubworkerStatusLabel(session: session)
            Text(session.lastActivity.relativeDescription(asOf: relativeTimeNow))
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(Color.textMuted)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .cardSelectionStyle(isSelected: false, isHovered: isHovered)
        .padding(.horizontal, AppChrome.rowSelectionHorizontalInset)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(session.displayName), \(session.status.accessibilityDescription), sub-worker group"
        )
    }
}

/// Compact restatement of the session card's status label. Kept local so the Agents view
/// cannot drift into a second status vocabulary.
struct SubworkerStatusLabel: View {
    let session: SessionData

    var body: some View {
        if session.lifecycle == .dormant {
            text("Dormant", color: Color.textMuted)
        } else {
            switch session.status {
            case .idle:
                text("Idle", color: Color.textMuted)
            case .working:
                dot("Working", dotColor: Color.statusGreen, textColor: Color.statusWorkingText)
            case .compacting:
                dot("Compacting", dotColor: Color.agentBadge, textColor: Color.agentBadge)
            case .waitingPermission:
                dot("Permission", dotColor: Color.statusPermission, textColor: Color.statusPermissionText)
            case .waitingInput, .needsAttention:
                dot("Waiting", dotColor: Color.statusAttention, textColor: Color.statusAttentionText)
            }
        }
    }

    private func text(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(color)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func dot(_ label: String, dotColor: Color, textColor: Color) -> some View {
        HStack(spacing: 4.5) {
            Circle().fill(dotColor).frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(textColor)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - Previews

#Preview("Agents — three levels") {
    PopupView(
        userSessions: SubworkerTree.previewRoots,
        delegatedSessionRecords: SubworkerTree.previewDelegatedRecords,
        updater: DisabledUpdater(),
        pluginManager: PluginManager(
            homeDirectory: URL(fileURLWithPath: "/nonexistent"),
            refreshOnInit: false
        ),
        initialTab: .agents
    )
    .frame(width: 320)
}

#Preview("Agents — expanded rows") {
    let tree = SubworkerTree.build(
        roots: SubworkerTree.previewRoots,
        delegated: SubworkerTree.previewDelegatedRecords.map(\.data)
    )
    return ScrollView {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(tree.groups) { group in
                SubworkerGroupView(
                    group: group,
                    initiallyExpandedNodeIDs: SubworkerTree.previewExpandedNodeIDs(in: group)
                )
            }
        }
    }
    .frame(width: 320, height: 560)
    .background { PanelSurfaceBackground() }
}
