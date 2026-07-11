import AppKit

@MainActor
private enum HistoryPalette {
    static let models: [NSColor] = [.systemBlue, .systemPurple, .systemGreen, .systemOrange, .systemPink, .systemTeal]
}

@MainActor
final class UsageHistoryWindowController: NSWindowController {
    private let historyView = UsageHistoryView()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CodexPeek Usage History"
        window.minSize = NSSize(width: 680, height: 650)
        window.contentView = historyView
        super.init(window: window)
    }

    required init?(coder: NSCoder) { nil }

    func show(report: TokenUsageReport?, planHistory: PlanUsageHistory, snapshot: CodexUsageSnapshot?) {
        historyView.update(report: report, planHistory: planHistory, snapshot: snapshot)
        showWindow(nil)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    func update(report: TokenUsageReport?, planHistory: PlanUsageHistory, snapshot: CodexUsageSnapshot?) {
        guard window?.isVisible == true else { return }
        historyView.update(report: report, planHistory: planHistory, snapshot: snapshot)
    }
}

@MainActor
private final class UsageHistoryView: NSView {
    private let subtitle = NSTextField(labelWithString: "")
    private let todayValue = NSTextField(labelWithString: "—")
    private let comparisonValue = NSTextField(labelWithString: "")
    private let weekValue = NSTextField(labelWithString: "—")
    private let weekDetail = NSTextField(labelWithString: "Compared with the prior 7 days")
    private let cacheValue = NSTextField(labelWithString: "—")
    private let cacheDetail = NSTextField(labelWithString: "Of input tokens served from cache")
    private let rangeControl = NSSegmentedControl(labels: ["14 days", "30 days"], trackingMode: .selectOne, target: nil, action: nil)
    private let chart = DailyUsageChartView()
    private let modelBreakdown = NSTextField(labelWithString: "No token history yet")
    private let planChart = PlanUsageChartView()
    private let heatmap = ActivityHeatmapView()
    private var report: TokenUsageReport?
    private var planHistory = PlanUsageHistory()
    private var snapshot: CodexUsageSnapshot?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { nil }

    func update(report: TokenUsageReport?, planHistory: PlanUsageHistory, snapshot: CodexUsageSnapshot?) {
        self.report = report
        self.planHistory = planHistory
        self.snapshot = snapshot
        reload()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let title = NSTextField(labelWithString: "Usage History")
        title.font = .systemFont(ofSize: 22, weight: .bold)
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor

        rangeControl.selectedSegment = 0
        rangeControl.target = self
        rangeControl.action = #selector(rangeChanged)

        let headerText = NSStackView(views: [title, subtitle])
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 3
        let header = NSStackView(views: [headerText, rangeControl])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.distribution = .fill
        headerText.setContentHuggingPriority(.defaultLow, for: .horizontal)
        rangeControl.setContentHuggingPriority(.required, for: .horizontal)

        let cards = NSStackView(views: [
            summaryCard(title: "TODAY", value: todayValue, detail: comparisonValue),
            summaryCard(title: "LAST 7 DAYS", value: weekValue, detail: weekDetail),
            summaryCard(title: "CACHE REUSE", value: cacheValue, detail: cacheDetail)
        ])
        cards.orientation = .horizontal
        cards.distribution = .fillEqually
        cards.spacing = 10

        chart.translatesAutoresizingMaskIntoConstraints = false
        planChart.translatesAutoresizingMaskIntoConstraints = false
        heatmap.translatesAutoresizingMaskIntoConstraints = false
        modelBreakdown.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        modelBreakdown.textColor = .secondaryLabelColor
        modelBreakdown.maximumNumberOfLines = 1
        modelBreakdown.lineBreakMode = .byTruncatingTail

        let tokenPanel = panel(title: "Token usage", subtitle: "Daily totals, stacked by model", views: [chart, modelBreakdown])
        let planPanel = panel(title: "Weekly plan", subtitle: "Observed allowance history", views: [planChart])
        let activityPanel = panel(title: "Activity pattern", subtitle: "Tokens by weekday and hour", views: [heatmap])
        let lowerRow = NSStackView(views: [planPanel, activityPanel])
        lowerRow.orientation = .horizontal
        lowerRow.alignment = .top
        lowerRow.distribution = .fill
        lowerRow.spacing = 12
        lowerRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [
            header,
            cards,
            tokenPanel,
            lowerRow
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            cards.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tokenPanel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            lowerRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            header.heightAnchor.constraint(equalToConstant: 48),
            cards.heightAnchor.constraint(equalToConstant: 96),
            tokenPanel.heightAnchor.constraint(equalToConstant: 260),
            lowerRow.heightAnchor.constraint(equalToConstant: 205),
            planPanel.widthAnchor.constraint(equalTo: activityPanel.widthAnchor, multiplier: 0.56),
            planPanel.heightAnchor.constraint(equalTo: lowerRow.heightAnchor),
            activityPanel.heightAnchor.constraint(equalTo: lowerRow.heightAnchor),
            chart.heightAnchor.constraint(equalToConstant: 156),
            modelBreakdown.heightAnchor.constraint(equalToConstant: 18),
            planChart.heightAnchor.constraint(equalToConstant: 112),
            heatmap.heightAnchor.constraint(equalToConstant: 112)
        ])
    }

    private func summaryCard(title: String, value: NSTextField, detail: NSTextField) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .secondaryLabelColor
        value.font = .monospacedDigitSystemFont(ofSize: 23, weight: .semibold)
        value.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [label, value, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 8
        box.borderColor = .separatorColor
        box.borderWidth = 1
        box.fillColor = NSColor.controlBackgroundColor.withAlphaComponent(0.72)
        guard let content = box.contentView else { return box }
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])
        return box
    }

    private func panel(title: String, subtitle: String, views: [NSView]) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        let detail = NSTextField(labelWithString: subtitle)
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor
        let header = NSStackView(views: [label, detail])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 1
        let stack = NSStackView(views: [header] + views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        views.forEach { $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }

        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 10
        box.borderColor = .separatorColor
        box.borderWidth = 1
        box.fillColor = NSColor.controlBackgroundColor.withAlphaComponent(0.4)
        guard let content = box.contentView else { return box }
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -12)
        ])
        return box
    }

    @objc private func rangeChanged() { reload() }

    private func reload() {
        let days = rangeControl.selectedSegment == 1 ? 30 : 14
        let buckets = report?.history?.buckets ?? []
        let daily = UsageHistoryAnalytics.dailyUsage(from: buckets, days: days)
        let models = UsageHistoryAnalytics.modelTotals(from: daily)
        let comparison = UsageHistoryAnalytics.todayComparison(from: buckets)
        let percent = comparison.yesterday > 0
            ? Int((Double(comparison.today - comparison.yesterday) / Double(comparison.yesterday) * 100).rounded())
            : nil

        let now = Date()
        let weekStart = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let priorWeekStart = now.addingTimeInterval(-14 * 24 * 60 * 60)
        let weekUsage = UsageHistoryAnalytics.usage(from: buckets, since: weekStart, before: now)
        let priorWeekUsage = UsageHistoryAnalytics.usage(from: buckets, since: priorWeekStart, before: weekStart)
        let weekChange = priorWeekUsage.totalTokens > 0
            ? Int((Double(weekUsage.totalTokens - priorWeekUsage.totalTokens) / Double(priorWeekUsage.totalTokens) * 100).rounded())
            : nil
        let cacheRate = weekUsage.inputTokens > 0
            ? Int((Double(weekUsage.cachedInputTokens) / Double(weekUsage.inputTokens) * 100).rounded())
            : nil

        todayValue.stringValue = UIFormatters.compactTokenString(comparison.today)
        comparisonValue.stringValue = percent.map { "\($0 >= 0 ? "+" : "")\($0)% vs yesterday by now" } ?? "No comparable usage yesterday"
        weekValue.stringValue = UIFormatters.compactTokenString(weekUsage.totalTokens)
        weekDetail.stringValue = weekChange.map { "\($0 >= 0 ? "+" : "")\($0)% vs prior 7 days" } ?? "Prior-week comparison is building"
        cacheValue.stringValue = cacheRate.map { "\($0)%" } ?? "—"
        cacheDetail.stringValue = cacheRate == nil ? "Cache data is still building" : "Of input tokens served from cache"
        subtitle.stringValue = snapshot.map { "\($0.account.planType.displayName) • local session logs • updated \(UIFormatters.usageUpdatedString(from: $0.lastUpdatedAt))" }
            ?? "Local session logs"

        let names = models.map { $0.model }
        chart.emptyMessage = report?.history == nil ? "Building history from local sessions…" : "No token activity in this range"
        chart.update(days: daily, models: names)
        heatmap.values = UsageHistoryAnalytics.hourlyActivity(from: buckets, days: days)
        planChart.update(samples: planHistory.samples, days: days)
        let legend = NSMutableAttributedString()
        let rangeTotal = max(1, models.reduce(0) { $0 + $1.usage.totalTokens })
        for (index, item) in models.prefix(3).enumerated() {
            let (model, usage) = item
            let cost = TokenPricingCatalog.standard.estimateCost(for: model, usage: usage)?.total ?? 0
            let share = Int((Double(usage.totalTokens) / Double(rangeTotal) * 100).rounded())
            if index > 0 { legend.append(NSAttributedString(string: "     ")) }
            legend.append(NSAttributedString(
                string: "● ",
                attributes: [.foregroundColor: HistoryPalette.models[index % HistoryPalette.models.count]]
            ))
            legend.append(NSAttributedString(
                string: "\(TokenPricingCatalog.standard.displayModelName(for: model))  \(share)%  \(UIFormatters.compactTokenString(usage.totalTokens))  \(UIFormatters.costString(cost))",
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
            ))
        }
        modelBreakdown.attributedStringValue = legend.length > 0
            ? legend
            : NSAttributedString(string: "Model mix will appear when token history is ready.", attributes: [.foregroundColor: NSColor.secondaryLabelColor])
    }
}

@MainActor
private final class DailyUsageChartView: NSView {
    private var days: [DailyTokenUsage] = []
    private var models: [String] = []
    var emptyMessage = "No token activity in this range"

    func update(days: [DailyTokenUsage], models: [String]) {
        self.days = days
        self.models = models
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !days.isEmpty else { return }
        let plot = NSRect(x: 8, y: 22, width: bounds.width - 16, height: bounds.height - 30)
        let maxTokens = max(1, days.map(\.totalTokens).max() ?? 1)
        let slot = plot.width / CGFloat(days.count)
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("d MMM")

        for step in 0...3 {
            let y = plot.minY + plot.height * CGFloat(step) / 3
            NSColor.separatorColor.withAlphaComponent(0.45).setStroke()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: plot.minX, y: y))
            line.line(to: NSPoint(x: plot.maxX, y: y))
            line.stroke()
        }

        if days.allSatisfy({ $0.totalTokens == 0 }) {
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor]
            let size = emptyMessage.size(withAttributes: attributes)
            emptyMessage.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: plot.midY - size.height / 2), withAttributes: attributes)
        }

        for (index, day) in days.enumerated() {
            let x = plot.minX + CGFloat(index) * slot + 2
            let width = max(2, slot - 4)
            var y = plot.minY
            for (modelIndex, model) in models.enumerated() {
                let tokens = day.byModel[model]?.totalTokens ?? 0
                let height = plot.height * CGFloat(tokens) / CGFloat(maxTokens)
                HistoryPalette.models[modelIndex % HistoryPalette.models.count].setFill()
                if height > 0 {
                    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: height), xRadius: 2, yRadius: 2).fill()
                }
                y += height
            }
            if index == 0 || index == days.count - 1 || index == days.count / 2 {
                formatter.string(from: day.day).draw(
                    at: NSPoint(x: x, y: 2),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.secondaryLabelColor]
                )
            }
        }
    }
}

@MainActor
private final class PlanUsageChartView: NSView {
    private var samples: [PlanUsageSample] = []
    private var days = 14

    func update(samples: [PlanUsageSample], days: Int) {
        self.samples = samples
        self.days = days
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let now = Date()
        let requestedStart = now.addingTimeInterval(TimeInterval(-days * 24 * 60 * 60))
        let start = max(requestedStart, samples.first?.recordedAt ?? requestedStart)
        let selected = samples.filter { $0.recordedAt >= start && $0.recordedAt <= now && $0.secondaryPercent != nil }
        guard !selected.isEmpty else {
            "History begins after this update".draw(at: NSPoint(x: 8, y: bounds.midY), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
            return
        }
        let plot = bounds.insetBy(dx: 6, dy: 12)
        for step in 0...2 {
            let y = plot.minY + plot.height * CGFloat(step) / 2
            NSColor.separatorColor.withAlphaComponent(0.45).setStroke()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: plot.minX, y: y))
            line.line(to: NSPoint(x: plot.maxX, y: y))
            line.stroke()
        }
        let path = NSBezierPath()
        for (index, sample) in selected.enumerated() {
            let duration = max(1, now.timeIntervalSince(start))
            let x = plot.minX + plot.width * CGFloat(sample.recordedAt.timeIntervalSince(start) / duration)
            let y = plot.minY + plot.height * CGFloat(sample.secondaryPercent ?? 0) / 100
            index == 0 ? path.move(to: NSPoint(x: x, y: y)) : path.line(to: NSPoint(x: x, y: y))
        }
        NSColor.systemBlue.setStroke()
        path.lineWidth = 2
        path.stroke()
        if let latest = selected.last, let percent = latest.secondaryPercent {
            let x = plot.minX + plot.width * CGFloat(latest.recordedAt.timeIntervalSince(start) / max(1, now.timeIntervalSince(start)))
            let y = plot.minY + plot.height * CGFloat(percent) / 100
            NSColor.systemBlue.setFill()
            NSBezierPath(ovalIn: NSRect(x: x - 3, y: y - 3, width: 6, height: 6)).fill()
            "\(percent)%".draw(at: NSPoint(x: min(x + 6, plot.maxX - 28), y: min(y + 4, plot.maxY - 12)), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor])
        }
    }
}

@MainActor
private final class ActivityHeatmapView: NSView {
    var values = Array(repeating: Array(repeating: 0, count: 24), count: 7) { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let labels = Calendar.current.shortWeekdaySymbols
        let maxValue = max(1, values.flatMap { $0 }.max() ?? 1)
        let left: CGFloat = 28
        let top: CGFloat = 16
        let cellWidth = (bounds.width - left - 4) / 24
        let cellHeight = (bounds.height - top - 4) / 7
        for day in 0..<7 {
            labels[day].draw(at: NSPoint(x: 0, y: bounds.height - top - CGFloat(day + 1) * cellHeight + 2), withAttributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.secondaryLabelColor])
            for hour in 0..<24 {
                let intensity = CGFloat(values[day][hour]) / CGFloat(maxValue)
                NSColor.systemBlue.withAlphaComponent(0.06 + intensity * 0.78).setFill()
                let rect = NSRect(
                    x: left + CGFloat(hour) * cellWidth,
                    y: bounds.height - top - CGFloat(day + 1) * cellHeight,
                    width: max(2, cellWidth - 2),
                    height: max(2, cellHeight - 2)
                )
                NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
            }
        }
        for hour in stride(from: 0, to: 24, by: 6) {
            "\(hour)".draw(at: NSPoint(x: left + CGFloat(hour) * cellWidth, y: bounds.height - 11), withAttributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.secondaryLabelColor])
        }
    }
}
