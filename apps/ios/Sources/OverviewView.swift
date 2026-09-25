import QuotaPresentation
import QuotaWire
import SwiftUI

struct OverviewView: View {
  @Bindable var model: AppModel
  @Environment(\.displayClock) private var displayClock

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
        TodayUsageSection(model: model, usage: summary.usage.today)
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
    .navigationTitle(AppTab.quota.title)
    .navigationSubtitle(subtitle)
    .navigationBarTitleDisplayMode(.large)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        OverviewRefreshButton(model: model)
      }
    }
  }

  /// Under the title: **Updating…** while a refresh runs, then when the readings on screen were
  /// last refreshed.
  private var subtitle: String {
    if model.isRefreshing {
      return OverviewCopy.updatingLine(progress: model.refreshProgress)
    }
    guard let updatedAt = model.updatedAt else { return "" }
    return QuotaFormat.updated(updatedAt, now: displayClock.now())
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
    let placeholders = model.overviewPlaceholders
    Section {
      if placeholders > 0 {
        ForEach(0..<placeholders, id: \.self) { _ in
          QuotaCard {
            OverviewPlaceholderRow()
          }
          .quotaCardRow()
        }
      } else if providerCards.isEmpty {
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
                  serviceStatus: model.providerStatus[card.provider],
                  isAwaitingReading: model.isAwaitingReading(subscription)
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
    }
  }
}

enum OverviewCopy {
  static let updating = "Updating…"
  static let refresh = "Refresh"
  static let loadingQuota = "Loading quota"

  /// **Updating…**, and how many of this refresh's reads have answered once one has.
  static func updatingLine(progress: (answered: Int, total: Int)?) -> String {
    guard let progress else { return updating }
    return "\(updating) \(progress.answered) of \(progress.total)"
  }
}

/// The trailing Overview control: a refresh, or the one already running. Pull to refresh does the
/// same thing; this is the way to ask without scrolling.
struct OverviewRefreshButton: View {
  @Bindable var model: AppModel

  var body: some View {
    Button {
      Task { await model.refresh() }
    } label: {
      if model.isRefreshing {
        ProgressView()
          .controlSize(.small)
      } else {
        Image(systemName: "arrow.clockwise")
      }
    }
    .disabled(model.isRefreshing)
    .accessibilityLabel(model.isRefreshing ? OverviewCopy.updating : OverviewCopy.refresh)
    .accessibilityIdentifier("overview.refresh")
  }
}

/// A card-shaped stand-in while the first refresh is on its way and nothing has been read yet.
/// It has the shape of a quota card — mark and name, account, window title, remaining, meter,
/// reset line — so the real one replaces it without the list moving. It is drawn from shapes
/// rather than redacted text, so there is no text in it to read or to clip.
struct OverviewPlaceholderRow: View {
  @ScaledMetric(relativeTo: .headline) private var titleHeight: CGFloat = 16
  @ScaledMetric(relativeTo: .subheadline) private var supportHeight: CGFloat = 13
  @ScaledMetric(relativeTo: .title) private var valueHeight: CGFloat = 26
  @ScaledMetric(relativeTo: .footnote) private var metaHeight: CGFloat = 11

  var body: some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Layout.rowSpacing) {
      HStack(alignment: .center, spacing: 8) {
        Circle()
          .fill(Self.fill)
          .frame(width: QuotaDesign.Layout.markSize, height: QuotaDesign.Layout.markSize)
        bar(width: 96, height: titleHeight)
        Spacer(minLength: 8)
      }
      bar(width: 150, height: supportHeight)
      VStack(alignment: .leading, spacing: 10) {
        bar(width: 56, height: supportHeight)
        bar(width: 72, height: valueHeight)
        Capsule()
          .fill(Self.fill)
          .frame(height: QuotaDesign.Layout.meterHeight)
        bar(width: 136, height: metaHeight)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(OverviewCopy.loadingQuota)
    .accessibilityIdentifier("overview.placeholder")
  }

  private static let fill = Color(uiColor: .tertiarySystemFill)

  private func bar(width: CGFloat, height: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: 4, style: .continuous)
      .fill(Self.fill)
      .frame(width: width, height: height)
  }
}

/// Nothing to show, and the two ways to change that — each named with the outcome it gets you.
///
/// A phone reads its own providers and an account answers for every Mac, so an empty Overview
/// offers whichever of those this phone is short of rather than a single instruction to install
/// something on a computer it may not have.
struct OverviewEmptyState: View {
  @Bindable var model: AppModel

  static let localTitle = "See quota on this iPhone"
  static let connectProvider = "Connect a provider"
  static let connectOutcome = "Credentials stay on this phone."
  static let accountTitle = "Already use QuotaBar?"
  static let signIn = "Sign in to Quota"
  static let signInOutcome = "See readings from your other devices."
  static let accountOnly =
    "Set up QuotaBar on a Mac to start reporting, or connect a provider to read it on this iPhone."

  var body: some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Layout.sectionSpacing) {
      localPath
      if !model.hasAccountSession {
        accountPath
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
    .listRowBackground(Color.clear)
    .listRowSeparator(.hidden)
    .accessibilityIdentifier("overview.empty")
  }

  private var localPath: some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Layout.rowSpacing) {
      Text(Self.localTitle)
        .font(QuotaDesign.Typography.sectionTitle)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
      Button(action: { model.showProviders() }) {
        Text(Self.connectProvider)
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .frame(maxWidth: .infinity, minHeight: QuotaTheme.minimumTouchTarget)
      .accessibilityIdentifier("overview.connect-provider")
      Text(model.hasAccountSession ? Self.accountOnly : Self.connectOutcome)
        .font(QuotaDesign.Typography.support)
        .foregroundStyle(QuotaTheme.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var accountPath: some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Layout.rowSpacing) {
      Text(Self.accountTitle)
        .font(QuotaDesign.Typography.sectionTitle)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
      Button(action: { model.showSignIn() }) {
        Text(Self.signIn)
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.bordered)
      .controlSize(.large)
      .frame(maxWidth: .infinity, minHeight: QuotaTheme.minimumTouchTarget)
      .accessibilityIdentifier("overview.signin")
      Text(Self.signInOutcome)
        .font(QuotaDesign.Typography.support)
        .foregroundStyle(QuotaTheme.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// One compact Overview row for the Account's Today fold. Tokens and API-equivalent cost stay
/// supporting type; remaining quota on the cards above is the hero.
struct TodayUsageSection: View {
  @Bindable var model: AppModel
  let usage: UsagePeriod
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    Section {
      Button(action: openUsageToday) {
        row
          .frame(maxWidth: .infinity, minHeight: QuotaTheme.minimumTouchTarget, alignment: .leading)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .tint(.primary)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(accessibilityLabel)
      .accessibilityHint("Opens Usage for today")
      .accessibilityIdentifier("overview.today")
    }
  }

  @ViewBuilder
  private var row: some View {
    if dynamicTypeSize.isAccessibilitySize {
      stacked
    } else {
      ViewThatFits(in: .horizontal) {
        compact
        stacked
      }
    }
  }

  private var compact: some View {
    HStack(alignment: .center, spacing: 8) {
      title
      Spacer(minLength: 8)
      values(alignment: .trailing)
      chevron
    }
  }

  private var stacked: some View {
    HStack(alignment: .top, spacing: 8) {
      VStack(alignment: .leading, spacing: 4) {
        title
        values(alignment: .leading)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      chevron
    }
  }

  private var title: some View {
    Text("Today")
      .font(.body)
      .foregroundStyle(.primary)
      .accessibilityAddTraits(.isHeader)
      .accessibilityIdentifier("section.header.today")
  }

  @ViewBuilder
  private func values(alignment: HorizontalAlignment) -> some View {
    if hasUsage {
      VStack(alignment: alignment, spacing: 2) {
        Text(tokensText)
          .font(QuotaDesign.Typography.support.monospacedDigit())
          .foregroundStyle(QuotaTheme.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("overview.today.tokens")
        Text(costText)
          .font(QuotaDesign.Typography.support.monospacedDigit())
          .foregroundStyle(QuotaTheme.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("overview.today.cost")
      }
    } else {
      Text("No usage today.")
        .font(QuotaDesign.Typography.support)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("overview.today.empty")
    }
  }

  private var chevron: some View {
    Image(systemName: "chevron.right")
      .font(.footnote.weight(.semibold))
      .foregroundStyle(.tertiary)
      .accessibilityHidden(true)
  }

  private var hasUsage: Bool {
    usage.totals.messages > 0 || usage.totals.inputTokens > 0 || usage.totals.outputTokens > 0
  }

  private var tokensText: String {
    "\(QuotaFormat.compactCount(usage.totals.totalTokens)) tokens"
  }

  private var costText: String {
    let amount = QuotaFormat.cost(usage.cost)
    if usage.cost.status == .unavailable { return amount }
    return "\(amount) API-equivalent"
  }

  private var accessibilityLabel: String {
    guard hasUsage else { return "Today, no usage" }
    let tokens = QuotaFormat.accessibleCount(usage.totals.totalTokens)
    if usage.cost.status == .unavailable {
      return "Today, \(tokens) tokens, unpriced"
    }
    return "Today, \(tokens) tokens, \(QuotaFormat.cost(usage.cost)) API-equivalent cost"
  }

  /// `UsagePeriodSelection.today` is `.day(offset: 0)`, which the Usage picker already has.
  private func openUsageToday() {
    model.usage.selectUsagePeriod(.today)
    model.selectedTab = .usage
  }
}
