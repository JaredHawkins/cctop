import Foundation

/// Identifies the latest hook-owned activity represented by one grouped session.
/// Any later event advances this value and therefore expires a temporary drop.
struct SessionActivityRevision: Codable, Equatable {
    let lastActivity: Date

    init(userSession: UserSession) {
        lastActivity = userSession.records.map(\.data.lastActivity).max()
            ?? userSession.displayRecord.data.lastActivity
    }
}

/// Persists sessions removed from cctop only until their next activity event.
/// This is presentation state: it never edits, ends, archives, or permanently
/// hides the hook-owned session record.
struct SessionTemporaryDropStore {
    static let defaultsKey = "temporarilyDroppedSessionActivityRevisions"
    static let live = SessionTemporaryDropStore(defaults: .standard)

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var droppedRevisions: [String: SessionActivityRevision] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder.sessionDecoder.decode(
                  [String: SessionActivityRevision].self,
                  from: data
              ) else { return [:] }
        return decoded.filter { CctopSessionID.isValid($0.key) }
    }

    func drop(cctopSessionID: String, userSession: UserSession) {
        guard CctopSessionID.isValid(cctopSessionID) else { return }
        var revisions = droppedRevisions
        revisions[cctopSessionID] = SessionActivityRevision(userSession: userSession)
        save(revisions)
    }

    func remove(cctopSessionID: String) {
        var revisions = droppedRevisions
        guard revisions.removeValue(forKey: cctopSessionID) != nil else { return }
        save(revisions)
    }

    /// Keep an exact drop while its activity revision is unchanged. A changed
    /// revision restores the session; a complete inventory prunes missing IDs.
    func reconcile(
        currentRevisions: [String: SessionActivityRevision],
        observedSessionIDs: Set<String>,
        inventoryComplete: Bool
    ) {
        let current = droppedRevisions
        let retained = current.filter { cctopSessionID, droppedRevision in
            if let currentRevision = currentRevisions[cctopSessionID] {
                return currentRevision == droppedRevision
            }
            return !inventoryComplete && !observedSessionIDs.contains(cctopSessionID)
        }
        guard retained != current else { return }
        save(retained)
    }

    private func save(_ revisions: [String: SessionActivityRevision]) {
        guard !revisions.isEmpty else {
            defaults.removeObject(forKey: Self.defaultsKey)
            return
        }
        guard let data = try? JSONEncoder.sessionEncoder.encode(revisions) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
