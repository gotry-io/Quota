import Testing

@testable import QuotaBar

struct QuotaStatePresentationTests {
  @Test
  func navigationBufferHoldsUpdatesOnlyWhileATransitionRunsAndEndsOnTheLatest() {
    var stable = QuotaNavigationPresentationBuffer("loading")
    stable.receive("content", transitionActive: false)
    #expect(stable.displayed == "content")
    #expect(stable.pending == nil)

    var buffer = QuotaNavigationPresentationBuffer("loading")

    buffer.receive("empty", transitionActive: true)
    buffer.receive("content", transitionActive: true)

    #expect(buffer.displayed == "loading")
    #expect(buffer.pending == "content")

    buffer.finishTransition(latest: "content")

    #expect(buffer.displayed == "content")
    #expect(buffer.pending == nil)

    // A transition that ends with nothing pending still lands on the latest value.
    var idle = QuotaNavigationPresentationBuffer("loading")
    idle.finishTransition(latest: "error")
    #expect(idle.displayed == "error")
    #expect(idle.pending == nil)
  }

  @Test
  func aRejectedSignInExplainsItselfWhileMissingSetupKeepsTheGenericCopy() {
    let expired = "The saved sign-in expired or was rejected. Open Codex to refresh the sign-in."
    let rejected = ProviderStatusCopy.from(
      result: QuotaCollectionResult(
        provider: .codex,
        outcome: .authRequired,
        snapshots: [],
        source: nil,
        message: expired,
        sources: [
          QuotaCollectionSource(
            sourceID: "chatgpt_usage_api", outcome: .authRequired, category: .authRequired)
        ],
        accessDenied: nil
      )
    )
    #expect(rejected?.kind == .needsSignIn)
    #expect(rejected?.detail == expired)
    // The rung that was rejected is named: an expired OAuth grant and a stale saved
    // browser session are fixed in different places.
    #expect(rejected?.title == "OAuth")
    #expect(rejected?.accessibilityLabel == "OAuth. \(expired)")

    let staleSession = ProviderStatusCopy.from(
      result: QuotaCollectionResult(
        provider: .codex,
        outcome: .authRequired,
        snapshots: [],
        source: nil,
        message: "The saved browser session expired or was rejected. Add it again in Settings.",
        sources: [
          QuotaCollectionSource(
            sourceID: "chatgpt_usage_api", outcome: .authRequired, category: .authRequired),
          QuotaCollectionSource(
            sourceID: "browser_session", outcome: .authRequired, category: .authRequired),
        ],
        accessDenied: nil
      )
    )
    #expect(staleSession?.title == "Browser session")

    let neverConfigured = ProviderStatusCopy.from(
      result: QuotaCollectionResult(
        provider: .codex,
        outcome: .authRequired,
        snapshots: [],
        source: nil,
        message: nil,
        sources: [],
        accessDenied: nil
      )
    )
    #expect(neverConfigured?.kind == .needsSignIn)
    #expect(neverConfigured?.title == nil)
    #expect(neverConfigured?.detail == "Account setup required.")
  }
}
