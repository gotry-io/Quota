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

  /// A model's shade is its rank inside its provider, so every family must read as one ramp:
  /// rank 1 strongest against the canvas and each later rank closer to it, in both appearances.
  /// The fills are not held to 3:1 — a chart always labels its models — but the order is.
  @Test(arguments: ["light", "dark"])
  func everyModelFamilyFadesTowardTheCanvasByRank(_ appearance: String) {
    let env = Environment(appearance)
    let canvas = env.rgb(DesignTokens.Color.surfaceCanvas)
    for family in DesignTokens.ModelFamily.allCases {
      let ratios = (1...4).map { shade in
        env.ratio(env.rgb(DesignTokens.Color.model(family, shade: shade)), on: canvas)
      }
      #expect(
        zip(ratios, ratios.dropFirst()).allSatisfy { $0 > $1 },
        "\(appearance) \(family.rawValue) shades \(ratios.map(Environment.format)) do not fade by rank"
      )
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

  func ratio(_ foreground: DesignTokens.RGB, on background: DesignTokens.RGB) -> Double {
    ContrastRatio.ratio(
      foreground: (foreground.red, foreground.green, foreground.blue),
      background: (background.red, background.green, background.blue)
    )
  }

  func expect(
    _ name: String,
    _ foreground: DesignTokens.RGB,
    on background: DesignTokens.RGB,
    minimum: Double
  ) {
    let value = ratio(foreground, on: background)
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
