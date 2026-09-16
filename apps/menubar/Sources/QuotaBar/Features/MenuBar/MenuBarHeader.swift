import AppKit
import SwiftUI

struct MenuBarHeader: View {
  enum TrailingAction {
    case none
    case overflowMenu
  }

  let title: String
  var issue: String? = nil
  let canNavigateBack: Bool
  let onNavigateBack: () -> Void
  var showsLeadingIcon = false
  let trailing: TrailingAction
  var overflowMenuStartsExpanded = false

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @FocusState private var isOverflowButtonFocused: Bool
  @FocusState private var isQuitFocused: Bool
  @State private var isOverflowMenuExpanded: Bool

  init(
    title: String,
    issue: String? = nil,
    canNavigateBack: Bool,
    onNavigateBack: @escaping () -> Void,
    showsLeadingIcon: Bool = false,
    trailing: TrailingAction,
    overflowMenuStartsExpanded: Bool = false
  ) {
    self.title = title
    self.issue = issue
    self.canNavigateBack = canNavigateBack
    self.onNavigateBack = onNavigateBack
    self.showsLeadingIcon = showsLeadingIcon
    self.trailing = trailing
    self.overflowMenuStartsExpanded = overflowMenuStartsExpanded
    _isOverflowMenuExpanded = State(initialValue: overflowMenuStartsExpanded)
  }

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
      .onAppear {
        if isOverflowMenuExpanded {
          isQuitFocused = true
        }
      }
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
    case .overflowMenu:
      headerButton(systemName: "ellipsis", accessibilityLabel: "Settings menu") {
        setOverflowMenuExpanded(!isOverflowMenuExpanded)
      }
      .focusable()
      .focused($isOverflowButtonFocused)
      .accessibilityHint(isOverflowMenuExpanded ? "Collapse settings menu" : "Expand settings menu")
      .help("Settings menu")
      .onKeyPress(.upArrow) {
        setOverflowMenuExpanded(true)
        return .handled
      }
      .onKeyPress(.downArrow) {
        setOverflowMenuExpanded(true)
        return .handled
      }
    }
  }

  private var overflowMenu: some View {
    HStack(spacing: 0) {
      Spacer(minLength: 0)
      VStack(alignment: .leading, spacing: 0) {
        overflowMenuButton(title: "Open QuotaBar") {
          MainWindowController.shared.show()
        }
        overflowMenuButton(title: "Settings…") {
          MainWindowController.shared.showSettings()
        }
        overflowMenuButton(title: "Check for Updates…") {
          QuotaBarUpdater.checkForUpdates()
        }
        Rectangle()
          .fill(QuotaPalette.hairlineBorder.opacity(0.55))
          .frame(height: 0.5)
          .padding(.vertical, QuotaDesign.Spacing.xxs)
          .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
        overflowMenuButton(title: "Quit QuotaBar", isQuit: true) {
          NSApplication.shared.terminate(nil)
        }
      }
      .frame(width: QuotaDesign.Layout.headerMenuWidth)
      .quotaFloatingMenuSurface()
    }
    .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
    .padding(.top, 2)
  }

  @ViewBuilder
  private func overflowMenuButton(
    title: String,
    isEnabled: Bool = true,
    isQuit: Bool = false,
    action: @escaping () -> Void
  ) -> some View {
    let button = Button {
      setOverflowMenuExpanded(false)
      action()
    } label: {
      Text(title)
        .quotaSettingsLabelStyle()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
        .frame(minHeight: QuotaDesign.Layout.fieldMinHeight)
        .contentShape(Rectangle())
    }
    .buttonStyle(
      QuotaListRowButtonStyle(cornerRadius: QuotaDesign.Layout.floatingMenuRowCornerRadius)
    )
    .disabled(!isEnabled)
    .accessibilityLabel(title)
    if isQuit {
      button
        .focusable()
        .focused($isQuitFocused)
    } else {
      button
    }
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
