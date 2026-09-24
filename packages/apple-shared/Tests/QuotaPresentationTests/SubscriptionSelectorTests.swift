import QuotaPresentation
import Testing

struct SubscriptionSelectorTests {
  /// The selector is the twelve hex characters Relay and the web client derive from the same
  /// preimage: a source-scoped identity folds its source id in, and a missing source id hashes
  /// the same as an empty one.
  @Test func theSelectorIsTheTwelveHexEveryRuntimeDerives() {
    #expect(
      SubscriptionSelector.make(
        provider: "codex",
        fingerprint: "account_test",
        fingerprintScope: "global",
        sourceID: nil
      ) == "ccfc96629357"
    )
    #expect(
      SubscriptionSelector.make(
        provider: "codex",
        fingerprint: "account_test",
        fingerprintScope: "global",
        sourceID: ""
      ) == "ccfc96629357"
    )
    #expect(
      SubscriptionSelector.make(
        provider: "grok",
        fingerprint: "fp-source",
        fingerprintScope: "source",
        sourceID: "local"
      ) == "bf475adb085d"
    )
  }
}
