import QuotaWire
import SwiftUI

struct OverviewView: View {
  @Bindable var model: AppModel
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var confirmLogout = false

  var body: some View {
    let providerCards = model.providerCards
    return ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if let banner = model.banner {
          StatusBanner(symbolName: banner.symbolName, text: banner.text)
        }

        accountContext

        if providerCards.isEmpty {
          emptyCard(
            title: "No quota reported yet.",
            detail: "Collection happens on a Mac or Linux device signed into this Account."
          )
        } else {
          ForEach(providerCards) { card in
            ProviderQuotaCard(model: card)
          }
        }

        if let devices = model.summary?.devices, !devices.isEmpty {
          AccountDevicesCard(devices: devices)
        }

        TodayUsageCard(summary: model.summary)
      }
      .frame(maxWidth: QuotaTheme.contentMaxWidth, alignment: .leading)
      .padding(.horizontal, QuotaTheme.contentGutter)
      .padding(.vertical, 16)
      .frame(maxWidth: .infinity)
    }
    .refreshable {
      await model.refresh()
    }
    .navigationTitle(model.accountLabel)
    .navigationBarTitleDisplayMode(.large)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button("Log Out", role: .destructive) {
          confirmLogout = true
        }
        .accessibilityLabel("Log Out")
      }
    }
    .confirmationDialog(
      "Log out of Quota on this device?",
      isPresented: $confirmLogout,
      titleVisibility: .visible
    ) {
      Button("Log Out", role: .destructive) {
        Task { await model.logout() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "The remote Account stays signed in on the website. This device forgets the session and saved overview."
      )
    }
  }

  @ViewBuilder
  private var accountContext: some View {
    if let fetchedAt = model.fetchedAt {
      Group {
        if dynamicTypeSize.isAccessibilitySize {
          VStack(alignment: .leading, spacing: 4) {
            Text(model.accountLabel)
              .font(.subheadline.weight(.medium))
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            Text("Updated \(QuotaFormat.refreshedAge(fetchedAt))")
              .font(.footnote.monospacedDigit())
              .foregroundStyle(.tertiary)
              .fixedSize(horizontal: false, vertical: true)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        } else {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(model.accountLabel)
              .font(.subheadline.weight(.medium))
              .foregroundStyle(.secondary)
              .lineLimit(1)
            Spacer(minLength: 8)
            Text("Updated \(QuotaFormat.refreshedAge(fetchedAt))")
              .font(.footnote.monospacedDigit())
              .foregroundStyle(.tertiary)
              .lineLimit(1)
              .minimumScaleFactor(0.8)
          }
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        "\(model.accountLabel), Last updated \(QuotaFormat.fetchedTime(fetchedAt))"
      )
    }
  }

  private func emptyCard(title: String, detail: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.headline)
      Text(detail)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .quotaSurface()
  }
}

enum RemoteDeviceHealthStatus: String, Equatable, Sendable {
  case healthy = "Healthy"
  case needsAttention = "Needs attention"
  case checkDevice = "Check device"
  case notRecentlyActive = "Not recently active"
  case unknown = "Unknown"
  case signedOut = "Signed out"

  static func status(for device: AccountDevice, now: Date) -> Self {
    if device.status == .signedOut { return .signedOut }
    guard let health = device.health else { return .unknown }
    guard now <= health.freshUntil else { return .notRecentlyActive }
    guard health.summary.operation == .healthy,
      health.summary.data == .current || health.summary.data == .empty
    else { return .needsAttention }
    switch health.summary.attention {
    case .none, .automatic: return .healthy
    case .optional: return .checkDevice
    case .required: return .needsAttention
    }
  }
}

struct AccountDevicesCard: View {
  let devices: [AccountDevice]

  var body: some View {
    let now = Date()
    VStack(alignment: .leading, spacing: 12) {
      Text("Devices")
        .font(.headline)
        .accessibilityAddTraits(.isHeader)
      ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
        if index > 0 { Divider() }
        deviceRow(device, now: now)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .quotaSurface()
  }

  private func deviceRow(_ device: AccountDevice, now: Date) -> some View {
    let status = RemoteDeviceHealthStatus.status(for: device, now: now)
    return VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(device.displayName)
          .font(.subheadline.weight(.medium))
        Spacer(minLength: 8)
        Text(status.rawValue)
          .font(.footnote.weight(.medium))
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.trailing)
      }
      Text(deviceDetails(device, now: now))
        .font(.footnote.monospacedDigit())
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if status == .needsAttention || status == .checkDevice {
        Text("Review Diagnostics on this device.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "\(device.displayName), \(status.rawValue), \(deviceDetails(device, now: now))"
    )
  }

  private func deviceDetails(_ device: AccountDevice, now: Date) -> String {
    let platform = switch device.platform {
    case .macos: "macOS"
    case .linux: "Linux"
    case .windows: "Windows"
    }
    guard let health = device.health else {
      if let seenAt = device.lastSeenAt ?? device.signedOutAt {
        return "\(platform) · Last seen \(QuotaFormat.refreshedAge(seenAt, now: now)) ago"
      }
      return "\(platform) · Never reported"
    }
    let product = health.clientProduct == .quotaBar ? "QuotaBar" : "QuotaCLI"
    var parts = [platform, "\(product) \(health.clientVersion)"]
    parts.append("Report \(QuotaFormat.refreshedAge(health.receivedAt, now: now)) ago")
    if let refresh = health.lastCompletedRefreshAt {
      parts.append("Refresh \(QuotaFormat.refreshedAge(refresh, now: now)) ago")
    }
    if let sync = health.lastSuccessfulAccountSyncAt {
      parts.append("Sync \(QuotaFormat.refreshedAge(sync, now: now)) ago")
    }
    return parts.joined(separator: " · ")
  }
}

struct TodayUsageCard: View {
  let summary: AccountSummary?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Today")
        .font(.headline)
        .accessibilityAddTraits(.isHeader)
      if let usage = summary?.usage,
        usage.totals.requests > 0 || usage.totals.inputTokens > 0
          || usage.totals.outputTokens > 0
      {
        metric(
          label: "Input tokens", value: QuotaFormat.compactCount(usage.totals.inputTokens),
          accessibility: "\(QuotaFormat.accessibleCount(usage.totals.inputTokens)) input tokens")
        metric(
          label: "Output tokens", value: QuotaFormat.compactCount(usage.totals.outputTokens),
          accessibility: "\(QuotaFormat.accessibleCount(usage.totals.outputTokens)) output tokens")
        metric(
          label: "API-equivalent cost",
          value: QuotaFormat.cost(usage.cost),
          accessibility: "API-equivalent cost, \(QuotaFormat.costAccessibility(usage.cost))"
        )
      } else {
        Text("No Usage for Today.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .quotaSurface()
  }

  private func metric(label: String, value: String, accessibility: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(label)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .layoutPriority(0)
      Spacer(minLength: 12)
      Text(value)
        .font(.body.monospacedDigit().weight(.medium))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .layoutPriority(1)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibility)
  }
}
