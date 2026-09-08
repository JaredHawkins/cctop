import SwiftUI

/// Renders a session's source/host badge as quiet metadata.
/// Harness labels stay neutral so project names and session state remain primary.
struct SourceBadgeView: View {
    let badge: AgentBadge

    var body: some View {
        Text(badge.label)
            .font(.system(size: 9.5, weight: .medium))
            .tracking(0.4)
            .foregroundStyle(Color.textMuted.opacity(0.82))
            .accessibilityLabel(badge.label)
    }
}

/// Which login a session runs under, as a one-letter monogram in a hairline square. Renders
/// nothing on the default (personal) account, so the panel stays quiet unless a Klick
/// session or delegate is present. Same muted family as `SourceBadgeView`; it is metadata.
struct AccountMarkView: View {
    let session: SessionData

    var body: some View {
        if let monogram = session.accountMonogram, let account = session.account {
            Text(monogram)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(Color.textMuted.opacity(0.9))
                .frame(width: 12, height: 12)
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(Color.textMuted.opacity(0.55), lineWidth: 1)
                )
                .help("\(account) account")
                .accessibilityLabel("\(account) account")
        }
    }
}

#Preview("CC") {
    SourceBadgeView(badge: .cc).padding()
}
#Preview("Claude Desktop") {
    SourceBadgeView(badge: .claudeDesktop).padding()
}
#Preview("Codex") {
    SourceBadgeView(badge: .codex).padding()
}
#Preview("Opencode") {
    SourceBadgeView(badge: .opencode).padding()
}
#Preview("Pi") {
    SourceBadgeView(badge: .pi).padding()
}
#Preview("All variants") {
    VStack(alignment: .leading, spacing: 12) {
        SourceBadgeView(badge: .cc)
        SourceBadgeView(badge: .claudeDesktop)
        SourceBadgeView(badge: .codex)
        SourceBadgeView(badge: .opencode)
        SourceBadgeView(badge: .pi)
    }
    .padding()
}
