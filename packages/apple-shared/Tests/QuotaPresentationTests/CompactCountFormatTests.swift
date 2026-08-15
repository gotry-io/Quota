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
}
