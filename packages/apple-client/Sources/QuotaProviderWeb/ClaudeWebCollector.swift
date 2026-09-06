import Foundation
import QuotaWire

/// Claude Code's last rung: the claude.ai session, read on the device the reader signed in on.
///
/// Mirrors `packages/service/src/providers/claude/web.rs`, including the rule that separates a
/// session worth keeping from one that only looks signed in: the organization list alone is not
/// proof, because a session that can list organizations and can no longer read usage is one this
/// build would store and never be able to spend.
public struct ClaudeWebCollector: ProviderWebCollector {
  public static let provider: ProviderID = .claude
  public static let source = "claude_web_usage_api"

  public static let defaultOrigin = "https://claude.ai"

  private let http: ProviderWebHTTP
  private let origin: String
  private let now: Date

  public init(
    transport: any ProviderWebTransport,
    clientVersion: String,
    now: Date = Date(),
    origin: String = ClaudeWebCollector.defaultOrigin
  ) {
    http = ProviderWebHTTP(transport: transport, userAgent: "Quota/\(clientVersion)")
    self.origin = origin
    self.now = now
  }

  public func validate(cookieHeader: String) async throws -> ValidatedBrowserSession {
    let account = try await webAccount(
      cookieHeader: cookieHeader, timeout: ProviderWebLimits.validationTimeout)
    let usage = try await fetchUsage(
      cookieHeader: cookieHeader, organizationID: account.organizationID,
      timeout: ProviderWebLimits.validationTimeout)
    // An account that answers for a window this build knows, even to say it has none, has been
    // read — the same rule the OAuth rung applies, because refusing it told a reader whose
    // account simply has no windows that their session was broken.
    if ClaudeUsage.map(usage).isEmpty && !ClaudeUsage.answersForAKnownWindow(usage) {
      throw ProviderWebError(.error, Self.source)
    }
    let identity = ProviderWebIdentity.accountIdentity(
      provider: "claude", namespace: "organization_id", owner: account.organizationID)
    return ValidatedBrowserSession(
      accountFingerprint: identity.fingerprint,
      accountLabel: ProviderWebIdentity.maskEmail(account.email)
    )
  }

  public func collect(cookieHeader: String) async throws -> QuotaSnapshot {
    let account = try await webAccount(
      cookieHeader: cookieHeader, timeout: ProviderWebLimits.requestTimeout)
    let usage = try await fetchUsage(
      cookieHeader: cookieHeader, organizationID: account.organizationID,
      timeout: ProviderWebLimits.requestTimeout)
    let windows = ClaudeUsage.map(usage)
    if windows.isEmpty && !ClaudeUsage.answersForAKnownWindow(usage) {
      throw ProviderWebError(.unavailable, Self.source)
    }
    let identity = ProviderWebIdentity.accountIdentity(
      provider: "claude", namespace: "organization_id", owner: account.organizationID)
    return QuotaSnapshot(
      provider: .claude,
      account: QuotaAccount(
        fingerprint: identity.fingerprint,
        label: ProviderWebIdentity.maskEmail(account.email),
        plan: account.plan,
        fingerprintScope: identity.scope
      ),
      windows: windows,
      status: .available,
      observedAt: now
    )
  }

  /// The organization a reading belongs to, and the identity claude.ai shows beside it.
  struct WebAccount {
    let organizationID: String
    let email: String?
    let plan: String?
  }

  /// The one lookup both the validation and the reading make. `/api/account` is best-effort — it
  /// enriches the label and the plan, and a session that cannot reach it can still be read.
  private func webAccount(cookieHeader: String, timeout: TimeInterval) async throws -> WebAccount {
    guard Self.sessionKey(cookieHeader) != nil else {
      throw ProviderWebError(.error, Self.source)
    }
    let headers = Self.headers(cookieHeader)
    let organizations = try await http.getJSONSession(
      try url("/api/organizations"), headers: headers, timeout: timeout, source: Self.source)
    let account = try? await http.getJSONSession(
      try url("/api/account"), headers: headers, timeout: timeout, source: Self.source)
    let preferred =
      Self.lastActiveOrganization(cookieHeader)
      ?? account.flatMap(Self.accountOrganization)
    guard
      let organizationID = Self.selectOrganizationID(organizations, preferred: preferred)
    else { throw ProviderWebError(.error, Self.source) }
    return WebAccount(
      organizationID: organizationID,
      email: account.flatMap(Self.accountEmail),
      plan: account.flatMap(Self.accountPlan)
    )
  }

  private func fetchUsage(
    cookieHeader: String,
    organizationID: String,
    timeout: TimeInterval
  ) async throws -> JSONValue {
    guard Self.sessionKey(cookieHeader) != nil else {
      throw ProviderWebError(.error, Self.source)
    }
    return try await http.getJSONSession(
      try url("/api/organizations/\(organizationID)/usage"),
      headers: Self.headers(cookieHeader), timeout: timeout, source: Self.source)
  }

  private func url(_ path: String) throws -> URL {
    guard let url = URL(string: origin + path) else {
      throw ProviderWebError(.error, Self.source)
    }
    return url
  }

  static func headers(_ cookieHeader: String) -> [(String, String)] {
    [
      ("Accept", "application/json"),
      ("Cookie", cookieHeader),
      ("Origin", defaultOrigin),
      ("Referer", "https://claude.ai/"),
    ]
  }

  /// `sessionKey` is the whole sign-in, and Anthropic's carries a prefix of its own. A header
  /// that has only the org hint beside it names no session at all.
  static func sessionKey(_ header: String) -> String? {
    guard let value = ProviderWebIdentity.cookieNamedValue(header, "sessionKey")?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    else { return nil }
    guard value.hasPrefix("sk-ant-"), value.count <= 512, !value.contains(where: \.isControl)
    else { return nil }
    return value
  }

  static func lastActiveOrganization(_ header: String) -> String? {
    guard let value = ProviderWebIdentity.cookieNamedValue(header, "lastActiveOrg")?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    else { return nil }
    guard !value.isEmpty, value.count <= 128, !value.contains(where: \.isControl) else {
      return nil
    }
    return value
  }

  static func selectOrganizationID(_ value: JSONValue, preferred: String?) -> String? {
    guard let entries = value.arrayValue ?? value.get("organizations")?.arrayValue else {
      return nil
    }
    if let preferred {
      for entry in entries {
        guard let id = organizationID(entry) else { continue }
        if id == preferred && !isAPIDisabled(entry) { return id }
      }
    }
    for entry in entries where allowsChat(entry) {
      if let id = organizationID(entry) { return id }
    }
    return nil
  }

  static func organizationID(_ value: JSONValue) -> String? {
    guard let id = ProviderJSON.string(value.get(any: ["uuid", "id"])) else { return nil }
    return !id.isEmpty && id.count <= 128 && !id.contains(where: \.isControl) ? id : nil
  }

  static func accountOrganization(_ value: JSONValue) -> String? {
    let id =
      value.get("organization").flatMap(organizationID)
      ?? ProviderJSON.string(
        value.get(any: ["organizationUuid", "organization_uuid", "organization_id"]))
    guard let id, !id.isEmpty, id.count <= 128, !id.contains(where: \.isControl) else {
      return nil
    }
    return id
  }

  static func isAPIDisabled(_ value: JSONValue) -> Bool {
    value.get("api_disabled")?.isTrue == true || value.get("apiDisabled")?.isTrue == true
  }

  static func allowsChat(_ value: JSONValue) -> Bool {
    if isAPIDisabled(value) { return false }
    guard let capabilities = value.get(any: ["capabilities", "capability"])?.arrayValue else {
      return false
    }
    return capabilities.contains { capability in
      capability.rawString == "chat" || capability.rawString == "claude_pro"
    }
  }

  static func accountEmail(_ value: JSONValue) -> String? {
    ProviderJSON.string(value.get(any: ["email", "email_address", "emailAddress"]))
      ?? value.get("account").flatMap {
        ProviderJSON.string($0.get(any: ["email", "email_address", "emailAddress"]))
      }
  }

  static func accountPlan(_ value: JSONValue) -> String? {
    ClaudeUsage.plan(
      subscriptionType: ProviderJSON.string(
        value.get(any: ["subscription_type", "subscriptionType", "plan"])),
      rateLimitTier: ProviderJSON.string(value.get(any: ["rate_limit_tier", "rateLimitTier"]))
    )
  }
}
