# Local patch: temporary session drop and menu bar placement

This patch is stacked after
`docs/local-notch-and-session-ack-patch.md`. It adds two local behaviors:

1. **Drop Until Next Activity** removes a session from operational cctop
   surfaces without ending or permanently hiding it. The Dropped selector keeps
   it reachable for Restore Session, and a newer session event also restores it.
2. Settings > Appearance > Indicator adds **Menu Bar** beside **Side** and
   **Below**. Menu Bar uses a compact clickable status icon and disables the
   separate notch pill.

## Stable behavior contracts

- Temporary drop is presentation-only. It does not write hook-owned session
  JSON, change `SessionLifecycle`, stop a process, archive a thread, enter
  Recent, or create manual-hide evidence.
- Drops persist in UserDefaults under
  `temporarilyDroppedSessionActivityRevisions`, keyed only by the permanent
  `cctop_session_id`. Each value is the greatest `lastActivity` date across all
  records in the grouped `UserSession`.
- An exact stored activity revision is removed before `SessionManager` publishes
  operational `userSessions`. Active, Idle, counts, notifications, Navigate
  mode, notch or menu bar status, and Stream Deck therefore agree that the
  session is absent. `droppedUserSessions` retains the same grouped row only for
  the Dropped selector and its Restore Session action.
- Any later hook event advancing any grouped record's `lastActivity` invalidates
  the drop and restores the session. Partial inventories retain missing drop
  evidence; a complete inventory prunes it. Restore Session clears the drop
  immediately without changing source JSON. Manual Hide clears the temporary
  drop for the same permanent ID.
- The compact one-row selector strip keeps Active, Idle, Ack, and Dropped
  visible. A trailing overflow menu opens Recent or Cleanup with one additional
  click. Ack is a mirror of acknowledged rows that remain grey in Active or
  Idle. Dropped is a management-only collection and is excluded from every
  operational signal.
- Indicator placement keeps the existing UserDefaults key
  `notchStatusPlacement`. Existing `side` and `below` values remain valid;
  `menu_bar` is the new third value. Missing or invalid values still fall back
  to Below.
- Side and Below retain the existing 36×18 menubar fallback and notch geometry.
  Menu Bar tears down the notch pill, changes the status item to the native
  square footprint, and renders an 18×18 image containing a centered 14×6 live
  status hairline. Clicking it uses the existing `togglePanel` action.
- A third-party menu-bar organizer can still hide a newly registered native
  status item. On this machine Bartender 6 initially places cctop off-screen;
  mark cctop as Always Show (or move it into Bartender's visible section) after
  choosing Menu Bar. This is organizer state, not cctop placement state.

## Main implementation points

- `menubar/CctopMenubar/Services/SessionTemporaryDropStore.swift` owns
  `SessionActivityRevision` and `SessionTemporaryDropStore`.
- `menubar/CctopMenubar/Services/SessionManager+Notifications.swift` applies,
  expires, and directly triggers drops.
- `menubar/CctopMenubar/Services/SessionManager.swift` filters drops before the
  shared operational projection is published and exposes the auxiliary Ack and
  Dropped collections.
- `menubar/CctopMenubar/Views/PopupView+Sessions.swift` exposes the non-destructive
  context-menu and accessibility actions, including Restore Session.
- `menubar/CctopMenubar/Views/PopupNavigation.swift` owns the six selector labels,
  help text, and keyboard order.
- `menubar/CctopMenubar/Models/AppSettings.swift` owns the three-way indicator
  placement and preserves the prior preference key.
- `menubar/CctopMenubar/AppDelegate.swift` switches status-item footprint and
  notch visibility without changing the panel-opening action.
- `menubar/CctopMenubar/Views/MenubarIconRenderer.swift` owns the standard and
  compact status hairline layouts.

## Upgrade and reapply checklist

1. Reapply the Claude-launched Codex filter patch, then the notch and
   acknowledgement patch, then this patch.
2. Preserve the existing `notchStatusPlacement` preference key and its `side`
   and `below` raw values. Add `menu_bar`; do not silently reset prior choices.
3. Resolve upstream session-projection changes by keeping temporary-drop
   filtering before `userSessions` publication and downstream display-state
   writing.
4. Acknowledge one attention session. Confirm it turns grey but remains in its
   normal Active or Idle list and also appears under Ack. Deliver a newer
   attention event and confirm it leaves Ack and becomes conspicuous again.
5. Drop one active and one dormant session. Confirm each disappears from Active
   or Idle, counts, Navigate mode, notifications, and Stream Deck without
   changing its source JSON, while remaining reachable under Dropped.
6. Restart cctop and confirm each remains only under Dropped. Use Restore Session
   on one and confirm it returns immediately. Deliver a newer hook event to the
   other and confirm it returns automatically.
7. Confirm Hide remains durable and removes a row from Dropped; confirm Drop
   creates no `manuallyHiddenCctopSessionIDs` entry.
8. Switch among Side, Below, and Menu Bar. Confirm Menu Bar shows only the
   compact status item, clicking opens the same panel, and switching back
   restores notch-fallback behavior and its selected geometry.
9. If the native item is absent, check Bartender or another menu-bar organizer
   before changing cctop. Confirm the cctop item is configured to remain visible.
10. Under cctop's private runtime lease, run `make all`, then `make snapshots`.
   Inspect the Settings placement picker and capture the live menu-bar result on
   a notched display before publication.

Focused regression coverage lives in `SessionAttentionAcknowledgementTests`,
`SessionTemporaryDropTests`, `WorktreeCleanupTests`, `NotchVisibilityTests`,
`AppSettingsTests`, and `MenubarIconRendererTests`.
