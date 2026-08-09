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
        Text(lastCheckedLabel)
        .frame(minHeight: QuotaDesign.Layout.minimumInteractiveDimension)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Refresh all quota. \(lastCheckedLabel)")
    }
    .quotaSecondaryStyle()
    .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
    .frame(height: QuotaDesign.Layout.footerHeight)
  }

  /// Orchestration clock: last local collect and/or Relay pull — not provider data age.
  private var lastCheckedLabel: String {
    guard let lastCheckedAt = model.lastCheckedAt else {
      return "Not checked"
    }
    return "Last checked \(lastCheckedAt.formatted(date: .omitted, time: .shortened))"
  }
}
