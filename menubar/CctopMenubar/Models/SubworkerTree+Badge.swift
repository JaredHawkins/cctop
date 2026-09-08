import Foundation

/// The session card's sub-worker pill, derived from the same tree the Agents tab renders.
extension SubworkerTree {
    /// Parent-card badge: how many sub-workers this session is showing, and how many of them
    /// are blocked on a permission. Nil when the Agents view would show none, so the badge
    /// and the tab always agree. Deliberately no activity text: what the busiest child is
    /// doing belongs in the Agents view, not squeezed into a session card.
    struct Badge: Equatable {
        let count: Int
        let waiting: Int
        /// Accounts other than the default that at least one delegated child runs under,
        /// sorted. In-process subagents share their parent's login, so only delegated
        /// records can introduce one; the parent's own mark says which login the parent is.
        var accounts: [String] = []

        var label: String {
            let text = "\(count) agent\(count == 1 ? "" : "s")"
            guard waiting > 0 else { return text }
            return "\(text) \u{00B7} \(waiting) waiting"
        }

        var accountMonograms: [String] {
            accounts.compactMap { $0.first.map { String($0).uppercased() } }
        }

        var accessibilityLabel: String {
            var text = "Show \(count) agent\(count == 1 ? "" : "s")"
            if waiting > 0 { text += ", \(waiting) waiting" }
            if !accounts.isEmpty { text += ", some on \(accounts.joined(separator: " and ")) account" }
            return text
        }
    }

    /// In-process-only badge for a bare record, used where no tree is available. The panel
    /// uses `Snapshot.badges` instead so the card counts exactly the group's rows.
    static func badge(for data: SessionData, now: Date) -> Badge? {
        let visible = visibleSubagents(of: data, now: now)
        guard !visible.isEmpty else { return nil }
        return Badge(
            count: visible.count,
            waiting: visible.filter { $0.waitingMessage != nil }.count
        )
    }

    /// Badge for a whole group: every node the Agents view shows under this root, in-process
    /// and delegated, plus which non-default accounts the delegated children run under.
    static func badge(for group: Group) -> Badge {
        var waiting = 0
        var accounts: Set<String> = []
        for node in group.nodes {
            switch node.kind {
            case .inProcess(let info):
                if info.waitingMessage != nil { waiting += 1 }
            case .delegated(let data):
                if data.status == .waitingPermission { waiting += 1 }
                if let account = data.account { accounts.insert(account) }
            }
        }
        return Badge(count: group.nodes.count, waiting: waiting, accounts: accounts.sorted())
    }
}
