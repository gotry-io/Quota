import QuotaPresentation
import QuotaWire
import SwiftUI

struct ProviderQuotaView: View {
  let presentation: ProviderQuotaPresentation
  let now: Date
  let onOpenProvider: () -> Void
  @AppStorage(PaceLinePreference.storageKey) private var showsPaceLines =
    PaceLinePreference.fallback

  /// The day of the window this provider is read by: its primary-cadence window, the same one
  /// Quota iOS names its Today section after, so both surfaces answer for the same window.
  ///
  /// A provider whose reading came from Relay has no samples behind it and takes no row.
  private var windowsToday: [QuotaHistoryWindow] {
    presentation.accounts
      .compactMap { account in
        let snapshot = account.snapshot
        return (snapshot.primaryCadenceWindows.first ?? snapshot.windows.first)?.history
      }
      .first { !$0.windowsToday.isEmpty }?
      .windowsToday ?? []
  }

  var body: some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xs) {
      Button(action: onOpenProvider) {
        providerHeader
          .padding(.horizontal, QuotaDesign.Spacing.sm)
          .frame(
            maxWidth: .infinity,
            minHeight: QuotaDesign.Layout.minimumInteractiveDimension,
            alignment: .leading
          )
          .contentShape(Rectangle())
      }
      .padding(.horizontal, -QuotaDesign.Spacing.sm)
      .buttonStyle(QuotaListRowButtonStyle(surfaceInset: 0))
      .accessibilityLabel(headerAccessibilityLabel)
      .accessibilityHint("Opens \(presentation.provider.displayName) settings")

      if let detail = presentation.status?.detail {
        Text(detail)
          .quotaSecondaryStyle()
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel(presentation.status?.accessibilityLabel ?? detail)
      }

      ForEach(Array(presentation.accounts.enumerated()), id: \.element.id) { index, account in
        AccountQuotaView(presentation: account, accountIndex: index, now: now)

        if index < presentation.accounts.count - 1 {
          Divider()
            .opacity(0.45)
            .padding(.vertical, 2)
        }
      }

      if showsPaceLines {
        TodayWindowsRow(windows: windowsToday)
      }
    }
    .padding(.vertical, QuotaDesign.Layout.providerRowVerticalPadding)
  }

  private var headerAccessibilityLabel: String {
    var parts = [presentation.provider.displayName]
    if let serviceStatus = presentation.serviceStatus,
      ProviderServiceStatusCopy.showsDot(serviceStatus.indicator)
    {
      parts.append(serviceStatus.description)
    }
    if let title = presentation.status?.title {
      parts.append(title)
    }
    return parts.joined(separator: ". ")
  }

  private var providerHeader: some View {
    HStack(alignment: .center, spacing: QuotaDesign.Spacing.inline) {
      HStack(spacing: QuotaDesign.Spacing.iconLabel) {
        ProviderBrandIcon(provider: presentation.provider)
        Text(presentation.provider.displayName)
          .quotaRowTitleStyle()
        if let serviceStatus = presentation.serviceStatus,
          ProviderServiceStatusCopy.showsDot(serviceStatus.indicator)
        {
          Circle()
            .fill(statusDotColor(serviceStatus.indicator))
            .frame(
              width: QuotaDesign.Layout.statusDotSize,
              height: QuotaDesign.Layout.statusDotSize
            )
            .help(serviceStatus.description)
            .accessibilityHidden(true)
        }
      }
      .layoutPriority(1)

      if let title = presentation.status?.title {
        Text(title)
          .quotaMetaStyle()
          .lineLimit(1)
          .fixedSize()
          .accessibilityHidden(true)
      }

      Spacer(minLength: 0)

      Image(systemName: "chevron.right")
        .quotaChevronStyle()
        .accessibilityHidden(true)
    }
  }

  private func statusDotColor(_ indicator: ProviderServiceStatusIndicator) -> Color {
    switch indicator {
    case .none:
      QuotaPalette.mute
    case .minor:
      QuotaPalette.warning
    case .major, .critical:
      QuotaPalette.critical
    }
  }
}

extension AccountQuotaPresentation {
  fileprivate var planDisplayName: String? {
    PlanDisplay.planBadge(snapshot.account.plan)
  }

  fileprivate var accountLabelDisplay: String? {
    PlanDisplay.accountLabel(snapshot.account.label)
  }
}

private struct AccountQuotaView: View {
  let presentation: AccountQuotaPresentation
  let accountIndex: Int
  let now: Date

  var body: some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.iconLabel) {
      accountHeader

      ForEach(presentation.snapshot.windows) { window in
        QuotaWindowRow(
          window: window,
          provider: presentation.snapshot.provider,
          isStale: presentation.state != .available,
          now: now
        )
      }
    }
  }

  private var accountHeader: some View {
    HStack(alignment: .center, spacing: QuotaDesign.Spacing.iconLabel) {
      Text(presentation.accountLabelDisplay ?? "Account \(accountIndex + 1)")
        .quotaFont(.quotaLabel)
        .foregroundStyle(QuotaPalette.ink)
        .lineLimit(1)
        .truncationMode(.middle)
        .layoutPriority(1)
        .accessibilityLabel(
          presentation.accessibilityLabel(accountIndex: accountIndex, now: now)
        )

      Spacer(minLength: 8)

      if let plan = presentation.planDisplayName {
        Text(plan)
          .quotaFont(.quotaLabel)
          .foregroundStyle(QuotaPalette.body)
          .lineLimit(1)
          .fixedSize()
          .accessibilityLabel("Plan: \(plan)")
      }
    }
  }
}

struct QuotaWindowRow: View {
  let window: QuotaWindow
  let provider: ProviderID
  let isStale: Bool
  let now: Date
  @AppStorage(ResetCopyStylePreference.storageKey) private var resetCopyStyle =
    ResetCopyStylePreference.fallback
  @AppStorage(PaceLinePreference.storageKey) private var showsPaceLines =
    PaceLinePreference.fallback

  private var remainingLabel: String {
    window.overviewRemainingDisplayLabel(provider: provider)
  }

  private var meterColor: Color {
    let color = QuotaPalette.usageColor(remainingPercent: window.remainingPercent)
    return isStale ? color.opacity(0.55) : color
  }

  private var valueColor: Color {
    isStale ? QuotaPalette.mute : QuotaPalette.ink
  }

  /// The pace this window's reading was published with, and whether it warns.
  ///
  /// The service derived it; the panel prints it. A window with no pace takes no line.
  private var paceLine: (text: String, warns: Bool)? {
    guard let pace = window.pace,
      let text = QuotaPaceCopy.line(pace, resetsAt: window.resetsAt)
    else {
      return nil
    }
    if case .runsOut = pace { return (text, true) }
    return (text, false)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.meta) {
      HStack(alignment: .firstTextBaseline, spacing: QuotaDesign.Spacing.inline) {
        Text(window.displayTitle)
          .quotaFont(.quotaLabel)
          .foregroundStyle(QuotaPalette.body)
        Spacer(minLength: 8)
        Text(remainingLabel)
          .quotaFont(.remainingValue)
          .monospacedDigit()
          .foregroundStyle(valueColor)
          .accessibilityLabel(remainingLabel)
      }

      if window.showsPercentMeter {
        QuotaProgressBar(value: window.remainingPercent, fill: meterColor)
      }

      if showsPaceLines, let history = window.history, !history.points.isEmpty {
        QuotaPaceLineView(history: history, tint: meterColor)
      }

      if let resetsAt = window.resetsAt,
        let reset = FreshnessCopy.resetCopy(
          resetsAt: resetsAt, now: now, style: resetCopyStyle.style)
      {
        Text(reset)
          .quotaMetaStyle()
      } else if window.resetsAt == nil, FreshnessCopy.showsNoResetTime(window) {
        Text(FreshnessCopy.noResetTime)
          .quotaMetaStyle()
      }

      if let paceLine {
        Text(paceLine.text)
          .quotaFont(.meta)
          .foregroundStyle(paceLine.warns ? QuotaPalette.warning : QuotaPalette.mute)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.top, 2)
  }
}

private struct QuotaProgressBar: View {
  let value: Double
  let fill: Color

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule()
          .fill(QuotaPalette.progressTrack)
        Capsule()
          .fill(fill)
          .frame(width: geometry.size.width * min(max(value / 100, 0), 1))
      }
    }
    .frame(height: QuotaDesign.Layout.progressHeight)
    .accessibilityLabel("Remaining quota")
    .accessibilityValue(QuotaWindow.formattedPercent(value))
  }
}
