import AppKit
import QuotaPresentation
import QuotaWire
import SwiftUI

/// What the signed-in Account page offers, top to bottom.
///
/// The page renders exactly this list, so what a signed-in person is offered can be stated
/// without driving SwiftUI. A Mac that is not signed in still has Sign In on this page, but
/// has no account to manage.
enum AccountSettingsItem: String, CaseIterable, Identifiable, Sendable {
  case identity
  case devices
  case website
  case signOut

  var id: Self { self }

  static func items(for state: AccountViewState) -> [AccountSettingsItem] {
    state == .signedIn ? allCases : []
  }
}

enum AccountDevicesCopy {
  static let thisMac = "This Mac"
  static let remove = "Remove"
  static let empty = "No devices have signed in yet."
  static let loading = "Loading devices…"
  static let unavailableTitle = "Devices Unavailable"
  static let removeMessage =
    "Device deletion lives on quota.gotry.io. This opens the account devices page."

  static func removeTitle(_ name: String) -> String {
    "Remove \(name)?"
  }
}

/// The Account window page: sign-in states, the signed-in identity, Devices on this
/// same page, the web surface, and Sign Out.
struct AccountSettingsView: View {
  @Bindable var model: MenuBarViewModel
  @State private var confirmSignOut = false
  @State private var devicePendingRemoval: AccountDevice?

  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { context in
      Form {
        if let accountErrorMessage = model.accountFlow.accountErrorMessage {
          let hideSignedOutHint =
            accountErrorMessage == signedOutMessage
            && model.accountFlow.accountActionErrorMessage == nil
          if !hideSignedOutHint {
            Section {
              Label(accountErrorMessage, systemImage: "exclamationmark.circle")
            }
          }
        }

        accountSection
        if model.accountFlow.accountState == .signedIn {
          devicesSection(now: context.date)
          websiteSection
          signOutSection
        }
      }
      .formStyle(.grouped)
      .quotaSettingsColumn()
    }
    .confirmationDialog("Sign Out?", isPresented: $confirmSignOut, titleVisibility: .visible) {
      Button("Sign Out", role: .destructive) {
        Task { await model.accountFlow.logout() }
      }
    } message: {
      Text(
        "This signs QuotaBar out on this Mac. Your device and synced data stay in your Quota account."
      )
    }
    .confirmationDialog(
      devicePendingRemoval.map { AccountDevicesCopy.removeTitle($0.displayName) }
        ?? AccountDevicesCopy.removeTitle("this device"),
      isPresented: deviceRemovalPresented,
      titleVisibility: .visible
    ) {
      Button(AccountDevicesCopy.remove, role: .destructive) {
        NSWorkspace.shared.open(AppMetadata.devicesURL)
        devicePendingRemoval = nil
      }
    } message: {
      Text(AccountDevicesCopy.removeMessage)
    }
  }

  @ViewBuilder
  private var accountSection: some View {
    switch model.accountFlow.accountState {
    case .signedIn:
      SwiftUI.Section {
        LabeledContent("Signed in as") {
          Text(model.accountFlow.accountDisplayLabel)
        }
        .accessibilityLabel("Signed in as \(model.accountFlow.accountDisplayLabel)")
      } header: {
        Text("Account")
      }

    case .logoutPending:
      SwiftUI.Section {
        LabeledContent("Logout Pending") {
          Button {
            Task { await model.accountFlow.logout() }
          } label: {
            if model.accountFlow.isLoggingOut {
              ProgressView().controlSize(.small)
            } else {
              Text("Retry Logout")
            }
          }
          .disabled(model.accountFlow.isLoggingOut)
          .accessibilityLabel(
            model.accountFlow.isLoggingOut ? "Retrying logout" : "Retry Logout")
        }
      } header: {
        Text("Account")
      } footer: {
        Text("Logout will finish when this Mac is online")
      }

    case .notChecked, .signedOut:
      if model.accountFlow.isLoggingIn {
        SwiftUI.Section {
          Text("Finish sign-in in browser")
          if model.accountFlow.canCopyLoginLink {
            Button("Copy Link", action: model.accountFlow.copyLoginLink)
              .accessibilityLabel("Copy Link")
          }
          Button("Cancel", role: .cancel, action: model.accountFlow.cancelLogin)
        } header: {
          Text("Account")
        }
      } else {
        SwiftUI.Section {
          Button("Sign In", action: model.accountFlow.startLogin)
            .accessibilityLabel("Sign In")
            .accessibilityHint(signedOutMessage)
        } footer: {
          Text(signedOutMessage)
        }
      }
    }
  }

  @ViewBuilder
  private func devicesSection(now: Date) -> some View {
    SwiftUI.Section {
      if let summary = model.accountFlow.accountSummary {
        if summary.devices.isEmpty {
          Text(AccountDevicesCopy.empty)
            .foregroundStyle(.secondary)
        } else {
          ForEach(summary.devices) { device in
            deviceRow(device, now: now)
          }
        }
      } else if model.accountFlow.accountRefreshing {
        ProgressView(AccountDevicesCopy.loading)
      } else if let pageErrorMessage = model.accountFlow.accountErrorMessage ?? model.errorMessage {
        Text(pageErrorMessage)
        Button("Retry") { Task { await model.refresh() } }
      } else {
        Text(accountUnavailableMessage)
          .foregroundStyle(.secondary)
      }
    } header: {
      Text("Devices")
    }
  }

  private func deviceRow(_ device: AccountDevice, now: Date) -> some View {
    let activity = device.activity(now: now)
    let lastSeen = FreshnessCopy.lastReading(since: activity.since, now: now)
    let isThisMac = model.accountFlow.accountDeviceID == device.id
    return HStack(alignment: .firstTextBaseline, spacing: QuotaDesign.Spacing.sm) {
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xxs) {
        HStack(spacing: QuotaDesign.Spacing.sm) {
          Text(device.displayName)
          if isThisMac {
            Text(AccountDevicesCopy.thisMac)
              .quotaMetaStyle()
          }
        }
        Text(lastSeen)
          .foregroundStyle(.secondary)
          .quotaFont(.listSecondary)
      }
      Spacer(minLength: QuotaDesign.Spacing.sm)
      Button(AccountDevicesCopy.remove, role: .destructive) {
        devicePendingRemoval = device
      }
      .accessibilityLabel("\(AccountDevicesCopy.remove) \(device.displayName)")
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      isThisMac
        ? "\(device.displayName), \(AccountDevicesCopy.thisMac)"
        : device.displayName
    )
    .accessibilityValue("\(activity.label). \(lastSeen)")
  }

  private var websiteSection: some View {
    Section {
      Link("Open quota.gotry.io", destination: AppMetadata.accountURL)
    }
  }

  private var signOutSection: some View {
    Section {
      Button(
        model.accountFlow.isLoggingOut ? "Signing Out…" : "Sign Out", role: .destructive
      ) {
        confirmSignOut = true
      }
      .disabled(model.accountFlow.isLoggingOut)
      .accessibilityLabel(model.accountFlow.isLoggingOut ? "Signing out" : "Sign Out")
      .accessibilityHint("Shows a confirmation")
    }
  }

  private var deviceRemovalPresented: Binding<Bool> {
    Binding(
      get: { devicePendingRemoval != nil },
      set: { if !$0 { devicePendingRemoval = nil } }
    )
  }

  private var signedOutMessage: String {
    switch model.accountFlow.accountDisconnectReason {
    case .deviceDeleted:
      "This device was removed. Sign in again to reconnect it."
    case .sessionEnded:
      "The account session ended. Sign in again to continue syncing."
    case nil:
      "Sync quota and Usage across your devices."
    }
  }

  private var accountUnavailableMessage: String {
    model.accountFlow.accountState == .logoutPending
      ? "Logout is pending. QuotaBar will finish when this Mac is online."
      : "Sign in to view account devices."
  }
}
