import AppKit

@MainActor
final class StatusIconRenderer {
    private var cache: [IconCacheKey: NSImage] = [:]

    func render(primaryPercent: Int?, secondaryPercent: Int?, refreshState: RefreshState) -> NSImage {
        let cacheKey = IconCacheKey(
            primaryPercent: primaryPercent,
            secondaryPercent: secondaryPercent,
            isRefreshing: refreshState == .refreshing
        )

        if let cached = cache[cacheKey] {
            return cached
        }

        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)

        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        let level = UsageLevelResolver.resolve(for: primaryPercent)
        let strokeColor = color(for: level)
        let primaryRect = NSRect(x: 2, y: 2, width: 12, height: 14)
        let path = NSBezierPath(roundedRect: primaryRect, xRadius: 3, yRadius: 3)

        strokeColor.setStroke()
        path.lineWidth = 1.5
        path.stroke()

        if let primaryPercent {
            let fillHeight = max(0, min(1, CGFloat(primaryPercent) / 100.0)) * (primaryRect.height - 3)
            let fillRect = NSRect(
                x: primaryRect.minX + 1.5,
                y: primaryRect.minY + 1.5,
                width: primaryRect.width - 3,
                height: fillHeight
            )
            let clipped = NSBezierPath(roundedRect: primaryRect.insetBy(dx: 1.5, dy: 1.5), xRadius: 2, yRadius: 2)
            clipped.addClip()
            color(for: level).withAlphaComponent(refreshAlpha(for: refreshState)).setFill()
            fillRect.fill()
        } else {
            NSColor.tertiaryLabelColor.setStroke()
            let slash = NSBezierPath()
            slash.move(to: CGPoint(x: 4, y: 4))
            slash.line(to: CGPoint(x: 12, y: 12))
            slash.lineWidth = 1.2
            slash.stroke()
        }

        drawSecondaryBadge(
            percent: secondaryPercent,
            refreshState: refreshState,
            level: UsageLevelResolver.resolve(for: secondaryPercent)
        )

        if case .refreshing = refreshState {
            NSColor.white.withAlphaComponent(0.4).setFill()
            NSBezierPath(ovalIn: NSRect(x: 7, y: 7, width: 4, height: 4)).fill()
        }

        cache[cacheKey] = image
        return image
    }

    private func drawSecondaryBadge(percent: Int?, refreshState: RefreshState, level: UsageLevel) {
        let badgeRect = NSRect(x: 10.0, y: 9.0, width: 7, height: 7)
        let badge = NSBezierPath(roundedRect: badgeRect, xRadius: 2.2, yRadius: 2.2)
        let badgeColor = color(for: level).withAlphaComponent(refreshAlpha(for: refreshState))

        NSColor.windowBackgroundColor.setFill()
        badge.fill()

        badgeColor.setFill()
        badge.fill()

        NSColor.white.withAlphaComponent(percent == nil ? 0.55 : 0.95).setStroke()
        drawCodexGlyph(in: badgeRect)
    }

    private func drawCodexGlyph(in rect: NSRect) {
        let insetRect = rect.insetBy(dx: 1.1, dy: 1.35)
        let centerX = insetRect.midX
        let midY = insetRect.midY

        let left = NSBezierPath()
        left.move(to: CGPoint(x: centerX - 1.6, y: insetRect.maxY))
        left.line(to: CGPoint(x: insetRect.minX, y: midY))
        left.line(to: CGPoint(x: centerX - 1.6, y: insetRect.minY))
        left.lineWidth = 1.05
        left.lineCapStyle = .round
        left.lineJoinStyle = .round
        left.stroke()

        let right = NSBezierPath()
        right.move(to: CGPoint(x: centerX + 1.6, y: insetRect.maxY))
        right.line(to: CGPoint(x: insetRect.maxX, y: midY))
        right.line(to: CGPoint(x: centerX + 1.6, y: insetRect.minY))
        right.lineWidth = 1.05
        right.lineCapStyle = .round
        right.lineJoinStyle = .round
        right.stroke()

        let bar = NSBezierPath()
        bar.move(to: CGPoint(x: centerX, y: insetRect.minY + 0.3))
        bar.line(to: CGPoint(x: centerX, y: insetRect.maxY - 0.3))
        bar.lineWidth = 0.9
        bar.lineCapStyle = .round
        bar.stroke()
    }

    private func color(for level: UsageLevel) -> NSColor {
        switch level {
        case .normal:
            return NSColor.systemGreen
        case .warning:
            return NSColor.systemOrange
        case .critical:
            return NSColor.systemRed
        case .unavailable:
            return NSColor.tertiaryLabelColor
        }
    }

    private func refreshAlpha(for refreshState: RefreshState) -> CGFloat {
        switch refreshState {
        case .refreshing:
            return 0.6
        case .idle, .failed:
            return 0.95
        }
    }
}

private struct IconCacheKey: Hashable {
    let primaryPercent: Int?
    let secondaryPercent: Int?
    let isRefreshing: Bool
}
