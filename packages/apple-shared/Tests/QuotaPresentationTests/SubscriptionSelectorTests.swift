import QuotaPresentation
import Testing

struct SubscriptionSelectorTests {
  @Test func hashesAKnownGlobalSubscriptionToTwelveLowercaseHexCharacters() {
    #expect(
      SubscriptionSelector.make(
        provider: "codex",
        fingerprint: "account_test",
        fingerprintScope: "global",
        sourceID: nil
      ) == "ccfc96629357"
    )
  }

  @Test func includesASourceScopedIdentityInThePreimage() {
    #expect(
      SubscriptionSelector.make(
        provider: "grok",
        fingerprint: "fp-source",
        fingerprintScope: "source",
        sourceID: "local"
      ) == "bf475adb085d"
    )
  }

  @Test func treatsAMissingSourceIdTheSameAsAnEmptyOne() {
    let omitted = SubscriptionSelector.make(
      provider: "codex",
      fingerprint: "account_test",
      fingerprintScope: "global",
      sourceID: nil
    )
    let empty = SubscriptionSelector.make(
      provider: "codex",
      fingerprint: "account_test",
      fingerprintScope: "global",
      sourceID: ""
    )
    #expect(omitted == empty)
  }
}
