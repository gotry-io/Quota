import QuotaPresentation
import SwiftUI
import Testing
import UIKit

@testable import Quota

struct ContrastTokenTests {
  private static let bodyText: Double = 4.5
  private static let largeTextAndGraphics: Double = 3.0

  @Test(arguments: [UIUserInterfaceStyle.light, .dark])
  func labelAndSecondaryOnGroupedBackgrounds(_ style: UIUserInterfaceStyle) {
    let env = Environment(style)
    env.expect(
      "label on systemGroupedBackground",
      UIColor.label,
      on: UIColor.systemGroupedBackground,
      minimum: Self.bodyText
    )
    env.expect(
      "label on secondarySystemGroupedBackground",
      UIColor.label,
      on: UIColor.secondarySystemGroupedBackground,
      minimum: Self.bodyText
    )
    // docs/design.md type roles: supporting copy may be secondary at subheadline and larger (body text, 4.5:1).
    env.expect(
      "secondary on systemGroupedBackground",
      UIColor(QuotaTheme.secondary),
      on: UIColor.systemGroupedBackground,
      minimum: Self.bodyText
    )
    env.expect(
      "secondary on secondarySystemGroupedBackground",
      UIColor(QuotaTheme.secondary),
      on: UIColor.secondarySystemGroupedBackground,
      minimum: Self.bodyText
    )
  }

  @Test(arguments: [UIUserInterfaceStyle.light, .dark])
  func semanticTextOnCard(_ style: UIUserInterfaceStyle) {
    let env = Environment(style)
    env.expect(
      "emerald as text on card",
      UIColor(QuotaTheme.emerald),
      on: env.card,
      minimum: Self.bodyText
    )
    env.expect(
      "warning as text on card",
      UIColor(QuotaTheme.warning),
      on: env.card,
      minimum: Self.bodyText
    )
    env.expect(
      "critical (system red token) as text on card",
      UIColor(QuotaTheme.critical),
      on: env.card,
      minimum: Self.bodyText
    )
  }

  @Test(arguments: [UIUserInterfaceStyle.light, .dark])
  func whiteOnEmeraldAndMintLabel(_ style: UIUserInterfaceStyle) {
    let env = Environment(style)
    let emerald = UIColor(
      red: QuotaBrand.emerald.red,
      green: QuotaBrand.emerald.green,
      blue: QuotaBrand.emerald.blue,
      alpha: 1
    )
    env.expect("white on QuotaBrand.emerald", .white, on: emerald, minimum: Self.bodyText)

    let mint = UIColor(
      red: QuotaBrand.mint.red,
      green: QuotaBrand.mint.green,
      blue: QuotaBrand.mint.blue,
      alpha: 1
    )
    let mintRGB = env.rgb(mint)
    let whiteRatio = ContrastRatio.ratio(foreground: (1, 1, 1), background: mintRGB)
    let blackRatio = ContrastRatio.ratio(foreground: (0, 0, 0), background: mintRGB)
    let label: UIColor = whiteRatio >= blackRatio ? .white : .black
    env.expect("dark-mode mint with its label colour", label, on: mint, minimum: Self.bodyText)
  }

  @Test(arguments: [UIUserInterfaceStyle.light, .dark])
  func meterFillsAndStatusDots(_ style: UIUserInterfaceStyle) {
    let env = Environment(style)
    let fills: [(String, UIColor)] = [
      ("emerald", UIColor(QuotaTheme.emerald)),
      ("warning", UIColor(QuotaTheme.warning)),
      ("critical", UIColor(QuotaTheme.critical)),
    ]
    for (name, fill) in fills {
      env.expect(
        "\(name) meter fill on card",
        fill,
        on: env.card,
        minimum: Self.largeTextAndGraphics
      )
      env.expect(
        "\(name) status dot on card",
        fill,
        on: env.card,
        minimum: Self.largeTextAndGraphics
      )
      let trackOnCard = env.flatten(UIColor(QuotaTheme.meterTrack), on: env.cardRGB)
      env.expectRGB(
        "\(name) meter fill on meterTrack",
        env.flatten(fill, on: trackOnCard),
        on: trackOnCard,
        minimum: Self.largeTextAndGraphics
      )
    }
    // The Usage chart draws a cached day's bar in its own fill.
    env.expect(
      "cached chart bar on card",
      UIColor(QuotaTheme.cachedFill),
      on: env.card,
      minimum: Self.largeTextAndGraphics
    )
  }

  @Test(arguments: [UIUserInterfaceStyle.light, .dark])
  func capsuleStyles(_ style: UIUserInterfaceStyle) {
    let env = Environment(style)
    let emerald = UIColor(QuotaTheme.emerald)
    let activeFill = emerald.withAlphaComponent(QuotaTheme.capsuleFillOpacity)
    let activeBackground = env.flatten(activeFill, on: env.cardRGB)
    env.expectRGB(
      "Active capsule text on wash",
      env.flatten(emerald, on: activeBackground),
      on: activeBackground,
      minimum: Self.bodyText
    )
    env.expect(
      "Reporting capsule text on card",
      emerald,
      on: env.card,
      minimum: Self.bodyText
    )
    env.expect(
      "Reporting capsule stroke on card",
      emerald,
      on: env.card,
      minimum: Self.largeTextAndGraphics
    )
    env.expect(
      "plan capsule text on card",
      UIColor.label,
      on: env.card,
      minimum: Self.bodyText
    )
  }

  @Test(arguments: [UIUserInterfaceStyle.light, .dark])
  func heatmapStepsAndSelectedStroke(_ style: UIUserInterfaceStyle) {
    let env = Environment(style)
    // Non-empty fill vs the empty step is not required. The outline carries non-text contrast.
    var luminances: [Double] = []
    for level in 0...4 {
      let fill = UIColor(QuotaTheme.activityFill(level))
      let fillRatio = env.ratio(fill, on: env.card)
      print(
        "\(env.name) activity fill \(level) on card "
          + "\(Environment.format(fillRatio)):1 (informational)"
      )
      luminances.append(ContrastRatio.relativeLuminance(env.rgb(fill)))
      if level >= 1 {
        env.expect(
          "activity border \(level) on card",
          UIColor(QuotaTheme.activityBorder(level)),
          on: env.card,
          minimum: Self.largeTextAndGraphics
        )
      }
    }
    let diffs = zip(luminances, luminances.dropFirst()).map { $1 - $0 }
    let rising = diffs.allSatisfy { $0 > 0 }
    let falling = diffs.allSatisfy { $0 < 0 }
    let steps = luminances.map(Environment.format).joined(separator: ", ")
    print("\(env.name) activity fill luminance \(steps)")
    #expect(
      rising || falling,
      "\(env.name) activity fill ramp is not strictly monotonic in luminance"
    )
    env.expect(
      "selected-day stroke on card",
      UIColor(QuotaTheme.emerald),
      on: env.card,
      minimum: Self.largeTextAndGraphics
    )
  }
}

private struct Environment {
  var style: UIUserInterfaceStyle
  var traits: UITraitCollection
  var card: UIColor

  var name: String { style == .dark ? "dark" : "light" }
  var cardRGB: (red: Double, green: Double, blue: Double) {
    flatten(card, on: (0, 0, 0))
  }

  init(_ style: UIUserInterfaceStyle) {
    self.style = style
    traits = UITraitCollection(userInterfaceStyle: style)
    card = UIColor.secondarySystemGroupedBackground
  }

  func expect(_ name: String, _ foreground: UIColor, on background: UIColor, minimum: Double) {
    expectRGB(name, flatten(foreground, on: rgb(background)), on: rgb(background), minimum: minimum)
  }

  func expectRGB(
    _ name: String,
    _ foreground: (red: Double, green: Double, blue: Double),
    on background: (red: Double, green: Double, blue: Double),
    minimum: Double
  ) {
    let value = ContrastRatio.ratio(foreground: foreground, background: background)
    print("\(self.name) \(name) \(Self.format(value)):1 (min \(Self.format(minimum)):1)")
    #expect(
      value >= minimum,
      "\(self.name) \(name) \(Self.format(value)):1 < \(Self.format(minimum)):1"
    )
  }

  func ratio(_ foreground: UIColor, on background: UIColor) -> Double {
    ContrastRatio.ratio(
      foreground: flatten(foreground, on: rgb(background)),
      background: rgb(background)
    )
  }

  func rgb(_ color: UIColor) -> (red: Double, green: Double, blue: Double) {
    flatten(color, on: (0, 0, 0))
  }

  func flatten(
    _ color: UIColor,
    on backdrop: (red: Double, green: Double, blue: Double)
  ) -> (red: Double, green: Double, blue: Double) {
    let components = sRGB(color)
    return (
      components.red * components.alpha + backdrop.red * (1 - components.alpha),
      components.green * components.alpha + backdrop.green * (1 - components.alpha),
      components.blue * components.alpha + backdrop.blue * (1 - components.alpha)
    )
  }

  func sRGB(_ color: UIColor) -> (red: Double, green: Double, blue: Double, alpha: Double) {
    let resolved = color.resolvedColor(with: traits)
    guard
      let space = CGColorSpace(name: CGColorSpace.sRGB),
      let converted = resolved.cgColor.converted(
        to: space,
        intent: .relativeColorimetric,
        options: nil
      ),
      let components = converted.components,
      components.count >= 3
    else {
      return (0, 0, 0, 1)
    }
    let alpha = components.count > 3 ? Double(components[3]) : 1
    return (Double(components[0]), Double(components[1]), Double(components[2]), alpha)
  }

  static func format(_ value: Double) -> String {
    String(format: "%.3f", value)
  }
}
