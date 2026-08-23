import SwiftUI

struct NotchStatusView: View {
    let counts: StatusCounts
    var placement = NotchStatusPlacement.defaultValue
    var themeId: String = ""

    var body: some View {
        Group {
            if counts.total > 0 {
                StatusBar(counts: counts)
            } else {
                Capsule().fill(Color.white.opacity(0.52))
            }
        }
        .frame(width: 36, height: 4)
        .frame(height: 11)
        .id(themeId)
        .padding(.leading, placement == .side ? 5 : 8)
        .padding(.trailing, placement == .side ? 2 : 8)
        .padding(.top, 4)
        .padding(.bottom, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.90))
        .clipShape(NotchTabShape(radius: 6, placement: placement))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(counts.accessibilityLabel)
    }
}

private struct StatusBar: View {
    let counts: StatusCounts

    var body: some View {
        GeometryReader { geo in
            let segments = counts.barSegments(forWidth: Double(geo.size.width))
            HStack(spacing: 0) {
                ForEach(
                    Array(segments.enumerated()), id: \.offset
                ) { index, seg in
                    if index == segments.count - 1 {
                        // Last segment fills remaining space to avoid float rounding gaps
                        StatusColors.notchColor(for: seg.kind)
                    } else {
                        StatusColors.notchColor(for: seg.kind).frame(width: geo.size.width * seg.proportion)
                    }
                }
            }
        }
        .clipShape(Capsule())
    }
}

/// Side tabs meet the notch on their right edge. Below tabs meet it across their flat top.
private struct NotchTabShape: Shape {
    var radius: CGFloat
    var placement: NotchStatusPlacement

    func path(in rect: CGRect) -> Path {
        switch placement {
        case .side: sidePath(in: rect)
        case .below: belowPath(in: rect)
        }
    }

    private func sidePath(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.minX, y: rect.maxY - radius),
            radius: radius
        )
        path.closeSubpath()
        return path
    }

    private func belowPath(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.maxX - radius, y: rect.maxY),
            radius: radius
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.minX, y: rect.maxY - radius),
            radius: radius
        )
        path.closeSubpath()
        return path
    }
}

#Preview("Mixed") {
    NotchStatusView(counts: StatusCounts(permission: 1, attention: 1, working: 2, idle: 1))
        .padding()
        .background(Color.black)
}

#Preview("Needs permission") {
    NotchStatusView(counts: StatusCounts(permission: 2, attention: 0, working: 1, idle: 0))
        .padding()
        .background(Color.black)
}

#Preview("All working") {
    NotchStatusView(counts: StatusCounts(permission: 0, attention: 0, working: 4, idle: 0))
        .padding()
        .background(Color.black)
}

#Preview("All idle") {
    NotchStatusView(counts: StatusCounts(permission: 0, attention: 0, working: 0, idle: 3))
        .padding()
        .background(Color.black)
}

#Preview("1 attention in 10 (min width)") {
    NotchStatusView(counts: StatusCounts(permission: 0, attention: 1, working: 7, idle: 2))
        .padding()
        .background(Color.black)
}

#Preview("1 permission in 20 (extreme squeeze)") {
    NotchStatusView(counts: StatusCounts(permission: 1, attention: 0, working: 19, idle: 0))
        .padding()
        .background(Color.black)
}

#Preview("No sessions") {
    NotchStatusView(counts: StatusCounts(permission: 0, attention: 0, working: 0, idle: 0))
        .padding()
        .background(Color.black)
}
