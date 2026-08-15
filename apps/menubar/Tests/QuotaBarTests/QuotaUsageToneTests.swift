import Testing

@testable import QuotaBar

struct QuotaUsageToneTests {
  @Test
  func classifiesRemainingPercentThresholds() {
    #expect(QuotaUsageTone.tone(remainingPercent: 100) == .healthy)
    #expect(QuotaUsageTone.tone(remainingPercent: 40) == .healthy)
    #expect(QuotaUsageTone.tone(remainingPercent: 39.9) == .warning)
    #expect(QuotaUsageTone.tone(remainingPercent: 15) == .warning)
    #expect(QuotaUsageTone.tone(remainingPercent: 14.9) == .critical)
    #expect(QuotaUsageTone.tone(remainingPercent: 0) == .critical)
  }
}
