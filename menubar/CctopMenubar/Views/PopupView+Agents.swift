import SwiftUI

extension PopupView {
    /// Roots are the visible sessions in canonical order. Dropped sessions are already
    /// absent from `userSessions`; acknowledged ones are mirrors of rows that stay there.
    var subworkerTree: SubworkerTree.Snapshot {
        SubworkerTree.build(
            roots: userSessions,
            delegated: delegatedSessionRecords.map(\.data)
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
                            onFocusRoot: { focusSession($0) }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            ForEach(group.nodes) { node in
                SubworkerRowView(node: node, relativeTimeNow: relativeTimeNow)
            }
        }
        .padding(.top, 6)
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

struct SubworkerRowView: View {
    let node: SubworkerTree.Node
    var relativeTimeNow = Date()

    private var indent: CGFloat { CGFloat(node.depth - 1) * 12 }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            titleLine
            if let activity = activityText {
                HStack(spacing: 0) {
                    Text("› ")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Color.statusGreen.opacity(0.7))
                    Text(activity)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(secondaryColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.leading, 9 + indent + AppChrome.rowSelectionHorizontalInset)
        .padding(.trailing, 9 + AppChrome.rowSelectionHorizontalInset)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var titleLine: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isStale ? Color.textSecondary : Color.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            if case .delegated(let session) = node.kind {
                SourceBadgeView(badge: session.agentBadge)
                    .fixedSize(horizontal: true, vertical: false)
            }
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if case .delegated(let session) = node.kind {
                SubworkerStatusLabel(session: session)
            }
            Text(elapsedText)
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(Color.textMuted)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    // MARK: - Copy

    private var title: String {
        switch node.kind {
        case .inProcess(let info): return info.agentType
        case .delegated(let session): return session.displayName
        }
    }

    private var subtitle: String? {
        guard case .inProcess(let info) = node.kind else { return nil }
        return info.description
    }

    private var isStale: Bool {
        guard case .inProcess(let info) = node.kind else { return false }
        return SubworkerTree.isStale(info, now: relativeTimeNow)
    }

    private var secondaryColor: Color {
        isStale ? Color.textMuted : Color.textSecondary
    }

    private var elapsedText: String {
        let started: Date
        switch node.kind {
        case .inProcess(let info): started = info.startedAt
        case .delegated(let session): started = session.startedAt
        }
        let elapsed = started.relativeDescription(asOf: relativeTimeNow)
        return isStale ? "\(elapsed) · stale" : elapsed
    }

    /// In-process rows show the subagent's own tool. Delegated rows follow the session
    /// card's choice: a pending permission prompt wins over the running tool.
    private var activityText: String? {
        switch node.kind {
        case .inProcess(let info):
            guard let tool = info.lastTool else { return "no tool yet" }
            guard let detail = info.lastToolDetail else { return "\(tool)..." }
            return "\(tool): \(detail)"
        case .delegated(let session):
            if session.status == .waitingPermission {
                return session.notificationMessage ?? "Permission needed"
            }
            guard let tool = session.lastTool else { return nil }
            guard let detail = session.lastToolDetail else { return "\(tool)..." }
            return "\(tool): \(detail)"
        }
    }

    private var accessibilityLabel: String {
        var parts: [String] = [title]
        if let subtitle { parts.append(subtitle) }
        if case .delegated(let session) = node.kind {
            parts.append(session.status.accessibilityDescription)
        }
        parts.append("started \(elapsedText)")
        if let activityText { parts.append(activityText) }
        return parts.joined(separator: ", ")
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
