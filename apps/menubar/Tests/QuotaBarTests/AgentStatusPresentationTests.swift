import Foundation
import Testing

@testable import QuotaBar

struct AgentStatusPresentationTests {
  @Test
  func signedInIsToggleableWithoutStatusCopy() {
    let status = AgentStatusPresentation.resolve(
      result: QuotaCollectionResult(
        provider: .codex,
        outcome: .success,
        snapshots: [],
        source: "chatgpt_usage_api",
        message: nil
      )
    )
    #expect(status.canToggle)
    #expect(status.detail == nil)
  }

  @Test
  func authRequiredDisablesToggleAndShowsLoginHint() {
    let status = AgentStatusPresentation.resolve(
      result: QuotaCollectionResult(
        provider: .claude,
        outcome: .authRequired,
        snapshots: [],
        source: nil,
        message: "Claude OAuth credentials are missing or unreadable. Run `claude auth login`."
      )
    )
    #expect(!status.canToggle)
    #expect(status.detail == "Run `claude auth login`")
  }

  @Test
  func usesProviderFallbackWhenMessageHasNoCommand() {
    let status = AgentStatusPresentation.resolve(
      result: QuotaCollectionResult(
        provider: .grok,
        outcome: .authRequired,
        snapshots: [],
        source: nil,
        message: "Grok auth.json not found."
      )
    )
    #expect(!status.canToggle)
    #expect(status.detail == "Run `grok login`")
  }

  @Test
  func unavailableKeepsMessageAndDoesNotLookLikeLogin() {
    let status = AgentStatusPresentation.resolve(
      result: QuotaCollectionResult(
        provider: .codex,
        outcome: .unavailable,
        snapshots: [],
        source: nil,
        message: "Codex usage API is rate limited."
      )
    )
    #expect(!status.canToggle)
    #expect(status.detail == "Codex usage API is rate limited.")
  }

  @Test
  func errorUsesCantRefreshWithoutLoginCopy() {
    let status = AgentStatusPresentation.resolve(
      result: QuotaCollectionResult(
        provider: .grok,
        outcome: .error,
        snapshots: [],
        source: nil,
        message: "Malformed billing payload."
      )
    )
    #expect(!status.canToggle)
    #expect(status.detail == "Malformed billing payload.")
  }

  @Test
  func missingResultDisablesToggle() {
    let status = AgentStatusPresentation.resolve(result: nil)
    #expect(!status.canToggle)
    #expect(status.detail == "Refresh to check access.")
  }
}
