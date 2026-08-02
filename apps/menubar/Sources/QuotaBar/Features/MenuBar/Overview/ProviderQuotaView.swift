import SwiftUI

struct ProviderQuotaView: View {
  let presentation: ProviderQuotaPresentation

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      providerHeader

      ForEach(Array(presentation.accounts.enumerated()), id: \.element.id) { index, account in
        AccountQuotaView(
          presentation: account,
          accountIndex: index,
          showsAccountStatus: presentation.accounts.count > 1
        )

        if index < presentation.accounts.count - 1 {
          Divider()
            .overlay(QuotaPalette.hairline)
            .padding(.vertical, 4)
        }
      }
    }
    .padding(.vertical, QuotaDesign.Layout.providerRowVerticalPadding)
    .accessibilityElement(children: .combine)
  }

  private var providerHeader: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      HStack(spacing: 6) {
        ProviderBrandIcon(provider: presentation.provider)
        Text(presentation.provider.displayName)
      }
      .font(QuotaDesign.Typography.providerTitle)
      .foregroundStyle(QuotaPalette.ink)

      Text("Local")
        .font(QuotaDesign.Typography.sourceTag)
        .foregroundStyle(QuotaPalette.charcoal)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .overlay {
          RoundedRectangle(cornerRadius: QuotaDesign.Layout.tagCornerRadius)
            .stroke(QuotaPalette.hairline.opacity(0.5))
        }
        .fixedSize()
        .accessibilityLabel("Source: Local")

      if presentation.accounts.count == 1,
        presentation.accounts.first?.isStale == true
      {
        StaleTag()
      }

      Spacer()
    }
  }
}

private struct AccountQuotaView: View {
  let presentation: AccountQuotaPresentation
  let accountIndex: Int
  let showsAccountStatus: Bool

  private var snapshot: QuotaSnapshot { presentation.snapshot }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let accountSummary = accountSummary(snapshot.account) {
        accountHeader(title: accountSummary)
      } else if showsAccountStatus {
        accountHeader(title: "Account \(accountIndex + 1)")
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

  private func accountHeader(title: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(title)
        .lineLimit(1)
        .truncationMode(.middle)

      if showsAccountStatus, presentation.isStale {
        StaleTag()
      }
    }
    .font(QuotaDesign.Typography.metadata)
    .foregroundStyle(QuotaPalette.body)
  }
}

private struct QuotaWindowRow: View {
  let window: QuotaWindow
  let observedAt: Date
  let isStale: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(alignment: .firstTextBaseline) {
        Text(window.title)
          .font(QuotaDesign.Typography.quotaLabel)
          .foregroundStyle(QuotaPalette.charcoal)
        Spacer()
        Text("\(percent(window.remainingPercent)) left")
          .font(QuotaDesign.Typography.quotaLabel)
          .monospacedDigit()
          .foregroundStyle(QuotaPalette.ink)
      }

      QuotaProgressBar(value: window.remainingPercent)
      VStack(alignment: .leading, spacing: 2) {
        if let resetsAt = window.resetsAt {
          Text("Resets \(resetsAt, style: .relative)")
        } else {
          Text("Reset time unavailable")
        }

        if isStale {
          Text("Observed \(observedAt, style: .relative) ago")
        }
      }
      .font(QuotaDesign.Typography.resetTime)
      .foregroundStyle(QuotaPalette.body)
    }
    .padding(.top, 6)
  }
}

private struct QuotaProgressBar: View {
  let value: Double

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule()
          .fill(QuotaPalette.hairline)
        Capsule()
          .fill(QuotaPalette.ink)
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
          .stroke(QuotaPalette.hairline.opacity(0.55))
      }
      .fixedSize()
  }
}

private func accountSummary(_ account: QuotaAccount) -> String? {
  let summary = [account.plan, account.label]
    .compactMap { $0 }
    .filter { !$0.isEmpty }
    .joined(separator: " · ")
  return summary.isEmpty ? nil : summary
}

private func percent(_ value: Double) -> String {
  if abs(value.rounded() - value) < 0.05 {
    return "\(Int(value.rounded()))%"
  }
  return String(format: "%.1f%%", value)
}
