import Foundation
import SwiftUI

enum PopupTab: CaseIterable, Hashable {
    case active, idle, acknowledged, dropped, agents, recent, cleanup

    /// The selectors that are always segments in the row.
    static let baseCases: [PopupTab] = [.active, .idle, .acknowledged, .dropped]

    /// Agents earns a segment while it has something to show and falls back into the
    /// overflow when it does not, so a running sub-worker is one click away without a
    /// permanently empty selector taking width from the four that are always relevant.
    static func primaryCases(agentsCount: Int) -> [PopupTab] {
        agentsCount > 0 ? baseCases + [.agents] : baseCases
    }

    static func secondaryCases(agentsCount: Int) -> [PopupTab] {
        agentsCount > 0 ? [.recent, .cleanup] : [.agents, .recent, .cleanup]
    }

    /// Left-to-right order as rendered: segments first, then the overflow menu. Agents sits
    /// after Dropped in both placements, so keyboard cycling matches the screen either way
    /// and `allCases` stays a valid cycle order.
    static func orderedCases(agentsCount: Int) -> [PopupTab] {
        primaryCases(agentsCount: agentsCount) + secondaryCases(agentsCount: agentsCount)
    }

    var label: String {
        switch self {
        case .active: return "Active"
        case .idle: return "Idle"
        case .acknowledged: return "Ack"
        case .dropped: return "Dropped"
        case .agents: return "Agents"
        case .recent: return "Recent"
        case .cleanup: return "Cleanup"
        }
    }

    var helpText: String {
        let staleIdleDuration = Self.staleIdleDurationText
        switch self {
        case .active:
            return "Current sessions; idle moves after \(staleIdleDuration)."
        case .idle:
            return "Dormant sessions and idle sessions over \(staleIdleDuration)."
        case .acknowledged:
            return "Acknowledged sessions; newer attention clears the acknowledgement."
        case .dropped:
            return "Sessions removed from normal surfaces until restored or newer activity."
        case .agents:
            return "Sub-workers spawned by your sessions: in-process Claude subagents and delegated Claude or Codex runs. "
                + "Delegated runs leave when their process exits."
        case .recent:
            return "Finished work and archived desktop sessions. Rows open the project or app when possible."
        case .cleanup:
            return "Ended-session worktrees checked before removal."
        }
    }

    var emptyStateDetail: String {
        switch self {
        case .active:
            return "Current and recently idle sessions appear here."
        case .idle:
            return "Dormant and long-idle sessions appear here."
        case .acknowledged:
            return "Acknowledged sessions appear here until they report newer attention."
        case .dropped:
            return "Dropped sessions appear here until restored or they report newer activity."
        case .agents:
            return "No sub-workers running under your sessions."
        case .recent:
            return "Finished work and archived desktop sessions appear here."
        case .cleanup:
            return "Ended-session worktrees appear here after checks."
        }
    }

    static var cleanupScanningDetail: String {
        "Checking ended-session worktrees."
    }

    static func switched(
        from current: PopupTab,
        action: PanelNavAction,
        availableTabs: [PopupTab]
    ) -> PopupTab {
        guard let currentIndex = availableTabs.firstIndex(of: current), !availableTabs.isEmpty else {
            return .active
        }
        switch action {
        case .previousTab:
            return availableTabs[(currentIndex - 1 + availableTabs.count) % availableTabs.count]
        case .nextTab, .toggleTab:
            return availableTabs[(currentIndex + 1) % availableTabs.count]
        default:
            return current
        }
    }

    private static var staleIdleDurationText: String {
        let hours = Int(SessionDisplayPolicy.staleIdleInterval / 3_600)
        return "\(hours) hours"
    }
}

// MARK: - Panel tab row

extension PopupView {
    // MARK: - Tab picker

    var tabPicker: some View {
        // One tree build decides placement and fills the segment's own count.
        let agentsCount = subworkerTree.childCount
        return HStack(spacing: 1) {
            ForEach(PopupTab.primaryCases(agentsCount: agentsCount), id: \.self) { tab in
                tabButton(
                    tab.label,
                    count: tab == .agents ? agentsCount : count(for: tab),
                    tab: tab,
                    isScanning: tab == .cleanup && cleanupIsScanning,
                    hasAttention: tab == .cleanup && cleanupHasUnseenCandidates
                )
            }
            SecondaryTabMenuView(
                selectedTab: selectedTab,
                cleanupIsScanning: cleanupIsScanning,
                cleanupHasAttention: cleanupHasUnseenCandidates,
                cases: PopupTab.secondaryCases(agentsCount: agentsCount),
                count: { $0 == .agents ? agentsCount : count(for: $0) },
                onSelect: selectTab
            )
        }
        .padding(2)
        .background(Color.segmentBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    func count(for tab: PopupTab) -> Int {
        switch tab {
        case .active: return activeSessionRows.count
        case .idle: return idleSessionRows.count
        case .acknowledged: return acknowledgedSessionRows.count
        case .dropped: return droppedSessionRows.count
        case .agents: return subworkerTree.childCount
        case .recent: return recentTargets.count
        case .cleanup: return actionableCleanupCandidates.count
        }
    }

    private func tabButton(
        _ label: String,
        count: Int,
        tab: PopupTab,
        isScanning: Bool = false,
        hasAttention: Bool = false
    ) -> some View {
        TabButtonView(
            label: label,
            count: count,
            isScanning: isScanning,
            hasAttention: hasAttention && selectedTab != tab,
            isSelected: selectedTab == tab
        ) {
            selectTab(tab)
        }
        .help(tab.helpText)
    }

    func selectTab(_ tab: PopupTab) {
        if overlayController.active != nil { closeOverlay(animated: false) }
        withAnimation(.easeInOut(duration: 0.15)) { selectedTab = tab }
        notifyLayoutChanged()
    }
}

struct SecondaryTabMenuView: View {
    let selectedTab: PopupTab
    let cleanupIsScanning: Bool
    let cleanupHasAttention: Bool
    /// The tabs currently living in the overflow; Agents moves in and out of this list.
    let cases: [PopupTab]
    let count: (PopupTab) -> Int
    let onSelect: (PopupTab) -> Void

    private var isSelected: Bool {
        cases.contains(selectedTab)
    }

    var body: some View {
        Menu {
            ForEach(cases, id: \.self) { tab in
                Button {
                    onSelect(tab)
                } label: {
                    Text(menuLabel(for: tab))
                }
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                if cleanupIsScanning {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(isSelected ? Color.textPrimary : Color.textSecondary)
                        .frame(width: 10, height: 10)
                } else {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10, weight: .semibold))
                }
                if cleanupHasAttention && selectedTab != .cleanup {
                    Circle()
                        .fill(Color.statusAttention)
                        .frame(width: 5, height: 5)
                        .offset(x: 5, y: -3)
                }
            }
            .foregroundStyle(isSelected ? Color.textPrimary : Color.textSecondary)
            .frame(width: 28, height: 22)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.segmentThumbBackground)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: true, vertical: false)
        .help(cases.map(\.label).formattedAsList)
        .accessibilityLabel("More views")
        .accessibilityValue(isSelected ? selectedTab.label : "")
    }

    private func menuLabel(for tab: PopupTab) -> String {
        if tab == .cleanup && cleanupIsScanning {
            return "Cleanup checking"
        }
        return "\(tab.label) \(count(tab))"
    }
}

struct PopupSelectionContext {
    let recentTargets: [RecentResumeTarget]
    let cleanupCandidates: [WorktreeCleanupCandidate]

    init(
        recentProjects: [RecentProject] = [],
        recentResumeTargets: [RecentResumeTarget]? = nil,
        cleanupCandidates: [WorktreeCleanupCandidate]
    ) {
        self.recentTargets = recentResumeTargets ?? recentProjects.map(RecentResumeTarget.project)
        self.cleanupCandidates = cleanupCandidates
    }
}

enum PopupSelectionTarget: Equatable {
    case recentTarget(RecentResumeTarget)
    case cleanupCandidate(WorktreeCleanupCandidate)

    var confirmsNavigate: Bool {
        switch self {
        case .recentTarget:
            return true
        case .cleanupCandidate:
            return false
        }
    }

    static func target(
        for tab: PopupTab,
        index: Int,
        in context: PopupSelectionContext
    ) -> PopupSelectionTarget? {
        switch tab {
        // Session selectors resolve by logical identity, and Agents rows are inert.
        case .active, .idle, .acknowledged, .dropped, .agents:
            return nil
        case .recent:
            guard index < context.recentTargets.count else { return nil }
            return .recentTarget(context.recentTargets[index])
        case .cleanup:
            guard index < context.cleanupCandidates.count else { return nil }
            return .cleanupCandidate(context.cleanupCandidates[index])
        }
    }
}

extension Array where Element == String {
    /// "Recent and Cleanup" / "Agents, Recent, and Cleanup" — help text for the overflow,
    /// which changes membership as Agents moves in and out of the segment row.
    var formattedAsList: String {
        switch count {
        case 0: return ""
        case 1: return self[0]
        case 2: return "\(self[0]) and \(self[1])"
        default: return "\(dropLast().joined(separator: ", ")), and \(self[count - 1])"
        }
    }
}
