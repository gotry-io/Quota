import AppKit
import SwiftUI

struct MenuBarHeader: View {
  enum TrailingAction {
    case none
    case openSettings(() -> Void)
    case overflowMenu
    case usageSource(UsageSource, (UsageSource) -> Void)
    case support(
      isChecking: Bool,
      canRecheck: Bool,
      onRecheck: () -> Void
    )
  }

  let title: String
  var issue: String? = nil
  let canNavigateBack: Bool
  let onNavigateBack: () -> Void
  var showsLeadingIcon = false
  let trailing: TrailingAction

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @FocusState private var isOverflowButtonFocused: Bool
  @FocusState private var isQuitFocused: Bool
  @State private var isOverflowMenuExpanded = false

  var body: some View {
    headerRow
      .overlay(alignment: .top) {
        if isOverflowMenuExpanded {
          ZStack(alignment: .top) {
            Color.clear
              .contentShape(Rectangle())
              .frame(
                width: QuotaDesign.Layout.panelWidth,
                height: QuotaDesign.Layout.panelMaxHeight - QuotaDesign.Layout.headerHeight
              )
              .offset(y: QuotaDesign.Layout.headerHeight)
              .onTapGesture { setOverflowMenuExpanded(false) }

            overflowMenu
              .offset(y: QuotaDesign.Layout.headerHeight)
          }
          .transition(
            .asymmetric(
              insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .topTrailing)),
              removal: .opacity
            )
          )
        }
      }
      .onExitCommand {
        if isOverflowMenuExpanded { setOverflowMenuExpanded(false) }
      }
      .onChange(of: title) { _, _ in setOverflowMenuExpanded(false) }
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
      headerButton(systemName: "ellipsis", accessibilityLabel: "Settings menu") {
        setOverflowMenuExpanded(!isOverflowMenuExpanded)
      }
      .focusable()
      .focused($isOverflowButtonFocused)
      .accessibilityHint(isOverflowMenuExpanded ? "Collapse settings menu" : "Expand settings menu")
      .onKeyPress(.upArrow) {
        setOverflowMenuExpanded(true)
        return .handled
      }
      .onKeyPress(.downArrow) {
        setOverflowMenuExpanded(true)
        return .handled
      }
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
    case .support(let isChecking, let canRecheck, let onRecheck):
      supportRecheckButton(
        isChecking: isChecking,
        isEnabled: canRecheck,
        action: onRecheck
      )
    }
  }

  private func supportRecheckButton(
    isChecking: Bool,
    isEnabled: Bool,
    action: @escaping () -> Void
  ) -> some View {
    let accessibilityLabel = SupportHeaderAction.recheckAccessibilityLabel(
      isChecking: isChecking
    )
    return Button(action: action) {
      Group {
        if isChecking {
          ProgressView()
            .controlSize(.mini)
        } else {
          Image(systemName: "arrow.clockwise")
            .font(QuotaDesign.Typography.headerActionIcon)
        }
      }
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

  private var overflowMenu: some View {
    HStack(spacing: 0) {
      Spacer(minLength: 0)
      Button {
        isOverflowMenuExpanded = false
        NSApplication.shared.terminate(nil)
      } label: {
        HStack(spacing: QuotaDesign.Spacing.inline) {
          Image(systemName: "power")
            .font(.system(size: 11))
            .foregroundStyle(QuotaPalette.ink)
            .frame(width: QuotaDesign.Layout.headerGlyphWidth)
          Text("Quit QuotaBar")
            .quotaSettingsLabelStyle()
          Spacer(minLength: 0)
        }
        .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
        .frame(maxWidth: .infinity, minHeight: QuotaDesign.Layout.fieldMinHeight)
      }
      .buttonStyle(
        QuotaListRowButtonStyle(cornerRadius: QuotaDesign.Layout.floatingMenuRowCornerRadius)
      )
      .focusable()
      .focused($isQuitFocused)
      .accessibilityLabel("Quit QuotaBar")
      .frame(width: QuotaDesign.Layout.headerMenuWidth)
      .quotaFloatingMenuSurface()
    }
    .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
    .padding(.top, 2)
  }

  private func setOverflowMenuExpanded(_ expanded: Bool) {
    if reduceMotion {
      isOverflowMenuExpanded = expanded
    } else {
      withAnimation(expanded ? .easeOut(duration: 0.12) : .easeIn(duration: 0.08)) {
        isOverflowMenuExpanded = expanded
      }
    }
    Task { @MainActor in
      await Task.yield()
      if expanded, isOverflowMenuExpanded {
        isQuitFocused = true
      } else if !isOverflowMenuExpanded {
        isOverflowButtonFocused = true
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
