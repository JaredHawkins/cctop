# Local patch: notch placement and session acknowledgement

This patch is stacked on the local Claude-launched Codex subagent filter in
`docs/local-claude-codex-delegation-patch.md`. It adds two local UI behaviors:

1. The compact notch status bar defaults to a centered tab immediately below
   the physical notch. Settings > Appearance > Notch Bar can switch between
   Below and the original Side placement.
2. Right-clicking an attention session exposes Acknowledge. The current event
   becomes neutral grey/idle on every cctop surface while the session remains
   active and focusable. Pressing the same Stream Deck session key twice within
   350 ms sends the same action. A later attention event restores its normal
   color.

## Stable behavior contracts

- Notch placement is presentation-only and persists in UserDefaults under
  `notchStatusPlacement`. Missing or invalid values fall back to `below`.
- Below uses a 52×20 black tab centered on the screen midpoint. Its top edge is
  exactly the physical notch's bottom edge. Side preserves the prior left-edge
  geometry and nine-point overlap.
- Acknowledgement is not Hide Session and is not lifecycle. It never writes a
  hook-owned session JSON file, stops a process, removes a card, or changes
  `SessionLifecycle`.
- Acknowledgements persist in UserDefaults under
  `acknowledgedSessionAttentionRevisions`, keyed only by cctop's permanent
  session ID. Each value contains the attention status and `lastActivity` date.
- The app overlays `.idle` only when the stored revision exactly matches the
  currently derived attention revision. Any newer hook event changes
  `lastActivity`, invalidates the acknowledgement, and restores attention.
- The overlay is applied before the shared `UserSession` projection is
  published, so the card, header counts, menubar icon, notch bar, notifications,
  accessibility text, and Stream Deck state all agree.
- Partial session inventories retain unobserved acknowledgements. Complete
  inventories prune missing sessions, and any observed non-attention or changed
  revision is pruned immediately.
- A Stream Deck key's first press retains the existing immediate focus action.
  A second press within 350 ms acknowledges only when the same key context still
  owns the same rendered permanent session ID. Different keys never combine,
  even when they display the same grouped session ID.

## Main implementation points

- `menubar/CctopMenubar/Models/AppSettings.swift`
  owns `NotchStatusPlacement`, its default, and its preference key.
- `menubar/CctopMenubar/Services/NotchStatusController.swift`
  calculates Side and Below frames and repositions an existing panel.
- `menubar/CctopMenubar/Views/NotchStatusView.swift`
  renders the placement-specific tab shape and padding.
- `menubar/CctopMenubar/Views/SettingsControls.swift`
  exposes the Side/Below picker.
- `menubar/CctopMenubar/Services/SessionIdentityPolicy.swift`
  owns the exact-event acknowledgement revision and UserDefaults store.
- `menubar/CctopMenubar/Services/SessionManager+Notifications.swift`
  applies the neutral presentation, removes stale revisions, and updates
  notifications without changing persisted session state.
- `menubar/CctopMenubar/Views/PopupView+Sessions.swift`
  exposes Acknowledge only for current attention states.
- `plugins/streamdeck/com.st0012.cctop.sdPlugin/lib/controller.mjs`
  recognizes same-key, same-session double presses without re-resolving a
  shifted slot.
- `plugins/streamdeck/com.st0012.cctop.sdPlugin/lib/launcher.mjs` and
  `menubar/CctopMenubar/AppDelegate.swift` carry the validated
  `cctop://acknowledge?sid=...` command into `SessionManager`.

## Upgrade/reapply checklist

1. Rebase the local filter patch first, then replay this patch on top.
2. Resolve upstream changes around notch geometry, Settings appearance rows,
   `SessionData.lastActivity`, `UserSession` projection, or notification
   transition handling by preserving the contracts above rather than blindly
   choosing either side of a conflict.
3. Confirm the default Below frame is centered and touches the notch bottom;
   confirm Side still matches the legacy frame.
4. Confirm Acknowledge keeps the session count and active lifecycle unchanged,
   turns shared status counts idle/grey, and does not modify the source record.
5. Rewrite the same session with a newer `lastActivity` and confirm attention
   returns automatically.
6. Press one Stream Deck session key once and confirm it focuses immediately;
   press it twice quickly and confirm the exact rendered session turns grey.
   Confirm two different keys never combine into a double press.
7. Run `make all` while holding the cctop runtime lane.
8. Capture a real app screenshot on a notched display before reinstalling.

Focused regression coverage lives in `NotchVisibilityTests` and
`SessionAttentionAcknowledgementTests`, plus the Stream Deck protocol tests for
same-key double presses and separate-key isolation.
