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

/// The rung list is the catalog's ladder, in the order collection tries it.
@Test
func everyProviderListsItsRungsInLadderOrder() {
  #expect(
    SignInRungPresentation.rungs(for: .codex, result: nil, configuration: nil, browser: nil)
      .map(\.title) == ["Codex CLI"])
  #expect(
    SignInRungPresentation.rungs(
      for: .kimi, result: nil, configuration: nil,
      browser: .init(isEnabled: false, isScanning: false, accountLabels: [])
    ).map(\.title) == ["API Key", "Kimi Code CLI", "Browser Sign-in"])
  #expect(
    SignInRungPresentation.rungs(
      for: .cursor, result: nil, configuration: nil,
      browser: .init(isEnabled: false, isScanning: false, accountLabels: [])
    ).map(\.title) == ["Cursor App", "Browser Sign-in"])
  #expect(
    SignInRungPresentation.rungs(for: .openrouter, result: nil, configuration: nil, browser: nil)
      .map(\.title) == ["API Key"])
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

/// A browser success never counts for the CLI row: the ids keep the rungs apart.
@Test
func aBrowserSuccessDoesNotSignTheCliRungIn() {
  let rungs = SignInRungPresentation.rungs(
    for: .claude,
    result: result(
      .claude, outcome: .success,
      sources: [("anthropic_oauth_usage_api", .authRequired), ("claude_web_usage_api", .success)]),
    configuration: nil,
    browser: .init(isEnabled: true, isScanning: false, accountLabels: ["ad***@example.com"]))
  #expect(rungs.map(\.status) == [.notSignedIn, .browserOn])
  #expect(rungs.last?.detail == "ad***@example.com")
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

/// Kimi's two official rungs answer by different ids, so a CLI-file sign-in never reads as a key.
@Test
func kimiKeepsItsKeyAndCliRungsApart() {
  let viaCli = SignInRungPresentation.rungs(
    for: .kimi,
    result: result(.kimi, outcome: .success, sources: [("kimi_code_cli_credential", .success)]),
    configuration: nil,
    browser: .init(isEnabled: false, isScanning: false, accountLabels: []))
  #expect(viaCli.map(\.status) == [.notConfigured, .signedIn, .browserOff])
  #expect(viaCli.last?.detail == "Fallback when no key or CLI works")
}

@Test
func browserRungDetailFollowsTheScan() {
  func browser(_ state: SignInRungPresentation.BrowserState) -> SignInRung? {
    SignInRungPresentation.rungs(for: .codex, result: nil, configuration: nil, browser: state).last
  }
  #expect(browser(.init(isEnabled: false, isScanning: false, accountLabels: []))?.detail
    == "Fallback when the CLI is signed out")
  #expect(browser(.init(isEnabled: true, isScanning: true, accountLabels: []))?.detail
    == "Looking for sign-ins…")
  #expect(browser(.init(isEnabled: true, isScanning: false, accountLabels: []))?.detail
    == "No browser could be read")
  #expect(
    browser(
      .init(
        isEnabled: true, isScanning: false, accountLabels: [],
        readBrowsers: ["Chrome", "Firefox"], skippedBrowsers: ["Safari"])
    )?.detail == "No sign-in in Chrome, Firefox · Safari not checked")
  #expect(
    browser(
      .init(isEnabled: true, isScanning: false, accountLabels: [], readBrowsers: ["Chrome"])
    )?.detail == "No sign-in in Chrome")
  #expect(
    browser(
      .init(isEnabled: true, isScanning: false, accountLabels: [], skippedBrowsers: ["Safari"])
    )?.detail == "No browser could be read · Safari not checked")
  // A cookie that was found but refused by the service is not "nothing found".
  #expect(
    browser(
      .init(
        isEnabled: true, isScanning: false, accountLabels: [], readBrowsers: ["Chrome"],
        candidatesFound: 1)
    )?.detail == "Sign-in found but not accepted — see below")
  #expect(browser(.init(isEnabled: true, isScanning: false, accountLabels: ["a", "b"]))?.detail
    == "2 accounts · a, b")
}

@Test
func statusLineSaysWhatTheAgentsListNeeds() {
  let signedIn = SignInRungPresentation.rungs(
    for: .codex,
    result: result(.codex, outcome: .success, sources: [("chatgpt_usage_api", .success)]),
    configuration: nil, browser: nil)
  #expect(
    SignInRungPresentation.statusLine(rungs: signedIn, accountCount: 2, reportedByDevices: false)
      == "Signed in · 2 accounts")
  #expect(SignInRungPresentation.needsSignIn(rungs: signedIn) == false)

  let signedOut = SignInRungPresentation.rungs(for: .codex, result: nil, configuration: nil, browser: nil)
  #expect(
    SignInRungPresentation.statusLine(rungs: signedOut, accountCount: 0, reportedByDevices: false)
      == "Not signed in")
  #expect(
    SignInRungPresentation.statusLine(rungs: signedOut, accountCount: 1, reportedByDevices: true)
      == "Reported by another device")
  #expect(SignInRungPresentation.needsSignIn(rungs: signedOut))

  let keyOnly = SignInRungPresentation.rungs(
    for: .openrouter, result: nil, configuration: configuration(.openrouter, masked: "sk"),
    browser: nil)
  #expect(
    SignInRungPresentation.statusLine(rungs: keyOnly, accountCount: 1, reportedByDevices: false)
      == "Configured")
  let unconfigured = SignInRungPresentation.rungs(
    for: .deepseek, result: nil, configuration: nil, browser: nil)
  #expect(
    SignInRungPresentation.statusLine(rungs: unconfigured, accountCount: 0, reportedByDevices: false)
      == "Not configured")
}
