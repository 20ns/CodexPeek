import AppKit

private enum Metrics {
    static let width: CGFloat = 320
    static let inset: CGFloat = 14
    /// Icon buttons are 22pt around a ~12pt glyph; pulling them out by this much lines the glyph up with the content edge.
    static let iconInset: CGFloat = inset - 5
}

@MainActor
final class HeaderMenuItemView: NSView {
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private let refreshButton = NSButton()
    private let copyButton = NSButton()
    var onRefresh: (() -> Void)?
    var onCopyDebugInfo: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: Metrics.width, height: 52))
        translatesAutoresizingMaskIntoConstraints = false
        setup()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(snapshot: CodexUsageSnapshot?, refreshState: RefreshState) {
        titleField.stringValue = snapshot?.displayAccountName ?? "Codex unavailable"
        refreshButton.isEnabled = refreshState != .refreshing

        let detail: String
        if let snapshot {
            var parts = [snapshot.account.planType.displayName]
            if let renewsAt = snapshot.account.renewsAt {
                parts.append("renews \(UIFormatters.accountRenewalString(from: renewsAt))")
            }
            if snapshot.isWeeklyExhausted {
                parts.append("weekly limit reached")
            }
            if snapshot.isStale {
                parts.append("estimate")
            }
            if case .failed = refreshState {
                parts.append("refresh failed")
            }
            detail = parts.joined(separator: " • ")
        } else if case .failed(let message) = refreshState {
            detail = message
        } else {
            detail = "Waiting for Codex data"
        }

        subtitleField.stringValue = detail
        subtitleField.toolTip = detail
    }

    private func setup() {
        let stack = NSStackView(views: [titleField, subtitleField])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        subtitleField.font = .systemFont(ofSize: 11)
        subtitleField.textColor = .secondaryLabelColor
        titleField.lineBreakMode = .byTruncatingMiddle
        subtitleField.lineBreakMode = .byTruncatingTail
        subtitleField.maximumNumberOfLines = 1
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        configureIconButton(refreshButton, symbolName: "arrow.clockwise", tooltip: "Refresh usage", target: self, action: #selector(refreshTapped))
        configureIconButton(copyButton, symbolName: "doc.on.doc", tooltip: "Copy debug info", target: self, action: #selector(copyTapped))

        let controls = NSStackView(views: [refreshButton, copyButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 2
        controls.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        addSubview(controls)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Metrics.width),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.inset),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: controls.leadingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            // Buttons sit on the title line, as in the Claude section header.
            controls.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.iconInset)
        ])
    }

    @objc private func refreshTapped() {
        onRefresh?()
    }

    @objc private func copyTapped() {
        onCopyDebugInfo?()
    }
}

@MainActor
private func configureIconButton(_ button: NSButton, symbolName: String, tooltip: String, target: AnyObject, action: Selector) {
    let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
    button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip)?.withSymbolConfiguration(config)
    button.contentTintColor = .secondaryLabelColor
    button.bezelStyle = .inline
    button.isBordered = false
    button.imagePosition = .imageOnly
    button.toolTip = tooltip
    button.setAccessibilityLabel(tooltip)
    button.target = target
    button.action = action
    button.setButtonType(.momentaryChange)
    button.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        button.widthAnchor.constraint(equalToConstant: 22),
        button.heightAnchor.constraint(equalToConstant: 22)
    ])
}

/// Title and used-percentage on one line, the bar, then a quiet detail line.
/// Subclasses only pick the tint and decide what the detail says.
@MainActor
class UsageRowView: NSView {
    private let titleField = NSTextField(labelWithString: "")
    private let percentField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    private let bar = UsageBarView()
    /// Optional trailing note on the detail line (Spark's weekly percentage).
    fileprivate let noteField = NSTextField(labelWithString: "")

    class var tint: NSColor { .systemBlue }

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: Metrics.width, height: 65))
        translatesAutoresizingMaskIntoConstraints = false
        setup()
    }

    required init?(coder: NSCoder) {
        nil
    }

    fileprivate func render(title: String, window: RateLimitWindowSnapshot?, detail: String) {
        titleField.stringValue = title
        percentField.attributedStringValue = Self.percentText(window?.usedPercent)
        detailField.stringValue = detail
        detailField.toolTip = detail

        bar.fraction = window.map { CGFloat($0.usedPercent) / 100 }
        bar.pace = window?.weeklyPace().map { CGFloat($0) }
        bar.setAccessibilityLabel(title)
        bar.setAccessibilityValue(window?.usedPercent)
        bar.setAccessibilityValueDescription(window == nil ? "Unavailable" : nil)
    }

    fileprivate func setDimmed(_ isDimmed: Bool) {
        alphaValue = isDimmed ? 0.45 : 1
    }

    fileprivate static func resetDetail(for window: RateLimitWindowSnapshot?) -> String {
        guard let window else { return "Unavailable" }
        return window.resetsAt.map { UIFormatters.usageResetCountdownString(from: $0) } ?? "Reset unavailable"
    }

    private static func percentText(_ percent: Int?) -> NSAttributedString {
        guard let percent else {
            return NSAttributedString(string: "—", attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.tertiaryLabelColor])
        }
        let text = NSMutableAttributedString(string: "\(percent)%", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ])
        text.append(NSAttributedString(string: " used", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor
        ]))
        return text
    }

    private func setup() {
        bar.tint = Self.tint
        titleField.font = .systemFont(ofSize: 12, weight: .medium)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        percentField.maximumNumberOfLines = 1
        percentField.setContentHuggingPriority(.required, for: .horizontal)
        percentField.setContentCompressionResistancePriority(.required, for: .horizontal)
        detailField.font = .systemFont(ofSize: 11)
        detailField.textColor = .secondaryLabelColor
        detailField.lineBreakMode = .byTruncatingTail
        detailField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        noteField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        noteField.isHidden = true
        noteField.setContentHuggingPriority(.required, for: .horizontal)
        noteField.setContentCompressionResistancePriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let titleRow = NSStackView(views: [titleField, spacer, percentField])
        titleRow.alignment = .firstBaseline
        titleRow.spacing = 8
        let detailSpacer = NSView()
        detailSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let detailRow = NSStackView(views: [detailField, detailSpacer, noteField])
        detailRow.alignment = .firstBaseline
        detailRow.spacing = 8

        let stack = NSStackView(views: [titleRow, bar, detailRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Metrics.width),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.inset),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            titleRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }
}

@MainActor
final class UsageMenuItemView: UsageRowView {
    func update(title: String, window: RateLimitWindowSnapshot?, isDimmed: Bool = false, overrideDetail: String? = nil) {
        render(title: title, window: window, detail: overrideDetail ?? Self.resetDetail(for: window))
        setDimmed(isDimmed)
    }
}

@MainActor
final class ClaudeUsageMenuItemView: UsageRowView {
    override class var tint: NSColor { .systemOrange }

    func update(title: String, window: RateLimitWindowSnapshot?) {
        render(title: title, window: window, detail: Self.resetDetail(for: window))
    }
}

@MainActor
final class CompactSupplementalUsageMenuItemView: UsageRowView {
    func update(snapshot: SupplementalRateLimitSnapshot?) {
        let window = snapshot?.primary
        let detail: String
        if snapshot?.isWeeklyExhausted == true {
            detail = "Weekly limit reached"
        } else if let snapshot, window?.resetsAt != nil {
            detail = Self.resetDetail(for: snapshot.primary)
        } else {
            detail = "Unavailable"
        }
        render(title: snapshot?.title ?? "5.3 Spark", window: window, detail: detail)

        if let weeklyPercent = snapshot?.secondary?.usedPercent {
            noteField.stringValue = "\(weeklyPercent)% wk"
            noteField.textColor = color(for: UsageLevelResolver.resolve(for: weeklyPercent))
            noteField.isHidden = false
        } else {
            noteField.isHidden = true
        }
    }

    private func color(for level: UsageLevel) -> NSColor {
        switch level {
        case .normal: .systemGreen
        case .warning: .systemOrange
        case .critical: .systemRed
        case .unavailable: .tertiaryLabelColor
        }
    }
}

@MainActor
final class TokenCostMenuItemView: NSView {
    private let titleField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    private let modelField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: Metrics.width, height: 49))
        translatesAutoresizingMaskIntoConstraints = false
        setup()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(report: TokenUsageReport?, isRefreshing: Bool = false, sourceName: String = "Codex", failed: Bool = false) {
        titleField.stringValue = "API-equivalent estimate\(isRefreshing ? " • refreshing" : "")"
        toolTip = "Rolling 7- and 30-day totals in USD at published API token prices, including prompt cache reads and writes. From retained local \(sourceName) logs; unpriced models are excluded and deleted logs cannot be backfilled."

        guard let report, report.hasUsage else {
            detailField.stringValue = failed ? "Could not read local logs" : (report == nil ? "Calculating in background" : "No recorded token usage")
            modelField.stringValue = "Uses local \(sourceName) session logs"
            modelField.isHidden = false
            return
        }

        let cost: (TokenUsageSummary) -> String = {
            $0.hasUsage && $0.pricedSessionCount == 0 && $0.estimatedCostUSD == 0 ? "unpriced" : UIFormatters.costString($0.estimatedCostUSD)
        }
        let weekCost = cost(report.week)
        let last30DaysCost = cost(report.month)
        let allTimeCost = "\(report.legacyStats == nil ? "" : "≈")\(cost(report.allTime))"

        detailField.stringValue = report.allTime.pricedSessionCount == 0 && report.allTime.estimatedCostUSD == 0
            ? "Recorded models have no published price"
            : "7d \(weekCost) • 30d \(last30DaysCost) • all-time \(allTimeCost)"
        modelField.stringValue = failed ? "Refresh failed; showing previous estimate"
            : (report.legacyStats == nil ? "" : "Older stats included • cache writes assumed 5m")
        modelField.isHidden = !failed && report.legacyStats == nil
    }

    private func setup() {
        titleField.font = .systemFont(ofSize: 12, weight: .medium)
        detailField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        modelField.font = .systemFont(ofSize: 11)
        modelField.textColor = .secondaryLabelColor
        detailField.lineBreakMode = .byTruncatingTail
        detailField.maximumNumberOfLines = 1
        detailField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        modelField.lineBreakMode = .byTruncatingTail
        modelField.maximumNumberOfLines = 1
        modelField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [titleField, detailField, modelField])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Metrics.width),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.inset),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
    }
}

@MainActor
final class StatusMenuItemView: NSView {
    private let labelField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: Metrics.width, height: 24))
        translatesAutoresizingMaskIntoConstraints = false
        labelField.font = .systemFont(ofSize: 11)
        labelField.textColor = .secondaryLabelColor
        labelField.lineBreakMode = .byTruncatingTail
        labelField.maximumNumberOfLines = 1
        labelField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        labelField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labelField)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Metrics.width),
            heightAnchor.constraint(equalToConstant: 24),
            labelField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.inset),
            labelField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.inset),
            labelField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(snapshot: CodexUsageSnapshot?, refreshState: RefreshState, accountStatus: String? = nil) {
        let status: String
        switch refreshState {
        case .idle:
            if let accountStatus {
                status = accountStatus
            } else if let snapshot {
                let time = UIFormatters.usageUpdatedString(from: snapshot.lastUpdatedAt)
                let source = snapshot.source.displayName
                if snapshot.isWeeklyExhausted {
                    status = "Weekly limit reached • last updated \(time) • \(source)"
                } else {
                    status = "Last updated \(time) • \(source)"
                }
            } else {
                status = "No Codex data yet"
            }
        case .refreshing:
            status = "Refreshing…"
        case .failed(let message):
            if let snapshot {
                let time = UIFormatters.usageUpdatedString(from: snapshot.lastUpdatedAt)
                status = "\(message) • showing \(snapshot.source.displayName.lowercased()) from \(time)"
            } else {
                status = message
            }
        }

        labelField.stringValue = status
        labelField.toolTip = status
    }

    func update(message: String) {
        labelField.stringValue = message
        labelField.toolTip = message
    }
}

@MainActor
final class MenuSectionHeaderView: NSView {
    private let labelField = NSTextField(labelWithString: "")
    private let refreshButton = NSButton()
    var onRefresh: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: Metrics.width, height: 28))
        translatesAutoresizingMaskIntoConstraints = false
        labelField.font = .systemFont(ofSize: 13, weight: .semibold)
        labelField.textColor = .labelColor
        labelField.translatesAutoresizingMaskIntoConstraints = false
        configureIconButton(refreshButton, symbolName: "arrow.clockwise", tooltip: "Refresh usage", target: self, action: #selector(refreshTapped))
        refreshButton.isHidden = true
        addSubview(labelField)
        addSubview(refreshButton)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Metrics.width),
            heightAnchor.constraint(equalToConstant: 28),
            labelField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.inset),
            labelField.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -8),
            labelField.centerYAnchor.constraint(equalTo: centerYAnchor),
            refreshButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.iconInset),
            refreshButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(title: String, showsRefresh: Bool = false, isRefreshing: Bool = false) {
        labelField.stringValue = title
        refreshButton.isHidden = !showsRefresh
        refreshButton.isEnabled = !isRefreshing
    }

    @objc private func refreshTapped() {
        onRefresh?()
    }
}

@MainActor
final class UsageBarView: NSView {
    private static let barHeight: CGFloat = 6
    private static let tickInset: CGFloat = 2 // tick extends this far above and below the bar

    var tint: NSColor = .systemOrange {
        didSet { needsDisplay = true }
    }
    var fraction: CGFloat? {
        didSet { needsDisplay = true }
    }
    /// Where usage would sit at an even pace; left of the fill means ahead of it.
    var pace: CGFloat? {
        didSet {
            needsDisplay = true
            setAccessibilityHelp(pace.map { "Even pace would be \(Int(($0 * 100).rounded()))% by now" })
        }
    }

    init(tint: NSColor = .systemOrange) {
        self.tint = tint
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityMinValue(0)
        setAccessibilityMaxValue(100)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.barHeight + 2 * Self.tickInset)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let rect = NSRect(x: 0, y: (bounds.height - Self.barHeight) / 2, width: bounds.width, height: Self.barHeight)
        let radius = rect.height / 2

        // A neutral, translucent track lets the menu material show through; a hairline gives it edge definition.
        let track = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSColor.labelColor.withAlphaComponent(highContrast ? 0.28 : 0.1).setFill()
        track.fill()
        NSColor.labelColor.withAlphaComponent(highContrast ? 0.4 : 0.08).setStroke()
        let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
        edge.lineWidth = 0.5
        edge.stroke()

        if let fraction, fraction > 0 {
            var fill = rect
            fill.size.width = max(rect.width * min(fraction, 1), rect.height)
            tint.setFill()
            NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
        }

        guard let pace else { return }
        // Notch the bar with transparency (not a painted halo) so the tick reads on track, fill and material alike.
        let x = ((rect.width - 2) * min(max(pace, 0), 1)).rounded()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(roundedRect: NSRect(x: x - 1.5, y: 0, width: 5, height: bounds.height), xRadius: 2.5, yRadius: 2.5).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.labelColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: 0, width: 2, height: bounds.height), xRadius: 1, yRadius: 1).fill()
    }
}
