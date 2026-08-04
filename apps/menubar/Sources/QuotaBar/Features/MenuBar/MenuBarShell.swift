import SwiftUI

struct MenuBarShell<Content: View, Trailing: View>: View {
  let model: MenuBarViewModel
  let title: String
  let canNavigateBack: Bool
  let onNavigateBack: () -> Void
  let trailing: Trailing
  let content: Content

  init(
    model: MenuBarViewModel,
    title: String,
    canNavigateBack: Bool,
    onNavigateBack: @escaping () -> Void,
    @ViewBuilder trailing: () -> Trailing,
    @ViewBuilder content: () -> Content
  ) {
    self.model = model
    self.title = title
    self.canNavigateBack = canNavigateBack
    self.onNavigateBack = onNavigateBack
    self.trailing = trailing()
    self.content = content()
  }

  var body: some View {
    VStack(spacing: 0) {
      panelHeader

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

  private var panelHeader: some View {
    HStack(spacing: 0) {
      HStack(spacing: 0) {
        if canNavigateBack {
          Button(action: onNavigateBack) {
            Image(systemName: "chevron.left")
              .font(.system(size: 14, weight: .semibold))
              .foregroundStyle(QuotaPalette.body)
              .frame(
                width: 20,
                height: QuotaDesign.Layout.navigationControlSize,
                alignment: .leading
              )
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Back")
          .padding(.trailing, QuotaDesign.Spacing.iconLabel)
        }

        Text(title)
          .font(QuotaDesign.Typography.panelTitle)
          .foregroundStyle(QuotaPalette.ink)
          .lineLimit(1)
      }

      Spacer(minLength: QuotaDesign.Spacing.inline)

      trailing
        .frame(
          minWidth: QuotaDesign.Layout.navigationControlSize,
          minHeight: QuotaDesign.Layout.navigationControlSize,
          alignment: .trailing
        )
    }
    .frame(maxWidth: .infinity, minHeight: QuotaDesign.Layout.headerHeight, alignment: .center)
    .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
  }
}

extension MenuBarShell where Trailing == EmptyView {
  init(
    model: MenuBarViewModel,
    title: String,
    canNavigateBack: Bool,
    onNavigateBack: @escaping () -> Void,
    @ViewBuilder content: () -> Content
  ) {
    self.init(
      model: model,
      title: title,
      canNavigateBack: canNavigateBack,
      onNavigateBack: onNavigateBack,
      trailing: { EmptyView() },
      content: content
    )
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
        if model.isRefreshing {
          Text("Refreshing…")
        } else {
          Text(lastRefreshLabel)
        }
      }
      .buttonStyle(.plain)
      .disabled(model.isRefreshing)
      .accessibilityLabel("Refresh quota, \(lastRefreshLabel)")
    }
    .font(.caption)
    .foregroundStyle(QuotaPalette.body)
    .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
    .frame(height: QuotaDesign.Layout.footerHeight)
  }

  private var lastRefreshLabel: String {
    guard let refreshedAt = model.refreshedAt else {
      return "Not Refreshed"
    }
    return "Updated \(refreshedAt.formatted(date: .omitted, time: .shortened))"
  }
}
