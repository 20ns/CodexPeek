import AppKit
import SwiftUI

enum PopoverProvider: String, CaseIterable, Identifiable {
    case codex
    case claude
    case antigravity

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        case .antigravity: "Antigravity"
        }
    }

    var shortName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .antigravity: "AGY"
        }
    }

    var accentColor: Color {
        switch self {
        case .codex: Color(red: 0.23, green: 0.51, blue: 0.96)
        case .claude: Color(red: 0.97, green: 0.45, blue: 0.09)
        case .antigravity: Color(red: 0.55, green: 0.49, blue: 1.0)
        }
    }

    static var menuBarProviders: [PopoverProvider] { [.codex, .claude, .antigravity] }
}

enum PopoverTab: Equatable, Hashable {
    case all
    case provider(PopoverProvider)
}

struct PopoverAccountChoice: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let isActive: Bool
}

@MainActor
final class PopoverViewModel: ObservableObject {
    @Published var selectedTab: PopoverTab = .all
    @Published var primaryProvider: PopoverProvider = .codex
    @Published var codexEnabled = true
    @Published var claudeEnabled = true
    @Published var agyEnabled = true
    @Published var showAccountEmail = false
    @Published var launchAtLogin = false

    // Codex
    @Published var codexSnapshot: CodexUsageSnapshot?
    @Published var codexTokenReport: TokenUsageReport?
    @Published var codexTokenRefreshing = false
    @Published var codexRefreshState: RefreshState = .idle
    @Published var codexAccountStatus: String?
    @Published var codexProfileLabel: String = "Default Account"
    @Published var codexAccounts: [PopoverAccountChoice] = []
    @Published var codexSignedIn = false
    @Published var codexCanRemoveAccount = false
    @Published var codexActionsEnabled = true

    // Claude
    @Published var claudeSnapshot: ClaudeCodeUsageSnapshot?
    @Published var claudeTokenReport: TokenUsageReport?
    @Published var claudeTokenRefreshing = false
    @Published var claudeTokenFailed = false
    @Published var claudeUsageRefreshing = false
    @Published var claudeUsageError: String?
    @Published var claudeBridgeEnabled = false

    // Antigravity (AGY)
    @Published var agySnapshot: AntigravityUsageSnapshot?
    @Published var agyUsageError: String?
    @Published var agyTokenReport: TokenUsageReport?
    @Published var agyModelShares: [AntigravityModelShare] = []
    @Published var agyTokenRefreshing = false
    @Published var agyUsageRefreshing = false
    @Published var agyTokenFailed = false

    @Published var copiedDebugFeedback = false

    var enabledProviders: [PopoverProvider] {
        var list: [PopoverProvider] = []
        if codexEnabled { list.append(.codex) }
        if claudeEnabled { list.append(.claude) }
        if agyEnabled { list.append(.antigravity) }
        return list
    }

    var isAnyRefreshing: Bool {
        codexRefreshState == .refreshing || claudeUsageRefreshing || agyTokenRefreshing || agyUsageRefreshing
    }

    func ensureValidTab() {
        let enabled = enabledProviders
        if enabled.count == 1, let only = enabled.first {
            if selectedTab != .provider(only) { selectedTab = .provider(only) }
            return
        }
        if case .provider(let p) = selectedTab, !enabled.contains(p) {
            selectedTab = .all
        }
    }

    // Callbacks wired by AppController
    var onRefreshAll: (() -> Void)?
    var onRefreshClaude: (() -> Void)?
    var onRefreshAgy: (() -> Void)?
    var onOpenHistory: (() -> Void)?
    var onSelectPrimary: ((PopoverProvider) -> Void)?
    var onToggleProvider: ((PopoverProvider) -> Void)?
    var onToggleShowEmail: (() -> Void)?
    var onToggleLaunchAtLogin: (() -> Void)?
    var onCopyDebugInfo: (() -> Void)?
    var onSelectCodexAccount: ((String) -> Void)?
    var onAddCodexAccount: (() -> Void)?
    var onSignInCodexAccount: (() -> Void)?
    var onRemoveCodexAccount: (() -> Void)?
    var onOpenCodex: (() -> Void)?
    var onLogOutCodex: (() -> Void)?
    var onEnableClaudeBridge: (() -> Void)?
    var onOpenAgyCLI: (() -> Void)?
    var onQuit: (() -> Void)?
    var onPreferredSizeChange: (() -> Void)?
}

struct UsagePopoverView: View {
    @ObservedObject var vm: PopoverViewModel

    static let popoverWidth: CGFloat = 352

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().opacity(0.45)

            Group {
                switch vm.selectedTab {
                case .all:
                    overviewContent
                case .provider(.codex):
                    codexDetailContent
                case .provider(.claude):
                    claudeDetailContent
                case .provider(.antigravity):
                    agyDetailContent
                }
            }

            footerBar
        }
        .frame(width: Self.popoverWidth)
        .onChange(of: vm.selectedTab) { _, _ in
            vm.onPreferredSizeChange?()
        }
    }

    // MARK: - Top Segmented Bar

    private var topBar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                if vm.enabledProviders.count > 1 {
                    tabButton(tab: .all) {
                        Text("All")
                            .font(.system(size: 11, weight: vm.selectedTab == .all ? .semibold : .medium))
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }

                ForEach(vm.enabledProviders) { provider in
                    tabButton(tab: .provider(provider)) {
                        HStack(spacing: 3.5) {
                            Circle()
                                .fill(provider.accentColor)
                                .frame(width: 6, height: 6)
                            Text(provider.shortName)
                                .font(.system(size: 11, weight: vm.selectedTab == .provider(provider) ? .semibold : .medium))
                                .lineLimit(1)
                            tabIndicator(for: provider)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(2)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            Button {
                vm.onRefreshAll?()
            } label: {
                // A timeline, not a repeatForever animation: that transaction also animated
                // layout changes made mid-refresh, so the icon bobbed up and down forever.
                TimelineView(.animation(paused: !vm.isAnyRefreshing)) { context in
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(vm.isAnyRefreshing
                            ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.8) / 0.8 * 360
                            : 0))
                }
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(PopoverIconButtonStyle())
            .disabled(vm.isAnyRefreshing)
            .accessibilityLabel("Refresh all providers")
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func tabButton<Label: View>(tab: PopoverTab, @ViewBuilder label: () -> Label) -> some View {
        let selected = vm.selectedTab == tab
        Button {
            vm.selectedTab = tab
        } label: {
            label()
                .foregroundStyle(selected ? .primary : .secondary)
                .padding(.horizontal, tab == .all ? 9 : 5)
                .padding(.vertical, 5)
                .frame(maxWidth: tab == .all ? nil : .infinity)
                .background(
                    selected ? Color.primary.opacity(0.13) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func tabIndicator(for provider: PopoverProvider) -> some View {
        switch provider {
        case .codex:
            if let pct = vm.codexSnapshot?.sessionWindow?.usedPercent ?? vm.codexSnapshot?.weeklyWindow?.usedPercent {
                Text("\(pct)%")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(pct >= 90 || vm.codexSnapshot?.isWeeklyExhausted == true ? Color.red : Color.secondary)
            } else if case .failed = vm.codexRefreshState {
                Circle().fill(Color.orange).frame(width: 5, height: 5)
            }
        case .claude:
            if vm.claudeUsageError != nil {
                Circle().fill(Color.orange).frame(width: 5, height: 5)
            } else if let pct = vm.claudeSnapshot?.fiveHour?.usedPercent ?? vm.claudeSnapshot?.sevenDay?.usedPercent {
                Text("\(pct)%")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(pct >= 90 ? Color.red : Color.secondary)
            }
        case .antigravity:
            if let pct = vm.agySnapshot?.primaryBucket?.window.usedPercent {
                Text("\(pct)%")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(pct >= 90 ? Color.red : Color.secondary)
            } else if let report = vm.agyTokenReport, report.week.hasUsage {
                Text(compactCurrency(report.week.estimatedCostUSD))
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Overview (All Tab)

    private var overviewContent: some View {
        VStack(spacing: 0) {
            if vm.codexEnabled {
                let sessionWindow = vm.codexSnapshot?.sessionWindow
                let weeklyWindow = vm.codexSnapshot?.weeklyWindow
                overviewProviderRow(
                    provider: .codex,
                    meta: codexOverviewMeta,
                    badge: codexOverviewBadge,
                    leftTitle: shortWindowLabel(sessionWindow, fallback: "5-hour"),
                    leftWindow: sessionWindow,
                    rightTitle: shortWindowLabel(weeklyWindow, fallback: "Weekly"),
                    rightWindow: weeklyWindow,
                    isLeftDimmed: vm.codexSnapshot?.isWeeklyExhausted == true
                )
                Divider().opacity(0.4)
            }

            if vm.claudeEnabled {
                overviewProviderRow(
                    provider: .claude,
                    meta: claudeOverviewMeta,
                    badge: claudeOverviewBadge,
                    leftTitle: "5-hour",
                    leftWindow: vm.claudeSnapshot?.fiveHour,
                    rightTitle: "Weekly",
                    rightWindow: vm.claudeSnapshot?.sevenDay,
                    isLeftDimmed: false
                )
                Divider().opacity(0.4)
            }

            if vm.agyEnabled {
                agyOverviewRow
                Divider().opacity(0.4)
            }

            combinedCostStrip
            Divider().opacity(0.4)
        }
    }

    private func overviewProviderRow(
        provider: PopoverProvider,
        meta: String?,
        badge: StatusBadge?,
        leftTitle: String,
        leftWindow: RateLimitWindowSnapshot?,
        rightTitle: String,
        rightWindow: RateLimitWindowSnapshot?,
        isLeftDimmed: Bool
    ) -> some View {
        Button {
            vm.selectedTab = .provider(provider)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(provider.accentColor)
                        .frame(width: 6.5, height: 6.5)
                    Text(provider.displayName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                    if let meta, !meta.isEmpty {
                        Text(meta)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 6)
                    if let badge {
                        StatusBadgeView(badge: badge)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }

                if leftWindow == nil, let rightWindow {
                    miniGauge(
                        title: rightTitle,
                        window: rightWindow,
                        tint: provider.accentColor,
                        dimmed: false
                    )
                } else {
                    HStack(spacing: 12) {
                        miniGauge(
                            title: leftTitle,
                            window: leftWindow,
                            tint: provider.accentColor,
                            dimmed: isLeftDimmed
                        )
                        miniGauge(
                            title: rightTitle,
                            window: rightWindow,
                            tint: provider.accentColor,
                            dimmed: false
                        )
                    }
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(PopoverRowButtonStyle())
    }

    private var agyOverviewRow: some View {
        let snap = vm.agySnapshot
        let shares = vm.agyModelShares
        let report = vm.agyTokenReport
        let badge: StatusBadge? = {
            if let err = vm.agyUsageError, !err.isEmpty {
                return StatusBadge(text: "Check bridge", kind: .warning)
            }
            if let p = snap?.primaryBucket?.window.usedPercent, p >= 90 {
                return StatusBadge(text: "Near limit", kind: .critical)
            }
            if let tier = snap?.planTier, !tier.isEmpty {
                return StatusBadge(text: tier, kind: .subtle)
            }
            if let week = report?.week, week.hasUsage {
                return StatusBadge(text: "7d \(compactCurrency(week.estimatedCostUSD))", kind: .subtle)
            }
            return nil
        }()

        return Button {
            vm.selectedTab = .provider(.antigravity)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(PopoverProvider.antigravity.accentColor)
                        .frame(width: 6.5, height: 6.5)
                    Text("Antigravity")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                    if let top = shares.first {
                        Text("\(top.modelName) \(top.sharePercent)%")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    if let badge {
                        StatusBadgeView(badge: badge)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }

                if let primary = snap?.primaryBucket {
                    if let secondary = snap?.secondaryBucket {
                        HStack(spacing: 12) {
                            miniGauge(title: primary.title, window: primary.window, tint: PopoverProvider.antigravity.accentColor, dimmed: false)
                            miniGauge(title: secondary.title, window: secondary.window, tint: PopoverProvider.antigravity.accentColor, dimmed: false)
                        }
                    } else {
                        miniGauge(title: primary.title, window: primary.window, tint: PopoverProvider.antigravity.accentColor, dimmed: false)
                    }
                } else if !shares.isEmpty {
                    let topTwo = Array(shares.prefix(2))
                    HStack(spacing: 12) {
                        ForEach(topTwo) { item in
                            modelShareMiniGauge(item)
                        }
                    }
                } else {
                    Text(vm.agyTokenRefreshing ? "Scanning Antigravity logs…" : "No Antigravity activity yet")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(PopoverRowButtonStyle())
    }

    private func modelShareMiniGauge(_ item: AntigravityModelShare) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(item.modelName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(item.sharePercent)%")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.primary)
            }
            UsageProgressBar(
                fraction: Double(item.sharePercent) / 100.0,
                pace: nil,
                tint: PopoverProvider.antigravity.accentColor,
                slim: true
            )
            Text("\(compactCurrency(item.costUSD)) · \(UIFormatters.compactTokenString(item.totalTokens))")
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private func miniGauge(title: String, window: RateLimitWindowSnapshot?, tint: Color, dimmed: Bool) -> some View {
        let pct = window?.usedPercent
        let isCrit = (pct ?? 0) >= 90
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(pct.map { "\($0)%" } ?? "—")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(pct == nil ? AnyShapeStyle(.tertiary) : (isCrit ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary)))
            }
            UsageProgressBar(
                fraction: pct.map { Double($0) / 100.0 },
                pace: window?.pace(),
                tint: tint,
                slim: true
            )
            Text(window?.resetsAt.map { UIFormatters.shortResetCountdownString(from: $0) } ?? (window == nil ? "—" : "no reset"))
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .opacity(dimmed ? 0.45 : 1)
    }

    private var combinedCostStrip: some View {
        let reports = enabledTokenReports
        let weekTotal = reports.reduce(Decimal(0)) { $0 + $1.week.estimatedCostUSD }
        let monthTotal = reports.reduce(Decimal(0)) { $0 + $1.month.estimatedCostUSD }
        let allTotal = reports.reduce(Decimal(0)) { $0 + $1.allTime.estimatedCostUSD }
        let hasData = reports.contains(where: \.hasUsage)

        return HStack(spacing: 8) {
            Text("API-equiv")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if hasData {
                HStack(spacing: 6) {
                    Text("7d \(compactCurrency(weekTotal))")
                    Text("·").foregroundStyle(.tertiary)
                    Text("30d \(compactCurrency(monthTotal))")
                    Text("·").foregroundStyle(.tertiary)
                    Text("All \(compactCurrency(allTotal))")
                }
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
            } else {
                Text(vm.codexTokenRefreshing || vm.claudeTokenRefreshing || vm.agyTokenRefreshing ? "Calculating…" : "No local logs yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
    }

    // MARK: - Codex Detail

    private var codexDetailContent: some View {
        let snap = vm.codexSnapshot
        let sessionWindow = snap?.sessionWindow
        let weeklyWindow = snap?.weeklyWindow
        let hasBoth = sessionWindow != nil && weeklyWindow != nil
        let isExhausted = snap?.isWeeklyExhausted == true

        return VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Menu {
                    ForEach(vm.codexAccounts) { acct in
                        Button {
                            vm.onSelectCodexAccount?(acct.id)
                        } label: {
                            HStack {
                                Text(acct.subtitle.map { "\(acct.title) · \($0)" } ?? acct.title)
                                if acct.isActive { Image(systemName: "checkmark") }
                            }
                        }
                        .disabled(!vm.codexActionsEnabled)
                    }
                    Divider()
                    Button("Add Account…") { vm.onAddCodexAccount?() }
                        .disabled(!vm.codexActionsEnabled)
                    Button(vm.codexSignedIn ? "Reauthenticate Current Account…" : "Sign In Current Account…") {
                        vm.onSignInCodexAccount?()
                    }
                    .disabled(!vm.codexActionsEnabled)
                    if vm.codexCanRemoveAccount {
                        Divider()
                        Button("Remove Current Account…", role: .destructive) { vm.onRemoveCodexAccount?() }
                            .disabled(!vm.codexActionsEnabled)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(vm.codexProfileLabel)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        Text(codexHeaderSubtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 6)
                liveStatusPill(
                    isWarn: {
                        if case .failed = vm.codexRefreshState { return true }
                        return snap?.isStale == true || vm.codexAccountStatus != nil
                    }(),
                    text: codexLiveText
                )
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            Divider().opacity(0.4)

            if let bannerText = codexBannerMessage {
                alertBanner(title: bannerText.title, subtitle: bannerText.detail, actionTitle: bannerText.actionTitle) {
                    if vm.codexSignedIn {
                        vm.onRefreshAll?()
                    } else {
                        vm.onSignInCodexAccount?()
                    }
                }
            }

            VStack(spacing: 10) {
                if hasBoth {
                    detailUsageRow(
                        title: UIFormatters.rateLimitWindowTitle(for: sessionWindow, fallback: "5-hour window"),
                        window: sessionWindow,
                        tint: PopoverProvider.codex.accentColor,
                        dimmed: isExhausted,
                        overrideDetail: isExhausted ? "Weekly limit reached · resumes after reset" : nil
                    )
                    detailUsageRow(
                        title: UIFormatters.rateLimitWindowTitle(for: weeklyWindow, fallback: "Weekly window"),
                        window: weeklyWindow,
                        tint: PopoverProvider.codex.accentColor
                    )
                } else {
                    let single = weeklyWindow ?? sessionWindow ?? snap?.primary
                    detailUsageRow(
                        title: UIFormatters.rateLimitWindowTitle(for: single, fallback: single?.isWeekly == true ? "Weekly window" : "5-hour window"),
                        window: single,
                        tint: PopoverProvider.codex.accentColor
                    )
                }

                if let spark = snap?.spark {
                    detailUsageRow(
                        title: spark.title,
                        window: spark.primary,
                        tint: PopoverProvider.codex.accentColor,
                        overrideDetail: spark.isWeeklyExhausted ? "Weekly limit reached" : nil,
                        trailingNote: spark.secondary.map { "\($0.usedPercent)% wk" }
                    )
                }
            }
            .padding(.horizontal, 13)
            .padding(.top, 10)
            .padding(.bottom, 8)

            costBreakdownCard(report: vm.codexTokenReport, isRefreshing: vm.codexTokenRefreshing, failed: false, sourceName: "Codex")

            HStack(spacing: 6) {
                Button {
                    vm.onOpenCodex?()
                } label: {
                    Label("Open Codex", systemImage: "arrow.up.right.square")
                        .font(.system(size: 11.5, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5.5)
                }
                .buttonStyle(PopoverActionButtonStyle())
                .disabled(!vm.codexSignedIn)

                Button {
                    vm.onLogOutCodex?()
                } label: {
                    Text("Log Out")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5.5)
                }
                .buttonStyle(PopoverActionButtonStyle())
                .disabled(!vm.codexSignedIn || !vm.codexActionsEnabled)
            }
            .padding(.horizontal, 13)
            .padding(.bottom, 10)

            Divider().opacity(0.4)
        }
    }

    // MARK: - Claude Detail

    private var claudeDetailContent: some View {
        let snap = vm.claudeSnapshot
        return VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude Code")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(vm.claudeBridgeEnabled ? "OAuth · local bridge active" : "OAuth usage")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                liveStatusPill(
                    isWarn: vm.claudeUsageError != nil || snap?.isStale == true,
                    text: claudeLiveText
                )
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            Divider().opacity(0.4)

            if let error = vm.claudeUsageError {
                alertBanner(
                    title: claudeShortErrorTitle(error),
                    subtitle: error,
                    actionTitle: "Refresh"
                ) {
                    vm.onRefreshClaude?()
                }
            }

            VStack(spacing: 10) {
                if snap?.fiveHour != nil || snap?.sevenDay != nil || snap?.modelWeekly != nil {
                    if let five = snap?.fiveHour {
                        detailUsageRow(
                            title: UIFormatters.rateLimitWindowTitle(for: five, fallback: "5-hour window"),
                            window: five,
                            tint: PopoverProvider.claude.accentColor
                        )
                    }
                    if let week = snap?.sevenDay {
                        detailUsageRow(
                            title: UIFormatters.rateLimitWindowTitle(for: week, fallback: "Weekly window"),
                            window: week,
                            tint: PopoverProvider.claude.accentColor
                        )
                    }
                    if let model = snap?.modelWeekly {
                        detailUsageRow(
                            title: "\(snap?.modelWeeklyName ?? "Model") weekly",
                            window: model,
                            tint: PopoverProvider.claude.accentColor
                        )
                    }
                } else {
                    emptyQuotaPlaceholder(
                        text: vm.claudeUsageRefreshing ? "Fetching Claude Code usage…" : "No active Claude quota readings yet."
                    )
                }
            }
            .padding(.horizontal, 13)
            .padding(.top, 10)
            .padding(.bottom, 8)

            costBreakdownCard(report: vm.claudeTokenReport, isRefreshing: vm.claudeTokenRefreshing, failed: vm.claudeTokenFailed, sourceName: "Claude Code")

            if !vm.claudeBridgeEnabled || vm.claudeUsageError != nil {
                HStack(spacing: 6) {
                    Button {
                        vm.onEnableClaudeBridge?()
                    } label: {
                        Text(vm.claudeBridgeEnabled ? "Reinstall local usage bridge" : "Enable Claude local usage")
                            .font(.system(size: 11.5, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5.5)
                    }
                    .buttonStyle(PopoverActionButtonStyle())
                }
                .padding(.horizontal, 13)
                .padding(.bottom, 10)
            }

            Divider().opacity(0.4)
        }
    }

    // MARK: - Antigravity (AGY) Detail

    private var agyDetailContent: some View {
        let snap = vm.agySnapshot
        let report = vm.agyTokenReport
        let shares = vm.agyModelShares

        return VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Antigravity")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(agyHeaderSubtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                liveStatusPill(
                    isWarn: vm.agyTokenFailed || vm.agyUsageError != nil || snap?.isStale == true,
                    text: agyStatusText
                )
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            Divider().opacity(0.4)

            if let err = vm.agyUsageError {
                alertBanner(title: "Antigravity quota", subtitle: err, actionTitle: "Retry") {
                    vm.onRefreshAgy?()
                }
            }

            if let buckets = snap?.activeBuckets, !buckets.isEmpty {
                VStack(spacing: 10) {
                    ForEach(buckets) { bucket in
                        detailUsageRow(
                            title: bucket.title,
                            window: bucket.window,
                            tint: PopoverProvider.antigravity.accentColor
                        )
                    }
                }
                .padding(.horizontal, 13)
                .padding(.top, 10)
                .padding(.bottom, 8)
            }

            if !shares.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(report?.week.hasUsage == true ? "Model share (7d)" : "Model share (all-time)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let report, report.week.hasUsage {
                            Text("\(UIFormatters.compactTokenString(report.week.totalTokens)) tokens")
                                .font(.system(size: 10.5).monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }

                    ForEach(shares.prefix(4)) { share in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(share.modelName)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                                Text(compactCurrency(share.costUSD))
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text("\(share.sharePercent)%")
                                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                    .fixedSize()
                                    .frame(minWidth: 34, alignment: .trailing)
                            }
                            UsageProgressBar(
                                fraction: Double(share.sharePercent) / 100.0,
                                pace: nil,
                                tint: PopoverProvider.antigravity.accentColor,
                                slim: true
                            )
                        }
                    }
                }
                .padding(.horizontal, 13)
                .padding(.top, snap?.activeBuckets.isEmpty == false ? 2 : 10)
                .padding(.bottom, 8)
            } else if snap?.activeBuckets.isEmpty != false {
                emptyQuotaPlaceholder(
                    text: vm.agyTokenRefreshing
                        ? "Scanning Antigravity transcripts…"
                        : "No Antigravity usage recorded yet."
                )
                .padding(.horizontal, 13)
                .padding(.top, 10)
                .padding(.bottom, 8)
            }

            costBreakdownCard(report: report, isRefreshing: vm.agyTokenRefreshing, failed: vm.agyTokenFailed, sourceName: "Antigravity")

            HStack(spacing: 6) {
                Button {
                    vm.onOpenAgyCLI?()
                } label: {
                    Label("Open AGY", systemImage: "terminal")
                        .font(.system(size: 11.5, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5.5)
                }
                .buttonStyle(PopoverActionButtonStyle())

                Button {
                    vm.onRefreshAgy?()
                } label: {
                    Text("Rescan")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5.5)
                }
                .buttonStyle(PopoverActionButtonStyle())
                .disabled(vm.agyTokenRefreshing)
            }
            .padding(.horizontal, 13)
            .padding(.bottom, 10)

            Divider().opacity(0.4)
        }
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: 6) {
            Button {
                vm.onOpenHistory?()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("Usage History…")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(PopoverGhostButtonStyle())

            Spacer(minLength: 4)

            Menu {
                Section("Menu Bar Icon") {
                    ForEach(PopoverProvider.menuBarProviders) { provider in
                        Button {
                            vm.onSelectPrimary?(provider)
                        } label: {
                            HStack {
                                Text(provider.displayName)
                                if vm.primaryProvider == provider { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }

                Section("Show Providers") {
                    providerToggleMenuItem(.codex, enabled: vm.codexEnabled)
                    providerToggleMenuItem(.claude, enabled: vm.claudeEnabled)
                    providerToggleMenuItem(.antigravity, enabled: vm.agyEnabled)
                }

                Divider()

                Button {
                    vm.onToggleShowEmail?()
                } label: {
                    HStack {
                        Text("Show Account Email")
                        if vm.showAccountEmail { Image(systemName: "checkmark") }
                    }
                }

                Button {
                    vm.onToggleLaunchAtLogin?()
                } label: {
                    HStack {
                        Text("Launch at Login")
                        if vm.launchAtLogin { Image(systemName: "checkmark") }
                    }
                }

                Divider()

                Button(vm.copiedDebugFeedback ? "Debug Info Copied" : "Copy Debug Info") {
                    vm.onCopyDebugInfo?()
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Settings")

            Button {
                vm.onQuit?()
            } label: {
                Text("Quit")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PopoverGhostButtonStyle())
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }

    private func providerToggleMenuItem(_ provider: PopoverProvider, enabled: Bool) -> some View {
        Button {
            vm.onToggleProvider?(provider)
        } label: {
            HStack {
                Text(provider.displayName)
                if enabled { Image(systemName: "checkmark") }
            }
        }
        .disabled(vm.primaryProvider == provider)
    }

    // MARK: - Shared Components

    private func detailUsageRow(
        title: String,
        window: RateLimitWindowSnapshot?,
        tint: Color,
        dimmed: Bool = false,
        overrideDetail: String? = nil,
        trailingNote: String? = nil
    ) -> some View {
        let pct = window?.usedPercent
        let pace = window?.pace()
        let isCrit = (pct ?? 0) >= 90
        let detail = overrideDetail ?? (window?.resetsAt.map { UIFormatters.usageResetCountdownString(from: $0) } ?? (window == nil ? "Unavailable" : "Reset unavailable"))
        let paceText = trailingNote ?? paceDescription(usedPercent: pct, pace: pace)

        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if let pct {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(pct)%")
                            .font(.system(size: 13.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(isCrit ? Color.red : Color.primary)
                        Text("used")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("—")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }

            UsageProgressBar(
                fraction: pct.map { Double($0) / 100.0 },
                pace: pace,
                tint: tint,
                slim: false
            )

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(detail)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let paceText {
                    Text(paceText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .opacity(dimmed ? 0.45 : 1)
    }

    private func costBreakdownCard(report: TokenUsageReport?, isRefreshing: Bool, failed: Bool, sourceName: String) -> some View {
        Group {
            if let report, report.hasUsage {
                let fmt: (TokenUsageSummary) -> String = {
                    $0.hasUsage && $0.pricedSessionCount == 0 && $0.estimatedCostUSD == 0 ? "unpriced" : compactCurrency($0.estimatedCostUSD)
                }
                let allPrefix = report.legacyStats == nil ? "" : "≈"
                HStack(spacing: 8) {
                    costCell(label: "7d est.", value: fmt(report.week))
                    costCell(label: "30d est.", value: fmt(report.month))
                    costCell(label: "All-time", value: "\(allPrefix)\(fmt(report.allTime))")
                }
            } else {
                HStack {
                    Text(failed ? "Could not read local \(sourceName) logs" : (isRefreshing || report == nil ? "Scanning local \(sourceName) logs…" : "No recorded local token usage"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(.horizontal, 13)
        .padding(.bottom, 10)
    }

    private func costCell(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func alertBanner(title: String, subtitle: String, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.orange)
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button(actionTitle, action: action)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.orange.opacity(0.32), lineWidth: 1))
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.orange.opacity(0.24), lineWidth: 1))
        .padding(.horizontal, 13)
        .padding(.top, 9)
    }

    private func liveStatusPill(isWarn: Bool, text: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isWarn ? Color.orange : Color.green)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func emptyQuotaPlaceholder(text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
    }

    // MARK: - Formatting & Computed Copy

    private var enabledTokenReports: [TokenUsageReport] {
        var list: [TokenUsageReport] = []
        if vm.codexEnabled, let r = vm.codexTokenReport { list.append(r) }
        if vm.claudeEnabled, let r = vm.claudeTokenReport { list.append(r) }
        if vm.agyEnabled, let r = vm.agyTokenReport { list.append(r) }
        return list
    }

    private var codexHeaderSubtitle: String {
        if let snap = vm.codexSnapshot {
            var parts = [snap.account.planType.displayName]
            if let renewsAt = snap.account.renewsAt {
                parts.append("renews \(UIFormatters.accountRenewalString(from: renewsAt))")
            }
            if snap.isWeeklyExhausted { parts.append("weekly limit reached") }
            if snap.isStale { parts.append("estimate") }
            return parts.joined(separator: " · ")
        }
        return vm.codexAccountStatus ?? "Waiting for Codex data"
    }

    private var codexOverviewMeta: String? {
        if let spark = vm.codexSnapshot?.spark?.primary?.usedPercent {
            return "Spark \(spark)%"
        }
        if vm.showAccountEmail, let email = vm.codexSnapshot?.account.email {
            return email.components(separatedBy: "@").first
        }
        return nil
    }

    private var codexOverviewBadge: StatusBadge? {
        if vm.codexSnapshot?.isWeeklyExhausted == true {
            return StatusBadge(text: "Limit reached", kind: .critical)
        }
        if (vm.codexSnapshot?.sessionWindow?.usedPercent ?? 0) >= 90 {
            return StatusBadge(text: "Near limit", kind: .critical)
        }
        if case .failed = vm.codexRefreshState {
            return StatusBadge(text: "Refresh failed", kind: .warning)
        }
        if let plan = vm.codexSnapshot?.account.planType, plan != .unknown {
            return StatusBadge(text: plan.displayName, kind: .subtle)
        }
        return nil
    }

    private var claudeOverviewMeta: String? {
        guard let model = vm.claudeSnapshot?.modelWeekly else { return nil }
        let name = vm.claudeSnapshot?.modelWeeklyName ?? "Model"
        return "\(name) \(model.usedPercent)%"
    }

    private var claudeOverviewBadge: StatusBadge? {
        if let err = vm.claudeUsageError {
            return StatusBadge(text: claudeShortErrorTitle(err), kind: .warning)
        }
        if (vm.claudeSnapshot?.fiveHour?.usedPercent ?? 0) >= 90 || (vm.claudeSnapshot?.sevenDay?.usedPercent ?? 0) >= 90 {
            return StatusBadge(text: "Near limit", kind: .critical)
        }
        if vm.claudeSnapshot?.isStale == true {
            return StatusBadge(text: "Stale", kind: .warning)
        }
        return nil
    }

    private var codexLiveText: String {
        if vm.codexRefreshState == .refreshing { return "Refreshing…" }
        if let snap = vm.codexSnapshot {
            let prefix = snap.source == .live ? "Live" : "Cached"
            return "\(prefix) · \(UIFormatters.usageUpdatedShortString(from: snap.lastUpdatedAt))"
        }
        return "Idle"
    }

    private var claudeLiveText: String {
        if vm.claudeUsageRefreshing { return "Refreshing…" }
        if let snap = vm.claudeSnapshot {
            let prefix = snap.isStale ? "Stale" : "Live"
            return "\(prefix) · \(UIFormatters.usageUpdatedShortString(from: snap.updatedAt))"
        }
        return vm.claudeUsageError != nil ? "Error" : "Idle"
    }

    private var agyHeaderSubtitle: String {
        var parts: [String] = []
        if let tier = vm.agySnapshot?.planTier, !tier.isEmpty {
            parts.append(tier)
        }
        parts.append("AGY CLI quota · local logs")
        return parts.joined(separator: " · ")
    }

    private var agyStatusText: String {
        if vm.agyTokenRefreshing { return "Scanning…" }
        if vm.agyTokenFailed { return "Read error" }
        if let snap = vm.agySnapshot {
            let prefix = snap.isStale ? "Stale" : "Live"
            return "\(prefix) · \(UIFormatters.usageUpdatedShortString(from: snap.updatedAt))"
        }
        if let updated = vm.agyTokenReport?.generatedAt {
            return "Local · \(UIFormatters.usageUpdatedShortString(from: updated))"
        }
        return "Local"
    }

    private var codexBannerMessage: (title: String, detail: String, actionTitle: String)? {
        if case .failed(let message) = vm.codexRefreshState {
            return ("Codex refresh failed", message, "Retry")
        }
        if let status = vm.codexAccountStatus {
            return ("Codex account", status, vm.codexSignedIn ? "Refresh" : "Sign In")
        }
        return nil
    }

    private func claudeShortErrorTitle(_ message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("expired") { return "Sign-in expired" }
        if lower.contains("not signed in") { return "Not signed in" }
        if lower.contains("rate limit") { return "Rate limited" }
        return "Refresh failed"
    }

    private func shortWindowLabel(_ window: RateLimitWindowSnapshot?, fallback: String) -> String {
        guard let mins = window?.windowDurationMins else { return fallback }
        if mins >= 10080 { return "Weekly" }
        if mins == 1440 { return "24h" }
        if mins % 60 == 0 { return "\(mins / 60)-hour" }
        return "\(mins)m"
    }

    private func paceDescription(usedPercent: Int?, pace: Double?) -> String? {
        guard let usedPercent, let pace else { return nil }
        let delta = Double(usedPercent) - pace * 100.0
        if abs(delta) <= 4 { return "on pace" }
        return delta < 0 ? "under pace" : "ahead of pace"
    }

    private func compactCurrency(_ value: Decimal) -> String {
        let d = NSDecimalNumber(decimal: value).doubleValue
        if d >= 10_000 {
            return String(format: "$%.1fk", d / 1_000)
        }
        return UIFormatters.costString(value)
    }
}

// MARK: - Native-Styled Progress Bar with Pace Notch

struct UsageProgressBar: View {
    let fraction: Double?
    let pace: Double?
    let tint: Color
    let slim: Bool

    var body: some View {
        let barHeight: CGFloat = slim ? 5 : 6
        let totalHeight: CGFloat = barHeight + 4

        Canvas { context, size in
            let rect = CGRect(x: 0, y: (size.height - barHeight) / 2, width: size.width, height: barHeight)
            let radius = barHeight / 2
            let trackPath = Path(roundedRect: rect, cornerRadius: radius)

            context.fill(trackPath, with: .color(Color.primary.opacity(0.11)))
            context.stroke(Path(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), cornerRadius: radius), with: .color(Color.primary.opacity(0.08)), lineWidth: 0.5)

            if let fraction, fraction > 0 {
                let clamped = min(max(fraction, 0), 1)
                let fillWidth = max(rect.width * clamped, barHeight)
                let fillRect = CGRect(x: rect.minX, y: rect.minY, width: min(fillWidth, rect.width), height: rect.height)
                context.fill(Path(roundedRect: fillRect, cornerRadius: radius), with: .color(tint))
            }

            if let pace {
                let clamped = min(max(pace, 0.03), 0.97)
                let x = ((rect.width - 2) * clamped).rounded()
                let cutout = Path(roundedRect: CGRect(x: x - 1.5, y: 0, width: 5, height: size.height), cornerRadius: 2.5)
                context.blendMode = .clear
                context.fill(cutout, with: .color(.black))
                context.blendMode = .normal
                let tick = Path(roundedRect: CGRect(x: x, y: 0, width: 2, height: size.height), cornerRadius: 1)
                context.fill(tick, with: .color(.primary))
            }
        }
        .frame(height: totalHeight)
    }
}

private struct StatusBadge {
    enum Kind { case subtle, warning, critical }
    let text: String
    let kind: Kind
}

private struct StatusBadgeView: View {
    let badge: StatusBadge

    var body: some View {
        let bg: Color = {
            switch badge.kind {
            case .subtle: Color.primary.opacity(0.07)
            case .warning: Color.orange.opacity(0.16)
            case .critical: Color.red.opacity(0.16)
            }
        }()
        let fg: Color = {
            switch badge.kind {
            case .subtle: .secondary
            case .warning: .orange
            case .critical: .red
            }
        }()
        Text(badge.text)
            .font(.system(size: 10, weight: badge.kind == .subtle ? .medium : .semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(bg, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .lineLimit(1)
    }
}

// MARK: - Subtle Hover Button Styles

@MainActor
private final class HoverFlag: ObservableObject {
    @Published var isHovering = false
}

private struct HoverBackdrop<Content: View>: View {
    let isPressed: Bool
    let radius: CGFloat
    let idleOpacity: Double
    let hoverOpacity: Double
    let pressedOpacity: Double
    let borderOpacity: Double
    let content: Content
    @StateObject private var hover = HoverFlag()

    var body: some View {
        let opacity = isPressed ? pressedOpacity : (hover.isHovering ? hoverOpacity : idleOpacity)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(Color.primary.opacity(opacity), in: shape)
            .overlay {
                if borderOpacity > 0 {
                    shape.stroke(Color.primary.opacity(borderOpacity), lineWidth: 1)
                }
            }
            .onHover { hover.isHovering = $0 }
    }
}

private struct PopoverRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBackdrop(isPressed: configuration.isPressed, radius: 0, idleOpacity: 0, hoverOpacity: 0.055, pressedOpacity: 0.09, borderOpacity: 0, content: configuration.label)
    }
}

private struct PopoverIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBackdrop(isPressed: configuration.isPressed, radius: 7, idleOpacity: 0, hoverOpacity: 0.08, pressedOpacity: 0.12, borderOpacity: 0, content: configuration.label)
    }
}

private struct PopoverGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBackdrop(isPressed: configuration.isPressed, radius: 7, idleOpacity: 0, hoverOpacity: 0.065, pressedOpacity: 0.1, borderOpacity: 0, content: configuration.label)
    }
}

private struct PopoverActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBackdrop(isPressed: configuration.isPressed, radius: 7, idleOpacity: 0.055, hoverOpacity: 0.09, pressedOpacity: 0.13, borderOpacity: 0.11, content: configuration.label)
    }
}
