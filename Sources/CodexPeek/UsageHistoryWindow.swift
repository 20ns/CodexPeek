/* Hallmark · pre-emit critique: P5 H5 E5 S5 R5 V4
 * genre: playful-technical · macrostructure: Workbench · designed-as-app
 */
import AppKit
import Charts
import SwiftUI

@MainActor
final class UsageHistoryWindowController: NSWindowController, NSWindowDelegate {
    private let host = NSHostingView(rootView: UsageHistoryDashboard())
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        let contentSize = NSSize(width: 1120, height: 780)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CodexPeek Usage Telemetry"
        window.minSize = NSSize(width: 980, height: 700)
        window.appearance = NSAppearance(named: .darkAqua)
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: contentSize)
        window.contentView = host
        window.setContentSize(contentSize)
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }

    func show(report: TokenUsageReport?, planHistory: PlanUsageHistory, snapshot: CodexUsageSnapshot?) {
        updateRoot(report: report, planHistory: planHistory, snapshot: snapshot)
        showWindow(nil)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    func update(report: TokenUsageReport?, planHistory: PlanUsageHistory, snapshot: CodexUsageSnapshot?) {
        guard window?.isVisible == true else { return }
        updateRoot(report: report, planHistory: planHistory, snapshot: snapshot)
    }

    private func updateRoot(report: TokenUsageReport?, planHistory: PlanUsageHistory, snapshot: CodexUsageSnapshot?) {
        host.rootView = UsageHistoryDashboard(report: report, planHistory: planHistory, snapshot: snapshot)
    }
}

private enum TelemetryPalette {
    static let canvas = Color(red: 0.035, green: 0.055, blue: 0.082)
    static let panel = Color(red: 0.060, green: 0.088, blue: 0.125)
    static let elevated = Color(red: 0.082, green: 0.118, blue: 0.165)
    static let line = Color(red: 0.145, green: 0.196, blue: 0.255)
    static let text = Color(red: 0.925, green: 0.950, blue: 0.970)
    static let muted = Color(red: 0.510, green: 0.585, blue: 0.675)
    static let blue = Color(red: 0.250, green: 0.610, blue: 0.980)
    static let violet = Color(red: 0.675, green: 0.430, blue: 0.965)
    static let amber = Color(red: 1.000, green: 0.675, blue: 0.260)
    static let green = Color(red: 0.250, green: 0.800, blue: 0.610)
    static let models = [blue, violet, green, amber, .pink, .cyan]
}

private enum TelemetryType {
    static func display(_ size: CGFloat) -> Font {
        .custom("Avenir Next Condensed", fixedSize: size).weight(.semibold)
    }

    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("Avenir Next", fixedSize: size).weight(weight)
    }

    static func data(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

private enum ChartMetric: String, CaseIterable, Identifiable {
    case cost = "Cost"
    case tokens = "Tokens"
    var id: Self { self }
}

private struct UsageHistoryDashboard: View {
    var report: TokenUsageReport?
    var planHistory = PlanUsageHistory()
    var snapshot: CodexUsageSnapshot?

    @State private var range = 14
    @State private var metric = ChartMetric.cost

    private var sourceLine: String {
        guard let snapshot else { return "Local session logs" }
        return "\(snapshot.account.planType.displayName) plan  ·  local session logs  ·  refreshed \(UIFormatters.usageUpdatedString(from: snapshot.lastUpdatedAt))"
    }

    var body: some View {
        let buckets = report?.history?.buckets ?? []
        let rolling = UsageHistoryAnalytics.rollingComparison(from: buckets, days: range)
        let week = UsageHistoryAnalytics.calendarComparison(from: buckets, component: .weekOfYear)
        let month = UsageHistoryAnalytics.calendarComparison(from: buckets, component: .month)
        let allowance = UsageHistoryAnalytics.allowanceYield(from: buckets, history: planHistory)
        let pace = UsageHistoryAnalytics.planPace(snapshot: snapshot)
        ZStack(alignment: .top) {
            TelemetryPalette.canvas
            VStack(spacing: 12) {
                header.fixedSize(horizontal: false, vertical: true)
                ComparisonStrip(week: week, month: month, rolling: rolling)
                AllowanceWatchPanel(comparison: allowance, pace: pace)
                primaryPanel(buckets: buckets)
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
        .tint(TelemetryPalette.blue)
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(TelemetryPalette.green)
                        .frame(width: 7, height: 7)
                        .shadow(color: TelemetryPalette.green.opacity(0.65), radius: 5)
                    Text("CODEXPEEK  /  LOCAL TELEMETRY")
                        .font(TelemetryType.data(10, weight: .semibold))
                        .tracking(1.1)
                        .foregroundStyle(TelemetryPalette.muted)
                }
                Text("Usage, decoded")
                    .font(TelemetryType.display(36))
                    .foregroundStyle(TelemetryPalette.text)
                Text(sourceLine)
                    .font(TelemetryType.body(12, weight: .medium))
                    .foregroundStyle(TelemetryPalette.muted)
            }
            Spacer()
            Picker("Range", selection: $range) {
                Text("7 days").tag(7)
                Text("14 days").tag(14)
                Text("30 days").tag(30)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 220)
            .accessibilityLabel("History range")
        }
        .padding(.horizontal, 2)
    }

    private func primaryPanel(buckets: [TokenUsageBucket]) -> some View {
        let daily = UsageHistoryAnalytics.dailyUsage(from: buckets, days: range)
        let days = daily.map(DaySnapshot.init)
        let total = max(1, daily.reduce(0) { $0 + $1.totalTokens })
        let models = UsageHistoryAnalytics.modelTotals(from: daily).map {
            ModelSummary(model: $0.model, usage: $0.usage, cost: $0.cost, rangeTotal: total)
        }
        let totalCost = days.reduce(0) { $0 + $1.cost }
        let cacheSavings = days.reduce(0) { $0 + $1.cacheSavings }
        var rangeUsage = TokenUsagePayload.zero
        for day in daily {
            for usage in day.byModel.values { rangeUsage.add(usage) }
        }
        let reasoningMix = rangeUsage.outputTokens > 0
            ? Int((Double(rangeUsage.reasoningOutputTokens) / Double(rangeUsage.outputTokens) * 100).rounded())
            : nil
        let hasUnpricedUsage = models.contains { $0.cost == nil }
        let priorityTokensByModel = daily.reduce(into: [String: Int]()) { totals, day in
            for (model, tokens) in day.priorityTokensByModel {
                totals[model, default: 0] += tokens
            }
        }
        let priorityTokens = priorityTokensByModel.values.reduce(0, +)
        let fastTokensByModel = daily.reduce(into: [String: Int]()) { totals, day in
            for (model, tokens) in day.fastTokensByModel {
                totals[model, default: 0] += tokens
            }
        }
        let fastTokens = fastTokensByModel.values.reduce(0, +)
        let fastRates = Set(fastTokensByModel.keys.compactMap(TokenPricingCatalog.standard.fastCreditMultiplier))
            .sorted()
            .map { NSDecimalNumber(decimal: $0).stringValue }
            .joined(separator: "–")
        let tierLabel = fastTokens > 0 ? "FAST TOKENS" : "PRIORITY TOKENS"
        let tierValue = fastTokens > 0 ? fastTokens : priorityTokens
        let tierDetail = fastTokens > 0 && !fastRates.isEmpty
            ? "\(fastRates)× credit rate"
            : priorityTokens > 0 ? "priority-tier requests" : "none in range"

        return TelemetryPanel {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(metric == .cost ? "Cost burn" : "Token throughput")
                            .font(TelemetryType.display(22))
                            .foregroundStyle(TelemetryPalette.text)
                        Text(metric == .cost
                            ? "Daily API-equivalent spend\(hasUnpricedUsage ? " · known prices only" : "")"
                            : "Daily tokens stacked by model")
                            .font(TelemetryType.body(11, weight: .medium))
                            .foregroundStyle(TelemetryPalette.muted)
                    }
                    Spacer()
                    Picker("Metric", selection: $metric) {
                        ForEach(ChartMetric.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 154)
                    .accessibilityLabel("Chart metric")
                }

                HStack(spacing: 0) {
                    MetricCell(label: "EST. SPEND", value: money(totalCost), detail: hasUnpricedUsage ? "known prices only" : "selected range")
                    metricDivider
                    MetricCell(label: tierLabel, value: UIFormatters.compactTokenString(tierValue), detail: tierDetail, tint: TelemetryPalette.amber)
                    metricDivider
                    MetricCell(label: "CACHE SAVED", value: money(cacheSavings), detail: hasUnpricedUsage ? "known prices only" : "vs uncached input", tint: TelemetryPalette.violet)
                    metricDivider
                    MetricCell(
                        label: "REASONING MIX",
                        value: reasoningMix.map { "\($0)%" } ?? "—",
                        detail: "of output tokens",
                        tint: TelemetryPalette.green
                    )
                }
                .padding(.vertical, 10)
                .overlay(alignment: .top) { Rectangle().fill(TelemetryPalette.line).frame(height: 1) }
                .overlay(alignment: .bottom) { Rectangle().fill(TelemetryPalette.line).frame(height: 1) }

                Group {
                    if metric == .cost {
                        CostChart(days: days)
                    } else {
                        TokenChart(days: days, models: models.map(\.model))
                    }
                }
                .frame(height: 180)

                if models.isEmpty {
                    Text(report?.history == nil ? "Building history from local sessions…" : "No token activity in this range")
                        .font(TelemetryType.body(11, weight: .medium))
                        .foregroundStyle(TelemetryPalette.muted)
                } else {
                    HStack(spacing: 22) {
                        ForEach(Array(models.prefix(3).enumerated()), id: \.element.id) { index, model in
                            ModelKey(model: model, color: TelemetryPalette.models[index % TelemetryPalette.models.count])
                        }
                    }
                }
            }
        }
    }

    private var metricDivider: some View {
        Rectangle().fill(TelemetryPalette.line).frame(width: 1, height: 44)
    }

    private func money(_ value: Double) -> String {
        UIFormatters.costString(Decimal(value))
    }
}

private struct ComparisonStrip: View {
    let week: UsagePeriodComparison?
    let month: UsagePeriodComparison?
    let rolling: UsagePeriodComparison

    var body: some View {
        HStack(spacing: 0) {
            InsightCell(
                label: "THIS WEEK",
                value: comparisonValue(week),
                detail: comparisonDetail(week, period: "last week"),
                tint: TelemetryPalette.blue
            )
            divider
            InsightCell(
                label: "THIS MONTH",
                value: comparisonValue(month),
                detail: comparisonDetail(month, period: "last month"),
                tint: TelemetryPalette.violet
            )
            divider
            InsightCell(
                label: "ACTIVE-DAY INTENSITY",
                value: rolling.current.activeDayAverage.map { UIFormatters.compactTokenString(Int($0.rounded())) } ?? "—",
                detail: comparisonDetail(rolling.activeDayChangePercent, suffix: "vs prior period")
            )
            divider
            InsightCell(
                label: "CONTEXT LEVERAGE",
                value: leverage(rolling.current.contextLeverage),
                detail: leverageDetail(rolling),
                tint: TelemetryPalette.green
            )
        }
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(TelemetryPalette.line).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(TelemetryPalette.line).frame(height: 1) }
    }

    private var divider: some View {
        Rectangle().fill(TelemetryPalette.line).frame(width: 1, height: 50)
    }

    private func comparisonValue(_ comparison: UsagePeriodComparison?) -> String {
        if let change = comparison?.tokenChangePercent {
            return signed(change, suffix: "%")
        }
        return comparison.map { UIFormatters.compactTokenString($0.current.usage.totalTokens) } ?? "—"
    }

    private func comparisonDetail(_ comparison: UsagePeriodComparison?, period: String) -> String {
        comparison?.tokenChangePercent == nil
            ? "tokens so far · baseline collecting"
            : "tokens vs equal time \(period)"
    }

    private func comparisonDetail(_ value: Int?, suffix: String) -> String {
        value.map { "\(signed($0, suffix: "%")) \(suffix)" } ?? "needs a prior baseline"
    }

    private func leverage(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.isInfinite ? "all cached" : String(format: "%.1f×", value)
    }

    private func leverageDetail(_ comparison: UsagePeriodComparison) -> String {
        guard comparison.hasCompleteBaseline,
              let current = comparison.current.contextLeverage,
              let previous = comparison.previous.contextLeverage,
              current.isFinite, previous.isFinite else {
            return "cached input ÷ fresh input"
        }
        return "\(current >= previous ? "+" : "")\(String(format: "%.1f×", current - previous)) vs prior period"
    }
}

private struct InsightCell: View {
    let label: String
    let value: String
    let detail: String
    var tint = TelemetryPalette.text

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(TelemetryType.data(9, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(TelemetryPalette.muted)
            Text(value)
                .font(TelemetryType.display(25))
                .foregroundStyle(tint)
                .monospacedDigit()
            Text(detail)
                .font(TelemetryType.body(9, weight: .medium))
                .foregroundStyle(TelemetryPalette.muted)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct AllowanceWatchPanel: View {
    let comparison: AllowanceYieldComparison
    let pace: PlanPace?

    private var status: (title: String, detail: String, color: Color) {
        guard let current = comparison.current else {
            return ("Learning your reset pattern", "Needs at least 2 observed weekly points", TelemetryPalette.muted)
        }
        guard let change = comparison.changePercent else {
            return ("Current reset baseline ready", "\(current.observedPoints) plan points observed", TelemetryPalette.blue)
        }
        if change <= -15 {
            return ("Allowance signal is lower", "Could mean tighter limits—or a heavier model mix", TelemetryPalette.amber)
        }
        if change >= 15 {
            return ("Allowance signal is higher", "Could mean looser limits—or a lighter model mix", TelemetryPalette.green)
        }
        return ("Allowance signal looks steady", "Within 15% of the last observed reset", TelemetryPalette.green)
    }

    var body: some View {
        let status = status
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Allowance watch")
                    .font(TelemetryType.display(19))
                    .foregroundStyle(TelemetryPalette.text)
                Text(status.title)
                    .font(TelemetryType.display(27))
                    .foregroundStyle(status.color)
                    .fixedSize(horizontal: false, vertical: true)
                Text(status.detail)
                    .font(TelemetryType.body(10, weight: .medium))
                    .foregroundStyle(TelemetryPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Signal only · model mix affects yield")
                    .font(TelemetryType.data(8))
                    .foregroundStyle(TelemetryPalette.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            AllowanceMetric(
                label: "TOKENS / PT",
                value: comparison.current.map { UIFormatters.compactTokenString(Int($0.tokensPerPoint.rounded())) } ?? "—",
                detail: "local yield"
            )
            metricDivider
            AllowanceMetric(
                label: "VS PRIOR",
                value: comparison.changePercent.map { signed($0, suffix: "%") } ?? "—",
                detail: comparison.previous == nil ? "learning" : "yield change",
                tint: status.color
            )
            metricDivider
            AllowanceMetric(
                label: pace == nil ? "OBSERVED" : "WEEKLY PACE",
                value: pace.map { String(format: "%.1f×", $0.multiplier) }
                    ?? comparison.current.map { "\($0.observedPoints) pts" }
                    ?? "—",
                detail: pace.map { "\($0.projectedPercent)% projected" } ?? "this reset",
                tint: TelemetryPalette.violet
            )
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .overlay(alignment: .top) { Rectangle().fill(TelemetryPalette.line).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(TelemetryPalette.line).frame(height: 1) }
    }

    private var metricDivider: some View {
        Rectangle().fill(TelemetryPalette.line).frame(width: 1, height: 50)
    }
}

private struct AllowanceMetric: View {
    let label: String
    let value: String
    let detail: String
    var tint = TelemetryPalette.text

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(TelemetryType.data(9, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(TelemetryPalette.muted)
            Text(value)
                .font(TelemetryType.display(23))
                .foregroundStyle(tint)
                .monospacedDigit()
            Text(detail)
                .font(TelemetryType.body(9, weight: .medium))
                .foregroundStyle(TelemetryPalette.muted)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct TelemetryPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TelemetryPalette.panel, in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(TelemetryPalette.line, lineWidth: 1))
    }
}

private struct MetricCell: View {
    let label: String
    let value: String
    let detail: String
    var tint = TelemetryPalette.text

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(TelemetryType.data(9, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(TelemetryPalette.muted)
            Text(value)
                .font(TelemetryType.display(23))
                .foregroundStyle(tint)
                .monospacedDigit()
            Text(detail)
                .font(TelemetryType.body(10, weight: .medium))
                .foregroundStyle(TelemetryPalette.muted)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct CostChart: View {
    let days: [DaySnapshot]

    var body: some View {
        Chart {
            ForEach(days) { day in
                AreaMark(x: .value("Day", day.day), y: .value("Cost", day.cost))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [TelemetryPalette.blue.opacity(0.34), TelemetryPalette.blue.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Day", day.day), y: .value("Cost", day.cost))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(TelemetryPalette.blue)
            }
        }
        .telemetryAxes(range: days.count, money: true)
        .accessibilityLabel("Daily estimated cost chart")
    }
}

private struct TokenChart: View {
    let days: [DaySnapshot]
    let models: [String]

    private var points: [ModelDayPoint] {
        days.flatMap { day in
            models.map { ModelDayPoint(day: day.day, model: $0, tokens: day.byModel[$0]?.totalTokens ?? 0) }
        }
    }

    var body: some View {
        Chart {
            ForEach(points) { point in
                BarMark(
                    x: .value("Day", point.day, unit: .day),
                    y: .value("Tokens", point.tokens)
                )
                .foregroundStyle(by: .value("Model", point.model))
                .cornerRadius(2)
            }
        }
        .chartForegroundStyleScale(domain: models, range: Array(TelemetryPalette.models.prefix(models.count)))
        .chartLegend(.hidden)
        .telemetryAxes(range: days.count, money: false)
        .accessibilityLabel("Daily token chart by model")
    }
}

private extension View {
    func telemetryAxes(range: Int, money: Bool) -> some View {
        chartXAxis {
            AxisMarks(values: .stride(by: .day, count: max(1, range / 4))) {
                AxisTick().foregroundStyle(TelemetryPalette.line)
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    .font(TelemetryType.data(9))
                    .foregroundStyle(TelemetryPalette.muted)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(TelemetryPalette.line.opacity(0.75))
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(money ? costAxis(number) : UIFormatters.compactTokenString(Int(number)))
                    }
                }
                .font(TelemetryType.data(9))
                .foregroundStyle(TelemetryPalette.muted)
            }
        }
        .chartPlotStyle { plot in
            plot.background(TelemetryPalette.canvas.opacity(0.34))
        }
    }
}

private struct ModelKey: View {
    let model: ModelSummary
    let color: Color

    var body: some View {
        let cost = model.cost.map(UIFormatters.costString) ?? "unpriced"
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(TokenPricingCatalog.standard.displayModelName(for: model.model))
                    .font(TelemetryType.body(11, weight: .semibold))
                    .foregroundStyle(TelemetryPalette.text)
                Text("\(model.share)%  ·  \(UIFormatters.compactTokenString(model.usage.totalTokens))  ·  \(cost)")
                    .font(TelemetryType.data(9))
                    .foregroundStyle(TelemetryPalette.muted)
            }
        }
    }
}

private struct DaySnapshot: Identifiable {
    let day: Date
    let byModel: [String: TokenUsagePayload]
    let tokens: Int
    let cost: Double
    let cacheSavings: Double
    let cacheRate: Int
    let topModel: String?
    var id: Date { day }

    init(_ source: DailyTokenUsage) {
        var usage = TokenUsagePayload.zero
        for value in source.byModel.values { usage.add(value) }
        day = source.day
        byModel = source.byModel
        tokens = usage.totalTokens
        cost = source.costByModel.values.reduce(0) { $0 + NSDecimalNumber(decimal: $1).doubleValue }
        cacheSavings = NSDecimalNumber(decimal: source.cacheSavings).doubleValue
        cacheRate = usage.inputTokens > 0 ? Int((Double(usage.cachedInputTokens) / Double(usage.inputTokens) * 100).rounded()) : 0
        topModel = source.byModel.max { $0.value.totalTokens < $1.value.totalTokens }?.key
    }
}

private struct ModelDayPoint: Identifiable {
    let day: Date
    let model: String
    let tokens: Int
    var id: String { "\(day.timeIntervalSinceReferenceDate)-\(model)" }
}

private struct ModelSummary: Identifiable {
    let model: String
    let usage: TokenUsagePayload
    let share: Int
    let cost: Decimal?
    var id: String { model }

    init(model: String, usage: TokenUsagePayload, cost: Decimal?, rangeTotal: Int) {
        self.model = model
        self.usage = usage
        share = Int((Double(usage.totalTokens) / Double(rangeTotal) * 100).rounded())
        self.cost = cost
    }
}

private func signed(_ value: Int, suffix: String) -> String {
    "\(value > 0 ? "+" : "")\(value)\(suffix)"
}

private func costAxis(_ value: Double) -> String {
    value >= 10 ? String(format: "$%.0f", value) : String(format: "$%.2f", value)
}
