import Foundation
import QuotaWire

/// One way this Mac can hold a credential for a provider, in the order collection tries them.
///
/// The Agent page lists every rung with the verdict the last collection reached for it, so a
/// person can see not just how to sign in but whether they already are. The rung list is a
/// fact about the provider's catalog row; the verdict comes from the collection report's
/// `sources[]`, matched by source id.
struct SignInRung: Equatable, Identifiable, Sendable {
  enum Kind: Equatable, Sendable {
    /// The provider's own program, signed in with a command run in a terminal.
    case cli(command: String?)
    /// A key entered in QuotaBar and kept by the local service.
    case apiKey
    /// A desktop application's signed-in session, read from its own state.
    case application
    /// Cookies read from browsers on this Mac.
    case browser
  }

  enum Status: Equatable, Sendable {
    case signedIn
    case notSignedIn
    case configured
    case notConfigured
    case rejected
    case unavailable
    case browserOff
    case browserOn
  }

  let kind: Kind
  let title: String
  let status: Status
  /// Supporting line under the title; nil keeps the row single-line.
  let detail: String?

  var id: String { title }

  var statusTitle: String {
    switch status {
    case .signedIn: "Signed in"
    case .notSignedIn: "Not signed in"
    case .configured: "Configured"
    case .notConfigured: "Not configured"
    case .rejected: "Rejected"
    case .unavailable: "Unavailable"
    case .browserOff: "Off"
    case .browserOn: "On"
    }
  }

  var isWorking: Bool { status == .signedIn || status == .configured || status == .browserOn }
  var needsAttention: Bool { status == .notSignedIn || status == .notConfigured || status == .rejected }
}

/// Every source id a rung can answer with. Written once, here, beside the display-name table
/// the report is read with.
enum SignInRungCatalog {
  static let browserSourceIDs: Set<String> = [
    "browser_session", "chatgpt_web_usage_api", "claude_web_usage_api",
    "grok_web_billing_api", "kimi_web_billing_api", "cursor_dashboard_api",
  ]

  static func isBrowserSource(_ sourceID: String) -> Bool {
    browserSourceIDs.contains(sourceID)
  }

  /// The official rungs this provider has, before the browser one, with the ids each answers by.
  static func officialRungs(for provider: ProviderID) -> [(kind: SignInRung.Kind, title: String, sourceIDs: Set<String>)] {
    switch provider {
    case .codex:
      [(.cli(command: provider.setupAction), "Codex CLI", ["chatgpt_usage_api", "codex_pat_usage_api"])]
    case .claude:
      [(.cli(command: provider.setupAction), "Claude Code CLI", ["anthropic_oauth_usage_api", "anthropic_oauth_signed_out"])]
    case .grok:
      [(.cli(command: provider.setupAction), "Grok CLI", ["grok_billing_api"])]
    case .kimi:
      [
        (.apiKey, "API Key", ["kimi_code_usages_api"]),
        (.cli(command: nil), "Kimi Code CLI", ["kimi_code_cli_credential"]),
      ]
    case .openrouter:
      [(.apiKey, "API Key", ["openrouter_api"])]
    case .deepseek:
      [(.apiKey, "API Key", ["deepseek_balance_api"])]
    case .litellm:
      [(.apiKey, "API Key", ["litellm_budget_api"])]
    case .cursor:
      [(.application, "Cursor App", ["cursor_app_auth"])]
    case .unknown:
      []
    }
  }

  /// What the browser rung is a fallback for, in the words of that provider's page.
  static func browserFallbackSentence(for provider: ProviderID) -> String {
    switch provider {
    case .codex, .claude, .grok: "Fallback when the CLI is signed out"
    case .kimi: "Fallback when no key or CLI works"
    case .cursor: "Fallback when Cursor is signed out"
    case .openrouter, .deepseek, .litellm, .unknown: "Fallback when nothing else works"
    }
  }
}

/// Builds the Sign-in rows for one provider from what the local service already reports.
enum SignInRungPresentation {
  struct BrowserState: Equatable, Sendable {
    var isEnabled: Bool
    var isScanning: Bool
    var accountLabels: [String]
    /// Browsers the last scan actually opened, by display name, in scan order.
    var readBrowsers: [String] = []
    /// Browsers the last scan skipped because macOS has not granted the read yet.
    var skippedBrowsers: [String] = []
    /// Sign-ins the last scan found; with no stored account, the service refused them.
    var candidatesFound: Int = 0
  }

  static func rungs(
    for provider: ProviderID,
    result: QuotaCollectionResult?,
    configuration: LocalServiceProviderConfig?,
    browser: BrowserState?
  ) -> [SignInRung] {
    var rungs: [SignInRung] = []
    for official in SignInRungCatalog.officialRungs(for: provider) {
      let verdict = result?.sources.first { official.sourceIDs.contains($0.sourceID) }
      switch official.kind {
      case .apiKey:
        let configured = configuration?.configured == true
        let status: SignInRung.Status
        if let verdict, verdict.category == .success {
          status = .configured
        } else if configured, verdict?.category == .authRequired {
          status = .rejected
        } else if configured {
          status = .configured
        } else {
          status = .notConfigured
        }
        rungs.append(
          SignInRung(
            kind: .apiKey,
            title: official.title,
            status: status,
            detail: configured ? configuration?.maskedAPIKey : nil
          ))
      case .cli, .application:
        let status: SignInRung.Status
        switch verdict?.category {
        case .success: status = .signedIn
        case .authRequired, .none: status = .notSignedIn
        case .accessDenied, .unavailable, .unsupported, .error: status = .unavailable
        }
        let detail: String? =
          if official.kind == .application, status == .signedIn {
            "Signed-in session on this Mac"
          } else if status == .unavailable {
            result?.message
          } else {
            nil
          }
        rungs.append(
          SignInRung(kind: official.kind, title: official.title, status: status, detail: detail))
      case .browser:
        continue
      }
    }
    if let browser, provider.browserSession != nil {
      let detail: String
      let status: SignInRung.Status
      if !browser.isEnabled {
        status = .browserOff
        detail = SignInRungCatalog.browserFallbackSentence(for: provider)
      } else if browser.isScanning {
        status = .browserOn
        detail = "Looking for sign-ins…"
      } else if browser.accountLabels.isEmpty, browser.candidatesFound > 0 {
        status = .browserOn
        detail = "Sign-in found but not accepted — see below"
      } else if browser.accountLabels.isEmpty {
        status = .browserOn
        detail = Self.nothingFoundDetail(
          read: browser.readBrowsers, skipped: browser.skippedBrowsers)
      } else {
        status = .browserOn
        detail =
          browser.accountLabels.count == 1
          ? browser.accountLabels[0]
          : "\(browser.accountLabels.count) accounts · \(browser.accountLabels.joined(separator: ", "))"
      }
      rungs.append(SignInRung(kind: .browser, title: "Browser Sign-in", status: status, detail: detail))
    }
    return rungs
  }

  /// "Nothing found" has to say where QuotaBar looked, or a person cannot tell a browser that
  /// was read and held no sign-in from one that was never opened for want of a permission.
  static func nothingFoundDetail(read: [String], skipped: [String]) -> String {
    let looked =
      read.isEmpty
      ? "No browser could be read"
      : "No sign-in in \(read.joined(separator: ", "))"
    guard !skipped.isEmpty else { return looked }
    return "\(looked) · \(skipped.joined(separator: ", ")) not checked"
  }

  /// One line for the Agents list and the Settings home count: what this provider's sign-in
  /// state is, from this Mac's rungs and the account devices reporting it.
  static func statusLine(
    rungs: [SignInRung],
    accountCount: Int,
    reportedByDevices: Bool
  ) -> String {
    let working = rungs.filter { $0.kind != .browser && $0.isWorking }
    let browserWorking = rungs.contains { $0.kind == .browser && $0.status == .browserOn }
    if !working.isEmpty || browserWorking {
      let word = rungs.contains { $0.kind == .apiKey && $0.isWorking } && working.count == 1
        ? "Configured" : "Signed in"
      return accountCount > 1 ? "\(word) · \(accountCount) accounts" : word
    }
    if reportedByDevices {
      return "Reported by another device"
    }
    if rungs.contains(where: { $0.status == .rejected }) {
      return "Key rejected"
    }
    if rungs.contains(where: { $0.status == .unavailable }) {
      return "Unavailable"
    }
    if rungs.allSatisfy({ $0.kind == .apiKey || $0.kind == .browser }) {
      return "Not configured"
    }
    return "Not signed in"
  }

  static func needsSignIn(rungs: [SignInRung]) -> Bool {
    let official = rungs.filter { $0.kind != .browser }
    guard !official.isEmpty else { return false }
    return !official.contains(where: \.isWorking)
      && !rungs.contains { $0.kind == .browser && $0.status == .browserOn }
  }
}
