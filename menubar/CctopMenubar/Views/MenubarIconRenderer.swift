import AppKit

/// Renders the menubar item as the same hairline status bar used throughout cctop.
/// With no sessions it becomes a monochrome template bar.
@MainActor
enum MenubarIconRenderer {
    enum Layout {
        case standard
        case compact

        var size: NSSize {
            switch self {
            case .standard: NSSize(width: 36, height: 18)
            case .compact: NSSize(width: 18, height: 18)
            }
        }

        var barRect: NSRect {
            switch self {
            case .standard: NSRect(x: 0, y: 6, width: 36, height: 6)
            case .compact: NSRect(x: 2, y: 6, width: 14, height: 6)
            }
        }
    }

    static func render(counts: StatusCounts, layout: Layout = .standard) -> NSImage {
        let image = NSImage(size: layout.size, flipped: false) { _ in
            if counts.total == 0 {
                NSColor.labelColor.setFill()
                NSBezierPath(
                    roundedRect: layout.barRect,
                    xRadius: layout.barRect.height / 2,
                    yRadius: layout.barRect.height / 2
                ).fill()
            } else {
                // AppKit makes the status item's effective appearance current here,
                // so one live image follows menu-bar light/dark changes immediately.
                drawSegmentedBar(
                    in: layout.barRect,
                    counts: counts,
                    appearance: NSAppearance.current
                )
            }
            return true
        }

        image.isTemplate = counts.total == 0
        return image
    }

    private static func drawSegmentedBar(
        in barRect: NSRect, counts: StatusCounts, appearance: NSAppearance
    ) {
        let path = NSBezierPath(
            roundedRect: barRect,
            xRadius: barRect.height / 2,
            yRadius: barRect.height / 2
        )
        NSGraphicsContext.current?.saveGraphicsState()
        path.addClip()

        let segments = counts.barSegments(forWidth: Double(barRect.width))
        var xPos = barRect.minX
        for (index, seg) in segments.enumerated() {
            // Last segment fills to the right edge to avoid float rounding gaps
            let segWidth = index == segments.count - 1
                ? max(0, barRect.maxX - xPos)
                : barRect.width * seg.proportion
            StatusColors.color(for: seg.kind, appearance: appearance).setFill()
            NSRect(
                x: xPos, y: barRect.minY,
                width: segWidth, height: barRect.height
            ).fill()
            xPos += segWidth
        }

        NSGraphicsContext.current?.restoreGraphicsState()
    }
}
