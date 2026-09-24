import QuotaPresentation
import Testing

struct CompactCountFormatTests {
  @Test
  func compactCountsUseIndustrySuffixesAndKeepSmallValuesReadable() {
    #expect(!CompactCountFormat.compact(999).hasSuffix("k"))
    #expect(CompactCountFormat.compact(1_234).hasSuffix("k"))
    #expect(CompactCountFormat.compact(999_500).hasSuffix("M"))
    #expect(CompactCountFormat.compact(1_234_567).hasSuffix("M"))
    #expect(CompactCountFormat.compact(1_234_567_890).hasSuffix("B"))
  }

  @Test
  func accessibilityCountsDoNotUseCompactNotation() {
    #expect(!CompactCountFormat.accessible(1_234_567).contains("M"))
    #expect(!CompactCountFormat.accessible(1_234_567).contains("k"))
  }

  /// A share rounds half up to a whole percent, the whole is exactly 100%, and a share of
  /// nothing is no share at all rather than a division by zero.
  @Test
  func aShareRoundsHalfUpAndAShareOfNothingIsNone() {
    #expect(CompactCountFormat.share(1, of: 200) == "1%")
    #expect(CompactCountFormat.share(1, of: 201) == "0%")
    #expect(CompactCountFormat.share(7, of: 7) == "100%")
    #expect(CompactCountFormat.share(1, of: 0) == nil)
  }
}
