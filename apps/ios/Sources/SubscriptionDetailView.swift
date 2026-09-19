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

  var providerName: String
  var accountLabel: String
  var plan: String?
  var freshness: String
  var windows: [QuotaWindow]
  var sources: [SourceRow]
  /// The curve each window's own samples draw, keyed by window id. Empty unless the reading on
  /// screen is the one this phone took: nothing else has samples behind it (ADR 0042).
  var histories: [String: QuotaHistory]
  /// The windows of the reading's own cadence that the reader's day already holds.
  var windowsToday: [QuotaHistoryWindow]

  var todayLine: String? { QuotaHistoryCopy.todayLine(windowsToday) }

  static func make(
    subscription: QuotaSubscription,
    deviceNames: [String: String],
    samples: LocalQuotaSamples = LocalQuotaSamples(),
    now: Date = Date(),
    utcOffsetSeconds: Int = TimeZone.autoupdatingCurrent.secondsFromGMT()
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
    let histories = isLocalReading(subscription)
      ? snapshot.windows.reduce(into: [String: QuotaHistory]()) { result, window in
        result[window.id] = QuotaHistory.fold(
          window: QuotaHistoryReading(
            resetsAt: window.resetsAt,
            cadenceSeconds: window.durationSeconds
          ),
          samples: samples.samples(for: subscription, windowID: window.id),
          now: now,
          utcOffsetSeconds: utcOffsetSeconds
        )
      }
      : [:]
    let primary = snapshot.primaryCadenceWindows.first ?? snapshot.windows.first
    return SubscriptionDetailContent(
      providerName: snapshot.provider.displayName,
      accountLabel: PlanDisplay.accountLabel(snapshot.account.label) ?? "Account",
      plan: QuotaFormat.planBadge(snapshot.account.plan),
      freshness: QuotaFormat.observation(snapshot, now: now),
      windows: snapshot.windows,
      sources: sources,
      histories: histories,
      windowsToday: primary.flatMap { histories[$0.id] }?.windowsToday ?? []
    )
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
    if windows.isEmpty {
      strings.append("No quota windows yet.")
    } else {
      strings.append(contentsOf: windows.map { QuotaFormat.windowTitle($0) })
      strings.append(contentsOf: windows.map { QuotaFormat.remaining($0) })
    }
    if let todayLine {
      strings.append(todayLine)
      strings.append(contentsOf: windowsToday.map(QuotaHistoryCopy.span))
      strings.append(contentsOf: windowsToday.map { QuotaHistoryCopy.peak($0.peakUsedPercent) })
    }
    if sources.isEmpty {
      strings.append("No device readings yet.")
    } else {
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

struct SubscriptionDetailView: View {
  let subscription: QuotaSubscription
  /// What to call each source: the Account's Macs, and **This iPhone** for what this device read
  /// itself. A source with no name is a **Device**.
  let deviceNames: [String: String]
  /// What this phone has read of its own quota over time. Only the reading it took itself is
  /// drawn from these (ADR 0042).
  var samples = LocalQuotaSamples()

  var body: some View {
    let content = SubscriptionDetailContent.make(
      subscription: subscription,
      deviceNames: deviceNames,
      samples: samples
    )
    List {
      identitySection(content)
      quotaSection(content)
      todaySection(content)
      readingsSection(content)
    }
    .listStyle(.insetGrouped)
    .listRowSpacing(QuotaDesign.Layout.rowSpacing)
    .listSectionSpacing(.custom(QuotaDesign.Layout.sectionSpacing))
    .environment(\.defaultMinListRowHeight, QuotaTheme.minimumTouchTarget)
    .accessibilityIdentifier("subscription.detail")
    .navigationTitle(content.providerName)
    .navigationBarTitleDisplayMode(.inline)
  }

  private func identitySection(_ content: SubscriptionDetailContent) -> some View {
    Section {
      QuotaCard {
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .center, spacing: 12) {
            headerMark
            headerName(content.providerName)
          }
          VStack(alignment: .leading, spacing: 8) {
            headerMark
            headerName(content.providerName)
          }
        }

        ViewThatFits(in: .horizontal) {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            accountLabel(content.accountLabel)
            Spacer(minLength: 8)
            if let plan = content.plan { planCapsule(plan) }
          }
          VStack(alignment: .leading, spacing: 6) {
            accountLabel(content.accountLabel)
            if let plan = content.plan { planCapsule(plan) }
          }
        }

        Text(content.freshness)
          .font(QuotaDesign.Typography.meta.monospacedDigit())
          .foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel(content.freshness)
          .accessibilityIdentifier("section.footer.subscription-updated")
      }
      .quotaCardRow()
    }
  }

  private var headerMark: some View {
    ProviderMark(
      provider: subscription.snapshot.provider,
      size: QuotaDesign.Layout.detailMarkSize
    )
    .foregroundStyle(.primary)
  }

  private func headerName(_ name: String) -> some View {
    Text(name)
      .font(.title2.bold())
      .foregroundStyle(.primary)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func accountLabel(_ label: String) -> some View {
    Text(label)
      .font(QuotaDesign.Typography.support)
      .foregroundStyle(QuotaTheme.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityIdentifier("subscription.account")
      .accessibilityLabel("Account: \(label)")
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
  private func quotaSection(_ content: SubscriptionDetailContent) -> some View {
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
              history: content.histories[window.id]
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

  /// The windows of this subscription's own cadence that the reader's day already holds.
  ///
  /// Absent for a reading that came from an Account: those were taken by a Mac, which keeps its
  /// own samples and never sends them here.
  @ViewBuilder
  private func todaySection(_ content: SubscriptionDetailContent) -> some View {
    if let todayLine = content.todayLine {
      Section {
        QuotaCard(title: "Today", titleIdentifier: "section.header.today") {
          ForEach(Array(content.windowsToday.enumerated()), id: \.element.startedAt) {
            index,
            window in
            if index > 0 { Divider() }
            todayWindowRow(window)
          }
          Text(todayLine)
            .font(QuotaDesign.Typography.meta)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("section.footer.today")
        }
        .quotaCardRow()
      }
    }
  }

  private func todayWindowRow(_ window: QuotaHistoryWindow) -> some View {
    let span = QuotaHistoryCopy.span(window)
    let peak = QuotaHistoryCopy.peak(window.peakUsedPercent)
    return VStack(alignment: .leading, spacing: 6) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(span)
            .font(QuotaDesign.Typography.support)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 8)
          Text("peak \(peak)")
            .font(.body.monospacedDigit().weight(.semibold))
            .foregroundStyle(.primary)
        }
        VStack(alignment: .leading, spacing: 2) {
          Text(span)
            .font(QuotaDesign.Typography.support)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
          Text("peak \(peak)")
            .font(.body.monospacedDigit().weight(.semibold))
            .foregroundStyle(.primary)
        }
      }
      usedFractionBar(window.peakUsedPercent)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier(
      window.isCurrent ? "subscription.today.current" : "subscription.today.window"
    )
  }

  private func usedFractionBar(_ usedPercent: Double) -> some View {
    GeometryReader { proxy in
      let fraction = min(max(usedPercent / 100, 0), 1)
      ZStack(alignment: .leading) {
        Capsule()
          .fill(QuotaTheme.meterTrack)
        Capsule()
          .fill(
            QuotaTheme.color(for: QuotaTone.remaining(percent: 100 - usedPercent))
          )
          .frame(width: proxy.size.width * CGFloat(fraction))
      }
    }
    .frame(height: QuotaDesign.Layout.compactMeterHeight)
    .accessibilityHidden(true)
  }

  @ViewBuilder
  private func readingsSection(_ content: SubscriptionDetailContent) -> some View {
    Section {
      QuotaCard(title: "Readings", titleIdentifier: "section.header.readings") {
        if content.sources.isEmpty {
          Text("No device readings yet.")
            .foregroundStyle(.primary)
        } else {
          ForEach(Array(content.sources.enumerated()), id: \.offset) { index, row in
            if index > 0 { Divider() }
            sourceRow(row)
          }
        }
      }
      .quotaCardRow()
    }
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
