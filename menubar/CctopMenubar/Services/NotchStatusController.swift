import AppKit
import SwiftUI

/// Manages the notch status panel lifecycle. Creates a small status indicator
/// attached to the camera notch on built-in displays. No-op on non-notch Macs.
@MainActor
class NotchStatusController {
    private static let pillWidth: CGFloat = 52
    private static let pillHeight: CGFloat = 20
    /// How far the pill overlaps the notch edge, anchoring it visually.
    private static let notchOverlap: CGFloat = 9

    private var panel: NotchStatusPanel?
    private var hostingView: NSHostingView<NotchStatusView>?

    /// Provides the current theme identifier; injected so tests and previews
    /// don't have to go through the ThemeManager singleton.
    private let themeId: @MainActor () -> String
    /// Provides the user's preferred attachment edge.
    private let placement: @MainActor () -> NotchStatusPlacement

    /// Called when the notch pill is clicked.
    var onPillClicked: (() -> Void)?

    /// Last counts received, used when creating or updating the panel.
    private(set) var lastCounts = StatusCounts.zero
    private(set) var lastPlacement = NotchStatusPlacement.defaultValue

    init(
        themeId: @escaping @MainActor () -> String = { ThemeManager.shared.themeId },
        placement: @escaping @MainActor () -> NotchStatusPlacement = {
            NotchStatusPlacement.current()
        }
    ) {
        self.themeId = themeId
        self.placement = placement
    }

    /// The pill's current frame in screen coordinates, if visible.
    var pillFrame: NSRect? {
        guard let panel, panel.isVisible else { return nil }
        return panel.frame
    }

    /// Show the notch panel on the given screen. Idempotent — reuses existing panel.
    func showOnScreen(_ screen: NSScreen, counts: StatusCounts) {
        guard screen.hasPhysicalNotch else { return }

        let currentPlacement = placement()
        let frame = Self.pillFrame(
            screenFrame: screen.frame,
            notchSize: screen.notchSize,
            placement: currentPlacement
        )

        if let panel {
            if counts != lastCounts || currentPlacement != lastPlacement {
                hostingView?.rootView = NotchStatusView(
                    counts: counts,
                    placement: currentPlacement,
                    themeId: themeId()
                )
                lastCounts = counts
                lastPlacement = currentPlacement
            }
            panel.setFrame(frame, display: true)
            if !panel.isVisible { panel.orderFrontRegardless() }
            return
        }

        let statusView = NotchStatusView(
            counts: counts,
            placement: currentPlacement,
            themeId: themeId()
        )
        let hosting = NSHostingView(rootView: statusView)
        hosting.autoresizingMask = [.width, .height]

        let newPanel = NotchStatusPanel(
            contentRect: .zero, styleMask: [],
            backing: .buffered, defer: false
        )
        newPanel.onPillClick = { [weak self] in self?.onPillClicked?() }
        newPanel.contentView = hosting
        newPanel.setFrame(frame, display: true)
        newPanel.orderFrontRegardless()

        self.panel = newPanel
        self.hostingView = hosting
        lastCounts = counts
        lastPlacement = currentPlacement
    }

    /// Update the status display. No-op if the panel hasn't been created yet.
    func update(counts: StatusCounts) {
        lastCounts = counts
        let currentPlacement = placement()
        lastPlacement = currentPlacement
        guard let hostingView else { return }
        hostingView.rootView = NotchStatusView(
            counts: counts,
            placement: currentPlacement,
            themeId: themeId()
        )
    }

    nonisolated static func pillFrame(
        screenFrame: NSRect,
        notchSize: CGSize,
        placement: NotchStatusPlacement
    ) -> NSRect {
        let origin: NSPoint
        switch placement {
        case .side:
            origin = NSPoint(
                x: screenFrame.midX - notchSize.width / 2 - pillWidth + notchOverlap,
                y: screenFrame.maxY - pillHeight
            )
        case .below:
            origin = NSPoint(
                x: screenFrame.midX - pillWidth / 2,
                y: screenFrame.maxY - notchSize.height - pillHeight
            )
        }
        return NSRect(origin: origin, size: NSSize(width: pillWidth, height: pillHeight))
    }

    /// Remove the notch panel. Hide first, then release views.
    func tearDown() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        hostingView = nil
    }

    /// Decide whether to show, keep, or tear down the notch pill.
    nonisolated static func resolveVisibility(
        hasNotch: Bool,
        hasBuiltinScreen: Bool,
        appIsActive: Bool,
        pillExists: Bool,
        statusItemOccluded: Bool
    ) -> NotchPillAction {
        guard hasNotch, hasBuiltinScreen else { return .tearDown }
        // While cctop is active, menu bar status-item visibility can be transient.
        // Keep an existing pill, but do not create one until cctop is inactive.
        if appIsActive { return pillExists ? .keep : .tearDown }
        return statusItemOccluded ? .show : .tearDown
    }
}

enum NotchPillAction: Equatable {
    case show
    case keep
    case tearDown
}
