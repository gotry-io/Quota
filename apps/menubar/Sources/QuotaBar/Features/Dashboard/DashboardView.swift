import QuotaPresentation
import QuotaWire
import SwiftUI

/// Quota workspace: a subscription list beside one selected subscription's detail.
struct DashboardView: View {
  var dashboard: DashboardModel
  let now: Date

  @AppStorage(ResetCopyStylePreference.storageKey) private var resetCopyStyle =
    ResetCopyStylePreference.fallback
  @State private var selectedHistoryWindowID: String?

  private var subscriptions: [DashboardProvider] {
    dashboard.subscriptions(now: now)
  }

  private var selectedID: String? {
    dashboard.resolvedSubscriptionID(now: now)
  }

  private var selected: DashboardProvider? {
    dashboard.selectedSubscription(now: now)
  }

  var body: some View {
    Group {
      if let empty = dashboard.pageEmptyState(now: now) {
        emptyState(empty)
      } else {
        GeometryReader { geo in
          if geo.size.width >= QuotaDesign.Layout.quotaWorkspaceMinWidth {
            wideLayout
              .frame(width: geo.size.width, height: geo.size.height)
          } else {
            compactLayout
              .frame(width: geo.size.width, height: geo.size.height)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .accessibilityIdentifier("quota.workspace")
    .onChange(of: selectedID) { _, _ in
      selectedHistoryWindowID = nil
    }
  }

  private var wideLayout: some View {
    HStack(spacing: 0) {
      subscriptionList
        .frame(width: QuotaDesign.Layout.quotaListWidth)
        .frame(maxHeight: .infinity)
      Rectangle()
        .fill(QuotaPalette.hairline)
        .frame(width: QuotaDesign.Layout.columnHairlineWidth)
        .frame(maxHeight: .infinity)
      detailScroll
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var compactLayout: some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.md) {
      subscriptionPicker
        .padding(.horizontal, QuotaDesign.Layout.contentGutter)
        .padding(.top, QuotaDesign.Layout.pageVerticalPadding)
      detailScroll
    }
  }

  private var subscriptionList: some View {
    List(selection: selectionBinding) {
      ForEach(subscriptions) { item in
        DashboardSubscriptionRow(item: item)
          .tag(Optional(item.id))
          .listRowSeparator(.hidden)
      }
    }
    .listStyle(.sidebar)
    .scrollContentBackground(.hidden)
    .accessibilityIdentifier("quota.subscription.list")
  }

  private var subscriptionPicker: some View {
    Picker("Subscription", selection: selectionBinding) {
      ForEach(subscriptions) { item in
        Text(pickerLabel(item)).tag(Optional(item.id))
      }
    }
    .pickerStyle(.menu)
    .labelsHidden()
    .frame(maxWidth: 360, alignment: .leading)
    .accessibilityLabel("Subscription")
    .accessibilityValue(selected.map(pickerLabel) ?? "")
    .accessibilityIdentifier("quota.subscription.picker")
  }

  private var selectionBinding: Binding<String?> {
    Binding(
      get: { selectedID },
      set: { newValue in
        if let newValue {
          dashboard.selectSubscription(newValue)
        }
      }
    )
  }

  private var detailScroll: some View {
    ScrollView {
      Group {
        if let selected {
          DashboardSubscriptionDetail(
            item: selected,
            now: now,
            resetStyle: resetCopyStyle.style,
            selectedHistoryWindowID: $selectedHistoryWindowID
          )
        }
      }
      .padding(.horizontal, QuotaDesign.Layout.contentGutter)
      .padding(.vertical, QuotaDesign.Layout.pageVerticalPadding)
      .frame(maxWidth: QuotaDesign.Layout.settingsContentMaxWidth, alignment: .topLeading)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder
  private func emptyState(_ empty: DashboardEmptyState) -> some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.md) {
      switch empty {
      case .rebuilding:
        CacheRebuildNotice()
      case .noSubscriptions:
        Text("No quota yet")
          .quotaSecondaryStyle()
      }
    }
    .padding(QuotaDesign.Layout.contentGutter)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private func pickerLabel(_ item: DashboardProvider) -> String {
    if let account = item.accountLabel {
      return "\(item.provider.displayName) · \(account)"
    }
    return item.provider.displayName
  }
}

private struct DashboardSubscriptionRow: View {
  let item: DashboardProvider

  var body: some View {
    HStack(alignment: .center, spacing: QuotaDesign.Spacing.sm) {
      ProviderBrandIcon(
        provider: item.provider,
        size: QuotaDesign.Layout.settingsIconColumnWidth
      )
      VStack(alignment: .leading, spacing: 1) {
        Text(item.provider.displayName)
          .quotaRowTitleStyle()
          .lineLimit(1)
        HStack(spacing: QuotaDesign.Spacing.xs) {
          if let account = item.accountLabel {
            Text(account)
              .quotaMetaStyle()
              .lineLimit(1)
          }
          if let plan = item.plan {
            DashboardPlanCapsule(plan: plan)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if let remaining = item.remainingPercent {
        VStack(alignment: .trailing, spacing: 2) {
          Text(RemainingQuotaFormat.percent(remaining))
            .quotaFont(.remainingValue)
            .monospacedDigit()
            .foregroundStyle(QuotaPalette.ink)
            .lineLimit(1)
          QuotaRemainingMeter(
            value: remaining,
            fill: QuotaPalette.usageColor(remainingPercent: remaining)
          )
          .frame(width: 48)
          .accessibilityHidden(true)
        }
      }
    }
    .padding(.vertical, QuotaDesign.Spacing.xxs)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(item.rowAccessibilityLabel)
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("quota.subscription.row")
  }
}

private struct DashboardSubscriptionDetail: View {
  let item: DashboardProvider
  let now: Date
  let resetStyle: ResetCopyStyle
  @Binding var selectedHistoryWindowID: String?

  var body: some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.section) {
      header
      windows
      remainingHistory
      if !item.sources.isEmpty {
        sources
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .accessibilityIdentifier("quota.subscription.detail")
  }

  private var header: some View {
    HStack(alignment: .center, spacing: QuotaDesign.Spacing.sm) {
      ProviderBrandIcon(
        provider: item.provider,
        size: QuotaDesign.Layout.quotaDetailMarkSize
      )
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xxs) {
        HStack(alignment: .center, spacing: QuotaDesign.Spacing.xs) {
          Text(item.provider.displayName)
            .quotaOverviewProviderTitleStyle()
            .lineLimit(1)
          if let plan = item.plan {
            DashboardPlanCapsule(plan: plan)
          }
        }
        Text(supportingLine)
          .quotaMetaStyle()
          .lineLimit(1)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(headerAccessibility)
  }

  private var supportingLine: String {
    if let account = item.accountLabel {
      return "\(account) · \(item.freshness)"
    }
    return item.freshness
  }

  private var headerAccessibility: String {
    var parts = [item.provider.displayName]
    if let plan = item.plan { parts.append(plan) }
    if let account = item.accountLabel { parts.append(account) }
    parts.append(item.freshness)
    return parts.joined(separator: ", ")
  }

  @ViewBuilder
  private var windows: some View {
    if item.quotaWindows.isEmpty {
      Text("No quota windows yet.")
        .quotaSecondaryStyle()
        .padding(QuotaDesign.Layout.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .quotaCardSurface()
    } else {
      ForEach(item.quotaWindows) { window in
        DashboardQuotaWindowCard(
          window: window,
          provider: item.provider,
          isStale: item.isStale,
          now: now,
          resetStyle: resetStyle
        )
      }
    }
  }

  @ViewBuilder
  private var remainingHistory: some View {
    if item.quotaWindows.isEmpty {
      EmptyView()
    } else {
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.md) {
        historyHeader
        historyBody
      }
      .padding(QuotaDesign.Layout.cardPadding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .quotaCardSurface()
    }
  }

  private var historyHeader: some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.sm) {
      HStack(alignment: .firstTextBaseline, spacing: QuotaDesign.Spacing.sm) {
        Text(DashboardQuotaCopy.remainingHistory)
          .quotaRowTitleStyle()
          .accessibilityAddTraits(.isHeader)
        Spacer(minLength: QuotaDesign.Spacing.sm)
        if item.isLocalReading {
          Text(DashboardQuotaCopy.thisMac)
            .quotaMetaStyle()
            .accessibilityIdentifier("quota.history.scope")
        }
      }
      if item.showsHistoryWindowPicker {
        Picker("Window", selection: windowSelection) {
          ForEach(item.quotaWindows) { window in
            Text(window.displayTitle).tag(window.id)
          }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .accessibilityLabel("History window")
        .accessibilityIdentifier("quota.history.window")
      }
    }
  }

  @ViewBuilder
  private var historyBody: some View {
    if !item.isLocalReading {
      Text(DashboardQuotaCopy.remoteOnlyHistory)
        .quotaSecondaryStyle()
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("quota.history")
    } else if let window = selectedHistoryWindow,
      let history = item.remainingHistories[window.id],
      !history.observedPoints.isEmpty
    {
      QuotaRemainingHistoryChart(
        history: history,
        tint: QuotaPalette.usageColor(remainingPercent: window.remainingPercent),
        windowTitle: window.displayTitle
      )
    } else {
      Text(DashboardQuotaCopy.notEnoughHistory)
        .quotaSecondaryStyle()
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("quota.history")
    }
  }

  private var windowSelection: Binding<String> {
    Binding(
      get: {
        if let selectedHistoryWindowID,
          item.quotaWindows.contains(where: { $0.id == selectedHistoryWindowID })
        {
          return selectedHistoryWindowID
        }
        return item.quotaWindows.first?.id ?? ""
      },
      set: { selectedHistoryWindowID = $0 }
    )
  }

  private var selectedHistoryWindow: QuotaWindow? {
    let id = windowSelection.wrappedValue
    return item.quotaWindows.first { $0.id == id } ?? item.quotaWindows.first
  }

  private var sources: some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.sm) {
      Text(DashboardQuotaCopy.readings(item.sources.count))
        .quotaRowTitleStyle()
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("quota.sources")
      ForEach(item.sources) { row in
        sourceRow(row)
      }
    }
    .padding(QuotaDesign.Layout.cardPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .quotaCardSurface()
  }

  private func sourceRow(_ row: DashboardSourceRow) -> some View {
    HStack(alignment: .center, spacing: QuotaDesign.Spacing.sm) {
      Image(systemName: row.isLocal ? "laptopcomputer" : "desktopcomputer")
        .quotaFont(.secondary)
        .foregroundStyle(QuotaPalette.body)
        .frame(width: QuotaDesign.Layout.settingsIconColumnWidth)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(row.displayName)
          .quotaSettingsLabelStyle()
          .fixedSize(horizontal: false, vertical: true)
        if let remaining = row.remaining {
          Text(remaining)
            .quotaMetaStyle()
            .monospacedDigit()
        }
        Text(row.freshness)
          .quotaMetaStyle()
          .monospacedDigit()
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if row.isReporting {
        Text("Reporting")
          .quotaFont(.meta)
          .foregroundStyle(QuotaPalette.accent)
          .padding(.horizontal, QuotaDesign.Spacing.sm)
          .padding(.vertical, 3)
          .overlay {
            Capsule().strokeBorder(QuotaPalette.accent, lineWidth: 1)
          }
          .accessibilityHidden(true)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(sourceAccessibility(row))
    .accessibilityIdentifier(row.isReporting ? "quota.reporting" : "quota.source")
  }

  private func sourceAccessibility(_ row: DashboardSourceRow) -> String {
    var parts = [row.displayName]
    if let remaining = row.remaining { parts.append(remaining) }
    parts.append(row.freshness)
    if row.isReporting { parts.append("Reporting") }
    return parts.joined(separator: ", ")
  }
}

private struct DashboardQuotaWindowCard: View {
  let window: QuotaWindow
  let provider: ProviderID
  let isStale: Bool
  let now: Date
  let resetStyle: ResetCopyStyle

  private var remainingLabel: String {
    window.overviewRemainingDisplayLabel(provider: provider)
  }

  private var meterColor: Color {
    let color = QuotaPalette.usageColor(remainingPercent: window.remainingPercent)
    return isStale ? color.opacity(0.55) : color
  }

  private var paceHeadline: (text: String, warns: Bool)? {
    guard let pace = window.pace,
      let text = QuotaPaceCopy.headline(pace, resetsAt: window.resetsAt)
    else {
      return nil
    }
    if case .runsOut = pace { return (text, true) }
    return (text, false)
  }

  private var paceDetail: String? {
    guard paceHeadline != nil, let pace = window.pace else { return nil }
    return QuotaPaceCopy.detail(pace)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.sm) {
      Text(window.displayTitle)
        .quotaSecondaryStyle()
        .fixedSize(horizontal: false, vertical: true)

      Text(remainingLabel)
        .font(QuotaDesign.Typography.statValue)
        .foregroundStyle(isStale ? QuotaPalette.mute : QuotaPalette.ink)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(remainingLabel)

      if window.showsPercentMeter {
        QuotaRemainingMeter(value: window.remainingPercent, fill: meterColor)
          .accessibilityHidden(true)
      }

      if let resetsAt = window.resetsAt,
        let reset = FreshnessCopy.resetCopy(resetsAt: resetsAt, now: now, style: resetStyle)
      {
        Text(reset)
          .quotaMetaStyle()
      } else if window.resetsAt == nil, FreshnessCopy.showsNoResetTime(window) {
        Text(FreshnessCopy.noResetTime)
          .quotaMetaStyle()
      }

      if let paceHeadline {
        Text(paceHeadline.text)
          .quotaFont(.meta)
          .foregroundStyle(paceHeadline.warns ? QuotaPalette.warning : QuotaPalette.mute)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let paceDetail {
        Text(paceDetail)
          .quotaFont(.meta)
          .foregroundStyle(QuotaPalette.mute)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(QuotaDesign.Layout.cardPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .quotaCardSurface()
  }
}

private struct DashboardPlanCapsule: View {
  let plan: String

  var body: some View {
    Text(plan)
      .quotaFont(.meta)
      .foregroundStyle(QuotaPalette.ink)
      .fixedSize()
      .padding(.horizontal, QuotaDesign.Spacing.sm)
      .padding(.vertical, 2)
      .overlay {
        Capsule().strokeBorder(QuotaPalette.hairlineBorder, lineWidth: 1)
      }
      .accessibilityLabel("Plan: \(plan)")
  }
}
