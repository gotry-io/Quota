import QuotaPresentation
import Testing

struct ContrastRatioTests {
  /// The WCAG 2.x anchors: the extremes are 21:1, a colour against itself is 1:1, and which of
  /// the two is the foreground does not change the answer.
  @Test
  func theRatioIsWCAGsFromTwentyOneToOneWhicheverColourIsInFront() {
    #expect(
      ContrastRatio.ratio(
        foreground: (red: 0, green: 0, blue: 0),
        background: (red: 1, green: 1, blue: 1)
      ) == 21
    )
    #expect(
      ContrastRatio.ratio(
        foreground: (red: 0.4, green: 0.5, blue: 0.6),
        background: (red: 0.4, green: 0.5, blue: 0.6)
      ) == 1
    )
    let light = (red: 1.0, green: 1.0, blue: 1.0)
    let dark = (red: 0.03, green: 0.45, blue: 0.34)
    #expect(
      ContrastRatio.ratio(foreground: light, background: dark)
        == ContrastRatio.ratio(foreground: dark, background: light)
    )
  }
}
