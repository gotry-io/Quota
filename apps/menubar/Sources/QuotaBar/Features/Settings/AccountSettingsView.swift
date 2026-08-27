import SwiftUI

/// What the Account page offers, top to bottom.
///
/// The page renders exactly this list, so what a signed-in person is offered can be stated
/// without driving SwiftUI. A Mac that is not signed in has no account to manage and never
/// reaches the page; signing out is what leaves it.
enum AccountSettingsItem: String, CaseIterable, Identifiable, Sendable {
  case identity
  case syncUsage
  case devices
  case website
  case signOut

  var id: Self { self }

  static func items(for state: AccountViewState) -> [AccountSettingsItem] {
    state == .signedIn ? allCases : []
  }
}

/// Everything that belongs to the account, one level below Settings: who is signed in, whether
/// this Mac's Usage joins the account, the account's devices, the web surface, and the way out.
struct AccountSettingsView: View {
  @Bindable var model: MenuBarViewModel
  let onOpenDevices: () -> Void
  let onRequestSignOut: () -> Void

  private var items: [AccountSettingsItem] { AccountSettingsItem.items(for: model.accountState) }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.md) {
        SettingsSection(title: "Account") {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(items.filter { $0 != .signOut }) { item in
              row(item)
            }
          }
        }

        if items.contains(.signOut) {
          signOutRow
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
      .padding(.vertical, QuotaDesign.Layout.pageVerticalPadding)
    }
  }

  @ViewBuilder
  private func row(_ item: AccountSettingsItem) -> some View {
    switch item {
    case .identity:
      SettingsListRow(title: model.accountDisplayLabel, systemImage: "person.crop.circle.fill") {
        EmptyView()
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Signed in as \(model.accountDisplayLabel)")

    case .syncUsage:
      SettingsListRow(title: "Sync Usage", systemImage: "arrow.triangle.2.circlepath") {
        Toggle(
          "Sync Usage",
          isOn: Binding(
            get: { model.usageUploadEnabled },
            set: { desired in Task { await model.setUsageUploadEnabled(desired) } }
          )
        )
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(QuotaPalette.accent)
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Sync Usage")
      .accessibilityHint("Upload this Mac's Usage to your Quota account")
      .disabled(model.isUpdatingUsageUpload)

    case .devices:
      Button(action: onOpenDevices) {
        SettingsListRow(title: "Devices", systemImage: "laptopcomputer.and.iphone") {
          HStack(spacing: QuotaDesign.Spacing.xxs) {
            Text(model.accountDeviceSummary)
              .quotaListSecondaryStyle()
              .lineLimit(1)
            Image(systemName: "chevron.right")
              .quotaChevronStyle()
          }
        }
      }
      .buttonStyle(QuotaListRowButtonStyle())
      .accessibilityLabel("Devices")
      .accessibilityHint(model.accountDeviceSummary)

    case .website:
      settingsExternalLinkRow(
        title: "Open quota.gotry.io",
        systemImage: "globe",
        url: AppMetadata.accountURL
      )

    case .signOut:
      EmptyView()
    }
  }

  private var signOutRow: some View {
    Button(action: onRequestSignOut) {
      HStack(spacing: QuotaDesign.Spacing.sm) {
        Image(systemName: "rectangle.portrait.and.arrow.right")
          .quotaFont(.secondary)
          .foregroundStyle(QuotaPalette.critical)
          .frame(width: QuotaDesign.Layout.settingsIconColumnWidth)
        Text(model.isLoggingOut ? "Signing Out…" : "Sign Out")
          .quotaFont(.settingsLabel)
          .foregroundStyle(QuotaPalette.critical)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
      .frame(maxWidth: .infinity, minHeight: QuotaDesign.Layout.settingsRowHeight)
      .contentShape(Rectangle())
    }
    .buttonStyle(QuotaListRowButtonStyle())
    .quotaGroupSurface()
    .disabled(model.isLoggingOut)
    .accessibilityLabel(model.isLoggingOut ? "Signing out" : "Sign Out")
    .accessibilityHint("Shows a confirmation")
  }
}
