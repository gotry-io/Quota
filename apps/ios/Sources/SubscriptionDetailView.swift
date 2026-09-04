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

  static func make(
    subscription: QuotaSubscription,
    devices: [AccountDevice],
    now: Date = Date()
  ) -> SubscriptionDetailContent {
    let snapshot = subscription.snapshot
    var deviceNames: [String: String] = [:]
    for device in devices {
      deviceNames[device.id] = device.displayName
    }
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
    return SubscriptionDetailContent(
      providerName: snapshot.provider.displayName,
      accountLabel: PlanDisplay.accountLabel(snapshot.account.label) ?? "Account",
      plan: QuotaFormat.planBadge(snapshot.account.plan),
      freshness: QuotaFormat.observation(snapshot, now: now),
      windows: snapshot.windows,
      sources: sources
    )
  }

  /// Every string the page would print. Tests use this to prove identifiers stay off screen.
  var displayedStrings: [String] {
    var strings = [providerName, accountLabel, freshness]
    if let plan { strings.append(plan) }
    strings.append(contentsOf: windows.map { QuotaFormat.windowTitle($0) })
    strings.append(contentsOf: windows.map { QuotaFormat.remaining($0) })
    for row in sources {
      strings.append(row.displayName)
      strings.append(row.freshness)
      if let remaining = row.remaining { strings.append(remaining) }
      if row.isReporting { strings.append("Reporting") }
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
  let devices: [AccountDevice]

  var body: some View {
    let content = SubscriptionDetailContent.make(
      subscription: subscription,
      devices: devices
    )
    return ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        windowsCard(content)
        if !content.sources.isEmpty {
          sourcesCard(content)
        }
      }
      .frame(maxWidth: QuotaTheme.contentMaxWidth, alignment: .leading)
      .padding(.horizontal, QuotaTheme.contentGutter)
      .padding(.vertical, 16)
      .frame(maxWidth: .infinity)
    }
    .accessibilityIdentifier("subscription.detail")
    .navigationTitle(content.providerName)
    .navigationBarTitleDisplayMode(.large)
  }

  private func windowsCard(_ content: SubscriptionDetailContent) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      identity(content)
      Text(content.freshness)
        .font(.footnote.monospacedDigit())
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(content.freshness)

      if content.windows.isEmpty {
        Text("No quota windows reported.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      } else {
        ForEach(Array(content.windows.enumerated()), id: \.element.id) { index, window in
          if index > 0 { Divider() }
          QuotaWindowBlock(
            window: window,
            usesLiveCountdown: true,
            emphasizedRemaining: true
          )
        }
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func identity(_ content: SubscriptionDetailContent) -> some View {
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
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      content.plan.map { "Account: \(content.accountLabel). Plan: \($0)" }
        ?? "Account: \(content.accountLabel)"
    )
  }

  private func accountLabel(_ label: String) -> some View {
    Text(label)
      .font(.subheadline.weight(.medium))
      .fixedSize(horizontal: false, vertical: true)
  }

  private func planCapsule(_ plan: String) -> some View {
    Text(plan)
      .font(.caption.weight(.semibold))
      .layoutPriority(1)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(QuotaTheme.meterTrack, in: Capsule())
      .accessibilityHidden(true)
      .allowsHitTesting(false)
  }

  private func sourcesCard(_ content: SubscriptionDetailContent) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Readings")
        .font(.headline)
        .accessibilityAddTraits(.isHeader)
      ForEach(Array(content.sources.enumerated()), id: \.offset) { index, row in
        if index > 0 { Divider() }
        sourceRow(row)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func sourceRow(_ row: SubscriptionDetailContent.SourceRow) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(row.displayName)
          .font(.subheadline.weight(.medium))
        Spacer(minLength: 8)
        if row.isReporting {
          Text("Reporting")
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
        }
      }
      if let remaining = row.remaining {
        Text(remaining)
          .font(.body.monospacedDigit().weight(.medium))
          .lineLimit(1)
          .minimumScaleFactor(0.75)
      }
      Text(row.freshness)
        .font(.footnote.monospacedDigit())
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(sourceAccessibility(row))
    .accessibilityIdentifier(row.isReporting ? "subscription.reporting" : "subscription.source")
  }

  private func sourceAccessibility(_ row: SubscriptionDetailContent.SourceRow) -> String {
    var parts = [row.displayName]
    if let remaining = row.remaining { parts.append(remaining) }
    parts.append(row.freshness)
    if row.isReporting { parts.append("Reporting") }
    return parts.joined(separator: ", ")
  }
}
