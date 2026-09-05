import Foundation
import QuotaProviderSessions
import QuotaProviderWeb
import QuotaWire

/// The providers this app can sign in to, and the collector that proves each sign-in.
///
/// A provider is here only when `QuotaProviderWeb` can read it: the catalog declares a browser
/// session for Kimi and Cursor too, but nothing in this app could answer for one, and a Connect
/// row that cannot finish is worse than no row. See
/// [ADR 0034](../../../docs/decisions/0034-ios-collects-for-itself.md).
enum ProviderWebLogin {
  static let supported: [ProviderID] = [.codex, .claude, .grok]

  static func collector(
    for provider: ProviderID,
    transport: any ProviderWebTransport,
    clientVersion: String,
    now: Date
  ) -> (any ProviderWebCollector)? {
    switch provider {
    case .codex:
      CodexWebCollector(transport: transport, clientVersion: clientVersion, now: now)
    case .claude:
      ClaudeWebCollector(transport: transport, clientVersion: clientVersion, now: now)
    case .grok:
      GrokWebCollector(transport: transport, clientVersion: clientVersion, now: now)
    default:
      nil
    }
  }

  /// The version this app spends as its `User-Agent`, so a provider sees one client rather than
  /// an unnamed one.
  static func clientVersion(bundle: Bundle = .main) -> String {
    bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
  }
}

/// The cookies a signed-in web view is holding.
///
/// The sheet's own store answers this in production. It is a protocol because the sign-in rule —
/// which cookies are a session, when a session is proven, and what is then kept — is worth
/// testing without a web view.
@MainActor
protocol ProviderLoginCookieSource: Sendable {
  func cookies() async -> [BrowserCookie]
}

/// One sign-in inside the app: what the sheet says, and what it keeps.
///
/// Nothing is stored until the provider answers for the cookie. The web view is asked for its
/// cookies after each navigation because a sign-in finishes on a page this app does not choose,
/// and a header it has already tried is never spent twice.
@MainActor
@Observable
final class ProviderLoginModel {
  enum Status: Equatable {
    case signIn
    case checking
    case notSignedIn
    case unreachable
    case unsupported
    /// The provider answered for the session and this device could not keep it.
    case notKept
  }

  let provider: ProviderID
  private(set) var status: Status = .signIn
  private(set) var connected: StoredProviderSession?

  private let store: any ProviderSessionStoring
  private let cookies: any ProviderLoginCookieSource
  private let transport: any ProviderWebTransport
  private let clientVersion: String
  private let now: () -> Date
  private var attemptedHeaders: Set<String> = []
  private var isChecking = false

  init(
    provider: ProviderID,
    store: any ProviderSessionStoring,
    cookies: any ProviderLoginCookieSource,
    transport: any ProviderWebTransport = URLSessionProviderWebTransport(),
    clientVersion: String = ProviderWebLogin.clientVersion(),
    now: @escaping () -> Date = Date.init
  ) {
    self.provider = provider
    self.store = store
    self.cookies = cookies
    self.transport = transport
    self.clientVersion = clientVersion
    self.now = now
  }

  var loginURL: URL? {
    provider.browserSession.flatMap { URL(string: $0.loginURL) }
  }

  var statusMessage: String {
    ProvidersCopy.loginStatus(status, provider: provider)
  }

  /// One pass over the web view's cookies after a page finished loading.
  ///
  /// A page that is not the sign-in leaves nothing new to try, so the status stays where it was:
  /// the reader is told they are not signed in yet only once a cookie has actually been refused.
  func pageDidLoad() async {
    guard !isChecking, connected == nil else { return }
    guard let spec = provider.browserSession else { return }
    let moment = now()
    let candidates = spec
      .assembleCookieHeaders(cookies: await cookies.cookies(), now: moment)
      .filter { !attemptedHeaders.contains($0) }
    guard !candidates.isEmpty else { return }
    guard
      let collector = ProviderWebLogin.collector(
        for: provider, transport: transport, clientVersion: clientVersion, now: moment)
    else { return }

    isChecking = true
    status = .checking
    defer { isChecking = false }
    var outcome: Status = .notSignedIn
    for header in candidates {
      attemptedHeaders.insert(header)
      do {
        let validated = try await collector.validate(cookieHeader: header)
        let session = StoredProviderSession(
          provider: provider,
          accountFingerprint: validated.accountFingerprint,
          cookieHeader: header,
          accountLabel: validated.accountLabel,
          storedAt: now(),
          lastValidatedAt: now()
        )
        try store.upsert(session)
        connected = session
        return
      } catch let error as ProviderWebError {
        outcome = Self.status(for: error.category)
      } catch {
        // Storing is the only other failure here, and a session this device cannot keep is a
        // session it does not have — but it is not the provider's fault and does not read as one.
        outcome = .notKept
      }
    }
    status = outcome
  }

  private static func status(for category: ProviderWebErrorCategory) -> Status {
    switch category {
    case .authRequired, .error: .notSignedIn
    case .unavailable: .unreachable
    case .unsupported: .unsupported
    }
  }
}
