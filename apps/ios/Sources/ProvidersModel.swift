import Foundation
import QuotaPresentation
import QuotaProviderSessions
import QuotaWire

/// Every sentence Quota says about signing in to a provider inside the app.
///
/// Reading a provider's own session is the one thing this app does that a reader has to agree to,
/// so what is about to happen is written out before it happens: which cookies on which hosts,
/// where they stay, and that they never leave the phone. Hosts and names come from the catalog,
/// so the sheet cannot promise a narrower read than the one that happens — the same rule
/// QuotaBar's consent copy follows
/// ([ADR 0010](../../../docs/decisions/0010-provider-browser-session-auth.md)).
enum ProvidersCopy {
  static let section = "Providers"
  static let sectionFooter =
    """
    Sign-in cookies stay in this iPhone's Keychain. Quota never uploads them, and Remove \
    deletes them.
    """
  static let connect = "Connect"
  static let addAccount = "Add Account"
  static let remove = "Remove"
  static let cancel = "Cancel"
  static let consentConfirm = "Continue"
  static let unreadable = "Couldn't read the sign-ins saved on this iPhone."

  static func consentTitle(provider: ProviderID) -> String {
    "Sign in to \(provider.displayName)?"
  }

  static func consentMessage(provider: ProviderID, spec: BrowserSessionSpec) -> String {
    let cookies = spec.cookieNames.count == 1 ? "cookie" : "cookies"
    return """
      Quota opens \(provider.displayName)'s own sign-in page and keeps the sign-in \(cookies) — \
      \(list(spec.cookieNames)) — it leaves for \(list(spec.cookieHosts)). They stay in this \
      iPhone's Keychain, are never uploaded, and are deleted when you remove the account.
      """
  }

  static func connectedAs(label: String?) -> String {
    guard let label, !label.isEmpty else { return "Connected" }
    return "Connected as \(label)"
  }

  static func checked(at date: Date, now: Date) -> String {
    "Checked \(FreshnessCopy.age(since: date, now: now))"
  }

  static func removeTitle(provider: ProviderID) -> String {
    "Remove this \(provider.displayName) sign-in?"
  }

  static func removeMessage(provider: ProviderID) -> String {
    """
    Quota deletes the cookies from this iPhone's Keychain and stops reading \
    \(provider.displayName) on this device.
    """
  }

  static func loginTitle(provider: ProviderID) -> String {
    "Sign in to \(provider.displayName)"
  }

  static func loginStatus(_ status: ProviderLoginModel.Status, provider: ProviderID) -> String {
    switch status {
    case .signIn: "Sign in to \(provider.displayName) to connect this account."
    case .checking: "Checking this session…"
    case .notSignedIn: "Not signed in yet. Finish signing in on this page."
    case .unreachable: "Couldn't reach \(provider.displayName). Try again."
    case .unsupported: "\(provider.displayName) doesn't report quota for this account."
    case .notKept: "Couldn't save this sign-in on this iPhone."
    }
  }

  private static func list(_ values: [String]) -> String {
    switch values.count {
    case 0: ""
    case 1: values[0]
    case 2: "\(values[0]) and \(values[1])"
    default: "\(values.dropLast().joined(separator: ", ")), and \(values[values.count - 1])"
    }
  }
}

/// One row the Providers group renders.
struct ProviderConnectionRow: Equatable, Identifiable {
  enum Kind: Equatable {
    /// A provider account this phone holds a session for.
    case connected(StoredProviderSession)
    /// The row that opens the sign-in sheet. `isFirst` is a provider with nothing connected yet.
    case connect(isFirst: Bool)
  }

  var provider: ProviderID
  var kind: Kind

  var id: String {
    switch kind {
    case .connected(let session): session.key
    case .connect: "connect:\(provider.rawValue)"
    }
  }
}

/// The provider sessions this phone holds, as Settings lists them.
///
/// Consent is asked once per provider and remembered in `UserDefaults`, which holds the answer
/// and never the session: the sessions themselves are the Keychain store's.
@MainActor
@Observable
final class ProvidersModel {
  static let consentStorageKey = "providers.consented"

  private let store: any ProviderSessionStoring
  private let consentDefaults: UserDefaults

  private(set) var sessions: [StoredProviderSession] = []
  /// The Keychain refused the read. An empty list would say the opposite of what happened.
  private(set) var isUnreadable = false
  private(set) var consented: Set<String>

  init(
    store: any ProviderSessionStoring = KeychainProviderSessionStore(),
    consentDefaults: UserDefaults = .standard
  ) {
    self.store = store
    self.consentDefaults = consentDefaults
    consented = Set(consentDefaults.stringArray(forKey: Self.consentStorageKey) ?? [])
    load()
  }

  func load() {
    do {
      sessions = try store.list()
      isUnreadable = false
    } catch {
      sessions = []
      isUnreadable = true
    }
  }

  var rows: [ProviderConnectionRow] {
    ProviderWebLogin.supported.flatMap { provider -> [ProviderConnectionRow] in
      let connected = sessions.filter { $0.provider == provider }
      return connected.map { ProviderConnectionRow(provider: provider, kind: .connected($0)) }
        + [ProviderConnectionRow(provider: provider, kind: .connect(isFirst: connected.isEmpty))]
    }
  }

  func needsConsent(for provider: ProviderID) -> Bool {
    !consented.contains(provider.rawValue)
  }

  func recordConsent(for provider: ProviderID) {
    consented.insert(provider.rawValue)
    consentDefaults.set(consented.sorted(), forKey: Self.consentStorageKey)
  }

  func keep(_ session: StoredProviderSession) {
    sessions.removeAll { $0.key == session.key }
    sessions.append(session)
    sessions.sort { ($0.key, $0.storedAt) < ($1.key, $1.storedAt) }
  }

  func remove(_ session: StoredProviderSession) {
    try? store.remove(
      provider: session.provider, accountFingerprint: session.accountFingerprint)
    load()
  }

  /// The store the sign-in sheet writes the accepted session into.
  var sessionStore: any ProviderSessionStoring { store }
}
