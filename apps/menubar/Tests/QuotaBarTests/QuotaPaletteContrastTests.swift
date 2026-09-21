import AppKit
import QuotaPresentation
import SwiftUI
import Testing

@testable import QuotaBar

struct QuotaPaletteContrastTests {
  @Test(arguments: ["aqua", "darkAqua"])
  func cardFillIsOpaque(_ appearanceName: String) {
    let named: NSAppearance.Name = appearanceName == "darkAqua" ? .darkAqua : .aqua
    let appearance = NSAppearance(named: named)!
    let resolved = QuotaPalette.resolvedColor(NSColor(QuotaPalette.cardFill), for: appearance)
    #expect(resolved.alphaComponent == 1)
  }

  @Test
  func contrastRatioDefersToSharedFunction() {
    let foreground = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    let background = NSColor(
      srgbRed: QuotaBrand.emerald.red,
      green: QuotaBrand.emerald.green,
      blue: QuotaBrand.emerald.blue,
      alpha: 1
    )
    let shared = ContrastRatio.ratio(
      foreground: (red: 1, green: 1, blue: 1),
      background: (
        red: QuotaBrand.emerald.red,
        green: QuotaBrand.emerald.green,
        blue: QuotaBrand.emerald.blue
      )
    )
    #expect(QuotaPalette.contrastRatio(foreground: foreground, background: background) == shared)
  }
}
