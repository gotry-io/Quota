import SwiftUI

struct MenuBarShell<Content: View>: View {
  let model: MenuBarViewModel
  let title: String
  let canNavigateBack: Bool
  let onNavigateBack: () -> Void
  let showsLeadingIcon: Bool
  let trailing: MenuBarHeader.TrailingAction
  let content: Content

  init(
    model: MenuBarViewModel,
    title: String,
    canNavigateBack: Bool,
    onNavigateBack: @escaping () -> Void,
    showsLeadingIcon: Bool = false,
    trailing: MenuBarHeader.TrailingAction = .none,
    @ViewBuilder content: () -> Content
  ) {
    self.model = model
    self.title = title
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
        canNavigateBack: canNavigateBack,
        onNavigateBack: onNavigateBack,
        showsLeadingIcon: showsLeadingIcon,
        trailing: trailing
      )

      Divider()

      content
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()

      Divider()

      MenuBarFooterView(model: model)
    }
    .frame(width: QuotaDesign.Layout.panelWidth)
    // MenuBarExtra often ignores flexible height on first open. Pin the shared ceiling.
    .frame(height: QuotaDesign.Layout.panelMaxHeight)
  }
}

struct MenuBarFooterView: View {
  @Bindable var model: MenuBarViewModel

  var body: some View {
    HStack(spacing: QuotaDesign.Spacing.sectionBody) {
      Spacer(minLength: 0)

      Button {
        Task { await model.refresh() }
      } label: {
        Group {
          if model.isRefreshing {
            Text("Refreshing…")
          } else {
            Text(lastCheckedLabel)
          }
        }
        .frame(minHeight: QuotaDesign.Layout.minimumInteractiveDimension)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(model.isRefreshing)
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
