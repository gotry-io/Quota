import SwiftUI

struct ProviderQuotaView: View {
  let presentation: ProviderQuotaPresentation

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      providerHeader

      ForEach(Array(presentation.accounts.enumerated()), id: \.element.id) { index, account in
        AccountQuotaView(
          presentation: account,
          accountIndex: index,
          showsAccountStatus: presentation.accounts.count > 1
        )

        if index < presentation.accounts.count - 1 {
          Divider()
            .padding(.vertical, 2)
        }
      }
    }
    .padding(.vertical, QuotaDesign.Layout.providerRowVerticalPadding)
    .accessibilityElement(children: .combine)
  }

  private var providerHeader: some View {
    HStack(alignment: .center, spacing: 8) {
      HStack(spacing: 6) {
        ProviderBrandIcon(provider: presentation.provider)
        Text(presentation.provider.displayName)
      }
      .font(QuotaDesign.Typography.providerTitle)
      .foregroundStyle(QuotaPalette.ink)

      if presentation.accounts.count == 1,
        presentation.accounts.first?.isStale == true
      {
        StaleTag()
      }

      Spacer(minLength: 8)

      if presentation.accounts.count == 1,
        let account = presentation.accounts.first
      {
        SourceLabel(summary: account.sourceSummary)
      }
    }
  }
}

private struct AccountQuotaView: View {
  let presentation: AccountQuotaPresentation
  let accountIndex: Int
  let showsAccountStatus: Bool

  private var snapshot: QuotaSnapshot { presentation.snapshot }

  private var identitySummary: String? {
    PlanDisplay.accountSummary(
      plan: snapshot.account.plan,
      label: snapshot.account.label
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if showsAccountMetadata {
        accountHeader
      }

      ForEach(snapshot.windows) { window in
        QuotaWindowRow(
          window: window,
          observedAt: snapshot.observedAt,
          isStale: presentation.isStale
        )
      }
    }
  }

  private var showsAccountMetadata: Bool {
    if showsAccountStatus {
      return true
    }
    return identitySummary != nil
  }

  private var accountHeader: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      if let identitySummary {
        Text(identitySummary)
          .font(QuotaDesign.Typography.metadata.weight(.medium))
          .foregroundStyle(QuotaPalette.body)
          .lineLimit(1)
          .truncationMode(.middle)
          .accessibilityLabel(accessibilityIdentityLabel)
      } else if showsAccountStatus {
        Text("Account \(accountIndex + 1)")
          .font(QuotaDesign.Typography.metadata)
          .foregroundStyle(QuotaPalette.body)
      }

      if showsAccountStatus, presentation.isStale {
        StaleTag()
      }

      Spacer(minLength: 8)

      if showsAccountStatus {
        SourceLabel(summary: presentation.sourceSummary)
      }
    }
  }

  private var accessibilityIdentityLabel: String {
    let plan = PlanDisplay.planBadge(snapshot.account.plan)
    let label = PlanDisplay.accountLabel(snapshot.account.label)
    switch (plan, label) {
    case let (plan?, label?):
      return "Plan: \(plan), Account: \(label)"
    case let (plan?, nil):
      return "Plan: \(plan)"
    case let (nil, label?):
      return "Account: \(label)"
    case (nil, nil):
      return "Account"
    }
  }
}

private struct QuotaWindowRow: View {
  let window: QuotaWindow
  let observedAt: Date
  let isStale: Bool

  private var usageColor: Color {
    let color = QuotaPalette.usageColor(remainingPercent: window.remainingPercent)
    return isStale ? color.opacity(0.55) : color
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(window.title)
          .font(QuotaDesign.Typography.quotaLabel)
          .foregroundStyle(QuotaPalette.charcoal)
        Spacer(minLength: 8)
        Text(percent(window.remainingPercent))
          .font(QuotaDesign.Typography.remainingValue)
          .monospacedDigit()
          .foregroundStyle(usageColor)
          .accessibilityLabel("\(percent(window.remainingPercent)) left")
      }

      QuotaProgressBar(value: window.remainingPercent, fill: usageColor)

      HStack(alignment: .firstTextBaseline, spacing: 8) {
        if let resetsAt = window.resetsAt {
          Text("Resets \(formatResetDate(resetsAt))")
        } else {
          Text("Reset time unavailable")
        }

        if isStale {
          Text("· Observed \(observedAt, style: .relative) ago")
        }
      }
      .font(QuotaDesign.Typography.resetTime)
      .foregroundStyle(QuotaPalette.body)
      .lineLimit(1)
    }
    .padding(.top, 2)
  }
}

/// Provenance as quiet meta (icon + text), not a bordered chip.
private struct SourceLabel: View {
  let summary: String

  var body: some View {
    Label {
      Text(summary)
    } icon: {
      Image(systemName: symbolName)
    }
    .labelStyle(.titleAndIcon)
    .font(QuotaDesign.Typography.sourceTag)
    .foregroundStyle(QuotaPalette.mute)
    .symbolRenderingMode(.monochrome)
    .fixedSize()
    .accessibilityLabel("Sources: \(summary)")
  }

  private var symbolName: String {
    let normalized = summary.lowercased()
    if normalized == "local" {
      return "laptopcomputer"
    }
    if normalized == "remote" {
      return "network"
    }
    if normalized.hasPrefix("local") {
      return "laptopcomputer.and.iphone"
    }
    if normalized.contains("remote") {
      return "network"
    }
    return "circle.grid.2x1"
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
    .accessibilityValue(percent(value))
  }
}

private struct StaleTag: View {
  var body: some View {
    Label("Stale", systemImage: "clock")
      .font(QuotaDesign.Typography.statusTag)
      .foregroundStyle(QuotaPalette.charcoal)
      .padding(.horizontal, 5)
      .padding(.vertical, 2)
      .overlay {
        RoundedRectangle(cornerRadius: QuotaDesign.Layout.tagCornerRadius)
          .stroke(QuotaPalette.hairline.opacity(0.7))
      }
      .fixedSize()
  }
}

private func percent(_ value: Double) -> String {
  if abs(value.rounded() - value) < 0.05 {
    return "\(Int(value.rounded()))%"
  }
  return String(format: "%.1f%%", value)
}

private let resetDateFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.locale = Locale.current
  formatter.timeZone = .current
  // Compact absolute time: keeps second precision without a long gray line.
  formatter.dateFormat = "MM-dd HH:mm:ss"
  return formatter
}()

private func formatResetDate(_ date: Date) -> String {
  resetDateFormatter.string(from: date)
}
