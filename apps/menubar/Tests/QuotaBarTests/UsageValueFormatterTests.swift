import Testing

@testable import QuotaBar

struct UsageValueFormatterTests {
  @Test
  func compactCountsUseIndustrySuffixesAndKeepSmallValuesReadable() {
    #expect(!UsageValueFormatter.count(999).hasSuffix("k"))
    #expect(UsageValueFormatter.count(1_234).hasSuffix("k"))
    #expect(UsageValueFormatter.count(999_500).hasSuffix("M"))
    #expect(UsageValueFormatter.count(1_234_567).hasSuffix("M"))
    #expect(UsageValueFormatter.count(1_234_567_890).hasSuffix("B"))
  }
}
