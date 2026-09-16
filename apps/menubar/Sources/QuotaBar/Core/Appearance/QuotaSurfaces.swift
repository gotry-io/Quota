import SwiftUI

/// Tahoe-only glass and scroll-edge modifiers, with the existing material fallbacks below 26.
/// Views use these helpers instead of branching on availability themselves.
extension View {
  /// Quota / Today / Usage cards: glass on 26, group fill otherwise, 20pt continuous corners.
  @ViewBuilder
  func quotaCardSurface() -> some View {
    if #available(macOS 26.0, *) {
      glassEffect(
        .regular,
        in: RoundedRectangle(
          cornerRadius: QuotaDesign.Layout.cardCornerRadius,
          style: .continuous
        )
      )
    } else {
      background {
        RoundedRectangle(
          cornerRadius: QuotaDesign.Layout.cardCornerRadius,
          style: .continuous
        )
        .fill(QuotaPalette.settingsGroupFill)
      }
    }
  }

  /// Transient menus: glass on 26, `quotaFloatingMenuSurface()` on 14/15.
  @ViewBuilder
  func quotaFloatingSurface() -> some View {
    if #available(macOS 26.0, *) {
      glassEffect(
        .regular,
        in: RoundedRectangle(
          cornerRadius: QuotaDesign.Layout.floatingSurfaceCornerRadius,
          style: .continuous
        )
      )
    } else {
      quotaFloatingMenuSurface()
    }
  }

  /// Soft scroll-edge effect on 26 so detail content can sit under toolbar and sidebar.
  @ViewBuilder
  func quotaScrollEdge() -> some View {
    if #available(macOS 26.0, *) {
      scrollEdgeEffectStyle(.soft, for: .all)
    } else {
      self
    }
  }

  /// One centred reading column for Quota / Today / Usage.
  func quotaWindowColumn() -> some View {
    frame(maxWidth: QuotaDesign.Layout.contentMaxWidth, alignment: .topLeading)
      .frame(maxWidth: .infinity)
      .padding(.horizontal, QuotaDesign.Layout.contentGutter)
      .padding(.vertical, QuotaDesign.Layout.pageVerticalPadding)
  }
}

/// ScrollView that applies `quotaScrollEdge()` and the 1040pt reading column.
struct QuotaWindowScroll<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    ScrollView {
      content.quotaWindowColumn()
    }
    .quotaScrollEdge()
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}
