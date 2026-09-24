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
}
