/* Seat-value ledger · subscription arbitrage vs API-equivalent market rate */
import AppKit
import Charts
import SwiftUI

@MainActor
final class UsageHistoryWindowController: NSWindowController, NSWindowDelegate {
    private let sessionState = UsageHistorySessionState()
    private let host: NSHostingView<UsageHistoryDashboard>
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        let root = UsageHistoryDashboard(sessionState: sessionState)
        host = NSHostingView(rootView: root)
        let contentSize = NSSize(width: 1120, height: 760)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CodexPeek Seat Value"
        window.minSize = NSSize(width: 960, height: 640)
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

    func show(
        report: TokenUsageReport?,
        planHistory: PlanUsageHistory,
        snapshot: CodexUsageSnapshot?,
        accountPlan: CodexPlanType = .unknown
    ) {
        updateRoot(report: report, planHistory: planHistory, snapshot: snapshot, accountPlan: accountPlan)
        showWindow(nil)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    func update(
        report: TokenUsageReport?,
        planHistory: PlanUsageHistory,
        snapshot: CodexUsageSnapshot?,
        accountPlan: CodexPlanType = .unknown
    ) {
        guard window?.isVisible == true else { return }
        updateRoot(report: report, planHistory: planHistory, snapshot: snapshot, accountPlan: accountPlan)
    }

    private func updateRoot(
        report: TokenUsageReport?,
        planHistory: PlanUsageHistory,
        snapshot: CodexUsageSnapshot?,
        accountPlan: CodexPlanType
    ) {
        host.rootView = UsageHistoryDashboard(
            report: report,
            planHistory: planHistory,
            snapshot: snapshot,
            accountPlan: accountPlan,
            sessionState: sessionState
        )
    }
}

@MainActor
final class UsageHistorySessionState: ObservableObject {
    enum RangeFilter: String, CaseIterable, Identifiable {
        case week
        case month
        case max

        var id: String { rawValue }

        var title: String {
            switch self {
            case .week: return "Week"
            case .month: return "Month"
            case .max: return "Max"
            }
        }
    }

    @Published var range: RangeFilter = .week
    @Published var hoverDay: Date?
}

private enum SeatPalette {
    static let canvas = Color(red: 0.043, green: 0.055, blue: 0.071)
    static let panel = Color(red: 0.078, green: 0.098, blue: 0.122)
    static let line = Color(red: 0.173, green: 0.208, blue: 0.259)
    static let text = Color(red: 0.910, green: 0.894, blue: 0.863)
    static let muted = Color(red: 0.545, green: 0.576, blue: 0.627)
    static let brass = Color(red: 0.769, green: 0.639, blue: 0.353)
    static let cyan = Color(red: 0.239, green: 0.722, blue: 0.773)
    static let models = [cyan, brass, Color(red: 0.55, green: 0.62, blue: 0.70), text.opacity(0.7)]
}

private enum SeatType {
    static func hero(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .serif)
    }

    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    static func data(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

private struct UsageHistoryDashboard: View {
    var report: TokenUsageReport?
    var planHistory = PlanUsageHistory()
    var snapshot: CodexUsageSnapshot?
    var accountPlan: CodexPlanType = .unknown
    @ObservedObject var sessionState: UsageHistorySessionState

    private var planType: CodexPlanType {
        let fromSnapshot = snapshot?.account.planType ?? .unknown
        if fromSnapshot != .unknown { return fromSnapshot }
        return accountPlan
    }

    private var refreshedLine: String {
        guard let snapshot else { return "Local session logs" }
        return "local session logs · refreshed \(UIFormatters.usageUpdatedString(from: snapshot.lastUpdatedAt))"
    }

    var body: some View {
        let buckets = report?.history?.buckets ?? []
        let dayCount = dayCount(for: sessionState.range, buckets: buckets)
        let allowance = UsageHistoryAnalytics.allowanceYield(from: buckets, history: planHistory)
        let value = UsageHistoryAnalytics.subscriptionValue(
            from: buckets,
            days: dayCount,
            planType: planType,
            allowance: allowance
        )
        let chartDays = value.daily.map(DaySnapshot.init)

        ZStack(alignment: .top) {
            SeatPalette.canvas
            VStack(spacing: 0) {
                header
                ValueHero(
                    value: value,
                    rangeLabel: rangeLabel(for: sessionState.range, days: dayCount),
                    refreshedLine: refreshedLine
                )
                .padding(.top, 14)
                .padding(.bottom, 12)
                ValueChipRow(value: value)
                    .padding(.bottom, 14)
                burnPanel(value: value, days: chartDays)
                    .padding(.bottom, 14)
                ValueLedger(value: value, building: report?.history == nil)
            }
            .padding(22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
        .tint(SeatPalette.brass)
        .onChange(of: sessionState.range) { _, _ in
            sessionState.hoverDay = nil
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text("CODEXPEEK  ·  SEAT VALUE")
                .font(SeatType.data(10, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(SeatPalette.muted)
            Spacer()
            Picker("Range", selection: $sessionState.range) {
                ForEach(UsageHistorySessionState.RangeFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 220)
            .accessibilityLabel("History range")
        }
    }

    private func burnPanel(value: SubscriptionValueReport, days: [DaySnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Daily burn")
                    .font(SeatType.body(15, weight: .semibold))
                    .foregroundStyle(SeatPalette.text)
                Spacer()
                Text(value.hasUnpricedUsage
                    ? "API-equivalent · known prices only"
                    : "API-equivalent spend")
                    .font(SeatType.data(10))
                    .foregroundStyle(SeatPalette.muted)
            }

            if days.isEmpty || days.allSatisfy({ $0.cost == 0 && $0.tokens == 0 }) {
                Text(report?.history == nil
                    ? "Building history from local sessions…"
                    : "No activity in this range")
                    .font(SeatType.body(12, weight: .medium))
                    .foregroundStyle(SeatPalette.muted)
                    .frame(maxWidth: .infinity, minHeight: 168, alignment: .center)
            } else {
                CostChart(days: days, hoverDay: $sessionState.hoverDay)
                    .frame(height: 188)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SeatPalette.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(SeatPalette.line, lineWidth: 1))
    }

    private func dayCount(for filter: UsageHistorySessionState.RangeFilter, buckets: [TokenUsageBucket]) -> Int {
        switch filter {
        case .week:
            return 7
        case .month:
            return 30
        case .max:
            return UsageHistoryAnalytics.availableHistoryDays(from: buckets)
        }
    }

    private func rangeLabel(for filter: UsageHistorySessionState.RangeFilter, days: Int) -> String {
        switch filter {
        case .week: return "week"
        case .month: return "month"
        case .max: return "\(days)d max"
        }
    }
}

private struct ValueHero: View {
    let value: SubscriptionValueReport
    let rangeLabel: String
    let refreshedLine: String

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            if let multiple = value.openMarketMultiple, value.listPriceUSD != nil {
                Text(multipleLabel(multiple))
                    .font(SeatType.hero(34))
                    .foregroundStyle(SeatPalette.brass)
                    .monospacedDigit()
                    .accessibilityLabel("Open-market multiple \(multipleLabel(multiple))")
            } else {
                Text(UIFormatters.costString(value.apiEquivalentSpend))
                    .font(SeatType.hero(30))
                    .foregroundStyle(SeatPalette.brass)
                    .monospacedDigit()
            }

            Rectangle()
                .fill(SeatPalette.brass.opacity(0.45))
                .frame(width: 1.5, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(value.openMarketMultiple != nil && value.listPriceUSD != nil
                    ? "open-market multiple"
                    : "API-equivalent value")
                    .font(SeatType.data(10, weight: .semibold))
                    .tracking(0.9)
                    .foregroundStyle(SeatPalette.muted)
                Text(subtitle)
                    .font(SeatType.body(13, weight: .medium))
                    .foregroundStyle(SeatPalette.text.opacity(0.9))
                    .lineLimit(2)
                Text(refreshedLine)
                    .font(SeatType.data(10))
                    .foregroundStyle(SeatPalette.muted)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        let covered = UIFormatters.costString(value.apiEquivalentSpend)
        if let price = value.listPriceUSD {
            return "\(value.planType.seatLabel) \(UIFormatters.costString(price)) seat · covered \(covered) · \(rangeLabel)"
        }
        return "\(value.planType.seatLabel) · covered \(covered) · \(rangeLabel)"
    }

    private func multipleLabel(_ value: Double) -> String {
        if value >= 100 {
            return String(format: "%.0f×", value)
        }
        if value >= 10 {
            return String(format: "%.1f×", value)
        }
        return String(format: "%.2f×", value)
    }
}

private struct ValueChipRow: View {
    let value: SubscriptionValueReport

    var body: some View {
        HStack(spacing: 0) {
            ValueChip(
                label: "BREAK-EVEN",
                value: breakEvenValue,
                detail: breakEvenDetail
            )
            chipDivider
            ValueChip(
                label: "CACHE REBATE",
                value: UIFormatters.costString(value.cacheRebate),
                detail: value.hasUnpricedUsage ? "known prices only" : "vs uncached input",
                tint: SeatPalette.cyan
            )
            chipDivider
            ValueChip(
                label: "$ / ALLOWANCE PT",
                value: value.dollarsPerAllowancePoint.map(UIFormatters.costString) ?? "—",
                detail: value.dollarsPerAllowancePoint == nil ? "needs weekly points" : "API value per 1%"
            )
        }
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(SeatPalette.line).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(SeatPalette.line).frame(height: 1) }
    }

    private var breakEvenValue: String {
        if let index = value.breakEvenDayIndex {
            return "Day \(index)"
        }
        if value.listPriceUSD == nil {
            return "—"
        }
        return "Not yet"
    }

    private var breakEvenDetail: String {
        if value.breakEvenDayIndex != nil {
            return "seat cost covered"
        }
        if value.listPriceUSD == nil {
            return "no list seat price"
        }
        return "below prorated seat"
    }

    private var chipDivider: some View {
        Rectangle().fill(SeatPalette.line).frame(width: 1, height: 44)
    }
}

private struct ValueChip: View {
    let label: String
    let value: String
    let detail: String
    var tint = SeatPalette.text

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(SeatType.data(9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(SeatPalette.muted)
            Text(value)
                .font(SeatType.body(20, weight: .semibold))
                .foregroundStyle(tint)
                .monospacedDigit()
            Text(detail)
                .font(SeatType.body(10, weight: .medium))
                .foregroundStyle(SeatPalette.muted)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct ValueLedger: View {
    let value: SubscriptionValueReport
    let building: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                LedgerCell(
                    label: "REASONING TAX",
                    value: value.reasoningTaxUSD.map(UIFormatters.costString) ?? "—",
                    detail: value.reasoningTaxUSD == nil ? "no reasoning output" : "of output cost"
                )
                ledgerDivider
                LedgerCell(
                    label: "CONTEXT VS GEN",
                    value: compositionValue,
                    detail: compositionDetail
                )
            }
            Rectangle().fill(SeatPalette.line).frame(height: 1)
            HStack(alignment: .top, spacing: 0) {
                LedgerCell(
                    label: "CREDIT-MODE SHARE",
                    value: value.creditModeSharePercent.map { "\($0)%" } ?? "—",
                    detail: "tokens on ChatGPT credits"
                )
                ledgerDivider
                ModelValueKey(
                    models: value.topModelsByValue,
                    building: building,
                    empty: value.daily.allSatisfy { $0.totalTokens == 0 }
                )
            }
        }
        .background(SeatPalette.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(SeatPalette.line, lineWidth: 1))
    }

    private var compositionValue: String {
        let total = value.contextCostUSD + value.generationCostUSD
        guard total > 0 else { return "—" }
        let contextShare = Int((NSDecimalNumber(decimal: value.contextCostUSD / total).doubleValue * 100).rounded())
        return "\(contextShare)% / \(100 - contextShare)%"
    }

    private var compositionDetail: String {
        let total = value.contextCostUSD + value.generationCostUSD
        guard total > 0 else { return "no priced spend" }
        return "\(UIFormatters.costString(value.contextCostUSD)) in · \(UIFormatters.costString(value.generationCostUSD)) out"
    }

    private var ledgerDivider: some View {
        Rectangle().fill(SeatPalette.line).frame(width: 1)
    }
}

private struct LedgerCell: View {
    let label: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(SeatType.data(9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(SeatPalette.muted)
            Text(value)
                .font(SeatType.body(18, weight: .semibold))
                .foregroundStyle(SeatPalette.text)
                .monospacedDigit()
            Text(detail)
                .font(SeatType.body(11, weight: .medium))
                .foregroundStyle(SeatPalette.muted)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct ModelValueKey: View {
    let models: [SubscriptionModelValue]
    let building: Bool
    let empty: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("VALUE BY MODEL")
                .font(SeatType.data(9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(SeatPalette.muted)

            if models.isEmpty {
                Text(building ? "Building history from local sessions…" : empty ? "No token activity in this range" : "No priced models in range")
                    .font(SeatType.body(12, weight: .medium))
                    .foregroundStyle(SeatPalette.muted)
            } else {
                ForEach(Array(models.enumerated()), id: \.element.model) { index, model in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(SeatPalette.models[index % SeatPalette.models.count])
                            .frame(width: 6, height: 6)
                        Text(TokenPricingCatalog.standard.displayModelName(for: model.model))
                            .font(SeatType.body(12, weight: .semibold))
                            .foregroundStyle(SeatPalette.text)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(model.cost.map(UIFormatters.costString) ?? "unpriced")
                            .font(SeatType.data(11, weight: .medium))
                            .foregroundStyle(SeatPalette.brass)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct CostChart: View {
    let days: [DaySnapshot]
    @Binding var hoverDay: Date?

    private var calendar: Calendar { .current }

    private var selected: DaySnapshot? {
        nearestDay(to: hoverDay)
    }

    private var domain: ClosedRange<Date> {
        guard let first = days.first?.day, let last = days.last?.day else {
            let now = calendar.startOfDay(for: Date())
            return now...now
        }
        return first...last
    }

    private var maxCost: Double {
        max(days.map(\.cost).max() ?? 0, 0.01)
    }

    var body: some View {
        Chart {
            ForEach(days) { day in
                AreaMark(
                    x: .value("Day", day.day, unit: .day),
                    y: .value("Cost", day.cost)
                )
                .interpolationMethod(.linear)
                .foregroundStyle(
                    LinearGradient(
                        colors: [SeatPalette.brass.opacity(0.26), SeatPalette.brass.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("Day", day.day, unit: .day),
                    y: .value("Cost", day.cost)
                )
                .interpolationMethod(.linear)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .foregroundStyle(SeatPalette.brass)

                PointMark(
                    x: .value("Day", day.day, unit: .day),
                    y: .value("Cost", day.cost)
                )
                .symbolSize(selected?.id == day.id ? 42 : 0)
                .foregroundStyle(SeatPalette.brass)
            }

            if let selected {
                RuleMark(x: .value("Selected", selected.day, unit: .day))
                    .foregroundStyle(SeatPalette.cyan.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .zIndex(-1)

                PointMark(
                    x: .value("Selected", selected.day, unit: .day),
                    y: .value("Cost", selected.cost)
                )
                .symbolSize(54)
                .foregroundStyle(SeatPalette.cyan)
                .annotation(position: annotationPosition(for: selected), spacing: 6) {
                    ChartTooltip(day: selected)
                }
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...maxCost * 1.08)
        .chartXAxis {
            AxisMarks(values: axisDates) { value in
                AxisTick().foregroundStyle(SeatPalette.line)
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date, format: .dateTime.month(.abbreviated).day())
                    }
                }
                .font(SeatType.data(9))
                .foregroundStyle(SeatPalette.muted)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(SeatPalette.line.opacity(0.7))
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(costAxis(number))
                    }
                }
                .font(SeatType.data(9))
                .foregroundStyle(SeatPalette.muted)
            }
        }
        .chartPlotStyle { plot in
            plot.background(SeatPalette.canvas.opacity(0.4))
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            updateHover(at: point, proxy: proxy, geometry: geometry)
                        case .ended:
                            hoverDay = nil
                        }
                    }
            }
        }
        .accessibilityLabel("Daily estimated cost chart")
        .onChange(of: days.map(\.id)) { _, _ in
            if let hoverDay, nearestDay(to: hoverDay) == nil {
                self.hoverDay = nil
            }
        }
    }

    private var axisDates: [Date] {
        guard days.count > 1 else { return days.map(\.day) }
        let step = max(1, days.count / 4)
        var marks = stride(from: 0, to: days.count, by: step).map { days[$0].day }
        if let last = days.last?.day, marks.last != last {
            marks.append(last)
        }
        return marks
    }

    private func annotationPosition(for day: DaySnapshot) -> AnnotationPosition {
        let index = days.firstIndex(where: { $0.id == day.id }) ?? 0
        if index <= 1 { return .trailing }
        if index >= days.count - 2 { return .leading }
        return day.cost > maxCost * 0.72 ? .bottom : .top
    }

    private func updateHover(at point: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        let plotFrame: CGRect
        if #available(macOS 14.0, *) {
            guard let frame = proxy.plotFrame else { return }
            plotFrame = geometry[frame]
        } else {
            return
        }
        let x = point.x - plotFrame.origin.x
        guard x >= 0, x <= plotFrame.width else {
            hoverDay = nil
            return
        }
        guard let date: Date = proxy.value(atX: x) else {
            hoverDay = nil
            return
        }
        hoverDay = nearestDay(to: date)?.day
    }

    private func nearestDay(to date: Date?) -> DaySnapshot? {
        guard let date, !days.isEmpty else { return nil }
        let target = calendar.startOfDay(for: date)
        return days.min { lhs, rhs in
            abs(lhs.day.timeIntervalSince(target)) < abs(rhs.day.timeIntervalSince(target))
        }
    }
}

private struct ChartTooltip: View {
    let day: DaySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(day.day, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                .font(SeatType.data(10, weight: .semibold))
                .foregroundStyle(SeatPalette.muted)
            Text(UIFormatters.costString(Decimal(day.cost)))
                .font(SeatType.body(14, weight: .semibold))
                .foregroundStyle(SeatPalette.text)
                .monospacedDigit()
            Text("\(UIFormatters.compactTokenString(day.tokens)) tokens")
                .font(SeatType.data(10))
                .foregroundStyle(SeatPalette.muted)
            if day.cacheSavings > 0 {
                Text("cache \(UIFormatters.costString(Decimal(day.cacheSavings)))")
                    .font(SeatType.data(10))
                    .foregroundStyle(SeatPalette.cyan)
            }
            if let topModel = day.topModel {
                Text(TokenPricingCatalog.standard.displayModelName(for: topModel))
                    .font(SeatType.data(10))
                    .foregroundStyle(SeatPalette.brass)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(SeatPalette.panel.opacity(0.96), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(SeatPalette.line, lineWidth: 1))
    }
}

private struct DaySnapshot: Identifiable, Equatable {
    let day: Date
    let cost: Double
    let tokens: Int
    let cacheSavings: Double
    let topModel: String?
    var id: Date { day }

    init(_ source: DailyTokenUsage) {
        var usage = TokenUsagePayload.zero
        for value in source.byModel.values { usage.add(value) }
        day = source.day
        cost = source.costByModel.values.reduce(0) { $0 + NSDecimalNumber(decimal: $1).doubleValue }
        tokens = usage.totalTokens
        cacheSavings = NSDecimalNumber(decimal: source.cacheSavings).doubleValue
        topModel = source.byModel.max { $0.value.totalTokens < $1.value.totalTokens }?.key
    }
}

private func costAxis(_ value: Double) -> String {
    value >= 10 ? String(format: "$%.0f", value) : String(format: "$%.2f", value)
}
