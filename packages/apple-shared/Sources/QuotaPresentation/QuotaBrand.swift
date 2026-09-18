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
  public static let emerald = RGB(red: 8.0 / 255.0, green: 116.0 / 255.0, blue: 86.0 / 255.0)

  /// Dark-appearance brand mint (`#82ddb8`).
  public static let mint = RGB(red: 130.0 / 255.0, green: 221.0 / 255.0, blue: 184.0 / 255.0)
}
