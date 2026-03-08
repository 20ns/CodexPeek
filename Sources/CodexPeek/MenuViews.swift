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
            if snapshot.isStale {
                parts.append("stale")
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

    func update(title: String, window: RateLimitWindowSnapshot?) {
        titleField.stringValue = title

        if let window {
            progressIndicator.doubleValue = Double(window.usedPercent)
            if let resetDate = window.resetsAt {
                detailField.stringValue = "\(window.usedPercent)% used • resets \(UIFormatters.usageResetString(from: resetDate))"
            } else {
                detailField.stringValue = "\(window.usedPercent)% used • reset unavailable"
            }
        } else {
            progressIndicator.doubleValue = 0
            detailField.stringValue = "Unavailable"
        }
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

    func update(snapshot: CodexUsageSnapshot?, refreshState: RefreshState) {
        let status: String
        switch refreshState {
        case .idle:
            if let snapshot {
                let time = UIFormatters.usageUpdatedString(from: snapshot.lastUpdatedAt)
                let source = snapshot.source == .live ? "live" : snapshot.source.rawValue
                status = "Last updated \(time) • \(source)"
            } else {
                status = "No Codex data yet"
            }
        case .refreshing:
            status = "Refreshing…"
        case .failed(let message):
            if let snapshot {
                let time = UIFormatters.usageUpdatedString(from: snapshot.lastUpdatedAt)
                status = "\(message) • showing \(snapshot.source.rawValue) from \(time)"
            } else {
                status = message
            }
        }

        labelField.stringValue = status
    }
}
