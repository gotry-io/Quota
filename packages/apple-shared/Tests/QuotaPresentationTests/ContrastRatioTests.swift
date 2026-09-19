import QuotaPresentation
import Testing

struct ContrastRatioTests {
  @Test
  func blackOnWhiteIs21() {
    #expect(
      ContrastRatio.ratio(
        foreground: (red: 0, green: 0, blue: 0),
        background: (red: 1, green: 1, blue: 1)
      ) == 21
    )
  }

  @Test
  func identicalColoursAre1() {
    #expect(
      ContrastRatio.ratio(
        foreground: (red: 0.4, green: 0.5, blue: 0.6),
        background: (red: 0.4, green: 0.5, blue: 0.6)
      ) == 1
    )
  }

  @Test
  func swappingForegroundAndBackgroundDoesNotChangeTheRatio() {
    let whiteOnEmerald = ContrastRatio.ratio(
      foreground: (red: 1, green: 1, blue: 1),
      background: (
        red: QuotaBrand.emerald.red,
        green: QuotaBrand.emerald.green,
        blue: QuotaBrand.emerald.blue
      )
    )
    let emeraldOnWhite = ContrastRatio.ratio(
      foreground: (
        red: QuotaBrand.emerald.red,
        green: QuotaBrand.emerald.green,
        blue: QuotaBrand.emerald.blue
      ),
      background: (red: 1, green: 1, blue: 1)
    )
    #expect(whiteOnEmerald == emeraldOnWhite)
  }

  @Test
  func whiteOnBrandEmeraldIsTheDocumentedWCAGRatio() {
    let ratio = ContrastRatio.ratio(
      foreground: (red: 1, green: 1, blue: 1),
      background: (
        red: QuotaBrand.emerald.red,
        green: QuotaBrand.emerald.green,
        blue: QuotaBrand.emerald.blue
      )
    )
    #expect((ratio * 1_000).rounded() / 1_000 == 5.765)
  }

  @Test
  func blackOnBrandMintIsTheDocumentedWCAGRatio() {
    let ratio = ContrastRatio.ratio(
      foreground: (red: 0, green: 0, blue: 0),
      background: (
        red: QuotaBrand.mint.red,
        green: QuotaBrand.mint.green,
        blue: QuotaBrand.mint.blue
      )
    )
    #expect((ratio * 1_000).rounded() / 1_000 == 12.984)
  }
}
