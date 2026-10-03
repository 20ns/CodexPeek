/* Seat-value ledger · subscription arbitrage vs API-equivalent market rate */
import AppKit
import Charts
import SwiftUI

@MainActor
final class UsageHistoryWindowController: NSWindowController, NSWindowDelegate {
    private let sessionState = UsageHistorySessionState()
    private let host: NSHostingView<UsageHistoryDashboard>
    private let onClose: () -> Void
    private let onRefresh: (() -> Void)?

    init(onRefresh: (() -> Void)? = nil, onClose: @escaping () -> Void) {
        self.onClose = onClose
        self.onRefresh = onRefresh
        let root = UsageHistoryDashboard(onRefresh: onRefresh, sessionState: sessionState)
        host = NSHostingView(rootView: root)
        let contentSize = NSSize(width: 1120, height: 760)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CodexPeek Usage History"
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
        claudeReport: TokenUsageReport?,
        planHistory: PlanUsageHistory,
        snapshot: CodexUsageSnapshot?,
        accountPlan: CodexPlanType = .unknown
    ) {
        updateRoot(report: report, claudeReport: claudeReport, planHistory: planHistory, snapshot: snapshot, accountPlan: accountPlan)
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
        updateRoot(report: report, claudeReport: claudeReport, planHistory: planHistory, snapshot: snapshot, accountPlan: accountPlan)
    }

    private func updateRoot(
        report: TokenUsageReport?,
        claudeReport: TokenUsageReport?,
        planHistory: PlanUsageHistory,
        snapshot: CodexUsageSnapshot?,
        accountPlan: CodexPlanType
    ) {
        host.rootView = UsageHistoryDashboard(
            report: report,
            claudeReport: claudeReport,
            planHistory: planHistory,
            snapshot: snapshot,
            accountPlan: accountPlan,
            onRefresh: onRefresh,
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

    enum Provider: String, CaseIterable, Identifiable {
        case codex = "Codex"
        case claude = "Claude Code"
        case all = "Combined"
        var id: String { rawValue }
    }

    @Published var provider: Provider = .codex
    @Published var range: RangeFilter = .week
    @Published var hoverDay: Date?
}

private enum SeatPalette {
    static let canvas = Color(red: 0.043, green: 0.055, blue: 0.071)
    static let panel = Color(red: 0.078, green: 0.098, blue: 0.122)
    static let track = Color(red: 0.106, green: 0.129, blue: 0.161)
    static let line = Color(red: 0.173, green: 0.208, blue: 0.259)
    static let hairline = Color(red: 0.133, green: 0.165, blue: 0.204)
    static let text = Color(red: 0.910, green: 0.894, blue: 0.863)
    static let secondary = Color(red: 0.725, green: 0.745, blue: 0.776)
    static let muted = Color(red: 0.545, green: 0.576, blue: 0.627)
    static let faint = Color(red: 0.353, green: 0.396, blue: 0.451)
    static let brass = Color(red: 0.769, green: 0.639, blue: 0.353)
    static let brassShadow = Color(red: 0.420, green: 0.353, blue: 0.200)
    static let cyan = Color(red: 0.239, green: 0.722, blue: 0.773)
    static let input = Color(red: 0.435, green: 0.510, blue: 0.600)
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

/// One money format for the whole window: whole dollars with grouping at $100+, cents below.
private enum SeatFormat {
    static func money(_ value: Decimal) -> String {
        money(double(value))
    }

    static func money(_ value: Double) -> String {
        if value >= 100 {
            return "$" + value.formatted(.number.precision(.fractionLength(0)))
        }
        return String(format: "$%.2f", value)
    }

    /// Compact label for chart bars.
    static func bar(_ value: Double) -> String {
        if value >= 10 { return String(format: "$%.0f", value) }
        if value <= 0 { return "$0" }
        return String(format: "$%.2f", value)
    }

    static func multiple(_ value: Double) -> String {
        if value >= 100 { return String(format: "%.0f×", value) }
        if value >= 10 { return String(format: "%.1f×", value) }
        return String(format: "%.2f×", value)
    }

    static func share(_ fraction: Double?) -> String {
        guard let fraction else { return "—" }
        if fraction > 0, fraction < 0.01 { return "<1%" }
        return "\(Int((fraction * 100).rounded()))%"
    }

    static func double(_ value: Decimal) -> Double {
        NSDecimalNumber(decimal: value).doubleValue
    }
}

private struct UsageHistoryDashboard: View {
    var report: TokenUsageReport?
    var claudeReport: TokenUsageReport?
    var planHistory = PlanUsageHistory()
    var snapshot: CodexUsageSnapshot?
    var accountPlan: CodexPlanType = .unknown
    var onRefresh: (() -> Void)? = nil
    @ObservedObject var sessionState: UsageHistorySessionState

    private var planType: CodexPlanType {
        guard sessionState.provider == .codex else { return .unknown }
        let fromSnapshot = snapshot?.account.planType ?? .unknown
        if fromSnapshot != .unknown { return fromSnapshot }
        return accountPlan
    }

    private var building: Bool {
        switch sessionState.provider {
        case .codex: return report?.history == nil
        case .claude: return claudeReport?.history == nil
        case .all: return report?.history == nil || claudeReport?.history == nil
        }
    }

    private var selectedBuckets: [TokenUsageBucket] {
        switch sessionState.provider {
        case .codex: return report?.history?.buckets ?? []
        case .claude: return claudeReport?.history?.buckets ?? []
        case .all: return (report?.history?.buckets ?? []) + (claudeReport?.history?.buckets ?? [])
        }
    }

    var body: some View {
        let buckets = selectedBuckets
        let dayCount = dayCount(for: sessionState.range, buckets: buckets)
        let allowance = UsageHistoryAnalytics.allowanceYield(from: buckets, history: sessionState.provider == .codex ? planHistory : PlanUsageHistory())
        let value = UsageHistoryAnalytics.subscriptionValue(
            from: buckets,
            days: dayCount,
            planType: planType,
            allowance: allowance
        )
        let chartDays = value.daily.map(DaySnapshot.init)
        let rangePhrase = "last \(dayCount) calendar days"

        GeometryReader { proxy in
            let compact = proxy.size.height < 700
            VStack(alignment: .leading, spacing: compact ? 12 : 18) {
                header(value: value)
                ValueHero(value: value, rangePhrase: rangePhrase, building: building, compact: compact, comparesSeat: sessionState.provider == .codex)
                burnPanel(value: value, days: chartDays, compact: compact)
                HStack(alignment: .top, spacing: 16) {
                    ModelValueCard(
                        models: value.topModelsByValue,
                        total: value.apiEquivalentSpend,
                        building: building,
                        empty: value.daily.allSatisfy { $0.totalTokens == 0 },
                        compact: compact
                    )
                    CompositionCard(value: value, building: building, compact: compact)
                }
                .fixedSize(horizontal: false, vertical: true)
                footer(value: value)
            }
            .padding(.horizontal, compact ? 22 : 28)
            .padding(.top, compact ? 18 : 24)
            .padding(.bottom, compact ? 14 : 20)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .background(SeatPalette.canvas)
        .preferredColorScheme(.dark)
        .tint(SeatPalette.brass)
        .onChange(of: sessionState.provider) { _, _ in
            sessionState.hoverDay = nil
        }
        .onChange(of: sessionState.range) { _, _ in
            sessionState.hoverDay = nil
        }
    }

    // MARK: Header

    private func header(value: SubscriptionValueReport) -> some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(sessionState.provider == .codex ? "Seat value" : "API value")
                    .font(SeatType.body(15, weight: .semibold))
                    .foregroundStyle(SeatPalette.text)
                Text(planLine(value))
                    .font(SeatType.body(13))
                    .foregroundStyle(SeatPalette.muted)
            }
            Spacer(minLength: 12)
            Picker("Usage source", selection: $sessionState.provider) {
                ForEach(UsageHistorySessionState.Provider.allCases) { provider in
                    Text(provider.rawValue).tag(provider)
                }
            }
            .labelsHidden()
            .frame(width: 130)
            .accessibilityLabel("Usage source")
            Text(updatedLine)
                .font(SeatType.data(11))
                .foregroundStyle(SeatPalette.muted)
                .lineLimit(1)
            RangeSwitcher(selection: $sessionState.range)
                .help("Charts show calendar days through today; menu estimates use rolling 7- and 30-day periods.")
            if let onRefresh {
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SeatPalette.secondary)
                        .frame(width: 30, height: 30)
                        .background(SeatPalette.panel, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(SeatPalette.line, lineWidth: 1))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help("Refresh")
                .accessibilityLabel("Refresh")
            }
        }
    }

    private func planLine(_ value: SubscriptionValueReport) -> String {
        guard sessionState.provider == .codex else { return sessionState.provider.rawValue }
        if let price = value.listPriceUSD {
            return "\(value.planType.seatLabel) · \(UIFormatters.costString(price))/mo"
        }
        return value.planType == .unknown ? "Plan unknown" : value.planType.seatLabel
    }

    private var updatedLine: String {
        if building { return "Reading session logs…" }
        if sessionState.provider != .codex {
            return "Local session logs"
        }
        guard let snapshot else { return "Local session logs" }
        return "Updated \(UIFormatters.usageUpdatedString(from: snapshot.lastUpdatedAt))"
    }

    // MARK: Chart panel

    private func burnPanel(value: SubscriptionValueReport, days: [DaySnapshot], compact: Bool) -> some View {
        let seatPerDay = value.listPriceUSD.map { SeatFormat.double($0) / 30 }
        let total = SeatFormat.double(value.apiEquivalentSpend)
        let hasActivity = !days.allSatisfy { $0.cost == 0 && $0.tokens == 0 }

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Daily value")
                    .font(SeatType.body(15, weight: .semibold))
                    .foregroundStyle(SeatPalette.text)
                if !building, hasActivity {
                    Text(chartSubtitle(days: days, seatPerDay: seatPerDay))
                        .font(SeatType.body(12))
                        .foregroundStyle(SeatPalette.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                HStack(spacing: 16) {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(SeatPalette.brass).frame(width: 10, height: 10)
                        Text("API-equivalent")
                    }
                    if seatPerDay != nil {
                        HStack(spacing: 6) {
                            DashedLine().stroke(SeatPalette.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                                .frame(width: 14, height: 1.5)
                            Text("Seat cost per day")
                        }
                    }
                }
                .font(SeatType.body(12))
                .foregroundStyle(SeatPalette.muted)
                .accessibilityElement(children: .combine)
            }

            Group {
                if building {
                    ChartPlaceholder(message: "Building history from local sessions…")
                } else if !hasActivity {
                    ChartPlaceholder(message: "No activity in this range")
                } else {
                    CostChart(days: days, seatPerDay: seatPerDay, rangeTotal: total, hoverDay: $sessionState.hoverDay)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 90, maxHeight: .infinity)
        }
        .padding(.horizontal, compact ? 18 : 20)
        .padding(.vertical, compact ? 14 : 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SeatPalette.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(SeatPalette.line, lineWidth: 1))
    }

    private func chartSubtitle(days: [DaySnapshot], seatPerDay: Double?) -> String {
        guard let seatPerDay, !days.isEmpty else { return "API-equivalent, by day" }
        let cleared = days.filter { $0.cost >= seatPerDay }.count
        let rate = SeatFormat.money(seatPerDay)
        if cleared == days.count { return "Every day cleared the seat’s \(rate)/day" }
        return "\(cleared) of \(days.count) days cleared the seat’s \(rate)/day"
    }

    // MARK: Footer

    private func footer(value: SubscriptionValueReport) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(sessionState.provider != .codex && claudeReport?.legacyStats != nil
                ? "Daily charts use detailed logs. All-time menu totals also include older stats with 5m cache writes assumed."
                : value.hasUnpricedUsage
                ? "Estimated at API list prices, not what you were charged. Unpriced models are excluded."
                : "Estimated at API list prices, not what you were charged. From retained local logs.")
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            if sessionState.provider == .codex, !building, let credit = value.creditModeSharePercent {
                Text("\(credit)% of tokens on ChatGPT credits")
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .font(SeatType.body(11))
        .foregroundStyle(SeatPalette.muted)
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
}

// MARK: - Range switcher

private struct RangeSwitcher: View {
    @Binding var selection: UsageHistorySessionState.RangeFilter

    var body: some View {
        HStack(spacing: 2) {
            ForEach(UsageHistorySessionState.RangeFilter.allCases) { filter in
                let selected = filter == selection
                Button {
                    selection = filter
                } label: {
                    Text(filter.title)
                        .font(SeatType.body(13, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? SeatPalette.canvas : SeatPalette.secondary)
                        .padding(.horizontal, 14)
                        .frame(height: 26)
                        .background(selected ? SeatPalette.brass : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(SeatPalette.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(SeatPalette.line, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("History range")
    }
}

// MARK: - Hero

private struct ValueHero: View {
    let value: SubscriptionValueReport
    let rangePhrase: String
    let building: Bool
    let compact: Bool
    var comparesSeat = true

    private var spend: Double { SeatFormat.double(value.apiEquivalentSpend) }
    private var seat: Double? { value.proratedSeatCost.map(SeatFormat.double) }

    var body: some View {
        HStack(alignment: .bottom, spacing: 48) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("API-equivalent value, \(rangePhrase)")
                        .font(SeatType.body(13))
                        .foregroundStyle(SeatPalette.muted)
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Text(building ? "—" : SeatFormat.money(spend))
                            .font(SeatType.hero(compact ? 54 : 68))
                            .foregroundStyle(building ? SeatPalette.faint : SeatPalette.brass)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        caption
                    }
                }

                if value.listPriceUSD != nil || building {
                    VStack(alignment: .leading, spacing: 10) {
                        comparisonRow(
                            label: "Seat, prorated",
                            amount: seat,
                            fill: SeatPalette.muted,
                            valueColor: SeatPalette.secondary
                        )
                        comparisonRow(
                            label: "Usage at API rates",
                            amount: building ? nil : spend,
                            fill: SeatPalette.brass,
                            valueColor: SeatPalette.text
                        )
                    }
                } else {
                    Text(!comparesSeat
                        ? "API-equivalent value from retained local logs, including prompt cache reads and writes. Subscription comparisons are available in the Codex view."
                        : value.planType == .free
                        ? "The Free plan has no seat price, so there’s nothing to compare against."
                        : "Plan unknown, so there’s no seat price to compare against. Sign in to Codex and CodexPeek will pick up your plan.")
                        .font(SeatType.body(12))
                        .foregroundStyle(SeatPalette.secondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(SeatPalette.line, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            StatList(value: value, building: building, compact: compact, comparesSeat: comparesSeat)
                .frame(maxWidth: 452)
        }
        .padding(.bottom, compact ? 12 : 18)
        .overlay(alignment: .bottom) {
            Rectangle().fill(SeatPalette.line).frame(height: 1)
        }
    }

    @ViewBuilder
    private var caption: some View {
        if building {
            Text("Reading local session logs…")
                .font(SeatType.body(17))
                .foregroundStyle(SeatPalette.secondary)
        } else if let multiple = value.openMarketMultiple, value.listPriceUSD != nil {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(multiple >= 1 ? SeatFormat.multiple(multiple) : SeatFormat.share(multiple))
                    .font(SeatType.body(17, weight: .semibold))
                    .foregroundStyle(SeatPalette.text)
                    .monospacedDigit()
                Text(multiple >= 1 ? "what the seat cost" : "of the seat cost covered")
                    .font(SeatType.body(17))
                    .foregroundStyle(SeatPalette.secondary)
            }
            .lineLimit(1)
            .accessibilityElement(children: .combine)
        } else {
            Text("at API list prices")
                .font(SeatType.body(17))
                .foregroundStyle(SeatPalette.secondary)
        }
    }

    private func comparisonRow(label: String, amount: Double?, fill: Color, valueColor: Color) -> some View {
        let scale = max(spend, seat ?? 0, 0.0001)
        return HStack(spacing: 12) {
            Text(label)
                .font(SeatType.body(12))
                .foregroundStyle(SeatPalette.muted)
                .frame(width: 120, alignment: .leading)
            MeterBar(fraction: (amount ?? 0) / scale, fill: fill, height: 10)
            Text(amount.map(SeatFormat.money) ?? "—")
                .font(SeatType.data(12))
                .foregroundStyle(valueColor)
                .monospacedDigit()
                .frame(width: 72, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct StatList: View {
    let value: SubscriptionValueReport
    let building: Bool
    let compact: Bool
    var comparesSeat = true

    var body: some View {
        VStack(spacing: 0) {
            if comparesSeat { StatRow(
                title: "Paid for itself",
                detail: breakEven.detail,
                value: breakEven.value,
                tint: breakEven.tint,
                padding: compact ? 8 : 12,
                divider: true
            ) }
            StatRow(
                title: "Prompt cache savings",
                detail: cacheDetail,
                value: building ? "—" : SeatFormat.money(value.cacheRebate),
                tint: building ? SeatPalette.faint : SeatPalette.cyan,
                padding: compact ? 8 : 12,
                divider: true
            )
            if comparesSeat { StatRow(
                title: "Value of 1% of weekly limit",
                detail: pointDetail,
                value: value.dollarsPerAllowancePoint.map(SeatFormat.money) ?? "—",
                tint: SeatPalette.text,
                padding: compact ? 8 : 12,
                divider: false
            ) }
        }
    }

    private var breakEven: (value: String, detail: String, tint: Color) {
        if building {
            return ("—", "Waiting for history", SeatPalette.text)
        }
        guard let seat = value.proratedSeatCost else {
            return ("—", value.planType == .free ? "No seat price on Free" : "Needs your plan price", SeatPalette.text)
        }
        if let index = value.breakEvenDayIndex {
            let date = value.breakEvenDay.map {
                $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + " · "
            } ?? ""
            return ("Day \(index)", "\(date)seat covered", SeatPalette.text)
        }
        let remaining = max(seat - value.apiEquivalentSpend, 0)
        return ("Not yet", "\(SeatFormat.money(remaining)) more to cover the seat", SeatPalette.secondary)
    }

    private var cacheDetail: String {
        if building { return "Waiting for history" }
        if value.cacheRebate < 0 { return "Cache writes cost more than reads saved" }
        guard value.cacheRebate > 0 else { return "No cached input in this range" }
        return "\(SeatFormat.money(value.apiEquivalentSpend + value.cacheRebate)) at uncached input rates"
    }

    private var pointDetail: String {
        if let perPoint = value.dollarsPerAllowancePoint {
            return "≈ \(SeatFormat.money(perPoint * 100)) for 100% of the weekly limit"
        }
        return building ? "Waiting for history" : "Needs weekly limit data"
    }
}

private struct StatRow: View {
    let title: String
    let detail: String
    let value: String
    let tint: Color
    let padding: CGFloat
    let divider: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(SeatType.body(13))
                    .foregroundStyle(SeatPalette.text)
                Text(detail)
                    .font(SeatType.body(12))
                    .foregroundStyle(SeatPalette.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Text(value)
                .font(SeatType.body(20, weight: .semibold))
                .foregroundStyle(tint)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.vertical, padding)
        .overlay(alignment: .bottom) {
            if divider {
                Rectangle().fill(SeatPalette.hairline).frame(height: 1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Bottom cards

private struct ModelValueCard: View {
    let models: [SubscriptionModelValue]
    let total: Decimal
    let building: Bool
    let empty: Bool
    let compact: Bool

    var body: some View {
        let totalValue = SeatFormat.double(total)
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            Text("By model")
                .font(SeatType.body(15, weight: .semibold))
                .foregroundStyle(SeatPalette.text)

            if models.isEmpty {
                Text(building ? "Models appear once sessions are read." : empty ? "No activity in this range" : "No priced models in range")
                    .font(SeatType.body(13))
                    .foregroundStyle(SeatPalette.muted)
            } else {
                ForEach(models, id: \.model) { model in
                    let cost = model.cost.map(SeatFormat.double)
                    let share = cost.map { totalValue > 0 ? $0 / totalValue : 0 }
                    HStack(spacing: 12) {
                        Text(TokenPricingCatalog.standard.displayModelName(for: model.model))
                            .font(SeatType.body(13, weight: .medium))
                            .foregroundStyle(SeatPalette.text)
                            .lineLimit(1)
                            .frame(width: 104, alignment: .leading)
                        MeterBar(fraction: share ?? 0, fill: SeatPalette.brass, height: 8)
                        Text(cost.map(SeatFormat.money) ?? "unpriced")
                            .font(SeatType.data(12))
                            .foregroundStyle(SeatPalette.text)
                            .monospacedDigit()
                            .frame(width: 72, alignment: .trailing)
                        Text(SeatFormat.share(share))
                            .font(SeatType.body(12))
                            .foregroundStyle(SeatPalette.muted)
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(.horizontal, compact ? 18 : 20)
        .padding(.vertical, compact ? 14 : 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SeatPalette.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(SeatPalette.line, lineWidth: 1))
    }
}

private struct CompositionCard: View {
    let value: SubscriptionValueReport
    let building: Bool
    let compact: Bool

    var body: some View {
        let input = SeatFormat.double(value.contextCostUSD)
        let output = SeatFormat.double(value.generationCostUSD)
        let reasoning = min(value.reasoningTaxUSD.map(SeatFormat.double) ?? 0, output)
        let total = input + output
        let hasData = !building && total > 0

        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Input vs output")
                    .font(SeatType.body(15, weight: .semibold))
                    .foregroundStyle(SeatPalette.text)
                Spacer(minLength: 8)
                if hasData {
                    Text("of \(SeatFormat.money(total))")
                        .font(SeatType.body(12))
                        .foregroundStyle(SeatPalette.muted)
                }
            }

            GeometryReader { geometry in
                let available = max(geometry.size.width - 4, 0)
                HStack(spacing: 2) {
                    if hasData {
                        Rectangle().fill(SeatPalette.input)
                            .frame(width: available * input / total)
                        Rectangle().fill(SeatPalette.brass)
                            .frame(width: available * (output - reasoning) / total)
                        StripeFill()
                            .frame(width: available * reasoning / total)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
                .background(SeatPalette.track)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .frame(height: 12)
            .accessibilityHidden(true)

            HStack(alignment: .top, spacing: 12) {
                CompositionStat(
                    label: "Input (context)",
                    value: hasData ? SeatFormat.money(input) : "—",
                    share: hasData ? SeatFormat.share(input / total) : ""
                ) {
                    RoundedRectangle(cornerRadius: 2).fill(SeatPalette.input)
                }
                CompositionStat(
                    label: "Output",
                    value: hasData ? SeatFormat.money(output) : "—",
                    share: hasData ? SeatFormat.share(output / total) : ""
                ) {
                    RoundedRectangle(cornerRadius: 2).fill(SeatPalette.brass)
                }
                CompositionStat(
                    label: "Reasoning",
                    value: hasData && value.reasoningTaxUSD != nil ? SeatFormat.money(reasoning) : "—",
                    share: hasData && output > 0 && value.reasoningTaxUSD != nil ? "\(SeatFormat.share(reasoning / output)) of output" : ""
                ) {
                    StripeFill().clipShape(RoundedRectangle(cornerRadius: 2))
                }
            }
        }
        .padding(.horizontal, compact ? 18 : 20)
        .padding(.vertical, compact ? 14 : 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SeatPalette.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(SeatPalette.line, lineWidth: 1))
    }
}

private struct CompositionStat<Swatch: View>: View {
    let label: String
    let value: String
    let share: String
    @ViewBuilder let swatch: () -> Swatch

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                swatch().frame(width: 8, height: 8)
                Text(label)
                    .font(SeatType.body(12))
                    .foregroundStyle(SeatPalette.muted)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(SeatType.body(17, weight: .semibold))
                    .foregroundStyle(SeatPalette.text)
                    .monospacedDigit()
                if !share.isEmpty {
                    Text(share)
                        .font(SeatType.body(12))
                        .foregroundStyle(SeatPalette.muted)
                }
            }
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Shared pieces

private struct MeterBar: View {
    let fraction: Double
    let fill: Color
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(SeatPalette.track)
                if fraction > 0 {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(fill)
                        .frame(width: max(3, geometry.size.width * min(fraction, 1)))
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// Diagonal brass hatching used for the reasoning share of output.
private struct StripeFill: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(SeatPalette.brassShadow))
            var x = -size.height
            while x < size.width + size.height {
                var stripe = Path()
                stripe.move(to: CGPoint(x: x, y: size.height))
                stripe.addLine(to: CGPoint(x: x + size.height, y: 0))
                context.stroke(stripe, with: .color(SeatPalette.brass), lineWidth: 1.5)
                x += 4
            }
        }
    }
}

private struct DashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

private struct ChartPlaceholder: View {
    let message: String
    private let heights: [CGFloat] = [0.30, 0.45, 0.25, 0.60, 0.40, 0.20, 0.35]

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .bottom, spacing: 14) {
                ForEach(heights.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(SeatPalette.track)
                        .frame(maxWidth: 72)
                        .frame(height: geometry.size.height * heights[index])
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottom)
            .overlay {
                Text(message)
                    .font(SeatType.body(13))
                    .foregroundStyle(SeatPalette.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(SeatPalette.panel, in: Capsule())
                    .overlay(Capsule().stroke(SeatPalette.line, lineWidth: 1))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message)
    }
}

// MARK: - Chart

private struct CostChart: View {
    let days: [DaySnapshot]
    let seatPerDay: Double?
    let rangeTotal: Double
    @Binding var hoverDay: Date?

    private var calendar: Calendar { .current }
    private var dense: Bool { days.count > 14 }
    private var selected: DaySnapshot? { nearestDay(to: hoverDay) }
    private var peakID: Date? { days.max { $0.cost < $1.cost }?.id }
    private var todayID: Date { calendar.startOfDay(for: Date()) }

    /// Nice tick step and top, with headroom above the tallest bar for its label.
    private var scale: (step: Double, top: Double, domainTop: Double) {
        let peak = max(days.map(\.cost).max() ?? 0, seatPerDay ?? 0, 0.01)
        let step = niceStep(peak / 4)
        let top = max(step, (peak / step).rounded(.up) * step)
        return (step, top, max(top, peak / 0.82))
    }

    private var yTicks: [Double] {
        guard dense else { return [0] }
        return Array(stride(from: 0, through: scale.top + 1e-9, by: scale.step))
    }

    /// Axis labels sit at noon so they centre under each day's bar.
    private var xTicks: [Date] {
        let picked: [DaySnapshot]
        if dense {
            let count = days.count
            picked = days.enumerated().filter { (count - 1 - $0.offset) % 7 == 0 }.map(\.element)
        } else {
            picked = days
        }
        return picked.map { $0.day.addingTimeInterval(12 * 60 * 60) }
    }

    var body: some View {
        Chart {
            ForEach(days) { day in
                BarMark(
                    x: .value("Day", day.day, unit: .day),
                    y: .value("Value", day.cost),
                    width: .ratio(dense ? 0.8 : 0.55)
                )
                .cornerRadius(3)
                .foregroundStyle(day.id == todayID ? SeatPalette.brass.opacity(0.5) : SeatPalette.brass)
                .opacity(selected == nil || selected?.id == day.id ? 1 : 0.4)
                .annotation(position: .top, alignment: .center, spacing: 4) {
                    if let label = barLabel(for: day) {
                        Text(label)
                            .font(SeatType.data(11))
                            .foregroundStyle(day.id == peakID ? SeatPalette.text : SeatPalette.muted)
                            .fixedSize()
                    }
                }
                .accessibilityLabel(Text(day.day, format: .dateTime.weekday(.wide).day().month(.wide)))
                .accessibilityValue(SeatFormat.money(day.cost))
            }

            if let seatPerDay {
                RuleMark(y: .value("Seat cost per day", seatPerDay))
                    .foregroundStyle(SeatPalette.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                    .accessibilityLabel("Seat cost per day")
                    .accessibilityValue(SeatFormat.money(seatPerDay))
            }

            if let selected {
                let index = days.firstIndex { $0.id == selected.id } ?? 0
                let onRight = Double(index) + 0.5 < Double(days.count) * 0.6
                RuleMark(x: .value("Selected", selected.day.addingTimeInterval(12 * 60 * 60)))
                    .foregroundStyle(Color.clear)
                    .annotation(
                        position: onRight ? .trailing : .leading,
                        alignment: .top,
                        spacing: dense ? 10 : 44,
                        overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                    ) {
                        ChartTooltip(day: selected, isToday: selected.id == todayID, rangeTotal: rangeTotal, seatPerDay: seatPerDay)
                    }
            }
        }
        .chartYScale(domain: 0...scale.domainTop)
        .chartXAxis {
            AxisMarks(values: xTicks) { value in
                AxisValueLabel(anchor: .top) {
                    if let date = value.as(Date.self) {
                        Text(axisLabel(for: date))
                            .foregroundStyle(calendar.isDate(date, inSameDayAs: todayID) ? SeatPalette.text : SeatPalette.muted)
                    }
                }
                .font(SeatType.body(12))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: yTicks) { value in
                AxisGridLine()
                    .foregroundStyle(SeatPalette.line.opacity(dense ? 0.55 : 1))
                AxisValueLabel {
                    if dense, let number = value.as(Double.self), number > 0 {
                        Text(costAxis(number))
                    }
                }
                .font(SeatType.data(10))
                .foregroundStyle(SeatPalette.muted)
            }
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
        .accessibilityLabel("Daily API-equivalent value")
        .onChange(of: days.map(\.id)) { _, _ in
            if let hoverDay, nearestDay(to: hoverDay) == nil {
                self.hoverDay = nil
            }
        }
    }

    private func barLabel(for day: DaySnapshot) -> String? {
        if dense {
            return day.id == peakID && selected == nil ? SeatFormat.bar(day.cost) : nil
        }
        return day.id == todayID ? "\(SeatFormat.bar(day.cost)) so far" : SeatFormat.bar(day.cost)
    }

    private func axisLabel(for date: Date) -> String {
        if calendar.isDate(date, inSameDayAs: todayID) { return "Today" }
        if dense { return date.formatted(.dateTime.day().month(.abbreviated)) }
        return date.formatted(.dateTime.weekday(.abbreviated).day())
    }

    private func updateHover(at point: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let frame = proxy.plotFrame else { return }
        let plotFrame = geometry[frame]
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
    let isToday: Bool
    let rangeTotal: Double
    let seatPerDay: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(day.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + (isToday ? " · so far" : ""))
                .font(SeatType.body(11))
                .foregroundStyle(SeatPalette.muted)
            Text(SeatFormat.money(day.cost))
                .font(SeatType.body(15, weight: .semibold))
                .foregroundStyle(SeatPalette.text)
                .monospacedDigit()
            Text("\(UIFormatters.compactTokenString(day.tokens)) tokens · \(SeatFormat.share(rangeTotal > 0 ? day.cost / rangeTotal : 0)) of range")
                .font(SeatType.body(11))
                .foregroundStyle(SeatPalette.secondary)
            if let seatPerDay, seatPerDay > 0 {
                Text(String(format: "%.1f× the daily seat cost", day.cost / seatPerDay))
                    .font(SeatType.body(11))
                    .foregroundStyle(SeatPalette.brass)
            }
            if day.cacheSavings > 0 {
                Text("Cache saved \(SeatFormat.money(day.cacheSavings))")
                    .font(SeatType.body(11))
                    .foregroundStyle(SeatPalette.cyan)
            }
            if let topModel = day.topModel {
                Text(TokenPricingCatalog.standard.displayModelName(for: topModel))
                    .font(SeatType.body(11))
                    .foregroundStyle(SeatPalette.muted)
                    .lineLimit(1)
            }
        }
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(SeatPalette.track, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(SeatPalette.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
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

private func niceStep(_ raw: Double) -> Double {
    guard raw > 0 else { return 1 }
    let magnitude = pow(10, floor(log10(raw)))
    let residual = raw / magnitude
    let nice: Double = residual <= 1 ? 1 : residual <= 2 ? 2 : residual <= 5 ? 5 : 10
    return nice * magnitude
}

private func costAxis(_ value: Double) -> String {
    value >= 10 ? String(format: "$%.0f", value) : String(format: "$%.2f", value)
}
