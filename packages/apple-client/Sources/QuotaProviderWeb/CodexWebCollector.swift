import Foundation
import QuotaWire

/// Codex's last rung: the ChatGPT web session, read on the device the reader signed in on.
///
/// The request sequence, the identity it keeps, and every classification are the Rust
/// collector's (`packages/service/src/providers/codex/web.rs`). The account it names is the one
/// the OAuth rung reports, so a reading made here does not rename the account.
public struct CodexWebCollector: ProviderWebCollector {
  public static let provider: ProviderID = .codex
  public static let source = "chatgpt_web_usage_api"

  public static let defaultOrigin = "https://chatgpt.com"
  static let sessionPath = "/api/auth/session"
  static let mePath = "/backend-api/me"
  static let usagePath = "/backend-api/wham/usage"

  private let http: ProviderWebHTTP
  private let origin: String
  private let now: Date

  public init(
    transport: any ProviderWebTransport,
    clientVersion: String,
    now: Date = Date(),
    origin: String = CodexWebCollector.defaultOrigin
  ) {
    http = ProviderWebHTTP(transport: transport, userAgent: "Quota/\(clientVersion)")
    self.origin = origin
    self.now = now
  }

  public func validate(cookieHeader: String) async throws -> ValidatedBrowserSession {
    guard Self.hasChatGPTSessionCookie(cookieHeader) else {
      throw ProviderWebError(.error, Self.source)
    }
    let session = try await webSession(
      cookieHeader: cookieHeader, timeout: ProviderWebLimits.validationTimeout)
    guard session.isIdentified else { throw ProviderWebError(.error, Self.source) }
    let identity = ProviderWebIdentity.accountIdentity(
      provider: "codex", namespace: "account_id", owner: session.accountID)
    return ValidatedBrowserSession(
      accountFingerprint: identity.fingerprint,
      accountLabel: ProviderWebIdentity.maskEmail(session.email)
    )
  }

  public func collect(cookieHeader: String) async throws -> QuotaSnapshot {
    let session = try await webSession(
      cookieHeader: cookieHeader, timeout: ProviderWebLimits.requestTimeout)
    // The session document often carries a bearer the usage endpoint accepts. Spending it is the
    // same request the OAuth rung makes, so it reports the same windows.
    if let accessToken = session.accessToken {
      do {
        return try await collectWithBearer(accessToken: accessToken, session: session)
      } catch let error as ProviderWebError where error.category != .authRequired {
        throw error
      } catch is ProviderWebError {
        // A bearer the endpoint refuses falls through to the cookie, which is a second
        // credential rather than a second attempt with the same one.
      }
    }
    return try await collectWebUsage(cookieHeader: cookieHeader, session: session)
  }

  private func collectWithBearer(
    accessToken: String,
    session: WebSession
  ) async throws -> QuotaSnapshot {
    var headers = [("Authorization", "Bearer \(accessToken)"), ("Accept", "application/json")]
    if let accountID = session.accountID {
      headers.append(("ChatGPT-Account-Id", accountID))
    }
    let value = try await http.getJSON(
      try url(Self.usagePath), headers: headers,
      timeout: ProviderWebLimits.requestTimeout, source: Self.source)
    let mapped = CodexUsage.map(value)
    if mapped.malformedSuccess { throw ProviderWebError(.error, Self.source) }
    guard !mapped.windows.isEmpty else { throw ProviderWebError(.unavailable, Self.source) }
    return snapshot(mapped: mapped, session: session)
  }

  private func collectWebUsage(
    cookieHeader: String,
    session: WebSession
  ) async throws -> QuotaSnapshot {
    var headers = [
      ("Cookie", cookieHeader),
      ("Accept", "application/json"),
    ]
    if let accountID = session.accountID {
      headers.append(("ChatGPT-Account-Id", accountID))
    }
    let value = try await http.getJSONSession(
      try url(Self.usagePath), headers: headers,
      timeout: ProviderWebLimits.requestTimeout, source: Self.source)
    let mapped = CodexUsage.map(value)
    if mapped.malformedSuccess { throw ProviderWebError(.error, Self.source) }
    guard !mapped.windows.isEmpty else { throw ProviderWebError(.unavailable, Self.source) }
    return snapshot(mapped: mapped, session: session)
  }

  private func snapshot(mapped: CodexUsage.Mapped, session: WebSession) -> QuotaSnapshot {
    let accountID = mapped.accountID ?? session.accountID
    let identity = ProviderWebIdentity.accountIdentity(
      provider: "codex", namespace: "account_id", owner: accountID)
    return QuotaSnapshot(
      provider: .codex,
      account: QuotaAccount(
        fingerprint: identity.fingerprint,
        label: ProviderWebIdentity.maskEmail(mapped.email ?? session.email),
        plan: mapped.plan ?? session.plan,
        fingerprintScope: identity.scope
      ),
      windows: mapped.windows,
      status: .available,
      observedAt: now
    )
  }

  /// Which account this cookie signs in as, from the session document or, when that names
  /// nobody, from the account document beside it.
  private func webSession(cookieHeader: String, timeout: TimeInterval) async throws -> WebSession {
    guard Self.hasChatGPTSessionCookie(cookieHeader) else {
      throw ProviderWebError(.error, Self.source)
    }
    let headers = [("Cookie", cookieHeader), ("Accept", "application/json")]
    do {
      let value = try await http.getJSONSession(
        try url(Self.sessionPath), headers: headers, timeout: timeout, source: Self.source)
      let session = WebSession(value)
      if session.isIdentified { return session }
    } catch let error as ProviderWebError
      where error.category == .unavailable || error.category == .authRequired
    {
      throw error
    }
    let value = try await http.getJSONSession(
      try url(Self.mePath), headers: headers, timeout: timeout, source: Self.source)
    let session = WebSession(value)
    if session.isIdentified { return session }
    throw ProviderWebError(.authRequired, Self.source)
  }

  private func url(_ path: String) throws -> URL {
    guard let url = URL(string: origin + path) else {
      throw ProviderWebError(.error, Self.source)
    }
    return url
  }

  /// Whether the stored header carries a whole ChatGPT sign-in rather than only the context
  /// cookies that travel beside one. The names come from the catalog, never from a second list.
  static func hasChatGPTSessionCookie(_ header: String) -> Bool {
    guard let spec = ProviderID.codex.browserSession else { return false }
    return spec.cookieNames.contains { name in
      isSessionCookieName(name) && ProviderWebIdentity.cookieNamedValue(header, name) != nil
    }
  }

  static func isSessionCookieName(_ name: String) -> Bool {
    name.contains("session-token") || name.contains("authjs") || name.contains("next-auth")
  }

  struct WebSession {
    var email: String?
    var plan: String?
    var accountID: String?
    var accessToken: String?

    /// Whether the document names an account at all. A signed-out jar gets an empty one.
    var isIdentified: Bool { email != nil || accountID != nil || accessToken != nil }

    init(_ value: JSONValue) {
      let user = value.get("user") ?? value
      let account = value.get("account") ?? user.get("account")
      email =
        ProviderJSON.string(user.get(any: ["email", "email_address", "emailAddress"]))
        ?? ProviderJSON.string(value.get(any: ["email", "email_address", "emailAddress"]))
      plan =
        account.flatMap {
          ProviderJSON.string($0.get(any: ["planType", "plan_type", "plan"]))
        } ?? ProviderJSON.string(value.get(any: ["planType", "plan_type", "plan"]))
      accountID =
        account.flatMap {
          ProviderJSON.string($0.get(any: ["id", "account_id", "accountId"]))
        }
        ?? ProviderJSON.string(
          value.get(any: ["account_id", "accountId", "chatgpt_account_id"]))
      accessToken = ProviderJSON.string(value.get(any: ["accessToken", "access_token"]))
    }
  }
}
