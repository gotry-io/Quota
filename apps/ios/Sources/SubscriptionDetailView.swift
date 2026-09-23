import QuotaBrandIcons
import QuotaPresentation
import QuotaWire
import SwiftUI

/// What the subscription detail page prints. Device ids, fingerprints, and keys stay out.
struct SubscriptionDetailContent: Equatable {
  struct SourceRow: Equatable {
    var displayName: String
    var remaining: String?
    var freshness: String
    var isReporting: Bool
  }

  var provider: ProviderID
  var providerName: String
  var accountLabel: String
  var plan: String?
  var freshness: String
  var windows: [QuotaWindow]
  var sources: [SourceRow]
  /// Remaining history for each window id. Local samples unless the Account switch is on and
  /// the merged series has points, in which case those points are what the chart folds.
  var remainingHistories: [String: QuotaRemainingHistory]
  /// Whether the reading on screen is the one this phone took for itself.
  var isLocalReading: Bool
  /// The chart is drawing the Account series, so the caption is "From your devices".
  var drawsAccountHistory: Bool
  /// **This iPhone**, or **From your devices** when the Account series is on screen.
  var historyCaption: String
  /// A window menu is only useful when this phone has readings to plot for at least one window.
  var showsHistoryWindowPicker: Bool {
    windows.count > 1
      && remainingHistories.values.contains { !$0.observedPoints.isEmpty }
  }

  static func make(
    subscription: QuotaSubscription,
    deviceNames: [String: String],
    samples: LocalQuotaSamples = LocalQuotaSamples(),
    now: Date = Date(),
    historySync: Bool = false,
    accountSamples: [String: [QuotaSample]]? = nil
  ) -> SubscriptionDetailContent {
    let snapshot = subscription.snapshot
    let sources = subscription.sources
      .enumerated()
      .sorted { lhs, rhs in
        if lhs.element.observedAt != rhs.element.observedAt {
          return lhs.element.observedAt > rhs.element.observedAt
        }
        return lhs.offset < rhs.offset
      }
      .map(\.element)
      .map { source in
        SourceRow(
          displayName: deviceNames[source.deviceID] ?? "Device",
          remaining: primaryRemaining(source.snapshot),
          freshness: sourceFreshness(source, now: now),
          isReporting: isReporting(source, subscription: subscription)
        )
      }
    let local = isLocalReading(subscription)
    let accountPoints = accountSamples?.values.contains { !$0.isEmpty } ?? false
    let drawsAccountHistory = historySync && accountPoints
    let drawnAccountSamples =
      drawsAccountHistory
      ? seriesThroughNow(accountSamples ?? [:], snapshot: snapshot, now: now)
      : [:]
    // A window the Account has no points for yet — new, or a five-hour window whose rows
    // expired — still draws what this iPhone read, as it did before the switch.
    let historySamples: (QuotaWindow) -> [QuotaSample] = { window in
      if drawsAccountHistory, let account = drawnAccountSamples[window.id], !account.isEmpty {
        return account
      }
      guard local else { return [] }
      return samples.samples(for: subscription, windowID: window.id)
    }
    let remainingHistories =
      (drawsAccountHistory || local)
      ? snapshot.windows.reduce(into: [String: QuotaRemainingHistory]()) { result, window in
        result[window.id] = QuotaRemainingHistory.fold(
          window: QuotaHistoryReading(
            resetsAt: window.resetsAt,
            cadenceSeconds: window.durationSeconds
          ),
          samples: historySamples(window),
          usedPercent: window.usedPercent,
          now: now,
          isBalanceOnly: window.isBalanceOnly
        )
      }
      : [:]
    let caption = QuotaHistoryCopy.sourceCaption(
      drawsAccountHistory ? .yourDevices : .thisDevice,
      deviceNoun: ThisDevice.displayName
    )
    return SubscriptionDetailContent(
      provider: snapshot.provider,
      providerName: snapshot.provider.displayName,
      accountLabel: PlanDisplay.accountLabel(snapshot.account.label) ?? "Account",
      plan: QuotaFormat.planBadge(snapshot.account.plan),
      freshness: QuotaFormat.observation(snapshot, now: now),
      windows: snapshot.windows,
      sources: sources,
      remainingHistories: remainingHistories,
      isLocalReading: local,
      drawsAccountHistory: drawsAccountHistory,
      historyCaption: caption
    )
  }

  /// A merged Account series stops at the last change. The window on screen, at `now`, is
  /// what a local series already ends on, so the solid line reaches the right edge.
  ///
  /// Only a window that already has Account points is extended, and only when that window
  /// does not already reach `now`. Local samples are left alone.
  static func seriesThroughNow(
    _ samplesByWindow: [String: [QuotaSample]],
    snapshot: QuotaSnapshot,
    now: Date
  ) -> [String: [QuotaSample]] {
    var extended = samplesByWindow
    for window in snapshot.windows {
      guard let resetsAt = window.resetsAt, var samples = extended[window.id], !samples.isEmpty
      else { continue }
      let reachesNow = samples.contains { $0.resetsAt == resetsAt && $0.observedAt >= now }
      if reachesNow { continue }
      samples.append(
        QuotaSample(resetsAt: resetsAt, observedAt: now, usedPercent: window.usedPercent)
      )
      extended[window.id] = samples
    }
    return extended
  }

  /// Whether the reading on screen is the one this phone took for itself. A reading Relay
  /// resolved was taken by some Mac, and this phone kept no samples of it.
  static func isLocalReading(_ subscription: QuotaSubscription) -> Bool {
    subscription.sources.contains { source in
      source.deviceID == ThisDevice.sourceID && source.snapshot == subscription.snapshot
    }
  }

  /// Every string the page would print. Tests use this to prove identifiers stay off screen.
  var displayedStrings: [String] {
    var strings = [providerName, accountLabel, freshness]
    if let plan { strings.append(plan) }
    strings.append("\(accountLabel) · \(freshness)")
    if windows.isEmpty {
      strings.append("No quota windows yet.")
    } else {
      strings.append(contentsOf: windows.map { QuotaFormat.windowTitle($0) })
      strings.append(contentsOf: windows.map { QuotaFormat.remaining($0) })
    }
    if drawsAccountHistory || isLocalReading {
      strings.append(historyCaption)
      strings.append(SubscriptionDetailCopy.remainingHistory)
      if remainingHistories.values.contains(where: { $0.estimate != nil }) {
        strings.append("Estimate")
      }
      if remainingHistories.values.allSatisfy({ $0.observedPoints.isEmpty }) {
        strings.append(SubscriptionDetailCopy.notEnoughHistory)
      }
    } else if !windows.isEmpty {
      strings.append(SubscriptionDetailCopy.remoteOnlyHistory)
    }
    if sources.isEmpty {
      strings.append("No device readings yet.")
    } else {
      strings.append(SubscriptionDetailCopy.readings(sources.count))
      for row in sources {
        strings.append(row.displayName)
        strings.append(row.freshness)
        if let remaining = row.remaining { strings.append(remaining) }
        if row.isReporting { strings.append("Reporting") }
      }
    }
    return strings
  }

  static func primaryRemaining(_ snapshot: QuotaSnapshot?) -> String? {
    guard let snapshot else { return nil }
    guard let window = snapshot.primaryCadenceWindows.first ?? snapshot.windows.first else {
      return nil
    }
    return QuotaFormat.remaining(window)
  }

  static func sourceFreshness(_ source: QuotaSubscriptionSource, now: Date) -> String {
    if let snapshot = source.snapshot {
      return QuotaFormat.observation(snapshot, now: now)
    }
    return FreshnessCopy.updated(since: source.observedAt, now: now)
  }

  static func isReporting(
    _ source: QuotaSubscriptionSource,
    subscription: QuotaSubscription
  ) -> Bool {
    if let snapshot = source.snapshot {
      return snapshot == subscription.snapshot
    }
    return source.observedAt == subscription.snapshot.observedAt
  }
}

enum SubscriptionDetailCopy {
  static let remainingHistory = "Remaining history"
  static let remoteOnlyHistory =
    "This iPhone has no readings of its own for this subscription."
  static let notEnoughHistory =
    "This iPhone has not collected enough readings to draw remaining history yet."

  static func readings(_ count: Int) -> String {
    count == 1 ? "Readings from 1 device" : "Readings from \(count) devices"
  }
}

struct SubscriptionDetailView: View {
  let subscription: QuotaSubscription
  /// What to call each source: the Account's Macs, and **This iPhone** for what this device read
  /// itself. A source with no name is a **Device**.
  let deviceNames: [String: String]
  /// What this phone has read of its own quota over time. Drawn unless the Account series is on.
  var samples = LocalQuotaSamples()
  /// The Account history switch. Off keeps today's chart and copy.
  var historySync = false
  /// Samples folded from the Account read, keyed by window id. Nil is a miss or a failed read.
  var accountSamples: [String: [QuotaSample]]? = nil

  @State private var selectedWindowID: String?
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.displayClock) private var displayClock

  var body: some View {
    let now = displayClock.now()
    let content = SubscriptionDetailContent.make(
      subscription: subscription,
      deviceNames: deviceNames,
      samples: samples,
      now: now,
      historySync: historySync,
      accountSamples: accountSamples
    )
    List {
      if dynamicTypeSize.isAccessibilitySize {
        identitySection(content)
      }
      quotaSection(content, now: now)
      historySection(content)
      readingsSection(content)
    }
    .listStyle(.insetGrouped)
    .listRowSpacing(QuotaDesign.Layout.rowSpacing)
    .listSectionSpacing(.custom(QuotaDesign.Layout.sectionSpacing))
    .environment(\.defaultMinListRowHeight, QuotaTheme.minimumTouchTarget)
    .accessibilityIdentifier("subscription.detail")
    .navigationTitle(content.providerName)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if !dynamicTypeSize.isAccessibilitySize {
        ToolbarItem(placement: .principal) {
          identityHeader(content, compact: true)
            .frame(maxWidth: 280)
        }
      }
    }
  }

  private func identitySection(_ content: SubscriptionDetailContent) -> some View {
    Section {
      identityHeader(content, compact: false)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
  }

  private func identityHeader(_ content: SubscriptionDetailContent, compact: Bool) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: 8) {
        headerMark(content.provider)
        VStack(alignment: .leading, spacing: compact ? 1 : 4) {
          nameAndPlan(content, compact: compact)
          supportingText(content.accountLabel, freshness: content.freshness, compact: compact)
        }
      }
      VStack(alignment: .leading, spacing: 8) {
        headerMark(content.provider)
        nameAndPlan(content, compact: compact)
        supportingText(content.accountLabel, freshness: content.freshness, compact: compact)
      }
    }
  }

  private func headerMark(_ provider: ProviderID) -> some View {
    ProviderMark(
      provider: provider,
      size: QuotaDesign.Layout.markSize
    )
    .foregroundStyle(.primary)
  }

  @ViewBuilder
  private func nameAndPlan(_ content: SubscriptionDetailContent, compact: Bool) -> some View {
    HStack(alignment: .center, spacing: 6) {
      Text(content.providerName)
        .font(compact ? .headline : .title2.bold())
        .foregroundStyle(.primary)
        .lineLimit(compact ? 1 : nil)
        .fixedSize(horizontal: false, vertical: true)
      if let plan = content.plan {
        planCapsule(plan)
      }
    }
  }

  private func supportingText(_ account: String, freshness: String, compact: Bool) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 0) {
      Text(account)
        .font(compact ? .caption : QuotaDesign.Typography.support)
        .foregroundStyle(QuotaTheme.secondary)
        .accessibilityIdentifier("subscription.account")
        .accessibilityLabel("Account: \(account)")
      Text(" · ")
        .font(compact ? .caption : QuotaDesign.Typography.support)
        .foregroundStyle(QuotaTheme.secondary)
        .accessibilityHidden(true)
      Text(freshness)
        .font(
          (compact ? Font.caption : QuotaDesign.Typography.meta)
            .monospacedDigit()
        )
        .foregroundStyle(QuotaTheme.secondary)
        .accessibilityLabel(freshness)
        .accessibilityIdentifier("section.footer.subscription-updated")
    }
    .lineLimit(compact ? 1 : nil)
    .fixedSize(horizontal: false, vertical: true)
  }

  private func planCapsule(_ plan: String) -> some View {
    Text(plan)
      .font(.caption.weight(.semibold))
      .foregroundStyle(.primary)
      .fixedSize()
      .layoutPriority(1)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .overlay {
        Capsule().strokeBorder(Color(uiColor: .separator), lineWidth: 1)
      }
      .accessibilityIdentifier("subscription.plan")
      .accessibilityLabel("Plan: \(plan)")
  }

  @ViewBuilder
  private func quotaSection(_ content: SubscriptionDetailContent, now: Date) -> some View {
    Section {
      if content.windows.isEmpty {
        QuotaCard {
          Text("No quota windows yet.")
            .foregroundStyle(.primary)
        }
        .quotaCardRow()
      } else {
        ForEach(content.windows) { window in
          QuotaCard {
            QuotaWindowBlock(
              window: window,
              presentation: .detail,
              now: now
            )
          }
          .quotaCardRow()
        }
      }
    } header: {
      Text("Quota")
        .accessibilityIdentifier("section.header.quota")
    }
  }

  @ViewBuilder
  private func historySection(_ content: SubscriptionDetailContent) -> some View {
    if content.windows.isEmpty {
      EmptyView()
    } else {
      Section {
        QuotaCard {
          historyHeader(content)
          if !content.drawsAccountHistory && !content.isLocalReading {
            Text(SubscriptionDetailCopy.remoteOnlyHistory)
              .font(.body)
              .foregroundStyle(.primary)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("subscription.history")
          } else if let window = selectedWindow(content),
            let history = content.remainingHistories[window.id],
            !history.observedPoints.isEmpty
          {
            QuotaRemainingHistoryView(
              history: history,
              tint: QuotaTheme.color(for: QuotaTone.remaining(percent: window.remainingPercent)),
              windowTitle: QuotaFormat.windowTitle(window)
            )
          } else {
            Text(SubscriptionDetailCopy.notEnoughHistory)
              .font(.body)
              .foregroundStyle(.primary)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("subscription.history")
          }
        }
        .quotaCardRow()
      }
    }
  }

  private func historyHeader(_ content: SubscriptionDetailContent) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      historyTitleRow(content)
      if content.showsHistoryWindowPicker {
        Picker("Window", selection: windowSelection(content)) {
          ForEach(content.windows) { window in
            Text(QuotaFormat.windowTitle(window)).tag(window.id)
          }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(minHeight: QuotaTheme.minimumTouchTarget)
        .accessibilityLabel("History window")
        .accessibilityIdentifier("subscription.history.window")
      }
    }
  }

  /// Title and **This iPhone** share a line while they fit whole; otherwise they stack so the
  /// title is not clipped and both texts can grow with Dynamic Type.
  @ViewBuilder
  private func historyTitleRow(_ content: SubscriptionDetailContent) -> some View {
    if !content.drawsAccountHistory && !content.isLocalReading {
      remainingHistoryTitle
    } else if dynamicTypeSize.isAccessibilitySize {
      VStack(alignment: .leading, spacing: 4) {
        remainingHistoryTitle.fixedSize(horizontal: false, vertical: true)
        historyScope(content).fixedSize(horizontal: false, vertical: true)
      }
    } else {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          remainingHistoryTitle.fixedSize()
          Spacer(minLength: 8)
          historyScope(content).fixedSize()
        }
        VStack(alignment: .leading, spacing: 4) {
          remainingHistoryTitle.fixedSize(horizontal: false, vertical: true)
          historyScope(content).fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  private var remainingHistoryTitle: some View {
    Text(SubscriptionDetailCopy.remainingHistory)
      .font(QuotaDesign.Typography.cardTitle)
      .foregroundStyle(.primary)
      .accessibilityAddTraits(.isHeader)
      .accessibilityIdentifier("section.header.history")
  }

  private func historyScope(_ content: SubscriptionDetailContent) -> some View {
    Text(content.historyCaption)
      .font(QuotaDesign.Typography.support)
      .foregroundStyle(QuotaTheme.secondary)
      .accessibilityIdentifier("subscription.history.scope")
  }

  private func windowSelection(_ content: SubscriptionDetailContent) -> Binding<String> {
    Binding(
      get: {
        if let selectedWindowID,
          content.windows.contains(where: { $0.id == selectedWindowID })
        {
          return selectedWindowID
        }
        return content.windows.first?.id ?? ""
      },
      set: { selectedWindowID = $0 }
    )
  }

  private func selectedWindow(_ content: SubscriptionDetailContent) -> QuotaWindow? {
    let id = windowSelection(content).wrappedValue
    return content.windows.first { $0.id == id } ?? content.windows.first
  }

  @ViewBuilder
  private func readingsSection(_ content: SubscriptionDetailContent) -> some View {
    Section {
      readingsTitle(content)
      if content.sources.isEmpty {
        Text("No device readings yet.")
          .foregroundStyle(.primary)
      } else {
        ForEach(Array(content.sources.enumerated()), id: \.offset) { _, row in
          sourceRow(row)
        }
      }
    }
  }

  /// A wrapping row, not the system section header font the iOS 26.3 auditor flags.
  private func readingsTitle(_ content: SubscriptionDetailContent) -> some View {
    Text(
      content.sources.isEmpty
        ? "Readings"
        : SubscriptionDetailCopy.readings(content.sources.count)
    )
    .font(.headline)
    .foregroundStyle(.primary)
    .frame(maxWidth: .infinity, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityIdentifier("subscription.sources")
    .accessibilityAddTraits(.isHeader)
    .listRowBackground(Color.clear)
    .listRowSeparator(.hidden)
  }

  private func sourceRow(_ row: SubscriptionDetailContent.SourceRow) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: 8) {
        sourceSymbol(row)
        sourceCopy(row)
        Spacer(minLength: 8)
        if row.isReporting { reportingCapsule }
      }
      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .center, spacing: 8) {
          sourceSymbol(row)
          Text(row.displayName)
            .font(.body)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let remaining = row.remaining {
          Text(remaining)
            .font(QuotaDesign.Typography.meta.monospacedDigit())
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Text(row.freshness)
          .font(QuotaDesign.Typography.meta.monospacedDigit())
          .foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)
        if row.isReporting { reportingCapsule }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(sourceAccessibility(row))
    .accessibilityIdentifier(row.isReporting ? "subscription.reporting" : "subscription.source")
  }

  private func sourceSymbol(_ row: SubscriptionDetailContent.SourceRow) -> some View {
    Image(systemName: row.displayName == ThisDevice.displayName ? "iphone" : "laptopcomputer")
      .font(.body)
      .foregroundStyle(QuotaTheme.secondary)
      .frame(width: QuotaDesign.Layout.markSize, alignment: .center)
      .accessibilityHidden(true)
  }

  private func sourceCopy(_ row: SubscriptionDetailContent.SourceRow) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(row.displayName)
        .font(.body)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
      if let remaining = row.remaining {
        Text(remaining)
          .font(QuotaDesign.Typography.meta.monospacedDigit())
          .foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Text(row.freshness)
        .font(QuotaDesign.Typography.meta.monospacedDigit())
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var reportingCapsule: some View {
    Text("Reporting")
      .font(.caption.weight(.semibold))
      .foregroundStyle(QuotaTheme.emerald)
      .fixedSize()
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .overlay {
        Capsule().strokeBorder(QuotaTheme.emerald, lineWidth: 1)
      }
      .accessibilityHidden(true)
  }

  private func sourceAccessibility(_ row: SubscriptionDetailContent.SourceRow) -> String {
    var parts = [row.displayName]
    if let remaining = row.remaining { parts.append(remaining) }
    parts.append(row.freshness)
    if row.isReporting { parts.append("Reporting") }
    return parts.joined(separator: ", ")
  }
}
