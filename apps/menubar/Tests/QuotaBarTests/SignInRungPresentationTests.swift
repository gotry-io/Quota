import Foundation
import QuotaWire
import Testing

@testable import QuotaBar

private func result(
  _ provider: ProviderID,
  outcome: CollectionOutcome,
  sources: [(String, CollectionSourceCategory)],
  message: String? = nil
) -> QuotaCollectionResult {
  QuotaCollectionResult(
    provider: provider,
    outcome: outcome,
    snapshots: [],
    source: nil,
    message: message,
    sources: sources.map { id, category in
      QuotaCollectionSource(
        sourceID: id,
        outcome: category == .success ? .success : CollectionOutcome(rawValue: category.rawValue) ?? .error,
        category: category)
    },
    accessDenied: nil
  )
}

private func configuration(_ provider: ProviderID, masked: String?) -> LocalServiceProviderConfig {
  LocalServiceProviderConfig(
    provider: provider, configured: masked != nil, maskedAPIKey: masked, baseURL: nil)
}

@Test
func cliRungReadsItsVerdictFromTheReportAndOffersTheCommandOnlyWhenSignedOut() {
  let signedIn = SignInRungPresentation.rungs(
    for: .codex,
    result: result(.codex, outcome: .success, sources: [("chatgpt_usage_api", .success)]),
    configuration: nil, browser: nil)
  #expect(signedIn.first?.status == .signedIn)
  #expect(signedIn.first?.kind == .cli(command: "codex login"))

  let signedOut = SignInRungPresentation.rungs(
    for: .codex,
    result: result(.codex, outcome: .authRequired, sources: [("chatgpt_usage_api", .authRequired)]),
    configuration: nil, browser: nil)
  #expect(signedOut.first?.status == .notSignedIn)

  let nothing = SignInRungPresentation.rungs(for: .codex, result: nil, configuration: nil, browser: nil)
  #expect(nothing.first?.status == .notSignedIn)

  let down = SignInRungPresentation.rungs(
    for: .grok,
    result: result(
      .grok, outcome: .unavailable, sources: [("grok_billing_api", .unavailable)],
      message: "Grok quota is temporarily unavailable."),
    configuration: nil, browser: nil)
  #expect(down.first?.status == .unavailable)
  #expect(down.first?.detail == "Grok quota is temporarily unavailable.")
}

/// A success counts only for the rung whose source id answered: a browser success never signs
/// the CLI row in, and Kimi's CLI-file sign-in never reads as its API key.
@Test
func aRungIsSignedInOnlyByItsOwnSourceID() {
  let rungs = SignInRungPresentation.rungs(
    for: .claude,
    result: result(
      .claude, outcome: .success,
      sources: [("anthropic_oauth_usage_api", .authRequired), ("claude_web_usage_api", .success)]),
    configuration: nil,
    browser: .init(isEnabled: true, isScanning: false, accountLabels: ["ad***@example.com"]))
  #expect(rungs.map(\.status) == [.notSignedIn, .browserOn])
  #expect(rungs.last?.detail == "ad***@example.com")

  let viaCli = SignInRungPresentation.rungs(
    for: .kimi,
    result: result(.kimi, outcome: .success, sources: [("kimi_code_cli_credential", .success)]),
    configuration: nil,
    browser: .init(isEnabled: false, isScanning: false, accountLabels: []))
  #expect(viaCli.map(\.status) == [.notConfigured, .signedIn, .browserOff])
}

@Test
func apiKeyRungCombinesConfigurationWithTheReport() {
  let none = SignInRungPresentation.rungs(for: .openrouter, result: nil, configuration: nil, browser: nil)
  #expect(none.first?.status == .notConfigured)
  #expect(none.first?.detail == nil)

  let configured = SignInRungPresentation.rungs(
    for: .openrouter, result: nil, configuration: configuration(.openrouter, masked: "sk-or-…4f2a"),
    browser: nil)
  #expect(configured.first?.status == .configured)
  #expect(configured.first?.detail == "sk-or-…4f2a")

  let rejected = SignInRungPresentation.rungs(
    for: .openrouter,
    result: result(.openrouter, outcome: .authRequired, sources: [("openrouter_api", .authRequired)]),
    configuration: configuration(.openrouter, masked: "sk-or-…4f2a"), browser: nil)
  #expect(rejected.first?.status == .rejected)
}
