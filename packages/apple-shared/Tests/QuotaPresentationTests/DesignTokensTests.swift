import QuotaPresentation
import Testing

struct DesignTokensTests {
  @Test
  func brandAccentMatchesQuotaBrand() {
    #expect(DesignTokens.Color.brandAccent.light == rgb(QuotaBrand.emerald))
    #expect(DesignTokens.Color.brandAccent.dark == rgb(QuotaBrand.mint))
  }

  @Test
  func thresholdsMatchQuotaTone() {
    #expect(DesignTokens.Threshold.quotaHealthyPercent == QuotaTone.healthyPercent)
    #expect(DesignTokens.Threshold.quotaWarningPercent == QuotaTone.warningPercent)
  }

  @Test
  func appleCardRadiusIsTwenty() {
    #expect(DesignTokens.Radius.card == 20)
    #expect(DesignTokens.Radius.control == 8)
    #expect(DesignTokens.Radius.group == 12)
  }

  @Test
  func activityRampStartsAtEmptyStep() {
    #expect(Int((DesignTokens.Color.activity0Fill.light.red * 255).rounded()) == 0xEF)
    #expect(Int((DesignTokens.Color.activity4Fill.light.red * 255).rounded()) == 0x08)
  }

  private func rgb(_ value: QuotaBrand.RGB) -> DesignTokens.RGB {
    DesignTokens.RGB(red: value.red, green: value.green, blue: value.blue)
  }
}
