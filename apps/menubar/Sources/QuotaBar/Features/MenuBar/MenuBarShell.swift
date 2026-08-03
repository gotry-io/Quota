import SwiftUI

struct MenuBarShell<Content: View>: View {
  let model: MenuBarViewModel
  let title: String
  let canNavigateBack: Bool
  let onNavigateBack: () -> Void
  let onOpenSettings: () -> Void
  let content: Content

  init(
    model: MenuBarViewModel,
    title: String,
    canNavigateBack: Bool,
    onNavigateBack: @escaping () -> Void,
    onOpenSettings: @escaping () -> Void,
    @ViewBuilder content: () -> Content
  ) {
    self.model = model
    self.title = title
    self.canNavigateBack = canNavigateBack
    self.onNavigateBack = onNavigateBack
    self.onOpenSettings = onOpenSettings
    self.content = content()
  }

  var body: some View {
    VStack(spacing: 0) {
      panelHeader

      Divider()
        .overlay(QuotaPalette.hairline)

      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()

      Divider()
        .overlay(QuotaPalette.hairline)

      MenuBarFooterView(model: model)
    }
    .frame(width: QuotaDesign.Layout.panelWidth, height: QuotaDesign.Layout.panelHeight)
  }

  private var panelHeader: some View {
    HStack(spacing: 8) {
      if canNavigateBack {
        Button(action: onNavigateBack) {
          Image(systemName: "chevron.left")
            .font(.system(size: 13, weight: .semibold))
            .frame(
              width: QuotaDesign.Layout.navigationControlSize,
              height: QuotaDesign.Layout.navigationControlSize
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(QuotaPalette.body)
        .accessibilityLabel("Back")
      }

      Text(title)
        .font(QuotaDesign.Typography.panelTitle)
        .foregroundStyle(QuotaPalette.ink)

      Spacer()

      if !canNavigateBack {
        Button(action: onOpenSettings) {
          Image(systemName: "gearshape")
            .font(.system(size: 13, weight: .medium))
            .frame(
              width: QuotaDesign.Layout.navigationControlSize,
              height: QuotaDesign.Layout.navigationControlSize
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(QuotaPalette.body)
        .accessibilityLabel("Open settings")
      }
    }
    .frame(height: QuotaDesign.Layout.headerHeight)
    .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
  }
}

struct MenuBarFooterView: View {
  @Bindable var model: MenuBarViewModel

  var body: some View {
    HStack(spacing: 12) {
      Text("v\(AppMetadata.version)")

      Spacer()

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
      return "Not refreshed"
    }
    return "Updated \(refreshedAt.formatted(date: .omitted, time: .shortened))"
  }
}
