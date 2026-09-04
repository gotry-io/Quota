import QuotaWire
import SwiftUI

struct OverviewView: View {
  @Bindable var model: AppModel

  var body: some View {
    List {
      if let banner = model.banner {
        Section {
          StatusMessage(symbolName: banner.symbolName, text: banner.text)
            .accessibilityIdentifier("overview.status")
        }
      }

      quotaSection

      TodayUsageSection(summary: model.summary)

      if model.summary?.devices.isEmpty == true {
        MacSetupGuideSection()
      }
    }
    .listStyle(.insetGrouped)
    .environment(\.defaultMinListRowHeight, QuotaTheme.minimumTouchTarget)
    .accessibilityIdentifier("overview.root")
    .refreshable {
      await model.refresh()
    }
    .navigationTitle(model.accountLabel)
    .navigationBarTitleDisplayMode(.large)
  }

  @ViewBuilder
  private var quotaSection: some View {
    let providerCards = model.providerCards
    Section {
      if providerCards.isEmpty {
        ContentUnavailableView {
          Label("No quota yet", systemImage: "gauge.with.dots.needle.33percent")
            .foregroundStyle(Color(uiColor: .label))
        } description: {
          Text("Set up QuotaBar on a Mac to start reporting.")
            .foregroundStyle(Color(uiColor: .label))
            .fixedSize(horizontal: false, vertical: true)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, minHeight: 180)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
      } else {
        ForEach(providerCards) { card in
          ForEach(Array(card.subscriptions.enumerated()), id: \.element.id) {
            index,
            subscription in
            NavigationLink(value: subscription.key) {
              ProviderQuotaRow(
                provider: card.provider,
                snapshot: subscription.snapshot,
                accountIndex: index
              )
              .foregroundStyle(Color(uiColor: .label))
            }
            .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
            .accessibilityHint("Opens subscription details")
            .accessibilityIdentifier("overview.subscription")
          }
        }
      }
    } footer: {
      if let fetchedAt = model.fetchedAt {
        Text(QuotaFormat.updated(fetchedAt))
          .font(.footnote.monospacedDigit())
          .foregroundStyle(Color(uiColor: .label))
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

struct TodayUsageSection: View {
  let summary: AccountSummary?

  var body: some View {
    Section("Today") {
      todayContent
    }
    .accessibilityIdentifier("overview.today")
  }

  @ViewBuilder
  private var todayContent: some View {
    if let usage = summary?.usage.today,
      usage.totals.messages > 0 || usage.totals.inputTokens > 0
        || usage.totals.outputTokens > 0
    {
      todayRow(
        label: "Tokens",
        value: QuotaFormat.compactCount(usage.totals.totalTokens),
        accessibility: "\(QuotaFormat.accessibleCount(usage.totals.totalTokens)) tokens"
      )
      todayRow(
        label: "API-equivalent cost",
        value: QuotaFormat.cost(usage.cost),
        accessibility: "API-equivalent cost, \(QuotaFormat.costAccessibility(usage.cost))"
      )
      todayRow(
        label: "Input",
        value: QuotaFormat.compactCount(usage.totals.inputTokens),
        accessibility: "\(QuotaFormat.accessibleCount(usage.totals.inputTokens)) input tokens"
      )
      todayRow(
        label: "Output",
        value: QuotaFormat.compactCount(usage.totals.outputTokens),
        accessibility: "\(QuotaFormat.accessibleCount(usage.totals.outputTokens)) output tokens"
      )
    } else {
      Text("No usage today.")
        .font(.body)
        .foregroundStyle(.primary)
    }
  }

  private func todayRow(label: String, value: String, accessibility: String) -> some View {
    LabeledContent {
      Text(value)
        .font(.body.monospacedDigit().weight(.medium))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    } label: {
      Text(label)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibility)
  }
}
