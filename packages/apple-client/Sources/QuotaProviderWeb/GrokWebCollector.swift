import Foundation
import QuotaWire

/// Grok's last rung: grok.com's own gRPC-web billing RPC, reached with the browser's cookie.
///
/// Mirrors the cookie half of `packages/service/src/providers/grok/billing_rpc.rs`. The RPC names
/// nobody, so a clean answer is the whole proof of a session, and the sign-in cookie is what
/// tells two signed-in accounts apart.
public struct GrokWebCollector: ProviderWebCollector {
  public static let provider: ProviderID = .grok
  public static let source = "grok_web_billing_api"

  public static let defaultURL =
    "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig"
  /// What a stored Grok session is called, since the RPC names nobody.
  static let accountLabel = "Grok"
  static let emptyFrame = Data([0x00, 0x00, 0x00, 0x00, 0x00])

  private let http: ProviderWebHTTP
  private let endpoint: String
  private let now: Date

  public init(
    transport: any ProviderWebTransport,
    clientVersion: String,
    now: Date = Date(),
    endpoint: String = GrokWebCollector.defaultURL
  ) {
    http = ProviderWebHTTP(transport: transport, userAgent: "Quota/\(clientVersion)")
    self.endpoint = endpoint
    self.now = now
  }

  public func validate(cookieHeader: String) async throws -> ValidatedBrowserSession {
    guard Self.ssoToken(cookieHeader) != nil else {
      throw ProviderWebError(.error, Self.source)
    }
    _ = try await billing(
      cookieHeader: cookieHeader, timeout: ProviderWebLimits.validationTimeout)
    return ValidatedBrowserSession(
      accountFingerprint: Self.accountIdentity(cookieHeader).fingerprint,
      accountLabel: Self.accountLabel
    )
  }

  public func collect(cookieHeader: String) async throws -> QuotaSnapshot {
    guard Self.ssoToken(cookieHeader) != nil else {
      throw ProviderWebError(.error, Self.source)
    }
    let billing = try await billing(
      cookieHeader: cookieHeader, timeout: ProviderWebLimits.requestTimeout)
    let identity = Self.accountIdentity(cookieHeader)
    return QuotaSnapshot(
      provider: .grok,
      account: QuotaAccount(
        fingerprint: identity.fingerprint,
        label: Self.accountLabel,
        plan: nil,
        fingerprintScope: identity.scope
      ),
      windows: [Self.billingWindow(billing, now: Int(now.timeIntervalSince1970))],
      status: .available,
      observedAt: now
    )
  }

  /// Whose grok.com account a stored session speaks for. A cookie that names no one keeps the
  /// source-wide fingerprint, which says exactly that.
  static func accountIdentity(
    _ cookieHeader: String
  ) -> (fingerprint: String, scope: FingerprintScope) {
    let owner = ssoToken(cookieHeader).flatMap(ProviderWebIdentity.jwtSubject)
    return ProviderWebIdentity.accountIdentity(
      provider: "grok", namespace: "user_id", owner: owner)
  }

  /// The one cookie that is a whole grok.com sign-in. `sso-rw` is the same session's read-write
  /// half, so either alone names it.
  static func ssoToken(_ header: String) -> String? {
    let value =
      (ProviderWebIdentity.cookieNamedValue(header, "sso")
        ?? ProviderWebIdentity.cookieNamedValue(header, "sso-rw"))?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let value, !value.isEmpty, value.count <= 8_192, !value.contains(where: \.isControl)
    else { return nil }
    return value
  }

  private func billing(cookieHeader: String, timeout: TimeInterval) async throws -> Billing {
    guard let url = URL(string: endpoint) else { throw ProviderWebError(.error, Self.source) }
    let headers = [
      ("Cookie", cookieHeader),
      ("Origin", "https://grok.com"),
      ("Referer", "https://grok.com/?_s=usage"),
      ("Accept", "*/*"),
      ("Content-Type", "application/grpc-web+proto"),
      ("x-grpc-web", "1"),
      ("x-user-agent", "connect-es/2.1.1"),
    ]
    let body = try await http.postBytes(
      url, headers: headers, body: Self.emptyFrame, timeout: timeout, source: Self.source)
    return try Self.parse(body, now: Int(now.timeIntervalSince1970))
  }

  struct Billing: Equatable {
    let usedPercent: Double
    let resetsAt: Int?
  }

  /// The RPC exposes only the reset instant, not the cadence. A reset 20–45 days out reads as
  /// monthly; anything nearer is the weekly credit pool, and no reset at all stays generic.
  ///
  /// That heuristic names the window for a person to read. It does not name the headline meter:
  /// only a reset that actually lands inside a cadence earns one.
  static func billingWindow(_ billing: Billing, now: Int) -> QuotaWindow {
    let delta = billing.resetsAt.map { $0 - now }
    let title: String
    let cadence: Cadence?
    switch delta {
    case .some(let seconds) where (20 * 86_400...45 * 86_400).contains(seconds):
      (title, cadence) = (Cadence.monthly.title, .monthly)
    case .some(let seconds) where seconds <= 10 * 86_400:
      (title, cadence) = (Cadence.weekly.title, .weekly)
    // Still titled by the guess, deliberately unnamed: a title is a word, a cadence is a claim.
    case .some:
      (title, cadence) = (Cadence.weekly.title, nil)
    case .none:
      (title, cadence) = ("Billing Cycle", nil)
    }
    return QuotaWindow.make(
      id: "billing_cycle",
      title: title,
      usedPercent: billing.usedPercent,
      resetsAt: billing.resetsAt,
      primaryCadence: cadence?.primaryCadence
    )
  }

  static func parse(_ data: Data, now: Int) throws -> Billing {
    let bytes = [UInt8](data)
    let trailers = trailerFields(bytes)
    if let raw = trailers["grpc-status"], let status = Int(raw), status != 0 {
      throw statusError(status, message: trailers["grpc-message"] ?? "")
    }
    var payloads = dataFrames(bytes)
    if payloads.isEmpty && looksLikeProtobuf(bytes) { payloads.append(bytes) }
    if payloads.isEmpty { throw ProviderWebError(.error, source) }
    var scan = ProtobufScan()
    for payload in payloads { scan.merge(scanProtobuf(payload, depth: 0, path: [])) }
    let parsedPercent =
      scan.fixed32
      .filter { $0.path.last == 1 && $0.value.isFinite && (0...100).contains($0.value) }
      .min {
        ($0.path.count, $0.order) < ($1.path.count, $1.order)
      }
      .map { Double($0.value) }
    let resetFields = scan.varints.compactMap { field -> ([UInt64], Int)? in
      guard (1_700_000_000...2_100_000_000).contains(field.value) else { return nil }
      return (field.path, Int(field.value))
    }
    // The reset the response types as the period end wins; any other future instant is the
    // fallback, and a past one is not a reset at all.
    let future = resetFields.filter { $0.1 > now }
    let reset = (future.first { $0.0 == [1, 5, 1] } ?? future.first)?.1
    let hasUsagePeriod = scan.varints.contains { field in
      field.path.starts(with: [1, 6]) || (field.path == [1, 8, 1] && (1...2).contains(field.value))
    }
    let percent: Double
    if let parsedPercent {
      percent = parsedPercent
    } else if reset != nil && hasUsagePeriod && scan.fixed32.isEmpty {
      percent = 0
    } else {
      throw ProviderWebError(.error, source)
    }
    return Billing(usedPercent: percent, resetsAt: reset)
  }

  static func statusError(_ status: Int, message: String) -> ProviderWebError {
    let lower = message.lowercased()
    if status == 16
      || (status == 7
        && (lower.contains("unauthenticated") || lower.contains("bad-credentials")
          || lower.contains("no-credentials") || lower.contains("no credentials")))
    {
      return ProviderWebError(.authRequired, source)
    }
    if status == 9 && lower.contains("no personal team") {
      return ProviderWebError(.unsupported, source)
    }
    if status == 4 || status == 14 { return ProviderWebError(.unavailable, source) }
    return ProviderWebError(.error, source)
  }
}
