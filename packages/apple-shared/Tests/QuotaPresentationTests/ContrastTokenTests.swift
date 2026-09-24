import QuotaPresentation
import Testing

struct ContrastTokenTests {
  private static let bodyText: Double = 4.5

  /// Primary and secondary text and every tone, drawn as text or as a meter, reach body-text
  /// contrast on the card fill in both appearances.
  @Test(arguments: ["light", "dark"])
  func everyTextAndTonePairingOnTheCardFillReachesBodyTextContrast(_ appearance: String) {
    let env = Environment(appearance)
    env.expect("primary on card", env.primary, on: env.card, minimum: Self.bodyText)
    env.expect("secondary on card", env.secondary, on: env.card, minimum: Self.bodyText)
    for (name, color) in env.tones {
      env.expect("\(name) on card", color, on: env.card, minimum: Self.bodyText)
    }
  }
}

private struct Environment {
  var appearance: String
  var card: DesignTokens.RGB
  var primary: DesignTokens.RGB
  var secondary: DesignTokens.RGB

  var tones: [(String, DesignTokens.RGB)] {
    [
      ("healthy", rgb(DesignTokens.Color.quotaHealthy)),
      ("warning", rgb(DesignTokens.Color.quotaWarning)),
      ("critical", rgb(DesignTokens.Color.quotaCritical)),
    ]
  }

  init(_ appearance: String) {
    self.appearance = appearance
    card = Self.rgb(DesignTokens.Color.surfaceContent, appearance: appearance)
    primary = Self.rgb(DesignTokens.Color.textPrimary, appearance: appearance)
    secondary = Self.rgb(DesignTokens.Color.textSecondary, appearance: appearance)
  }

  func rgb(_ pair: DesignTokens.AdaptiveRGB) -> DesignTokens.RGB {
    Self.rgb(pair, appearance: appearance)
  }

  func expect(
    _ name: String,
    _ foreground: DesignTokens.RGB,
    on background: DesignTokens.RGB,
    minimum: Double
  ) {
    let value = ContrastRatio.ratio(
      foreground: (foreground.red, foreground.green, foreground.blue),
      background: (background.red, background.green, background.blue)
    )
    print(
      "\(appearance) \(name) \(Self.format(value)):1 (min \(Self.format(minimum)):1)"
    )
    #expect(
      value >= minimum,
      "\(appearance) \(name) \(Self.format(value)):1 < \(Self.format(minimum)):1"
    )
  }

  private static func rgb(
    _ pair: DesignTokens.AdaptiveRGB,
    appearance: String
  ) -> DesignTokens.RGB {
    appearance == "dark" ? pair.dark : pair.light
  }

  static func format(_ value: Double) -> String {
    String(format: "%.3f", value)
  }
}
