import QuotaPresentation
import Testing

struct ProviderServiceStatusCopyTests {
  @Test
  func operationalAndDegradedLinesMatchTheProductCopy() {
    #expect(
      ProviderServiceStatusCopy.settingsLine(indicator: .none, description: "All Systems Operational")
        == "All systems operational"
    )
    #expect(
      ProviderServiceStatusCopy.settingsLine(
        indicator: .minor,
        description: "Partial System Outage"
      ) == "Degraded · Partial System Outage"
    )
    #expect(ProviderServiceStatusCopy.showsDot(.none) == false)
    #expect(ProviderServiceStatusCopy.showsDot(.minor))
    #expect(ProviderServiceStatusCopy.showsDot(.major))
    #expect(ProviderServiceStatusCopy.showsDot(.critical))
  }
}
