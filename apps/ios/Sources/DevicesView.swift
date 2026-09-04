import QuotaPresentation
import QuotaWire
import SwiftUI

struct DevicesView: View {
  @Bindable var model: AppModel

  private static let manageURL = URL(string: "https://quota.gotry.io/my")!

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if let devices = model.summary?.devices, !devices.isEmpty {
          AccountDevicesCard(devices: devices)
        } else {
          MacSetupGuideCard()
        }

        Link(destination: Self.manageURL) {
          Text("Manage devices on the web")
            .font(.subheadline)
            .frame(
              maxWidth: .infinity,
              minHeight: QuotaTheme.minimumTouchTarget,
              alignment: .leading
            )
        }
        .contentShape(Rectangle())
        .frame(minHeight: QuotaTheme.minimumTouchTarget, alignment: .leading)
      }
      .frame(maxWidth: QuotaTheme.contentMaxWidth, alignment: .leading)
      .padding(.horizontal, QuotaTheme.contentGutter)
      .padding(.vertical, 16)
      .frame(maxWidth: .infinity)
    }
    .accessibilityIdentifier("devices.root")
    .navigationTitle("Devices")
    .navigationBarTitleDisplayMode(.large)
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
    let activity = device.activity(now: now)
    let details = deviceDetails(device, activity: activity, now: now)
    return VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(device.displayName)
          .font(.subheadline.weight(.medium))
        Spacer(minLength: 8)
        Text(activity.label)
          .font(.footnote.weight(.medium))
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.trailing)
      }
      Text(details)
        .font(.footnote.monospacedDigit())
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(device.displayName), \(activity.label), \(details)")
  }

  private func deviceDetails(
    _ device: AccountDevice,
    activity: DeviceActivity,
    now: Date
  ) -> String {
    let platform = switch device.platform {
    case .macos: "macOS"
    case .unknown: "Unknown"
    }
    return "\(platform) · \(FreshnessCopy.lastReading(since: activity.since, now: now))"
  }
}

struct OverviewDevicesSummary: View {
  let devices: [AccountDevice]

  var body: some View {
    let now = Date()
    VStack(alignment: .leading, spacing: 12) {
      Text("Devices")
        .font(.headline)
        .accessibilityAddTraits(.isHeader)
      ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
        if index > 0 { Divider() }
        let activity = device.activity(now: now)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(device.displayName)
            .font(.subheadline.weight(.medium))
          Spacer(minLength: 8)
          Text(activity.label)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(device.displayName), \(activity.label)")
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .quotaSurface()
  }
}
