import QuotaWire
import SwiftUI

struct OverviewView: View {
  @Bindable var model: AppModel
  @State private var showsPaywall = false

  var body: some View {
    List {
      if let status = statusLine {
        Section {
          StatusMessage(symbolName: status.symbolName, text: status.text)
            .accessibilityIdentifier("overview.status")
        }
      }

      if let sync = model.syncBanner {
        Section {
          Button {
            showsPaywall = true
          } label: {
            HStack(spacing: 12) {
              StatusMessage(symbolName: "arrow.trianglehead.2.clockwise.rotate.90", text: sync)
              Image(systemName: "chevron.forward")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            }
          }
          .accessibilityHint("Opens Sync across devices")
          .accessibilityIdentifier("overview.sync-off")
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
    .environment(\.defaultMinListRowHeight, QuotaTheme.minimumTouchTarget)
    .accessibilityIdentifier("overview.root")
    .refreshable {
      await model.refresh()
    }
    .navigationTitle(model.accountLabel)
    .navigationBarTitleDisplayMode(.large)
    .sheet(isPresented: $showsPaywall) {
      NavigationStack {
        PaywallView(model: model)
          .toolbar {
            ToolbarItem(placement: .confirmationAction) {
              Button("Done") { showsPaywall = false }
            }
          }
      }
    }
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
              ProviderQuotaRow(
                provider: card.provider,
                snapshot: subscription.snapshot,
                accountIndex: index
              )
              .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .tint(.primary)
            .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
            .accessibilityHint("Opens subscription details")
            .accessibilityIdentifier("overview.subscription")
          }
        }
      }
    } footer: {
      if let updatedAt = model.updatedAt {
        Text(QuotaFormat.updated(updatedAt))
          .font(.footnote.monospacedDigit())
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
    ContentUnavailableView {
      Label(Self.title, systemImage: "gauge.with.dots.needle.33percent")
    } description: {
      Text(model.hasAccountSession ? Self.accountOnly : Self.localAndAccount)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
    } actions: {
      VStack(spacing: 12) {
        Button(Self.connectProvider) { model.showProviders() }
          .frame(minHeight: QuotaTheme.minimumTouchTarget)
          .accessibilityIdentifier("overview.connect-provider")
        if !model.hasAccountSession {
          Button(Self.signIn) { Task { await model.connectAccount() } }
            .frame(minHeight: QuotaTheme.minimumTouchTarget)
            .accessibilityIdentifier("overview.signin")
        }
      }
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
      todayContent
    } header: {
      Text("Today")
        .accessibilityIdentifier("section.header.today")
        .accessibilityAddTraits(.isHeader)
    }
    .accessibilityIdentifier("overview.today")
  }

  @ViewBuilder
  private var todayContent: some View {
    let usage = summary.usage.today
    if usage.totals.messages > 0 || usage.totals.inputTokens > 0
      || usage.totals.outputTokens > 0
    {
      todayRow(
        label: "Tokens",
        value: QuotaFormat.compactCount(usage.totals.totalTokens),
        accessibility: "\(QuotaFormat.accessibleCount(usage.totals.totalTokens)) tokens",
        identifier: "overview.today.tokens"
      )
      todayRow(
        label: "API-equivalent cost",
        value: QuotaFormat.cost(usage.cost),
        accessibility: "API-equivalent cost, \(QuotaFormat.costAccessibility(usage.cost))",
        identifier: "overview.today.cost"
      )
      todayRow(
        label: "Input",
        value: QuotaFormat.compactCount(usage.totals.inputTokens),
        accessibility: "\(QuotaFormat.accessibleCount(usage.totals.inputTokens)) input tokens",
        identifier: "overview.today.input"
      )
      todayRow(
        label: "Output",
        value: QuotaFormat.compactCount(usage.totals.outputTokens),
        accessibility: "\(QuotaFormat.accessibleCount(usage.totals.outputTokens)) output tokens",
        identifier: "overview.today.output"
      )
    } else {
      Text("No usage today.")
        .font(.body)
        .foregroundStyle(.primary)
        .accessibilityIdentifier("overview.today.empty")
    }
  }

  private func todayRow(
    label: String,
    value: String,
    accessibility: String,
    identifier: String
  ) -> some View {
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
    .accessibilityIdentifier(identifier)
  }
}
