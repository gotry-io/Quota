import QuotaPresentation
import SwiftUI

struct MenuBarShell<Content: View>: View {
  let model: MenuBarViewModel
  let title: String
  var issue: String? = nil
  let usageSource: UsageSource
  let now: Date
  let canNavigateBack: Bool
  let onNavigateBack: () -> Void
  let showsLeadingIcon: Bool
  let trailing: MenuBarHeader.TrailingAction
  let content: Content

  init(
    model: MenuBarViewModel,
    title: String,
    issue: String? = nil,
    usageSource: UsageSource,
    now: Date,
    canNavigateBack: Bool,
    onNavigateBack: @escaping () -> Void,
    showsLeadingIcon: Bool = false,
    trailing: MenuBarHeader.TrailingAction = .none,
    @ViewBuilder content: () -> Content
  ) {
    self.model = model
    self.title = title
    self.issue = issue
    self.usageSource = usageSource
    self.now = now
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

      MenuBarFooterView(model: model, usageSource: usageSource, now: now)
    }
    .frame(width: QuotaDesign.Layout.panelWidth)
    // MenuBarExtra often ignores flexible height on first open. Pin the shared ceiling.
    .frame(height: QuotaDesign.Layout.panelMaxHeight)
    .background(QuotaPalette.panelWash)
  }
}

/// The panel's bottom bar: what today cost on the left, one refresh action on the right.
///
/// Today's spend is the one supporting number that belongs beside quota everywhere, so it sits
/// in the bar every page already has rather than spending an Overview line on itself. How long
/// ago the last sync finished is a fact about the button, not a number worth a permanent line,
/// so it rides in the button's tooltip and its VoiceOver label.
struct MenuBarFooterView: View {
  @Bindable var model: MenuBarViewModel
  let usageSource: UsageSource
  let now: Date

  var body: some View {
    HStack(spacing: QuotaDesign.Spacing.sectionBody) {
      if let today = model.todayUsageSummary(source: usageSource) {
        Text(today.text)
          .quotaMetaStyle()
          .lineLimit(1)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(today.accessibilityLabel)
      }

      Spacer(minLength: 0)

      Button {
        guard !model.isRefreshing else { return }
        Task { await model.refresh() }
      } label: {
        Group {
          if model.isRefreshing {
            ProgressView()
              .controlSize(.mini)
          } else {
            Image(systemName: "arrow.clockwise")
              .font(QuotaDesign.Typography.headerActionIcon)
              .foregroundStyle(QuotaPalette.body)
          }
        }
        .frame(width: QuotaDesign.Layout.headerGlyphWidth)
        .frame(
          width: QuotaDesign.Layout.minimumInteractiveDimension,
          height: QuotaDesign.Layout.footerHeight
        )
        .contentShape(Rectangle())
      }
      .buttonStyle(QuotaHeaderButtonStyle())
      .accessibilityLabel(refreshActionLabel)
      .help(refreshActionLabel)
    }
    // The same gutter the header uses, so the refresh glyph sits under the header's action.
    .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
    .frame(height: QuotaDesign.Layout.footerHeight)
  }

  private var refreshActionLabel: String {
    "Refresh all quota. \(FreshnessCopy.updated(since: model.lastCheckedAt, now: now))"
  }
}
