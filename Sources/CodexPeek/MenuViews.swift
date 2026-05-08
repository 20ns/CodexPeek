import AppKit

@MainActor
final class HeaderMenuItemView: NSView {
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 52))
        translatesAutoresizingMaskIntoConstraints = false
        setup()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(snapshot: CodexUsageSnapshot?, refreshState: RefreshState) {
        titleField.stringValue = snapshot?.displayAccountName ?? "Codex unavailable"

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
    }

    private func setup() {
        let stack = NSStackView(views: [titleField, subtitleField])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false

        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        subtitleField.font = .systemFont(ofSize: 11)
        subtitleField.textColor = .secondaryLabelColor

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
        ])
    }
}

@MainActor
final class UsageMenuItemView: NSView {
    private let titleField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 64))
        translatesAutoresizingMaskIntoConstraints = false
        setup()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(title: String, window: RateLimitWindowSnapshot?, isDimmed: Bool = false, overrideDetail: String? = nil) {
        titleField.stringValue = title

        if let overrideDetail {
            progressIndicator.doubleValue = Double(window?.usedPercent ?? 0)
            detailField.stringValue = overrideDetail
        } else if let window {
            progressIndicator.doubleValue = Double(window.usedPercent)
            if let resetDate = window.resetsAt {
                detailField.stringValue = "\(window.usedPercent)% used • \(UIFormatters.usageResetCountdownString(from: resetDate))"
            } else {
                detailField.stringValue = "\(window.usedPercent)% used • reset unavailable"
            }
        } else {
            progressIndicator.doubleValue = 0
            detailField.stringValue = "Unavailable"
        }

        let alpha: CGFloat = isDimmed ? 0.45 : 1.0
        titleField.alphaValue = alpha
        progressIndicator.alphaValue = alpha
        detailField.alphaValue = alpha
    }

    private func setup() {
        titleField.font = .systemFont(ofSize: 12, weight: .semibold)
        detailField.font = .systemFont(ofSize: 11)
        detailField.textColor = .secondaryLabelColor

        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 100
        progressIndicator.controlSize = .small
        progressIndicator.style = .bar

        let stack = NSStackView(views: [titleField, progressIndicator, detailField])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            progressIndicator.widthAnchor.constraint(equalToConstant: 290)
        ])
    }
}

@MainActor
final class CompactSupplementalUsageMenuItemView: NSView {
    private let titleField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    private let weeklyField = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let detailSpacer = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 58))
        translatesAutoresizingMaskIntoConstraints = false
        setup()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(snapshot: SupplementalRateLimitSnapshot?) {
        titleField.stringValue = snapshot?.title ?? "5.3 Spark"

        if let snapshot {
            progressIndicator.doubleValue = Double(snapshot.primary?.usedPercent ?? 0)

            if snapshot.isWeeklyExhausted {
                detailField.stringValue = "Weekly limit reached"
            } else if let primaryReset = snapshot.primary?.resetsAt {
                let primaryPercent = snapshot.primary?.usedPercent ?? 0
                detailField.stringValue = "\(primaryPercent)% used • \(UIFormatters.usageResetCountdownString(from: primaryReset))"
            } else {
                detailField.stringValue = "Unavailable"
            }

            if let weeklyPercent = snapshot.secondary?.usedPercent {
                weeklyField.stringValue = "\(weeklyPercent)% wk"
                weeklyField.textColor = color(for: UsageLevelResolver.resolve(for: weeklyPercent))
                weeklyField.isHidden = false
            } else {
                weeklyField.stringValue = ""
                weeklyField.isHidden = true
            }
        } else {
            progressIndicator.doubleValue = 0
            detailField.stringValue = "Unavailable"
            weeklyField.stringValue = ""
            weeklyField.isHidden = true
        }
    }

    private func setup() {
        titleField.font = .systemFont(ofSize: 12, weight: .semibold)
        detailField.font = .systemFont(ofSize: 11)
        detailField.textColor = .secondaryLabelColor
        weeklyField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        weeklyField.alignment = .right
        weeklyField.setContentHuggingPriority(.required, for: .horizontal)
        weeklyField.setContentCompressionResistancePriority(.required, for: .horizontal)

        detailField.lineBreakMode = .byTruncatingTail
        detailField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        detailSpacer.translatesAutoresizingMaskIntoConstraints = false
        detailSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detailSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 100
        progressIndicator.controlSize = .small
        progressIndicator.style = .bar

        let detailRow = NSStackView(views: [detailField, detailSpacer, weeklyField])
        detailRow.orientation = .horizontal
        detailRow.alignment = .firstBaseline
        detailRow.spacing = 8
        detailRow.distribution = .fill

        let stack = NSStackView(views: [titleField, progressIndicator, detailRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            progressIndicator.widthAnchor.constraint(equalToConstant: 290),
            weeklyField.widthAnchor.constraint(greaterThanOrEqualToConstant: 48)
        ])
    }

    private func color(for level: UsageLevel) -> NSColor {
        switch level {
        case .normal:
            return .systemGreen
        case .warning:
            return .systemOrange
        case .critical:
            return .systemRed
        case .unavailable:
            return .tertiaryLabelColor
        }
    }
}

@MainActor
final class TokenCostMenuItemView: NSView {
    private let titleField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    private let modelField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 54))
        translatesAutoresizingMaskIntoConstraints = false
        setup()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(summary: TokenUsageSummary?) {
        titleField.stringValue = "7-day API estimate"

        guard let summary, summary.hasUsage else {
            detailField.stringValue = "No local token data yet"
            modelField.stringValue = "Updates from Codex session logs"
            return
        }

        let cost = UIFormatters.costString(summary.estimatedCostUSD)
        let total = UIFormatters.compactTokenString(summary.totalTokens)
        let input = UIFormatters.compactTokenString(summary.inputTokens)
        let cached = UIFormatters.compactTokenString(summary.cachedInputTokens)
        let output = UIFormatters.compactTokenString(summary.outputTokens)

        detailField.stringValue = "\(cost) est • \(total) tokens"
        if let topModel = summary.topModel {
            modelField.stringValue = "\(topModel) • in \(input) • cached \(cached) • out \(output)"
        } else {
            modelField.stringValue = "Unpriced models • in \(input) • cached \(cached) • out \(output)"
        }
    }

    private func setup() {
        titleField.font = .systemFont(ofSize: 12, weight: .semibold)
        detailField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        modelField.font = .systemFont(ofSize: 11)
        modelField.textColor = .secondaryLabelColor
        modelField.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [titleField, detailField, modelField])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
    }
}

@MainActor
final class StatusMenuItemView: NSView {
    private let labelField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 34))
        translatesAutoresizingMaskIntoConstraints = false
        labelField.font = .systemFont(ofSize: 11)
        labelField.textColor = .secondaryLabelColor
        labelField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labelField)

        NSLayoutConstraint.activate([
            labelField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            labelField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
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
    }
}
