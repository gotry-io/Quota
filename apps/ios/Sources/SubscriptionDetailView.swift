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
    if windows.isEmpty {
      strings.append("No quota windows yet.")
    } else {
      strings.append(contentsOf: windows.map { QuotaFormat.windowTitle($0) })
      strings.append(contentsOf: windows.map { QuotaFormat.remaining($0) })
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
  let devices: [AccountDevice]

  var body: some View {
    let content = SubscriptionDetailContent.make(
      subscription: subscription,
      devices: devices
    )
    List {
      identitySection(content)
      quotaSection(content)
      readingsSection(content)
    }
    .listStyle(.insetGrouped)
    .contentMargins(.bottom, 24, for: .scrollContent)
    .quotaTabBarClearance()
    .environment(\.defaultMinListRowHeight, QuotaTheme.minimumTouchTarget)
    .accessibilityIdentifier("subscription.detail")
    .navigationTitle(content.providerName)
    .navigationBarTitleDisplayMode(.large)
  }

  private func identitySection(_ content: SubscriptionDetailContent) -> some View {
    Section {
      labeledRow(label: "Account", value: content.accountLabel)
      if let plan = content.plan {
        labeledRow(label: "Plan", value: plan)
      }
    } footer: {
      BodyLabel(text: content.freshness, style: .footnote, monospacedDigit: true)
        .accessibilityLabel(content.freshness)
    }
  }

  @ViewBuilder
  private func quotaSection(_ content: SubscriptionDetailContent) -> some View {
    Section {
      if content.windows.isEmpty {
        Text("No quota windows yet.")
          .foregroundStyle(Color(uiColor: .label))
      } else {
        ForEach(content.windows) { window in
          QuotaWindowBlock(
            window: window,
            usesLiveCountdown: true,
            emphasizedRemaining: true
          )
        }
      }
    } header: {
      Text("Quota")
        .foregroundStyle(Color(uiColor: .label))
    }
  }

  @ViewBuilder
  private func readingsSection(_ content: SubscriptionDetailContent) -> some View {
    Section {
      if content.sources.isEmpty {
        Text("No device readings yet.")
          .foregroundStyle(Color(uiColor: .label))
      } else {
        ForEach(Array(content.sources.enumerated()), id: \.offset) { _, row in
          sourceRow(row)
        }
      }
    } header: {
      Text("Readings")
        .foregroundStyle(Color(uiColor: .label))
    }
  }

  private func labeledRow(label: String, value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      BodyLabel(text: label)
      Spacer(minLength: 8)
      BodyLabel(text: value, weight: .medium)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(label), \(value)")
  }

  private func sourceRow(_ row: SubscriptionDetailContent.SourceRow) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      VStack(alignment: .leading, spacing: 5) {
        BodyLabel(text: row.displayName, style: .subheadline, weight: .medium)
        if let remaining = row.remaining {
          BodyLabel(
            text: remaining,
            style: .body,
            weight: .medium,
            monospacedDigit: true
          )
        }
        BodyLabel(text: row.freshness, style: .footnote, monospacedDigit: true)
      }
      Spacer(minLength: 8)
      if row.isReporting {
        BodyLabel(text: "Reporting", style: .footnote, weight: .medium)
      }
    }
    .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
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
