import AppKit
import SwiftUI

/// Single header chrome for every page.
///
/// Edge rule: header, body, and footer share `panelHorizontalPadding` (16).
/// Every trailing action is the same plain SwiftUI button. Settings overflow floats on the same
/// app-owned Group/Row geometry as other Quota selection controls.
struct MenuBarHeader: View {
  private enum OverflowAction: Hashable {
    case deleteAll
    case quit
  }

  enum TrailingAction {
    case none
    case openSettings(() -> Void)
    case pairDevice(() -> Void)
    /// Quiet text action in the header ops area (e.g. provider API key **Save**).
    case textAction(title: String, accessibilityHint: String, action: () -> Void)
    case overflowMenu(deleteEnabled: Bool, onDeleteAll: () -> Void)
  }

  let title: String
  /// Page-level failure copy (e.g. API key save). Replaces the title while set.
  var issue: String? = nil
  let canNavigateBack: Bool
  let onNavigateBack: () -> Void
  /// Overview root only: app mark before the title.
  var showsLeadingIcon: Bool = false
  let trailing: TrailingAction

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @FocusState private var isOverflowButtonFocused: Bool
  @FocusState private var focusedOverflowAction: OverflowAction?
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
              insertion: .opacity.combined(
                with: .scale(scale: 0.98, anchor: .topTrailing)
              ),
              removal: .opacity
            )
          )
        }
      }
    .onExitCommand {
      if isOverflowMenuExpanded { setOverflowMenuExpanded(false) }
    }
    .onChange(of: title) { _, _ in
      isOverflowMenuExpanded = false
      focusedOverflowAction = nil
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
    .frame(maxWidth: .infinity, minHeight: QuotaDesign.Layout.headerHeight, alignment: .center)
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
    .frame(
      width: QuotaDesign.Layout.headerBrandSize,
      height: QuotaDesign.Layout.headerBrandSize
    )
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

    case .pairDevice(let action):
      headerButton(
        systemName: "plus",
        accessibilityLabel: "Pair Device",
        action: action
      )

    case .textAction(let title, let accessibilityHint, let action):
      Button(action: action) {
        Text(title)
          .quotaFont(.settingsLabel)
          .foregroundStyle(QuotaPalette.accent)
          .frame(
            minWidth: QuotaDesign.Layout.minimumInteractiveDimension,
            minHeight: QuotaDesign.Layout.headerHeight,
            alignment: .trailing
          )
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(title)
      .accessibilityHint(accessibilityHint)
      .help(title)

    case .overflowMenu:
      headerButton(
        systemName: "ellipsis",
        accessibilityLabel: "Settings menu"
      ) {
        setOverflowMenuExpanded(!isOverflowMenuExpanded)
      }
      .focusable()
      .focused($isOverflowButtonFocused)
      .accessibilityHint(
        isOverflowMenuExpanded ? "Collapse settings menu" : "Expand settings menu"
      )
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

  @ViewBuilder
  private var overflowMenu: some View {
    if case .overflowMenu(let deleteEnabled, let onDeleteAll) = trailing {
      HStack(spacing: 0) {
        Spacer(minLength: 0)

        VStack(alignment: .leading, spacing: 0) {
          overflowMenuButton(
            title: "Delete All QuotaBar Data…",
            systemName: "trash",
            color: QuotaPalette.critical,
            isEnabled: deleteEnabled,
            focus: .deleteAll
          ) {
            onDeleteAll()
          }

          overflowMenuButton(
            title: "Quit QuotaBar",
            systemName: "power",
            color: QuotaPalette.ink,
            focus: .quit
          ) {
            NSApplication.shared.terminate(nil)
          }
        }
        .frame(width: QuotaDesign.Layout.headerMenuWidth)
        .quotaFloatingMenuSurface()
      }
      .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
      .padding(.top, 2)
    }
  }

  private func overflowMenuButton(
    title: String,
    systemName: String,
    color: Color,
    isEnabled: Bool = true,
    focus: OverflowAction,
    action: @escaping () -> Void
  ) -> some View {
    Button {
      performOverflowAction(action)
    } label: {
      HStack(spacing: QuotaDesign.Spacing.inline) {
        Image(systemName: systemName)
          .font(.system(size: 11, weight: .regular))
          .foregroundStyle(color)
          .frame(width: QuotaDesign.Layout.headerGlyphWidth)

        Text(title)
          .quotaFont(.settingsLabel)
          .foregroundStyle(color)

        Spacer(minLength: 0)
      }
      .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
      .frame(
        maxWidth: .infinity,
        minHeight: QuotaDesign.Layout.fieldMinHeight,
        alignment: .leading
      )
    }
    .buttonStyle(
      QuotaListRowButtonStyle(
        cornerRadius: QuotaDesign.Layout.floatingMenuRowCornerRadius
      )
    )
    .disabled(!isEnabled)
    .accessibilityLabel(title)
    .focusable()
    .focused($focusedOverflowAction, equals: focus)
    .onKeyPress(.upArrow) {
      moveOverflowFocus(from: focus, by: -1)
      return .handled
    }
    .onKeyPress(.downArrow) {
      moveOverflowFocus(from: focus, by: 1)
      return .handled
    }
    .onKeyPress(.return) {
      performOverflowAction(action)
      return .handled
    }
    .onKeyPress(.space) {
      performOverflowAction(action)
      return .handled
    }
  }

  private func performOverflowAction(_ action: () -> Void) {
    // Action selection replaces the menu with its destination in the same render pass.
    // The animated close path is reserved for dismissing the menu without choosing an action.
    isOverflowMenuExpanded = false
    focusedOverflowAction = nil
    action()
  }

  private func setOverflowMenuExpanded(_ expanded: Bool) {
    if reduceMotion {
      isOverflowMenuExpanded = expanded
    } else {
      withAnimation(expanded ? .easeOut(duration: 0.12) : .easeIn(duration: 0.08)) {
        isOverflowMenuExpanded = expanded
      }
    }

    if expanded {
      Task { @MainActor in
        await Task.yield()
        guard isOverflowMenuExpanded else { return }
        let action = overflowActions.first
        focusedOverflowAction = action
      }
    } else {
      focusedOverflowAction = nil
      Task { @MainActor in
        await Task.yield()
        guard !isOverflowMenuExpanded else { return }
        isOverflowButtonFocused = true
      }
    }
  }

  private var overflowActions: [OverflowAction] {
    guard case .overflowMenu(let deleteEnabled, _) = trailing else { return [] }
    return deleteEnabled ? [.deleteAll, .quit] : [.quit]
  }

  private func moveOverflowFocus(from action: OverflowAction, by offset: Int) {
    let actions = overflowActions
    guard let index = actions.firstIndex(of: action), !actions.isEmpty else { return }
    let destination = min(
      max(index + offset, actions.startIndex),
      actions.index(before: actions.endIndex)
    )
    Task { @MainActor in
      await Task.yield()
      guard isOverflowMenuExpanded else { return }
      focusedOverflowAction = actions[destination]
    }
  }

  private func headerButton(
    systemName: String,
    font: Font = QuotaDesign.Typography.headerActionIcon,
    accessibilityLabel: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(font)
        .foregroundStyle(QuotaPalette.body)
        .frame(width: QuotaDesign.Layout.headerGlyphWidth)
        .frame(
          width: QuotaDesign.Layout.headerControlWidth,
          height: QuotaDesign.Layout.headerHeight,
          alignment: .center
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(QuotaHeaderButtonStyle())
    .accessibilityLabel(accessibilityLabel)
    .help(accessibilityLabel)
  }
}
