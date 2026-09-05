import QuotaPresentation
import QuotaWire
import SwiftUI

struct DeviceRowContent: Equatable {
  var displayName: String
  var verdict: String
  var platform: String
  var age: String

  static func make(_ device: AccountDevice, now: Date = Date()) -> Self {
    let activity = device.activity(now: now)
    let platform =
      switch device.platform {
      case .macos: "macOS"
      case .unknown: "Unknown"
      }
    return DeviceRowContent(
      displayName: device.displayName,
      verdict: activity.label,
      platform: platform,
      age: FreshnessCopy.lastReading(since: activity.since, now: now)
    )
  }

  var details: String { "\(platform) · \(age)" }

  var accessibilityLabel: String {
    "\(displayName), \(verdict), \(platform), \(age)"
  }

  var displayedStrings: [String] {
    [displayName, verdict, platform, age]
  }
}

struct DevicesView: View {
  @Bindable var model: AppModel

  var body: some View {
    List {
      if let devices = model.summary?.devices, !devices.isEmpty {
        ForEach(devices) { device in
          DeviceRow(device: device)
        }
      } else {
        ContentUnavailableView {
          Label(MacSetupGuide.emptyDevicesTitle, systemImage: "desktopcomputer")
        } description: {
          Text(MacSetupGuide.detail)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
        } actions: {
          Link(MacSetupGuide.devicesAction, destination: MacSetupGuide.downloadURL)
            .frame(minHeight: QuotaTheme.minimumTouchTarget)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, minHeight: 220)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
      }
    }
    .listStyle(.insetGrouped)
    .environment(\.defaultMinListRowHeight, QuotaTheme.minimumTouchTarget)
    .accessibilityIdentifier("devices.root")
    .navigationTitle("Devices")
    .navigationBarTitleDisplayMode(.large)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Link(destination: QuotaWebLinks.manageDevices) {
          Label("Manage Devices on Web", systemImage: "arrow.up.right")
        }
        .accessibilityIdentifier("devices.manage")
      }
    }
  }
}

struct DeviceRow: View {
  let device: AccountDevice

  var body: some View {
    let content = DeviceRowContent.make(device)
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(content.displayName)
          .font(.subheadline.weight(.medium))
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 8)
        Text(content.verdict)
          .font(.footnote.weight(.medium))
          .foregroundStyle(.primary)
          .multilineTextAlignment(.trailing)
      }
      Text(content.details)
        .font(.footnote.monospacedDigit())
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(content.accessibilityLabel)
    .accessibilityIdentifier("devices.row")
  }
}
