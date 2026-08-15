import SwiftUI

struct MenuBarShell<Content: View>: View {
  let model: MenuBarViewModel
  let title: String
  var issue: String? = nil
  let canNavigateBack: Bool
  let onNavigateBack: () -> Void
  let showsLeadingIcon: Bool
  let trailing: MenuBarHeader.TrailingAction
  let content: Content

  init(
    model: MenuBarViewModel,
    title: String,
    issue: String? = nil,
    canNavigateBack: Bool,
    onNavigateBack: @escaping () -> Void,
    showsLeadingIcon: Bool = false,
    trailing: MenuBarHeader.TrailingAction = .none,
    @ViewBuilder content: () -> Content
  ) {
    self.model = model
    self.title = title
    self.issue = issue
    self.canNavigateBack = canNavigateBack
    self.onNavigateBack = onNavigateBack
    self.showsLeadingIcon = showsLeadingIcon
    self.trailing = trailing
    self.content = content()
  }

  var body: some View {
    VStack(spacing: 0) {
      MenuBarHeader(
        title: title,
        issue: issue,
        canNavigateBack: canNavigateBack,
        onNavigateBack: onNavigateBack,
        showsLeadingIcon: showsLeadingIcon,
        trailing: trailing
      )
      .zIndex(1)

      Divider()
        .opacity(0.35)

      content
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()

      Divider()
        .opacity(0.35)

      MenuBarFooterView(model: model)
    }
    .frame(width: QuotaDesign.Layout.panelWidth)
    // MenuBarExtra often ignores flexible height on first open. Pin the shared ceiling.
    .frame(height: QuotaDesign.Layout.panelMaxHeight)
    .background(QuotaPalette.panelWash)
  }
}

struct MenuBarFooterView: View {
  @Bindable var model: MenuBarViewModel

  var body: some View {
    HStack(spacing: QuotaDesign.Spacing.sectionBody) {
      Spacer(minLength: 0)

      Button {
        guard !model.isRefreshing else { return }
        Task { await model.refresh() }
      } label: {
        Text(LastCheckedLabel.string(from: model.lastCheckedAt))
          .frame(minHeight: QuotaDesign.Layout.minimumInteractiveDimension)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(
        "Refresh all quota. \(LastCheckedLabel.accessibleString(from: model.lastCheckedAt))"
      )
    }
    .quotaSecondaryStyle()
    .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
    .frame(height: QuotaDesign.Layout.footerHeight)
  }
}

enum LastCheckedLabel {
  static func string(from date: Date?) -> String {
    guard let date else { return "—" }
    return date.formatted(date: .omitted, time: .shortened)
  }

  static func accessibleString(from date: Date?) -> String {
    guard let date else { return "Not checked" }
    return "Last checked \(string(from: date))"
  }

  /// Diagnostics status caption: fixed locale-shortened check time, not relative age.
  static func checkedStatusString(from date: Date) -> String {
    "Checked \(string(from: date))"
  }
}
