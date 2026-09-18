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

  @Test
  func shareOfNothingIsNil() {
    #expect(CompactCountFormat.share(1, of: 0) == nil)
  }

  @Test
  func shareRoundsHalfUpToWholePercent() {
    #expect(CompactCountFormat.share(1, of: 200) == "1%")
    #expect(CompactCountFormat.share(1, of: 201) == "0%")
  }

  @Test
  func shareOfTheWholeIsOneHundredPercent() {
    #expect(CompactCountFormat.share(7, of: 7) == "100%")
  }
}
