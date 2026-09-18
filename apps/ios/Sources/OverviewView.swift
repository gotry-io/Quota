import QuotaWire
import SwiftUI

struct OverviewView: View {
  @Bindable var model: AppModel

  var body: some View {
    List {
      if let status = statusLine {
        Section {
          StatusMessage(symbolName: status.symbolName, text: status.text)
            .accessibilityIdentifier("overview.status")
        }
      }

      quotaSection

      // Today Usage is the Account's fold of what every device reported. A phone with no account
      // has no such number, and a zero it never measured would be a lie rather than an empty
      // state.
      if let summary = model.summary {
        TodayUsageSection(summary: summary)
      }

      if model.summary?.devices.isEmpty == true {
        MacSetupGuideSection()
      }
    }
    .listStyle(.insetGrouped)
    .listRowSpacing(QuotaDesign.Layout.rowSpacing)
    .listSectionSpacing(.custom(QuotaDesign.Layout.sectionSpacing))
    .environment(\.defaultMinListRowHeight, QuotaTheme.minimumTouchTarget)
    .accessibilityIdentifier("overview.root")
    .refreshable {
      await model.refresh()
    }
    .navigationTitle(model.accountLabel)
    .navigationBarTitleDisplayMode(.large)
  }

  /// An expired session is the reason to sign in again, so it outranks a refresh failure.
  private var statusLine: (symbolName: String, text: String)? {
    if let expired = model.expiredMessage {
      return ("lock.slash", expired)
    }
    if let banner = model.banner {
      return (banner.symbolName, banner.text)
    }
    return nil
  }

  @ViewBuilder
  private var quotaSection: some View {
    let providerCards = model.providerCards
    Section {
      if providerCards.isEmpty {
        OverviewEmptyState(model: model)
      } else {
        ForEach(providerCards) { card in
          ForEach(Array(card.subscriptions.enumerated()), id: \.element.id) {
            index,
            subscription in
            NavigationLink(value: subscription.key) {
              QuotaCard {
                ProviderQuotaRow(
                  provider: card.provider,
                  snapshot: subscription.snapshot,
                  accountIndex: index,
                  serviceStatus: model.providerStatus[card.provider]
                )
                .foregroundStyle(.primary)
              }
            }
            .buttonStyle(.plain)
            .tint(.primary)
            .quotaCardRow()
            .navigationLinkIndicatorVisibility(.hidden)
            .accessibilityHint("Opens subscription details")
            .accessibilityIdentifier("overview.subscription")
          }
        }
      }
    } footer: {
      if let updatedAt = model.updatedAt {
        Text(QuotaFormat.updated(updatedAt))
          .font(QuotaDesign.Typography.meta.monospacedDigit())
          .foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("section.footer.updated")
      }
    }
  }
}

/// Nothing to show, and the two ways to change that.
///
/// A phone reads its own providers and an account answers for every Mac, so an empty Overview
/// offers whichever of those this phone is short of rather than a single instruction to install
/// something on a computer it may not have.
struct OverviewEmptyState: View {
  @Bindable var model: AppModel

  static let title = "No quota yet"
  static let localAndAccount =
    "Connect a provider to read your quota on this iPhone, or sign in to Quota to see what your "
    + "Macs report."
  static let accountOnly =
    "Set up QuotaBar on a Mac to start reporting, or connect a provider to read it on this iPhone."
  static let connectProvider = "Connect a provider"
  static let signIn = "Sign in to Quota"

  var body: some View {
    VStack(spacing: QuotaDesign.Layout.rowSpacing) {
      ContentUnavailableView {
        Label(Self.title, systemImage: "gauge.with.dots.needle.33percent")
      } description: {
        Text(model.hasAccountSession ? Self.accountOnly : Self.localAndAccount)
          .foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)
      }
      VStack(spacing: QuotaDesign.Layout.rowSpacing) {
        Button(action: { model.showProviders() }) {
          Text(Self.connectProvider)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .frame(maxWidth: .infinity, minHeight: QuotaTheme.minimumTouchTarget)
        .accessibilityIdentifier("overview.connect-provider")
        if !model.hasAccountSession {
          Button(action: { model.showSignIn() }) {
            Text(Self.signIn)
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.bordered)
          .controlSize(.large)
          .frame(maxWidth: .infinity, minHeight: QuotaTheme.minimumTouchTarget)
          .accessibilityIdentifier("overview.signin")
        }
      }
      .frame(maxWidth: .infinity)
    }
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: .infinity, minHeight: 200)
    .listRowBackground(Color.clear)
    .listRowSeparator(.hidden)
    .accessibilityIdentifier("overview.empty")
  }
}

struct TodayUsageSection: View {
  let summary: AccountSummary

  var body: some View {
    Section {
      QuotaCard(title: "Today", titleIdentifier: "section.header.today") {
        todayContent
      }
      .accessibilityIdentifier("overview.today")
      .quotaCardRow()
    }
  }

  @ViewBuilder
  private var todayContent: some View {
    let usage = summary.usage.today
    if usage.totals.messages > 0 || usage.totals.inputTokens > 0
      || usage.totals.outputTokens > 0
    {
      QuotaStatGrid {
        QuotaStatTile(
          label: "Tokens",
          value: QuotaFormat.compactCount(usage.totals.totalTokens)
        )
        .accessibilityLabel(
          "\(QuotaFormat.accessibleCount(usage.totals.totalTokens)) tokens"
        )
        .accessibilityIdentifier("overview.today.tokens")
        QuotaStatTile(
          label: "API-equivalent cost",
          value: QuotaFormat.cost(usage.cost)
        )
        .accessibilityLabel(
          "API-equivalent cost, \(QuotaFormat.costAccessibility(usage.cost))"
        )
        .accessibilityIdentifier("overview.today.cost")
        QuotaStatTile(
          label: "Input",
          value: QuotaFormat.compactCount(usage.totals.inputTokens)
        )
        .accessibilityLabel(
          "\(QuotaFormat.accessibleCount(usage.totals.inputTokens)) input tokens"
        )
        .accessibilityIdentifier("overview.today.input")
        QuotaStatTile(
          label: "Output",
          value: QuotaFormat.compactCount(usage.totals.outputTokens)
        )
        .accessibilityLabel(
          "\(QuotaFormat.accessibleCount(usage.totals.outputTokens)) output tokens"
        )
        .accessibilityIdentifier("overview.today.output")
      }
    } else {
      Text("No usage today.")
        .font(.body)
        .foregroundStyle(.primary)
        .accessibilityIdentifier("overview.today.empty")
    }
  }
}
