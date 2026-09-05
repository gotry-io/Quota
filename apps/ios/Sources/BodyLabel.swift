import SwiftUI
import UIKit

/// UILabel with `adjustsFontForContentSizeCategory` so List rows advertise full Dynamic Type.
struct BodyLabel: UIViewRepresentable {
  var text: String
  var style: UIFont.TextStyle = .body
  var weight: UIFont.Weight = .regular
  var monospacedDigit: Bool = false

  func makeUIView(context: Context) -> UILabel {
    let label = UILabel()
    label.numberOfLines = 0
    label.adjustsFontForContentSizeCategory = true
    label.textColor = .label
    label.setContentCompressionResistancePriority(.required, for: .vertical)
    label.setContentHuggingPriority(.required, for: .vertical)
    label.setContentHuggingPriority(.defaultLow, for: .horizontal)
    applyFont(label)
    return label
  }

  func updateUIView(_ uiView: UILabel, context: Context) {
    uiView.text = text
    applyFont(uiView)
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView: UILabel, context: Context) -> CGSize? {
    let width = proposal.width ?? 0
    uiView.preferredMaxLayoutWidth = width.isFinite && width > 0 ? width : 0
    return uiView.sizeThatFits(
      CGSize(
        width: width.isFinite && width > 0 ? width : UIView.layoutFittingCompressedSize.width,
        height: .greatestFiniteMagnitude
      )
    )
  }

  private func applyFont(_ label: UILabel) {
    let base = UIFont.preferredFont(forTextStyle: style)
    let font =
      monospacedDigit
      ? UIFont.monospacedDigitSystemFont(ofSize: base.pointSize, weight: weight)
      : UIFont.systemFont(ofSize: base.pointSize, weight: weight)
    label.font = UIFontMetrics(forTextStyle: style).scaledFont(for: font)
  }
}
