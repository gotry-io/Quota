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
          AccountDevicesCard(devices: devices, observations: model.summary?.quota ?? [])
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

/// How recently a device spoke, from the two things Relay actually witnessed: when the device
/// last called, and when the newest reading it sent was taken. A device that is asleep or closed
/// is quiet, not broken, so nothing here claims a device is unhealthy.
enum RemoteDeviceActivity: String, Equatable, Sendable {
  case active = "Active"
  case idle = "Idle"
  case notReporting = "Not reporting"
  case signedOut = "Signed out"

  static func status(for device: AccountDevice, lastReadingAt: Date?, now: Date) -> Self {
    if device.status == .signedOut { return .signedOut }
    let instants = [device.lastSeenAt, lastReadingAt].compactMap { $0 }
    guard let newest = instants.max() else { return .notReporting }
    let age = now.timeIntervalSince(newest)
    if age < 30 * 60 { return .active }
    if age < 24 * 60 * 60 { return .idle }
    return .notReporting
  }
}

struct AccountDevicesCard: View {
  let devices: [AccountDevice]
  let observations: [AccountQuotaObservation]

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

  private func lastReadingAt(_ device: AccountDevice) -> Date? {
    observations
      .filter { $0.deviceID == device.deviceID }
      .map(\.snapshot.observedAt)
      .max()
  }

  private func deviceRow(_ device: AccountDevice, now: Date) -> some View {
    let status = RemoteDeviceActivity.status(
      for: device, lastReadingAt: lastReadingAt(device), now: now)
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
    var parts = [platform]
    if let seenAt = device.lastSeenAt ?? device.signedOutAt {
      parts.append("Last seen \(QuotaFormat.refreshedAge(seenAt, now: now)) ago")
    } else {
      parts.append("Never reported")
    }
    if let reading = lastReadingAt(device) {
      parts.append("Last reading \(QuotaFormat.refreshedAge(reading, now: now)) ago")
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
