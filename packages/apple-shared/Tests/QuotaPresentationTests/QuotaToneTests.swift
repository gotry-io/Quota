import QuotaPresentation
import Testing

struct QuotaToneTests {
  @Test
  func remainingClassifiesPercentThresholds() {
    #expect(QuotaTone.remaining(percent: 100) == .healthy)
    #expect(QuotaTone.remaining(percent: 40) == .healthy)
    #expect(QuotaTone.remaining(percent: 39.9) == .warning)
    #expect(QuotaTone.remaining(percent: 15) == .warning)
    #expect(QuotaTone.remaining(percent: 14.9) == .critical)
    #expect(QuotaTone.remaining(percent: 0) == .critical)
    #expect(QuotaTone.remaining(percent: -5) == .critical)
    #expect(QuotaTone.remaining(percent: 150) == .healthy)
  }
}
