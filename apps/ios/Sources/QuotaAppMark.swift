import QuotaBrandIcons
import SwiftUI

/// The Quota catalog mark Connect and About share. The glyph fills the frame so
/// those screens cannot drift.
struct QuotaAppMark: View {
  var size: CGFloat = QuotaDesign.Layout.quotaMarkWelcome

  var body: some View {
    QuotaMark(size: size)
      .foregroundStyle(QuotaTheme.emerald)
      .accessibilityLabel("Quota")
      .accessibilityAddTraits(.isImage)
  }
}

/// The Quota mark as two strokes, so it can draw itself in: the open ring, then the tail.
///
/// The geometry is the catalog mark's (`QuotaBrandIcons/BrandIcons.xcassets/quota.imageset`):
/// an 18-unit square, a ring of radius 5.48 round its centre left open at the lower right, and a
/// tail from inside the gap outwards, both stroked 2 units wide with round caps. At `progress` 1
/// it is that mark exactly.
struct QuotaMarkDrawing: View {
  /// 0 draws nothing; the ring fills its first 80%, the tail the rest.
  var progress: Double

  private static let ringShare = 0.8

  var body: some View {
    GeometryReader { proxy in
      let side = min(proxy.size.width, proxy.size.height)
      let style = StrokeStyle(lineWidth: side * 2 / 18, lineCap: .round)
      let ring = min(progress / Self.ringShare, 1)
      let tail = max((progress - Self.ringShare) / (1 - Self.ringShare), 0)
      ZStack {
        QuotaMarkRing()
          .trim(from: 0, to: ring)
          .stroke(style: style)
          .opacity(ring > 0 ? 1 : 0)
        QuotaMarkTail()
          .trim(from: 0, to: tail)
          .stroke(style: style)
          .opacity(tail > 0 ? 1 : 0)
      }
      .frame(width: side, height: side)
    }
    .aspectRatio(1, contentMode: .fit)
  }
}

/// The ring: from (10.51, 14.27) clockwise round (9, 9) to (14.27, 10.51), in 18-unit space.
private struct QuotaMarkRing: Shape {
  func path(in rect: CGRect) -> Path {
    let scale = min(rect.width, rect.height) / 18
    let start = Angle.degrees(74.01)
    let end = Angle.degrees(360 + 15.99)
    var path = Path()
    path.addArc(
      center: CGPoint(x: 9 * scale, y: 9 * scale),
      radius: 5.48 * scale,
      startAngle: start,
      endAngle: end,
      clockwise: false
    )
    return path
  }
}

/// The tail: (9.98, 9.98) to (12.94, 12.94), in 18-unit space.
private struct QuotaMarkTail: Shape {
  func path(in rect: CGRect) -> Path {
    let scale = min(rect.width, rect.height) / 18
    var path = Path()
    path.move(to: CGPoint(x: 9.98 * scale, y: 9.98 * scale))
    path.addLine(to: CGPoint(x: 12.94 * scale, y: 12.94 * scale))
    return path
  }
}
