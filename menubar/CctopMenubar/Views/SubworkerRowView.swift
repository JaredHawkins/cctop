import Foundation
import SwiftUI

/// One sub-worker row in the Agents view: a compact summary line that expands in place into
/// the detail Jared asked to "click in and see". Expansion is view state only.
struct SubworkerRowView: View {
    let node: SubworkerTree.Node
    var relativeTimeNow = Date()
    var isExpanded = false
    var onToggle: () -> Void = {}

    @State private var isHovered = false

    private var indent: CGFloat { CGFloat(node.depth - 1) * 12 }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            summary
            if isExpanded { detail }
        }
        .padding(.leading, 9 + indent)
        .padding(.trailing, 9)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSelectionStyle(isSelected: false, isHovered: isHovered)
        .padding(.horizontal, AppChrome.rowSelectionHorizontalInset)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(isExpanded ? "Hide details" : "Show details")
    }

    // MARK: - Summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: 1) {
            titleLine
            if let activityText {
                HStack(spacing: 0) {
                    Text("\u{203A} ")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Color.statusGreen.opacity(0.7))
                    Text(activityText)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(secondaryColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 14)
            }
        }
    }

    private var titleLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Color.textMuted)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 8)
                .accessibilityHidden(true)
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
            if isWaiting {
                Circle()
                    .fill(Color.statusPermission)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
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

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 3) {
            switch node.kind {
            case .inProcess(let info): inProcessDetail(info)
            case .delegated(let session): delegatedDetail(session)
            }
        }
        .padding(.leading, 14)
        .padding(.top, 2)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private func inProcessDetail(_ info: SubagentInfo) -> some View {
        if let description = info.description {
            SubworkerDetailRow(label: "Task", value: description)
        }
        SubworkerDetailRow(label: "Type", value: typeDescription(info))
        SubworkerDetailRow(label: "Started", value: startedDescription(info.startedAt))
        SubworkerDetailRow(label: "Last activity", value: info.effectiveActivity.relativeDescription(asOf: relativeTimeNow))
        if let count = info.toolCallCount {
            SubworkerDetailRow(label: "Tool calls", value: "\(count)")
        }
        if let recent = info.recentTools, !recent.isEmpty {
            SubworkerDetailLinesRow(label: "Recent", values: recent)
        }
        if let waiting = info.waitingMessage {
            SubworkerDetailRow(label: "Waiting", value: waiting, valueColor: Color.statusPermissionText)
        }
        if let excerpt = info.promptExcerpt {
            SubworkerPromptBlock(text: excerpt)
        }
    }

    @ViewBuilder
    private func delegatedDetail(_ session: SessionData) -> some View {
        SubworkerDetailRow(label: "Project", value: (session.projectPath as NSString).abbreviatingWithTildeInPath)
        SubworkerDetailRow(label: "Branch", value: session.branch, monospaced: true)
        if let pid = session.pid {
            SubworkerDetailRow(label: "PID", value: "\(pid)", monospaced: true)
        }
        SubworkerDetailRow(label: "Started", value: startedDescription(session.startedAt))
        SubworkerDetailRow(label: "Last activity", value: session.lastActivity.relativeDescription(asOf: relativeTimeNow))
        if session.status == .waitingPermission {
            SubworkerDetailRow(
                label: "Waiting",
                value: session.notificationMessage ?? "Permission needed",
                valueColor: Color.statusPermissionText
            )
        }
        if let prompt = session.lastPrompt {
            SubworkerPromptBlock(text: HookHandler.subagentPromptExcerpt(prompt))
        }
    }

    // MARK: - Copy

    private static let startedTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private func startedDescription(_ date: Date) -> String {
        "\(Self.startedTimeFormatter.string(from: date)) \u{00B7} \(date.relativeDescription(asOf: relativeTimeNow))"
    }

    private func typeDescription(_ info: SubagentInfo) -> String {
        var parts = [info.agentType]
        if let subagentType = info.subagentType, subagentType != info.agentType {
            parts.append(subagentType)
        }
        var text = parts.joined(separator: " / ")
        if let model = info.model { text += " \u{00B7} \(model)" }
        return text
    }

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

    private var isWaiting: Bool {
        switch node.kind {
        case .inProcess(let info): return info.waitingMessage != nil
        case .delegated(let session): return session.status == .waitingPermission
        }
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
        return isStale ? "\(elapsed) \u{00B7} stale" : elapsed
    }

    /// In-process rows show the subagent's own tool, or what it is blocked on. Delegated rows
    /// follow the session card's choice: a pending permission prompt wins over the tool.
    private var activityText: String? {
        switch node.kind {
        case .inProcess(let info):
            if let waiting = info.waitingMessage { return waiting }
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

/// One label/value line in an expanded sub-worker row.
struct SubworkerDetailRow: View {
    let label: String
    let value: String
    var monospaced = false
    var valueColor: Color = .textSecondary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(Color.textMuted)
                .frame(width: 66, alignment: .leading)
            Text(value)
                .font(.system(size: 10.5, design: monospaced ? .monospaced : .default))
                .foregroundStyle(valueColor)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A label with several one-line values, newest last. Each entry is capped to one visual
/// line so a multi-line shell command cannot take over the panel.
struct SubworkerDetailLinesRow: View {
    let label: String
    let values: [String]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(Color.textMuted)
                .frame(width: 66, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    Text(value)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// Bordered, wrapped block for a spawning prompt. Capped so one verbose task cannot push the
/// rest of the group off screen.
struct SubworkerPromptBlock: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(Color.textSecondary)
            .lineLimit(6)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: AppChrome.groupCornerRadius, style: .continuous)
                    .fill(Color.groupedRowBackground)
            }
            .overlay {
                RoundedRectangle(cornerRadius: AppChrome.groupCornerRadius, style: .continuous)
                    .stroke(Color.groupedRowBorder, lineWidth: 0.5)
            }
            .padding(.top, 1)
    }
}
