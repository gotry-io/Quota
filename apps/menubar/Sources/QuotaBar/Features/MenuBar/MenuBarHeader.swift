import AppKit
import SwiftUI

struct MenuBarHeader: View {
  enum TrailingAction {
    case none
    case openSettings(() -> Void)
    case overflowMenu
    case usageSource(UsageSource, (UsageSource) -> Void)
  }

  let title: String
  var issue: String? = nil
  let canNavigateBack: Bool
  let onNavigateBack: () -> Void
  var showsLeadingIcon = false
  let trailing: TrailingAction

  var body: some View {
    headerRow
  }

  private var headerRow: some View {
    HStack(spacing: 0) {
      if canNavigateBack {
        headerButton(
          systemName: "chevron.backward",
          font: QuotaDesign.Typography.headerBackIcon,
          accessibilityLabel: "Back",
          action: onNavigateBack
        )
      } else if showsLeadingIcon {
        leadingTitleIcon
      }

      if let issue, !issue.isEmpty {
        Text(issue)
          .quotaFont(.secondary)
          .foregroundStyle(QuotaPalette.critical)
          .lineLimit(1)
          .minimumScaleFactor(0.85)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityLabel("\(title). \(issue)")
          .accessibilityAddTraits(.isHeader)
      } else {
        Text(title)
          .quotaFont(.panelTitle)
          .foregroundStyle(QuotaPalette.ink)
          .lineLimit(1)
          .accessibilityAddTraits(.isHeader)
      }

      Spacer(minLength: QuotaDesign.Spacing.inline)
      trailingControl
    }
    .frame(maxWidth: .infinity, minHeight: QuotaDesign.Layout.headerHeight)
    .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
  }

  private var leadingTitleIcon: some View {
    Group {
      if let image = QuotaBrandAssets.menuBarTemplateImage() {
        Image(nsImage: image)
          .resizable()
          .renderingMode(.template)
          .interpolation(.high)
          .scaledToFit()
      }
    }
    .frame(width: QuotaDesign.Layout.headerBrandSize, height: QuotaDesign.Layout.headerBrandSize)
    .frame(
      width: QuotaDesign.Layout.headerAccessoryWidth,
      height: QuotaDesign.Layout.headerHeight,
      alignment: .leading
    )
    .foregroundStyle(QuotaPalette.ink)
    .accessibilityHidden(true)
  }

  @ViewBuilder
  private var trailingControl: some View {
    switch trailing {
    case .none:
      EmptyView()
    case .openSettings(let action):
      headerButton(
        systemName: "gearshape",
        accessibilityLabel: "Open settings",
        action: action
      )
    case .overflowMenu:
      Menu {
        Button("Open Dashboard…") {
          // WP 7.7
        }
        .keyboardShortcut("d", modifiers: .command)
        .disabled(true)
        Button("Settings…") {
          SettingsWindowController.shared.show()
        }
        .keyboardShortcut(",", modifiers: .command)
        Button("Check for Updates…", action: QuotaBarUpdater.checkForUpdates)
        Divider()
        Button("Quit QuotaBar") {
          NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
      } label: {
        Image(systemName: "ellipsis")
          .font(QuotaDesign.Typography.headerActionIcon)
          .foregroundStyle(QuotaPalette.body)
          .frame(width: QuotaDesign.Layout.headerGlyphWidth)
          .frame(
            width: QuotaDesign.Layout.headerControlWidth,
            height: QuotaDesign.Layout.headerHeight
          )
          .contentShape(Rectangle())
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .buttonStyle(QuotaHeaderButtonStyle())
      .accessibilityLabel("Settings menu")
      .help("Settings menu")
    case .usageSource(let source, let select):
      Menu {
        usageSourceItem(.account, selected: source, select: select)
        usageSourceItem(.local, selected: source, select: select)
      } label: {
        HStack(spacing: QuotaDesign.Spacing.xxs) {
          Image(systemName: source.systemImage)
          Text(source.label)
          Image(systemName: "chevron.down")
            .font(.system(size: 8, weight: .semibold))
        }
        .quotaFont(.meta)
        .foregroundStyle(QuotaPalette.body)
        .padding(.horizontal, QuotaDesign.Spacing.xs)
        .frame(minHeight: QuotaDesign.Layout.minimumInteractiveDimension)
        .background {
          RoundedRectangle(cornerRadius: QuotaDesign.Layout.rowCornerRadius, style: .continuous)
            .fill(QuotaPalette.fieldFill)
        }
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .accessibilityLabel("Usage source")
      .accessibilityValue(source.label)
    }
  }

  private func usageSourceItem(
    _ source: UsageSource,
    selected: UsageSource,
    select: @escaping (UsageSource) -> Void
  ) -> some View {
    Button { select(source) } label: {
      Label {
        Text(source.label)
      } icon: {
        Image(systemName: source == selected ? "checkmark" : source.systemImage)
      }
    }
  }

  private func headerButton(
    systemName: String,
    font: Font = QuotaDesign.Typography.headerActionIcon,
    accessibilityLabel: String,
    isEnabled: Bool = true,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(font)
        .foregroundStyle(QuotaPalette.body)
        .frame(width: QuotaDesign.Layout.headerGlyphWidth)
        .frame(
          width: QuotaDesign.Layout.headerControlWidth,
          height: QuotaDesign.Layout.headerHeight
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(QuotaHeaderButtonStyle())
    .disabled(!isEnabled)
    .accessibilityLabel(accessibilityLabel)
    .help(accessibilityLabel)
  }
}

extension UsageSource {
  fileprivate var label: String { self == .account ? "Account" : "This Mac" }
  fileprivate var systemImage: String {
    self == .account ? "person.crop.circle" : "laptopcomputer"
  }
}
