/* Usage History window · API-equivalent cost of Codex and Claude Code sessions */
import AppKit
import Charts
import SwiftUI

@MainActor
final class UsageHistoryWindowController: NSWindowController, NSWindowDelegate {
    let sessionState = UsageHistorySessionState()
    private let onClose: () -> Void

    init(onRefresh: (() -> Void)? = nil, onClose: @escaping () -> Void) {
        self.onClose = onClose
        let host = NSHostingView(rootView: UsageHistoryDashboard(state: sessionState, onRefresh: onRefresh))
        let contentSize = NSSize(width: 1120, height: 760)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "CodexPeek Usage History"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 960, height: 640)

        let glass = NSVisualEffectView(frame: NSRect(origin: .zero, size: contentSize))
        glass.material = .underWindowBackground
        glass.blendingMode = .behindWindow
        glass.state = .followsWindowActiveState
        host.sizingOptions = []
        host.frame = glass.bounds
        host.autoresizingMask = [.width, .height]
        glass.addSubview(host)
        window.contentView = glass
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
        claudeReport: TokenUsageReport?,
        planHistory: PlanUsageHistory,
        snapshot: CodexUsageSnapshot?,
        accountPlan: CodexPlanType = .unknown
    ) {
        updateInputs(report: report, claudeReport: claudeReport, planHistory: planHistory, snapshot: snapshot, accountPlan: accountPlan)
        showWindow(nil)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    func update(
        report: TokenUsageReport?,
        claudeReport: TokenUsageReport?,
        planHistory: PlanUsageHistory,
        snapshot: CodexUsageSnapshot?,
        accountPlan: CodexPlanType = .unknown
    ) {
        guard window?.isVisible == true else { return }
        updateInputs(report: report, claudeReport: claudeReport, planHistory: planHistory, snapshot: snapshot, accountPlan: accountPlan)
    }

    private func updateInputs(
        report: TokenUsageReport?,
        claudeReport: TokenUsageReport?,
        planHistory: PlanUsageHistory,
        snapshot: CodexUsageSnapshot?,
        accountPlan: CodexPlanType
    ) {
        let fromSnapshot = snapshot?.account.planType ?? .unknown
        sessionState.setInputs(HistoryInputs(
            codex: report,
            claude: claudeReport,
            planHistory: planHistory,
            planType: fromSnapshot != .unknown ? fromSnapshot : accountPlan
        ))
    }
}

// MARK: - State and aggregation

/// Owns the selected provider/range and the aggregated result. Aggregation runs only when the
/// reports or the selection change, never while hovering or redrawing.
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

    enum Provider: String, CaseIterable, Identifiable {
        case all = "Combined"
        case claude = "Claude Code"
        case codex = "Codex"
        var id: String { rawValue }
    }

    @Published var provider: Provider = .all { didSet { if provider != oldValue { rebuild() } } }
    @Published var range: RangeFilter = .week { didSet { if range != oldValue { rebuild() } } }
    @Published private(set) var content: HistoryContent

    private var inputs = HistoryInputs()
    private var rebuildTask: Task<Void, Never>?

    init() {
        content = HistoryContent.make(inputs: HistoryInputs(), provider: .all, range: .week)
    }

    func setInputs(_ new: HistoryInputs) {
        guard new != inputs else { return }
        inputs = new
        rebuild()
    }

    /// Pricing every bucket takes 100+ ms on long histories, so content is built off the main thread;
    /// the previous content stays up until the new one lands, and a newer rebuild supersedes it.
    private func rebuild() {
        let inputs = inputs, provider = provider, range = range
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            let next = await Task.detached(priority: .userInitiated) {
                HistoryContent.make(inputs: inputs, provider: provider, range: range)
            }.value
            guard !Task.isCancelled else { return }
            self?.content = next
        }
    }
}

enum HistorySource: CaseIterable {
    case claude
    case codex

    var name: String { self == .claude ? "Claude Code" : "Codex" }

    var color: Color {
        switch self {
        case .claude: return .adaptive(light: (0.80, 0.36, 0.20), dark: (0.93, 0.52, 0.38))
        case .codex: return .adaptive(light: (0.12, 0.40, 0.88), dark: (0.38, 0.62, 1.0))
        }
    }
}

extension UsageHistorySessionState.Provider {
    fileprivate var sources: [HistorySource] {
        switch self {
        case .all: return [.claude, .codex]
        case .claude: return [.claude]
        case .codex: return [.codex]
        }
    }

    /// Accent for single-provider views; combined stays neutral.
    fileprivate var tint: Color {
        switch self {
        case .all: return Color.primary.opacity(0.7)
        case .claude: return HistorySource.claude.color
        case .codex: return HistorySource.codex.color
        }
    }
}

struct HistoryInputs: Equatable {
    var codex: TokenUsageReport?
    var claude: TokenUsageReport?
    var planHistory = PlanUsageHistory()
    var planType: CodexPlanType = .unknown

    func report(_ source: HistorySource) -> TokenUsageReport? {
        source == .codex ? codex : claude
    }
}

struct HistoryDay: Identifiable {
    let day: Date
    var claude = 0.0
    var codex = 0.0
    var tokens = 0
    var cacheSavings = 0.0
    var topModel: String?
    fileprivate var topModelTokens = 0

    var id: Date { day }
    var cost: Double { claude + codex }

    func cost(of source: HistorySource) -> Double {
        source == .claude ? claude : codex
    }
}

struct HistoryModelRow: Identifiable {
    let name: String
    let source: HistorySource
    let cost: Double?
    var id: String { source.name + name }
}

struct HistorySeat {
    let label: String
    let price: Double
    let prorated: Double
    let multiple: Double?
    let breakEvenDay: Date?
    let breakEvenIndex: Int?
    let dollarsPerPoint: Double?
}

struct HistorySummary {
    var sources: [HistorySource]
    var days: [HistoryDay]
    var spend = 0.0
    var cacheSavings = 0.0
    var tokens = 0
    var input = 0.0
    var output = 0.0
    var reasoning = 0.0
    var models: [HistoryModelRow] = []
    var hasUnpriced = false
    var hasLegacyStats = false
    var creditShare: Int?
    var seat: HistorySeat?
    var updatedAt: Date?

    func spend(of source: HistorySource) -> Double {
        days.reduce(0) { $0 + $1.cost(of: source) }
    }
}

enum HistoryContent {
    case unavailable(title: String, detail: String)
    case ready(HistorySummary)

    static func make(
        inputs: HistoryInputs,
        provider: UsageHistorySessionState.Provider,
        range: UsageHistorySessionState.RangeFilter,
        now: Date = Date()
    ) -> HistoryContent {
        // A missing report is simply unavailable; Combined merges whatever is loaded.
        let loaded = provider.sources.compactMap { source in
            inputs.report(source)?.history.map { (source: source, buckets: $0.buckets) }
        }
        guard !loaded.isEmpty else {
            return provider == .all
                ? .unavailable(title: "Reading local session logs…", detail: "Usage appears here once your sessions have been read.")
                : .unavailable(title: "No \(provider.rawValue) history yet", detail: "Usage appears here once \(provider.rawValue) sessions have been read.")
        }

        let dayCount: Int
        switch range {
        case .week: dayCount = 7
        case .month: dayCount = 30
        case .max: dayCount = loaded.map { UsageHistoryAnalytics.availableHistoryDays(from: $0.buckets, now: now) }.max() ?? 1
        }

        let seatView = provider == .codex
        let reports = loaded.map { source, buckets in
            let allowance = UsageHistoryAnalytics.allowanceYield(from: buckets, history: seatView ? inputs.planHistory : PlanUsageHistory())
            return (source, UsageHistoryAnalytics.subscriptionValue(
                from: buckets,
                days: dayCount,
                planType: seatView ? inputs.planType : .unknown,
                allowance: allowance,
                now: now
            ))
        }

        var summary = HistorySummary(
            sources: reports.map(\.0),
            days: reports[0].1.daily.map { HistoryDay(day: $0.day) },
            hasLegacyStats: provider != .codex && inputs.claude?.legacyStats != nil,
            updatedAt: reports.compactMap { inputs.report($0.0)?.generatedAt }.max()
        )
        var models: [HistoryModelRow] = []
        var reasoning: Decimal = 0

        for (source, report) in reports {
            summary.spend += report.apiEquivalentSpend.double
            summary.cacheSavings += report.cacheRebate.double
            summary.input += report.contextCostUSD.double
            summary.output += report.generationCostUSD.double
            reasoning += report.reasoningTaxUSD ?? 0
            summary.hasUnpriced = summary.hasUnpriced || report.hasUnpricedUsage

            for (index, usage) in report.daily.enumerated() {
                let cost = usage.costByModel.values.reduce(Decimal(0), +).double
                if source == .claude { summary.days[index].claude = cost } else { summary.days[index].codex = cost }
                summary.days[index].tokens += usage.totalTokens
                summary.days[index].cacheSavings += usage.cacheSavings.double
                if let top = usage.byModel.max(by: { $0.value.totalTokens < $1.value.totalTokens }),
                   top.value.totalTokens > summary.days[index].topModelTokens {
                    summary.days[index].topModel = TokenPricingCatalog.standard.displayModelName(for: top.key)
                    summary.days[index].topModelTokens = top.value.totalTokens
                }
            }

            models += UsageHistoryAnalytics.modelTotals(from: report.daily).map {
                HistoryModelRow(name: TokenPricingCatalog.standard.displayModelName(for: $0.model), source: source, cost: $0.cost?.double)
            }
            if seatView {
                summary.creditShare = report.creditModeSharePercent
                if let price = report.listPriceUSD, let prorated = report.proratedSeatCost {
                    summary.seat = HistorySeat(
                        label: report.planType.seatLabel,
                        price: price.double,
                        prorated: prorated.double,
                        multiple: report.openMarketMultiple,
                        breakEvenDay: report.breakEvenDay,
                        breakEvenIndex: report.breakEvenDayIndex,
                        dollarsPerPoint: report.dollarsPerAllowancePoint?.double
                    )
                }
            }
        }

        summary.tokens = summary.days.reduce(0) { $0 + $1.tokens }
        summary.reasoning = min(reasoning.double, summary.output)
        summary.models = models.sorted { ($0.cost ?? -1) > ($1.cost ?? -1) }.prefix(5).map { $0 }
        return .ready(summary)
    }
}

// MARK: - Style

private extension Decimal {
    var double: Double { NSDecimalNumber(decimal: self).doubleValue }
}

private extension Color {
    static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let (r, g, b) = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        })
    }
}

private enum Fmt {
    /// Whole dollars with grouping at $100+, cents below.
    static func money(_ value: Double) -> String {
        let sign = value < 0 ? "−" : ""
        let magnitude = abs(value)
        if magnitude >= 100 { return sign + "$" + magnitude.formatted(.number.precision(.fractionLength(0))) }
        return sign + String(format: "$%.2f", magnitude)
    }

    /// Compact label for chart bars.
    static func bar(_ value: Double) -> String {
        if value >= 10 { return String(format: "$%.0f", value) }
        if value <= 0 { return "$0" }
        return String(format: "$%.2f", value)
    }

    static func axis(_ value: Double) -> String {
        value >= 10 ? String(format: "$%.0f", value) : String(format: "$%.2f", value)
    }

    static func multiple(_ value: Double) -> String {
        String(format: value >= 10 ? "%.0f×" : "%.1f×", value)
    }

    static func share(_ fraction: Double?) -> String {
        guard let fraction else { return "" }
        if fraction > 0, fraction < 0.01 { return "<1%" }
        return "\(Int((fraction * 100).rounded()))%"
    }
}

private extension View {
    /// Frosted card: translucent material, hairline border and a soft lift.
    func glassPanel(radius: CGFloat = 18) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(.thinMaterial, in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5))
            .overlay(shape.inset(by: 0.5).strokeBorder(
                LinearGradient(colors: [.white.opacity(0.18), .clear], startPoint: .top, endPoint: .center),
                lineWidth: 0.5
            ))
            .shadow(color: .black.opacity(0.07), radius: 14, y: 5)
    }

    /// Floating surface for the chart tooltip.
    func floatingGlass(radius: CGFloat = 12) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(.regularMaterial, in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }
}

// MARK: - Dashboard

private struct UsageHistoryDashboard: View {
    @ObservedObject var state: UsageHistorySessionState
    var onRefresh: (() -> Void)?

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.height < 700
            VStack(alignment: .leading, spacing: compact ? 12 : 16) {
                HeaderBar(state: state, onRefresh: onRefresh)
                switch state.content {
                case .unavailable(let title, let detail):
                    EmptyState(title: title, detail: detail)
                case .ready(let summary):
                    HistoryBody(summary: summary, provider: state.provider, range: state.range, compact: compact)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 6)
            .padding(.bottom, compact ? 14 : 20)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .background(Glow(provider: state.provider))
        .ignoresSafeArea()
    }
}

/// Faint colour wash behind the glass so the cards have something to frost. Static, no animation.
private struct Glow: View {
    let provider: UsageHistorySessionState.Provider

    var body: some View {
        ZStack {
            if provider.sources.contains(.claude) {
                RadialGradient(colors: [HistorySource.claude.color.opacity(0.20), .clear], center: .topLeading, startRadius: 0, endRadius: 560)
            }
            if provider.sources.contains(.codex) {
                RadialGradient(colors: [HistorySource.codex.color.opacity(0.18), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 620)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct HeaderBar: View {
    @ObservedObject var state: UsageHistorySessionState
    var onRefresh: (() -> Void)?

    private var subtitle: String {
        guard case .ready(let summary) = state.content else { return "" }
        var parts: [String] = []
        if state.provider == .codex, let seat = summary.seat {
            parts.append("\(seat.label) · \(UIFormatters.costString(Decimal(seat.price)))/mo")
        }
        if summary.sources.count < state.provider.sources.count, let only = summary.sources.first {
            parts.append("\(only.name) only")
        }
        if let updatedAt = summary.updatedAt {
            parts.append("Updated \(UIFormatters.usageUpdatedString(from: updatedAt))")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Usage History")
                    .font(.system(size: 14, weight: .semibold))
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 76)
            Spacer(minLength: 12)
            Picker("Usage source", selection: $state.provider) {
                ForEach(UsageHistorySessionState.Provider.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Picker("History range", selection: $state.range) {
                ForEach(UsageHistorySessionState.RangeFilter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Charts show calendar days through today; menu estimates use rolling 7- and 30-day periods.")
            if let onRefresh {
                RefreshButton(action: onRefresh)
            }
        }
        .frame(height: 36)
    }
}

private struct RefreshButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise").accessibilityLabel("Refresh")
        }
        .buttonStyle(.bordered)
        .help("Refresh")
    }
}

private struct EmptyState: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.system(size: 17, weight: .semibold))
            Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassPanel()
        .accessibilityElement(children: .combine)
    }
}

private struct HistoryBody: View {
    let summary: HistorySummary
    let provider: UsageHistorySessionState.Provider
    let range: UsageHistorySessionState.RangeFilter
    let compact: Bool

    var body: some View {
        Group {
            HeroCard(summary: summary, provider: provider, rangeLabel: rangeLabel, compact: compact)
            ChartCard(summary: summary, compact: compact)
            HStack(alignment: .top, spacing: 16) {
                ModelCard(summary: summary, compact: compact)
                CompositionCard(summary: summary, tint: summary.sources.count == 1 ? summary.sources[0].color : provider.tint, compact: compact)
            }
            .fixedSize(horizontal: false, vertical: true)
            Footer(summary: summary)
        }
    }

    private var rangeLabel: String {
        switch range {
        case .week, .month: return "Last \(summary.days.count) days"
        case .max:
            guard let first = summary.days.first else { return "All time" }
            return "Since " + first.day.formatted(.dateTime.month(.abbreviated).day().year())
        }
    }
}

// MARK: - Hero

private struct Stat {
    let title: String
    let value: String
    let detail: String
}

private struct HeroCard: View {
    let summary: HistorySummary
    let provider: UsageHistorySessionState.Provider
    let rangeLabel: String
    let compact: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 10) {
                Text("API-equivalent value · \(rangeLabel)")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text(Fmt.money(summary.spend))
                    .font(.system(size: compact ? 48 : 60, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                context
            }
            .frame(width: 340, alignment: .leading)

            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(stats.enumerated()), id: \.offset) { index, stat in
                    StatView(stat: stat)
                        .overlay(alignment: .leading) {
                            if index > 0 { Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1) }
                        }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, compact ? 16 : 22)
        .glassPanel(radius: 20)
    }

    @ViewBuilder
    private var context: some View {
        if let seat = summary.seat {
            VStack(spacing: 8) {
                CompareRow(label: "Seat, prorated", amount: seat.prorated, scale: scale, color: .secondary.opacity(0.55))
                CompareRow(label: "Usage at API rates", amount: summary.spend, scale: scale, color: provider.tint)
            }
            .padding(.top, 2)
        } else if summary.sources.count > 1 {
            HStack(spacing: 16) {
                ForEach(summary.sources, id: \.self) { source in
                    HStack(spacing: 6) {
                        Circle().fill(source.color).frame(width: 8, height: 8)
                        Text(source.name).foregroundStyle(.secondary)
                        Text(Fmt.money(summary.spend(of: source))).monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .font(.system(size: 13))
        }
    }

    private var scale: Double {
        max(summary.spend, summary.seat?.prorated ?? 0, 0.0001)
    }

    private var stats: [Stat] {
        var result: [Stat] = []
        if let seat = summary.seat {
            if let index = seat.breakEvenIndex {
                let date = seat.breakEvenDay.map { $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + " · " } ?? ""
                result.append(Stat(title: "Paid for itself", value: "Day \(index)", detail: "\(date)seat covered"))
            } else {
                let multiple = summary.spend / max(seat.prorated, 0.0001)
                result.append(Stat(title: "Paid for itself", value: "Not yet", detail: "\(Fmt.money(max(seat.prorated - summary.spend, 0))) more · \(Fmt.share(multiple)) covered"))
            }
        } else {
            let active = summary.days.filter { $0.tokens > 0 }.count
            result.append(Stat(title: "Daily average", value: Fmt.money(summary.spend / Double(max(summary.days.count, 1))), detail: "\(active) active \(active == 1 ? "day" : "days")"))
            result.append(Stat(title: "Tokens", value: UIFormatters.compactTokenString(summary.tokens), detail: "input, output and cache"))
        }
        result.append(Stat(title: "Prompt cache savings", value: Fmt.money(summary.cacheSavings), detail: cacheDetail))
        if let perPoint = summary.seat?.dollarsPerPoint {
            result.append(Stat(title: "1% of weekly limit", value: Fmt.money(perPoint), detail: "≈ \(Fmt.money(perPoint * 100)) for the full limit"))
        }
        return result
    }

    private var cacheDetail: String {
        if summary.cacheSavings < 0 { return "Writes cost more than reads saved" }
        if summary.cacheSavings == 0 { return "No cached input" }
        return "\(Fmt.money(summary.spend + summary.cacheSavings)) uncached"
    }
}

private struct StatView: View {
    let stat: Stat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(stat.title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(stat.value)
                .font(.system(size: 24, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(stat.detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct CompareRow: View {
    let label: String
    let amount: Double
    let scale: Double
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 112, alignment: .leading)
            Meter(fraction: amount / scale, color: color, height: 8)
            Text(Fmt.money(amount))
                .font(.system(size: 12))
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct Meter: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 5

    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(0.08))
            .frame(height: height)
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    if fraction > 0 {
                        Capsule().fill(color).frame(width: max(height, geometry.size.width * min(fraction, 1)))
                    }
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Chart card

private struct ChartCard: View {
    let summary: HistorySummary
    let compact: Bool

    private var seatPerDay: Double? { summary.seat.map { $0.price / 30 } }
    private var hasActivity: Bool { summary.days.contains { $0.cost > 0 || $0.tokens > 0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Daily value").font(.system(size: 14, weight: .semibold))
                if hasActivity, let subtitle {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 12)
                legend
            }
            Group {
                if hasActivity {
                    CostChart(days: summary.days, sources: summary.sources, seatPerDay: seatPerDay, rangeTotal: summary.spend)
                } else {
                    Text("No activity in this range")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minHeight: 90, maxHeight: .infinity)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, compact ? 14 : 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassPanel()
    }

    private var subtitle: String? {
        guard let seatPerDay else { return nil }
        let cleared = summary.days.filter { $0.cost >= seatPerDay }.count
        let rate = Fmt.money(seatPerDay)
        if cleared == summary.days.count { return "Every day cleared the seat’s \(rate)/day" }
        return "\(cleared) of \(summary.days.count) days cleared the seat’s \(rate)/day"
    }

    @ViewBuilder
    private var legend: some View {
        HStack(spacing: 14) {
            if summary.sources.count > 1 {
                ForEach(summary.sources, id: \.self) { source in
                    HStack(spacing: 5) {
                        Circle().fill(source.color).frame(width: 8, height: 8)
                        Text(source.name)
                    }
                }
            }
            if seatPerDay != nil {
                HStack(spacing: 5) {
                    Capsule().fill(Color.primary.opacity(0.45)).frame(width: 14, height: 2)
                    Text("Seat cost per day")
                }
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }
}

private struct CostChart: View {
    let days: [HistoryDay]
    let sources: [HistorySource]
    let seatPerDay: Double?
    let rangeTotal: Double

    private var dense: Bool { days.count > 14 }
    // Read per bar, so computed once rather than per access (a Max range has 400+ bars).
    private let todayID: Date
    private let peakID: Date?

    init(days: [HistoryDay], sources: [HistorySource], seatPerDay: Double?, rangeTotal: Double) {
        self.days = days
        self.sources = sources
        self.seatPerDay = seatPerDay
        self.rangeTotal = rangeTotal
        todayID = Calendar.current.startOfDay(for: Date())
        peakID = days.max { $0.cost < $1.cost }?.id
    }

    /// Nice tick step and top, with headroom above the tallest bar for its label.
    private var scale: (step: Double, top: Double, domainTop: Double) {
        let peak = max(days.map(\.cost).max() ?? 0, seatPerDay ?? 0, 0.01)
        let step = niceStep(peak / 4)
        let top = max(step, (peak / step).rounded(.up) * step)
        return (step, top, max(top, peak / 0.82))
    }

    private var yTicks: [Double] {
        dense ? Array(stride(from: 0, through: scale.top + 1e-9, by: scale.step)) : [0]
    }

    /// Dense ranges keep about eight labels, aligned to today; ranges past 90 days label month starts so names never skip.
    /// Placed at noon, the centre of each day's bar.
    private var xLabels: [XLabels.Label] {
        let step = dense ? max(7, Int((Double(days.count) / 8 / 7).rounded(.up)) * 7) : 1
        let monthStarts = days.count > 90
        let shown = days.enumerated().filter { offset, day in
            let fromEnd = days.count - 1 - offset
            guard monthStarts else { return fromEnd % step == 0 }
            return fromEnd == 0 || (fromEnd > 10 && Calendar.current.component(.day, from: day.day) == 1)
        }
        return shown.map { XLabels.Label(date: $0.element.day.addingTimeInterval(12 * 3600), text: axisLabel(for: $0.element.day), isToday: $0.element.id == todayID) }
    }

    var body: some View {
        Chart {
            ForEach(days) { day in
                ForEach(sources, id: \.self) { source in
                    if day.cost(of: source) > 0 {
                        BarMark(
                            x: .value("Day", day.day, unit: .day),
                            y: .value("Value", day.cost(of: source)),
                            width: .ratio(days.count > 90 ? 0.9 : dense ? 0.8 : 0.55)
                        )
                        .cornerRadius(2.5)
                        .foregroundStyle(by: .value("Source", source.name))
                        .opacity(day.id == todayID ? 0.65 : 1)
                        .accessibilityLabel("\(day.day.formatted(.dateTime.weekday(.wide).day().month(.wide))), \(source.name)")
                        .accessibilityValue(Fmt.money(day.cost(of: source)))
                    }
                }
                if let label = barLabel(for: day) {
                    PointMark(x: .value("Day", day.day.addingTimeInterval(12 * 3600)), y: .value("Total", day.cost))
                        .foregroundStyle(Color.clear)
                        .annotation(position: .top, spacing: 2) {
                            Text(label)
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(day.id == peakID ? .primary : .secondary)
                                .fixedSize()
                        }
                }
            }
            if let seatPerDay {
                RuleMark(y: .value("Seat cost per day", seatPerDay))
                    .foregroundStyle(Color.primary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .accessibilityLabel("Seat cost per day")
                    .accessibilityValue(Fmt.money(seatPerDay))
            }
        }
        .chartForegroundStyleScale(domain: sources.map(\.name), range: sources.map(\.color))
        .chartLegend(.hidden)
        .chartYScale(domain: 0...scale.domainTop)
        .chartXAxis(.hidden)
        .chartPlotStyle { $0.padding(.bottom, 22) }
        .chartYAxis {
            AxisMarks(position: .trailing, values: yTicks) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel(anchor: .leading) {
                    if dense, let number = value.as(Double.self), number > 0 {
                        Text(Fmt.axis(number))
                    }
                }
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(Color.secondary)
            }
        }
        .chartOverlay { proxy in
            ZStack {
                XLabels(proxy: proxy, labels: xLabels)
                ChartHover(proxy: proxy, days: days, sources: sources, seatPerDay: seatPerDay, rangeTotal: rangeTotal, todayID: todayID)
            }
        }
        .accessibilityLabel("Daily API-equivalent value")
    }

    private func barLabel(for day: HistoryDay) -> String? {
        if dense { return day.id == peakID ? Fmt.bar(day.cost) : nil }
        guard day.cost > 0 else { return nil }
        return day.id == todayID ? "\(Fmt.bar(day.cost)) so far" : Fmt.bar(day.cost)
    }

    private func axisLabel(for date: Date) -> String {
        if date == todayID { return "Today" }
        if days.count > 90 {
            let january = Calendar.current.component(.month, from: date) == 1
            return january ? date.formatted(.dateTime.month(.abbreviated).year()) : date.formatted(.dateTime.month(.abbreviated))
        }
        if dense { return date.formatted(.dateTime.day().month(.abbreviated)) }
        return date.formatted(.dateTime.weekday(.abbreviated).day())
    }
}

/// Day labels drawn from the chart's own scale, so they sit exactly under each bar.
private struct XLabels: View {
    struct Label {
        let date: Date
        let text: String
        let isToday: Bool
    }

    let proxy: ChartProxy
    let labels: [Label]

    var body: some View {
        GeometryReader { geometry in
            let plot = proxy.plotFrame.map { geometry[$0] } ?? .zero
            ForEach(labels, id: \.date) { label in
                if let x = proxy.position(forX: label.date) {
                    Text(label.text)
                        .font(.system(size: 11))
                        .foregroundStyle(label.isToday ? Color.primary : Color.secondary)
                        .fixedSize()
                        .position(x: plot.minX + x, y: plot.maxY + 13)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

@MainActor
private final class ChartHoverState: ObservableObject {
    @Published var index: Int?
}

/// Hover highlight and tooltip. Owns its own state so hovering never re-evaluates the chart.
private struct ChartHover: View {
    let proxy: ChartProxy
    let days: [HistoryDay]
    let sources: [HistorySource]
    let seatPerDay: Double?
    let rangeTotal: Double
    let todayID: Date
    @StateObject private var hover = ChartHoverState()

    var body: some View {
        GeometryReader { geometry in
            let plot = proxy.plotFrame.map { geometry[$0] } ?? .zero
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point): hover.index = dayIndex(atX: point.x - plot.minX, width: plot.width)
                        case .ended: hover.index = nil
                        }
                    }
                if let index = hover.index, days.indices.contains(index), let column = column(of: days[index], in: plot) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                        .frame(width: column.width, height: plot.height)
                        .offset(x: column.minX, y: plot.minY)
                        .allowsHitTesting(false)
                    tooltip(days[index], column: column, width: geometry.size.width, top: plot.minY)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func tooltip(_ day: HistoryDay, column: Column, width: CGFloat, top: CGFloat) -> some View {
        let onRight = (column.minX + column.width / 2) < width * 0.6
        return HStack(spacing: 0) {
            if onRight {
                Spacer().frame(width: column.maxX + 8)
                ChartTooltip(day: day, sources: sources, isToday: day.id == todayID, rangeTotal: rangeTotal, seatPerDay: seatPerDay)
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                ChartTooltip(day: day, sources: sources, isToday: day.id == todayID, rangeTotal: rangeTotal, seatPerDay: seatPerDay)
                Spacer().frame(width: width - column.minX + 8)
            }
        }
        .frame(width: width, alignment: .top)
        .padding(.top, top + 6)
    }

    private struct Column {
        let minX: CGFloat
        let width: CGFloat
        let maxX: CGFloat
    }

    private func dayIndex(atX x: CGFloat, width: CGFloat) -> Int? {
        guard x >= 0, x <= width, let first = days.first?.day,
              let date = proxy.value(atX: x, as: Date.self) else { return nil }
        let offset = Calendar.current.dateComponents([.day], from: first, to: date).day ?? 0
        return min(max(offset, 0), days.count - 1)
    }

    private func column(of day: HistoryDay, in plot: CGRect) -> Column? {
        guard let next = Calendar.current.date(byAdding: .day, value: 1, to: day.day),
              let start = proxy.position(forX: day.day), let end = proxy.position(forX: next) else { return nil }
        let minX = plot.minX + start
        return Column(minX: minX, width: end - start, maxX: plot.minX + end)
    }
}

private struct ChartTooltip: View {
    let day: HistoryDay
    let sources: [HistorySource]
    let isToday: Bool
    let rangeTotal: Double
    let seatPerDay: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(day.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + (isToday ? " · so far" : ""))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(Fmt.money(day.cost))
                .font(.system(size: 17, weight: .semibold))
                .monospacedDigit()
            if sources.count > 1 {
                ForEach(sources, id: \.self) { source in
                    HStack(spacing: 5) {
                        Circle().fill(source.color).frame(width: 6, height: 6)
                        Text(source.name)
                        Spacer(minLength: 10)
                        Text(Fmt.money(day.cost(of: source))).monospacedDigit()
                    }
                    .font(.system(size: 11))
                }
            }
            Text("\(UIFormatters.compactTokenString(day.tokens)) tokens · \(Fmt.share(rangeTotal > 0 ? day.cost / rangeTotal : 0)) of range")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if let seatPerDay, seatPerDay > 0 {
                Text(String(format: "%.1f× the daily seat cost", day.cost / seatPerDay))
                    .font(.system(size: 11))
            }
            if day.cacheSavings > 0 {
                Text("Cache saved \(Fmt.money(day.cacheSavings))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if let topModel = day.topModel {
                Text(topModel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize()
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .floatingGlass()
    }
}

// MARK: - Bottom cards

private struct ModelCard: View {
    let summary: HistorySummary
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            Text("By model").font(.system(size: 14, weight: .semibold))
            if summary.models.isEmpty {
                Text("No activity in this range")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(summary.models.prefix(compact ? 3 : 5)) { row in
                    let share = row.cost.map { summary.spend > 0 ? $0 / summary.spend : 0 }
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 10) {
                            Text(row.name)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 12)
                            Text(row.cost.map(Fmt.money) ?? "Unpriced")
                                .font(.system(size: 13))
                                .monospacedDigit()
                            Text(Fmt.share(share))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .frame(width: 38, alignment: .trailing)
                        }
                        Meter(fraction: share ?? 0, color: row.source.color)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, compact ? 14 : 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassPanel()
    }
}

private struct CompositionCard: View {
    let summary: HistorySummary
    let tint: Color
    let compact: Bool

    var body: some View {
        let total = summary.input + summary.output
        let hasData = total > 0
        let inputColor = Color.primary.opacity(0.25)

        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Input vs output").font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 8)
                if hasData {
                    Text("of \(Fmt.money(total))").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }

            if hasData {
                GeometryReader { geometry in
                    let available = max(geometry.size.width - 4, 0)
                    HStack(spacing: 2) {
                        Capsule().fill(inputColor).frame(width: available * summary.input / total)
                        Capsule().fill(tint).frame(width: available * (summary.output - summary.reasoning) / total)
                        if summary.reasoning > 0 {
                            Capsule().fill(tint.opacity(0.45)).frame(width: available * summary.reasoning / total)
                        }
                    }
                }
                .frame(height: 10)
                .accessibilityHidden(true)

                HStack(alignment: .top, spacing: 12) {
                    CompositionStat(label: "Input", value: summary.input, share: summary.input / total, color: inputColor)
                    CompositionStat(label: "Output", value: summary.output - summary.reasoning, share: (summary.output - summary.reasoning) / total, color: tint)
                    if summary.reasoning > 0 {
                        CompositionStat(label: "Reasoning", value: summary.reasoning, share: summary.reasoning / total, color: tint.opacity(0.45))
                    }
                }
            } else {
                Text("No activity in this range")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, compact ? 14 : 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassPanel()
    }
}

private struct CompositionStat: View {
    let label: String
    let value: Double
    let share: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(Fmt.money(value)).font(.system(size: 18, weight: .semibold)).monospacedDigit()
                Text(Fmt.share(share)).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct Footer: View {
    let summary: HistorySummary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(note)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            if let credit = summary.creditShare {
                Text("\(credit)% of tokens on ChatGPT credits").lineLimit(1).fixedSize()
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    private var note: String {
        if summary.hasLegacyStats {
            return "Estimated at API list prices, not what you were charged. Charts use detailed logs; menu all-time totals also include older stats."
        }
        return "Estimated at API list prices, not what you were charged." + (summary.hasUnpriced ? " Unpriced models are excluded." : "")
    }
}

private func niceStep(_ raw: Double) -> Double {
    guard raw > 0 else { return 1 }
    let magnitude = pow(10, floor(log10(raw)))
    let residual = raw / magnitude
    let nice: Double = residual <= 1 ? 1 : residual <= 2 ? 2 : residual <= 5 ? 5 : 10
    return nice * magnitude
}
