import Foundation
import QuotaProviderSessions
import QuotaProviderWeb
import QuotaWire
import Testing

@testable import Quota

/// What the sign-in sheet does with what a web view holds: assemble the session, ask the
/// provider, and keep only what the provider answered for.
@MainActor
struct ProviderLoginTests {
  static let now = Date(timeIntervalSince1970: 1_786_723_200)

  static func model(
    provider: ProviderID = .codex,
    store: any ProviderSessionStoring,
    cookies: [BrowserCookie],
    responses: [ProviderWebResponse]
  ) -> (ProviderLoginModel, StubProviderWebTransport) {
    let transport = StubProviderWebTransport(responses: responses)
    let model = ProviderLoginModel(
      provider: provider,
      store: store,
      cookies: StubCookieSource(cookies: cookies),
      transport: transport,
      clientVersion: "0.0.2",
      now: { now }
    )
    return (model, transport)
  }

  static func cookie(_ name: String, _ value: String) -> BrowserCookie {
    BrowserCookie(name: name, value: value, domain: "chatgpt.com", expiresAt: nil)
  }

  static func json(_ object: [String: Any], status: Int = 200) -> ProviderWebResponse {
    ProviderWebResponse(
      status: status, body: try! JSONSerialization.data(withJSONObject: object))
  }

  static let signedInSession = json([
    "user": ["email": "ada@example.com"],
    "account": ["id": "acct_1", "planType": "plus"],
  ])

  @Test
  func aProvenSessionIsStoredAndTheSheetReportsTheAccount() async throws {
    let store = MemoryProviderSessionStore()
    let (model, transport) = Self.model(
      store: store,
      cookies: [
        Self.cookie("__Secure-next-auth.session-token", "abc"),
        Self.cookie("_account", "acct_1"),
      ],
      responses: [Self.signedInSession]
    )

    await model.pageDidLoad()

    let session = try #require(model.connected)
    #expect(session.provider == .codex)
    #expect(session.accountLabel == "ad***@example.com")
    #expect(session.cookieHeader == "__Secure-next-auth.session-token=abc; _account=acct_1")
    #expect(session.storedAt == Self.now)
    #expect(session.lastValidatedAt == Self.now)
    #expect(try store.list().map(\.key) == [session.key])
    // The cookie travels as a cookie, and nowhere else.
    let sent = try #require(transport.requests.first)
    #expect(sent.value(forHTTPHeaderField: "Cookie") == session.cookieHeader)
    #expect(sent.url?.absoluteString == "https://chatgpt.com/api/auth/session")
  }

  @Test
  func aPageWithNoSessionCookieIsNotAnAttempt() async throws {
    let store = MemoryProviderSessionStore()
    let (model, transport) = Self.model(
      store: store,
      cookies: [Self.cookie("oai-did", "device")],
      responses: [Self.signedInSession]
    )

    await model.pageDidLoad()

    #expect(model.connected == nil)
    #expect(model.status == .signIn)
    #expect(transport.requests.isEmpty)
    #expect(try store.list().isEmpty)
  }

  @Test
  func aRefusedCookieIsNotStoredAndSaysSoOnce() async throws {
    let store = MemoryProviderSessionStore()
    let (model, transport) = Self.model(
      store: store,
      cookies: [Self.cookie("__Secure-next-auth.session-token", "abc")],
      responses: [ProviderWebResponse(status: 401, body: Data())]
    )

    await model.pageDidLoad()
    #expect(model.status == .notSignedIn)
    #expect(model.connected == nil)
    #expect(try store.list().isEmpty)

    // The same header is not spent twice: the next page load has nothing new to try.
    await model.pageDidLoad()
    #expect(transport.requests.count == 1)
  }

  @Test
  func aProviderThatCannotBeReachedIsNotASignedOutReader() async throws {
    let (model, _) = Self.model(
      store: MemoryProviderSessionStore(),
      cookies: [Self.cookie("__Secure-next-auth.session-token", "abc")],
      responses: [ProviderWebResponse(status: 503, body: Data())]
    )

    await model.pageDidLoad()

    #expect(model.status == .unreachable)
    #expect(model.statusMessage == "Couldn't reach Codex. Try again.")
  }

  /// The provider answered, and this device could not keep what it answered for. That is not the
  /// provider's fault and does not read as one.
  @Test
  func aSessionThisPhoneCannotKeepIsNotConnected() async {
    let (model, _) = Self.model(
      store: RefusingProviderSessionStore(),
      cookies: [Self.cookie("__Secure-next-auth.session-token", "abc")],
      responses: [Self.signedInSession]
    )

    await model.pageDidLoad()

    #expect(model.status == .notKept)
    #expect(model.connected == nil)
    #expect(model.statusMessage == "Couldn't save this sign-in on this iPhone.")
  }

  @Test
  func signingInAgainAsTheSameAccountReplacesTheStoredSession() async throws {
    let store = MemoryProviderSessionStore()
    let (first, _) = Self.model(
      store: store,
      cookies: [Self.cookie("__Secure-next-auth.session-token", "abc")],
      responses: [Self.signedInSession]
    )
    await first.pageDidLoad()
    let (second, _) = Self.model(
      store: store,
      cookies: [Self.cookie("__Secure-next-auth.session-token", "def")],
      responses: [Self.signedInSession]
    )
    await second.pageDidLoad()

    let sessions = try store.list()
    #expect(sessions.count == 1)
    #expect(sessions[0].cookieHeader == "__Secure-next-auth.session-token=def")
  }

  @Test
  func theSheetOpensTheCatalogsLoginPage() {
    let (model, _) = Self.model(
      store: MemoryProviderSessionStore(), cookies: [], responses: [])
    #expect(model.loginURL == URL(string: "https://chatgpt.com/"))
    #expect(ProviderWebLogin.supported == [.codex, .claude, .grok])
    // Every supported provider has a page to open and a collector to answer for it.
    for provider in ProviderWebLogin.supported {
      #expect(provider.browserSession != nil)
      #expect(
        ProviderWebLogin.collector(
          for: provider,
          transport: StubProviderWebTransport(responses: []),
          clientVersion: "0.0.2",
          now: Self.now
        ) != nil)
    }
  }
}

@MainActor
struct ProvidersModelTests {
  static let now = Date(timeIntervalSince1970: 1_786_723_200)

  static func session(
    _ provider: ProviderID,
    _ fingerprint: String,
    label: String? = "ad***@example.com"
  ) -> StoredProviderSession {
    StoredProviderSession(
      provider: provider,
      accountFingerprint: fingerprint,
      cookieHeader: "session=\(fingerprint)",
      accountLabel: label,
      storedAt: now,
      lastValidatedAt: now
    )
  }

  static func defaults() -> UserDefaults {
    let defaults = UserDefaults(suiteName: "providers.\(UUID().uuidString)")!
    defaults.removePersistentDomain(forName: defaults.description)
    return defaults
  }

  /// Not connected, connected once, and connected twice are three rows' worth of difference.
  @Test
  func rowsListEveryAccountAndThenTheWayToAddOne() {
    let model = ProvidersModel(
      store: MemoryProviderSessionStore(sessions: [
        Self.session(.codex, "work"),
        Self.session(.codex, "personal"),
        Self.session(.claude, "team"),
      ]),
      consentDefaults: Self.defaults()
    )

    #expect(
      model.rows.map(\.id) == [
        "codex:personal", "codex:work", "connect:codex",
        "claude:team", "connect:claude",
        "connect:grok",
      ])
    #expect(model.rows.first { $0.id == "connect:grok" }?.kind == .connect(isFirst: true))
    #expect(model.rows.first { $0.id == "connect:codex" }?.kind == .connect(isFirst: false))
    #expect(!model.isUnreadable)
  }

  @Test
  func consentIsAskedOncePerProviderAndRemembered() {
    let defaults = Self.defaults()
    let model = ProvidersModel(store: MemoryProviderSessionStore(), consentDefaults: defaults)

    #expect(model.needsConsent(for: .codex))
    model.recordConsent(for: .codex)
    #expect(!model.needsConsent(for: .codex))
    #expect(model.needsConsent(for: .claude))

    let reopened = ProvidersModel(
      store: MemoryProviderSessionStore(), consentDefaults: defaults)
    #expect(!reopened.needsConsent(for: .codex))
    #expect(reopened.needsConsent(for: .claude))
  }

  @Test
  func removingOneAccountLeavesTheOthers() throws {
    let store = MemoryProviderSessionStore(sessions: [
      Self.session(.codex, "work"), Self.session(.claude, "team"),
    ])
    let model = ProvidersModel(store: store, consentDefaults: Self.defaults())

    model.remove(Self.session(.codex, "work"))

    #expect(model.sessions.map(\.provider) == [.claude])
    #expect(try store.list().map(\.provider) == [.claude])
  }

  /// A Keychain that refuses the read is not a phone with no sessions.
  @Test
  func aRefusedReadSaysSoRatherThanShowingNothingConnected() {
    let model = ProvidersModel(
      store: RefusingProviderSessionStore(), consentDefaults: Self.defaults())
    #expect(model.isUnreadable)
    #expect(model.sessions.isEmpty)
  }

  @Test
  func theConsentSheetNamesTheCookiesTheCatalogDeclares() throws {
    let spec = try #require(ProviderID.claude.browserSession)
    let message = ProvidersCopy.consentMessage(provider: .claude, spec: spec)
    #expect(message.contains("sessionKey"))
    #expect(message.contains("lastActiveOrg"))
    #expect(message.contains("claude.ai"))
    #expect(message.contains("Keychain"))
    #expect(message.contains("never uploaded"))
    #expect(ProvidersCopy.connectedAs(label: nil) == "Connected")
    #expect(
      ProvidersCopy.connectedAs(label: "ad***@example.com") == "Connected as ad***@example.com")
    #expect(
      ProvidersCopy.checked(at: Self.now.addingTimeInterval(-3_600), now: Self.now)
        == "Checked 1h ago")
  }
}

@MainActor
final class StubCookieSource: ProviderLoginCookieSource {
  private let stored: [BrowserCookie]

  init(cookies: [BrowserCookie]) {
    stored = cookies
  }

  func cookies() async -> [BrowserCookie] { stored }
}

final class StubProviderWebTransport: ProviderWebTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var queued: [ProviderWebResponse]
  private(set) var requests: [URLRequest] = []

  init(responses: [ProviderWebResponse]) {
    queued = responses
  }

  func send(_ request: URLRequest) async throws -> ProviderWebResponse {
    try lock.withLock {
      requests.append(request)
      guard !queued.isEmpty else { throw URLError(.badServerResponse) }
      return queued.removeFirst()
    }
  }
}

/// A Keychain that answers neither read nor write.
struct RefusingProviderSessionStore: ProviderSessionStoring {
  func list() throws -> [StoredProviderSession] { throw ProviderSessionStoreError.unreadable }
  func upsert(_ session: StoredProviderSession) throws {
    throw ProviderSessionStoreError.unwritable
  }
  func remove(provider: ProviderID, accountFingerprint: String) throws {}
}
