import AppKit
import Charts
import SwiftUI

@MainActor
final class UsageHistoryWindowController: NSWindowController, NSWindowDelegate {
    private let host = NSHostingView(rootView: UsageHistoryDashboard())
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CodexPeek Usage Telemetry"
        window.minSize = NSSize(width: 820, height: 680)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
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
        ZStack {
            TelemetryPalette.canvas.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 14) {
                    header
                    primaryPanel(buckets: buckets)
                    HStack(alignment: .top, spacing: 14) {
                        TelemetryPanel { PlanPanel(samples: planHistory.samples, range: range) }
                        TelemetryPanel { ActivityPanel(values: UsageHistoryAnalytics.hourlyActivity(from: buckets, days: range)) }
                    }
                }
                .padding(24)
            }
        }
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
                Text("Usage telemetry")
                    .font(TelemetryType.display(34))
                    .foregroundStyle(TelemetryPalette.text)
                Text(sourceLine)
                    .font(TelemetryType.body(11, weight: .medium))
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
            ModelSummary(model: $0.model, usage: $0.usage, rangeTotal: total)
        }
        let totalCost = days.reduce(0) { $0 + $1.cost }
        let cacheSavings = days.reduce(0) { $0 + $1.cacheSavings }
        let activeDays = days.filter { $0.tokens > 0 }.count
        let hasUnpricedUsage = models.contains { $0.cost == nil }

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
                    MetricCell(label: "CACHE SAVED", value: money(cacheSavings), detail: hasUnpricedUsage ? "known prices only" : "vs uncached input", tint: TelemetryPalette.violet)
                    metricDivider
                    MetricCell(label: "ACTIVE-DAY AVG", value: money(totalCost / Double(max(1, activeDays))), detail: "\(activeDays) active days")
                    metricDivider
                    MetricCell(label: "30-DAY PACE", value: money(totalCost / Double(range) * 30), detail: "at current rate", tint: TelemetryPalette.amber)
                }
                .padding(.vertical, 10)
                .background(TelemetryPalette.elevated.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))

                Group {
                    if metric == .cost {
                        CostChart(days: days)
                    } else {
                        TokenChart(days: days, models: models.map(\.model))
                    }
                }
                .frame(height: 245)

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
    @State private var selectedDate: Date?

    private var selected: DaySnapshot? { nearestDay(to: selectedDate, in: days) }

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
            if let selected {
                RuleMark(x: .value("Selected", selected.day))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    .foregroundStyle(TelemetryPalette.text.opacity(0.55))
                    .annotation(position: .top, spacing: 8) { DayCallout(day: selected, metric: .cost) }
                PointMark(x: .value("Selected", selected.day), y: .value("Cost", selected.cost))
                    .symbolSize(52)
                    .foregroundStyle(TelemetryPalette.text)
            }
        }
        .chartXSelection(value: $selectedDate)
        .telemetryAxes(range: days.count, money: true)
        .accessibilityLabel("Daily estimated cost chart")
    }
}

private struct TokenChart: View {
    let days: [DaySnapshot]
    let models: [String]
    @State private var selectedDate: Date?

    private var points: [ModelDayPoint] {
        days.flatMap { day in
            models.map { ModelDayPoint(day: day.day, model: $0, tokens: day.byModel[$0]?.totalTokens ?? 0) }
        }
    }

    private var selected: DaySnapshot? { nearestDay(to: selectedDate, in: days) }

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
            if let selected {
                RuleMark(x: .value("Selected", selected.day))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    .foregroundStyle(TelemetryPalette.text.opacity(0.55))
                    .annotation(position: .top, spacing: 8) { DayCallout(day: selected, metric: .tokens) }
            }
        }
        .chartForegroundStyleScale(domain: models, range: Array(TelemetryPalette.models.prefix(models.count)))
        .chartLegend(.hidden)
        .chartXSelection(value: $selectedDate)
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

private struct DayCallout: View {
    let day: DaySnapshot
    let metric: ChartMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(day.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)).uppercased())
                .font(TelemetryType.data(9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(TelemetryPalette.muted)
            Text(metric == .cost ? UIFormatters.costString(Decimal(day.cost)) : UIFormatters.compactTokenString(day.tokens))
                .font(TelemetryType.display(20))
                .foregroundStyle(TelemetryPalette.text)
            HStack(spacing: 10) {
                Label("\(day.cacheRate)% cache", systemImage: "arrow.triangle.2.circlepath")
                if let model = day.topModel {
                    Text(TokenPricingCatalog.standard.displayModelName(for: model))
                }
            }
            .font(TelemetryType.body(9, weight: .medium))
            .foregroundStyle(TelemetryPalette.muted)
        }
        .padding(10)
        .background(TelemetryPalette.elevated, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(TelemetryPalette.line))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
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

private struct PlanPanel: View {
    let samples: [PlanUsageSample]
    let range: Int

    private var selected: [PlanUsageSample] {
        let start = Date().addingTimeInterval(TimeInterval(-range * 24 * 60 * 60))
        return samples.filter { $0.recordedAt >= start && $0.secondaryPercent != nil }
    }

    var body: some View {
        let selected = selected
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: "Weekly limit", detail: "Observed plan allowance", value: selected.last?.secondaryPercent.map { "\($0)%" })
            if selected.isEmpty {
                EmptyChart(message: "History starts after the next refresh")
            } else {
                Chart(selected, id: \.recordedAt) { sample in
                    AreaMark(x: .value("Time", sample.recordedAt), y: .value("Used", sample.secondaryPercent ?? 0))
                        .foregroundStyle(LinearGradient(colors: [TelemetryPalette.violet.opacity(0.28), .clear], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Time", sample.recordedAt), y: .value("Used", sample.secondaryPercent ?? 0))
                        .interpolationMethod(.stepEnd)
                        .foregroundStyle(TelemetryPalette.violet)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(values: [0, 50, 100]) { value in
                        AxisGridLine().foregroundStyle(TelemetryPalette.line)
                        AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%") }
                            .font(TelemetryType.data(8))
                            .foregroundStyle(TelemetryPalette.muted)
                    }
                }
                .chartXAxis(.hidden)
                .frame(height: 130)
            }
        }
        .frame(minHeight: 180, alignment: .top)
    }
}

private struct ActivityPanel: View {
    let values: [[Int]]

    var body: some View {
        let maximum = max(1, values.flatMap { $0 }.max() ?? 1)
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: "Work rhythm", detail: "Tokens by weekday and hour")
            HStack(spacing: 3) {
                Color.clear.frame(width: 30, height: 10)
                ForEach(0..<24, id: \.self) { hour in
                    Text(hour.isMultiple(of: 6) ? "\(hour)" : "")
                        .font(TelemetryType.data(8))
                        .foregroundStyle(TelemetryPalette.muted)
                        .frame(maxWidth: .infinity)
                }
            }
            VStack(spacing: 4) {
                ForEach(0..<7, id: \.self) { day in
                    HStack(spacing: 3) {
                        Text(Calendar.current.shortWeekdaySymbols[day])
                            .font(TelemetryType.body(9, weight: .semibold))
                            .foregroundStyle(TelemetryPalette.muted)
                            .frame(width: 30, alignment: .leading)
                        ForEach(0..<24, id: \.self) { hour in
                            let intensity = pow(Double(values[day][hour]) / Double(maximum), 0.4)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(TelemetryPalette.blue.opacity(0.08 + intensity * 0.85))
                                .frame(maxWidth: .infinity, minHeight: 13)
                                .help("\(Calendar.current.weekdaySymbols[day]) at \(hour):00 · \(UIFormatters.compactTokenString(values[day][hour])) tokens")
                        }
                    }
                }
            }
        }
        .frame(minHeight: 180, alignment: .top)
    }
}

private struct PanelHeader: View {
    let title: String
    let detail: String
    var value: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(TelemetryType.display(18)).foregroundStyle(TelemetryPalette.text)
                Text(detail).font(TelemetryType.body(10, weight: .medium)).foregroundStyle(TelemetryPalette.muted)
            }
            Spacer()
            if let value {
                Text(value).font(TelemetryType.data(15, weight: .semibold)).foregroundStyle(TelemetryPalette.violet)
            }
        }
    }
}

private struct EmptyChart: View {
    let message: String

    var body: some View {
        Text(message)
            .font(TelemetryType.body(11, weight: .medium))
            .foregroundStyle(TelemetryPalette.muted)
            .frame(maxWidth: .infinity, minHeight: 130)
            .background(TelemetryPalette.canvas.opacity(0.25), in: RoundedRectangle(cornerRadius: 9))
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
        cost = source.byModel.reduce(0) {
            $0 + NSDecimalNumber(decimal: TokenPricingCatalog.standard.estimateCost(for: $1.key, usage: $1.value)?.total ?? 0).doubleValue
        }
        cacheSavings = source.byModel.reduce(0) {
            $0 + NSDecimalNumber(decimal: TokenPricingCatalog.standard.estimateCacheSavings(for: $1.key, usage: $1.value) ?? 0).doubleValue
        }
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

    init(model: String, usage: TokenUsagePayload, rangeTotal: Int) {
        self.model = model
        self.usage = usage
        share = Int((Double(usage.totalTokens) / Double(rangeTotal) * 100).rounded())
        cost = TokenPricingCatalog.standard.estimateCost(for: model, usage: usage)?.total
    }
}

private func nearestDay(to date: Date?, in days: [DaySnapshot]) -> DaySnapshot? {
    guard let date else { return nil }
    return days.min { abs($0.day.timeIntervalSince(date)) < abs($1.day.timeIntervalSince(date)) }
}

private func costAxis(_ value: Double) -> String {
    value >= 10 ? String(format: "$%.0f", value) : String(format: "$%.2f", value)
}
