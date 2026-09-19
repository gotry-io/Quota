import Foundation

/// WCAG 2.x contrast ratio of two opaque sRGB colours.
public enum ContrastRatio: Sendable {
  /// Contrast ratio from sRGB components in 0…1.
  public static func ratio(
    foreground: (red: Double, green: Double, blue: Double),
    background: (red: Double, green: Double, blue: Double)
  ) -> Double {
    let lighter = max(relativeLuminance(foreground), relativeLuminance(background))
    let darker = min(relativeLuminance(foreground), relativeLuminance(background))
    return (lighter + 0.05) / (darker + 0.05)
  }

  public static func relativeLuminance(
    _ color: (red: Double, green: Double, blue: Double)
  ) -> Double {
    func channel(_ value: Double) -> Double {
      value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(color.red) + 0.7152 * channel(color.green)
      + 0.0722 * channel(color.blue)
  }
}
