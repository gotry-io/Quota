import Foundation

/// Product brand color values as sRGB 0…1 components.
public enum QuotaBrand {
  public struct RGB: Sendable, Equatable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
      self.red = red
      self.green = green
      self.blue = blue
    }
  }

  /// Light-appearance brand emerald (`#087456`).
  public static let emerald = RGB(
    red: DesignTokens.Color.brandAccent.light.red,
    green: DesignTokens.Color.brandAccent.light.green,
    blue: DesignTokens.Color.brandAccent.light.blue
  )

  /// Dark-appearance brand mint (`#82ddb8`).
  public static let mint = RGB(
    red: DesignTokens.Color.brandAccent.dark.red,
    green: DesignTokens.Color.brandAccent.dark.green,
    blue: DesignTokens.Color.brandAccent.dark.blue
  )
}
