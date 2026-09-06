import QuotaPresentation
import QuotaWire
import SwiftUI

struct DeviceRowContent: Equatable {
  var displayName: String
  var verdict: String
  var platform: String
  var age: String

  /// This iPhone, as a row of its own. It is the one a phone that registered no Device gets:
  /// its verdict comes from the last local collection rather than from anything Relay witnessed
  /// ([ADR 0041](../../../docs/decisions/0041-ios-is-a-device-when-sync-is-paid.md)).
  static func thisIPhone(lastCollectedAt: Date?, now: Date = Date()) -> Self {
    let activity = DeviceActivity.make(
      lastSeenAt: lastCollectedAt,
      lastObservedAt: lastCollectedAt,
      now: now
    )
    return DeviceRowContent(
      displayName: ThisDevice.displayName,
      verdict: activity.label,
      platform: "iOS",
      age: FreshnessCopy.lastReading(since: activity.since, now: now)
    )
  }

  static func make(_ device: AccountDevice, now: Date = Date()) -> Self {
    let activity = device.activity(now: now)
    let platform =
      switch device.platform {
      case .macos: "macOS"
      case .ios: "iOS"
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
      // Devices are the Account's. Without one there is no list to show, and the phone's own
      // readings are not a substitute for it — they are on Overview, where the quota is.
      if !model.hasAccountSession {
        ContentUnavailableView {
          Label(DevicesCopy.signedOutTitle, systemImage: "desktopcomputer")
        } description: {
          Text(DevicesCopy.signedOutDetail)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
        } actions: {
          Button(DevicesCopy.signIn) { model.showSignIn() }
            .frame(minHeight: QuotaTheme.minimumTouchTarget)
            .accessibilityIdentifier("devices.signin")
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, minHeight: 220)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
      } else {
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
        // Last, and only when the Account does not already list this phone: a registered
        // iPhone is one of the Devices above, not a second row beside itself.
        if !model.isRegisteredDevice {
          ThisIPhoneRow(lastCollectedAt: model.localCollection?.collectedAt)
        }
      }
    }
    .listStyle(.insetGrouped)
    .environment(\.defaultMinListRowHeight, QuotaTheme.minimumTouchTarget)
    .accessibilityIdentifier("devices.root")
    .navigationTitle("Devices")
    .navigationBarTitleDisplayMode(.large)
    .toolbar {
      if model.hasAccountSession {
        ToolbarItem(placement: .topBarTrailing) {
          Link(destination: QuotaWebLinks.manageDevices) {
            Label("Manage Devices on Web", systemImage: "arrow.up.right")
          }
          .accessibilityIdentifier("devices.manage")
        }
      }
    }
  }
}

enum DevicesCopy {
  static let signedOutTitle = "Sign in to see your Macs"
  static let signedOutDetail =
    "Quota lists the Macs reporting to your account. This iPhone reads the providers you connect "
    + "here whether or not you sign in."
  static let signIn = "Sign in to Quota"
}

/// This device's own row. It carries no Manage or Remove control: there is nothing remote to
/// manage, and removing what it reads is removing a provider sign-in in Settings.
struct ThisIPhoneRow: View {
  let lastCollectedAt: Date?

  var body: some View {
    let content = DeviceRowContent.thisIPhone(lastCollectedAt: lastCollectedAt)
    DeviceRowBody(content: content)
      .accessibilityIdentifier("devices.this-iphone")
  }
}

struct DeviceRow: View {
  let device: AccountDevice

  var body: some View {
    DeviceRowBody(content: DeviceRowContent.make(device))
      .accessibilityIdentifier("devices.row")
  }
}

struct DeviceRowBody: View {
  let content: DeviceRowContent

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(content.displayName)
          .font(.subheadline.weight(.medium))
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 8)
        // The verdict claims its own width: it is one of three fixed words, and **Not reporting**
        // is long enough that leaving it to the remainder truncates it at the larger text sizes.
        // The display name beside it is what wraps instead.
        Text(content.verdict)
          .font(.footnote.weight(.medium))
          .foregroundStyle(.primary)
          .multilineTextAlignment(.trailing)
          .fixedSize()
      }
      Text(content.details)
        .font(.footnote.monospacedDigit())
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(content.accessibilityLabel)
  }
}
