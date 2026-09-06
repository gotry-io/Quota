import AppKit
import CryptoKit
import Foundation
import QuotaWire
import SweetCookieKit

struct BrowserSessionCookieCandidate: Equatable, Sendable {
  let cookieHeader: String
  let headerFingerprint: String
  let browserName: String
  let profileName: String
}

/// Why macOS handed this app nothing when it opened a browser's cookie store.
///
/// Each of these is a different thing for the reader to do, and none of them is fixed by
/// waiting. The reason travels as a case, never as the underlying error's text: that text
/// names the store's path, which must not reach the panel, a log, or the service.
enum BrowserAccessDenialReason: String, Equatable, Sendable {
  /// Safari keeps its cookies where only an app with Full Disk Access may look.
  case fullDiskAccess = "full_disk_access"
  /// A Chrome-family store is sealed with a Keychain item macOS would not release.
  case keychainRefused = "keychain_refused"
  /// The store is there, and could not be opened or parsed.
  case storeUnreadable = "store_unreadable"
}

/// What one pass over a browser's cookie stores produced.
///
/// "This browser is not signed in" and "this Mac was refused the file" both end with no
/// candidate, and only the second is something the reader can act on. Collapsing them is how a
/// missing Full Disk Access grant spends two minutes reading as "no session found".
enum BrowserSessionReadOutcome: Equatable, Sendable {
  /// The stores opened and held no cookie the catalog names.
  case noSession
  case accessDenied(BrowserAccessDenial)
  case found([BrowserSessionCookieCandidate])
}

/// One refused read, in the two facts a reader and the Diagnostics page both need.
struct BrowserAccessDenial: Equatable, Sendable {
  let browserName: String
  let reason: BrowserAccessDenialReason

  var message: String {
    BrowserSessionCopy.accessDeniedMessage(browserName: browserName, reason: reason)
  }
}

protocol BrowserSessionImporting: Sendable {
  func read(
    spec: BrowserSessionSpec,
    browser: Browser,
    now: Date,
    deadline: Date
  ) async -> BrowserSessionReadOutcome
}

struct BrowserSessionImporter: BrowserSessionImporting, Sendable {
  private static let maximumStores = 64
  private static let maximumCandidates = 32

  func read(
    spec: BrowserSessionSpec,
    browser: Browser,
    now: Date,
    deadline: Date
  ) async -> BrowserSessionReadOutcome {
    let task = Task<BrowserSessionReadOutcome, Never>.detached(priority: .utility) {
      guard !Task.isCancelled, Date() < deadline else { return .noSession }
      let client = BrowserCookieClient()
      let stores = Array(client.stores(for: browser).prefix(Self.maximumStores))
      let query = BrowserCookieQuery(
        domains: spec.cookieHosts,
        domainMatch: .exact,
        includeExpired: false,
        referenceDate: now
      )
      var seen = Set<String>()
      var candidates: [BrowserSessionCookieCandidate] = []
      var denial: BrowserAccessDenialReason?
      for store in stores {
        guard !Task.isCancelled, Date() < deadline else { return .noSession }
        let records: [BrowserCookieRecord]
        do {
          records = try client.records(matching: query, in: store, logger: nil)
        } catch {
          // Only the case and the browser survive: the error's own text names the store's path.
          denial = denial ?? Self.denialReason(for: error, browser: browser)
          continue
        }
        let grouped = Self.candidates(
          records: records,
          spec: spec,
          browserName: browser.displayName,
          profileName: store.profile.name,
          now: now
        )
        for candidate in grouped {
          guard candidates.count < Self.maximumCandidates else { break }
          guard seen.insert(candidate.headerFingerprint).inserted else { continue }
          candidates.append(candidate)
        }
        if candidates.count == Self.maximumCandidates { break }
      }
      if !candidates.isEmpty { return .found(candidates) }
      // A profile this Mac may read and is simply not signed into answers the question; a
      // refusal only means the answer is still unknown.
      if let denial {
        return .accessDenied(
          BrowserAccessDenial(browserName: browser.displayName, reason: denial))
      }
      return .noSession
    }
    return await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
  }

  /// Which gatekeeper stands in front of this browser's cookie jar. Read once, here, from the
  /// browser itself: the consent sheet and the refusal copy are two sentences about the same
  /// fact, and neither may recover it by looking at a name on screen.
  static func family(of browser: Browser) -> BrowserSessionFamily {
    if browser == .safari { return .safari }
    return geckoBrowsers.contains(browser) ? .gecko : .chromium
  }

  /// A store that is simply not there is not a refusal: that browser has never been used.
  ///
  /// The two refusals macOS actually issues come from different gatekeepers. Safari's jar sits
  /// behind Full Disk Access; a Chrome-family jar is encrypted with a Keychain item the user
  /// has to release. Gecko has neither, so an unreadable profile is just that.
  static func denialReason(for error: any Error, browser: Browser) -> BrowserAccessDenialReason? {
    guard let cookieError = error as? BrowserCookieError else { return .storeUnreadable }
    switch cookieError {
    case .notFound:
      return nil
    case .loadFailed:
      return .storeUnreadable
    case .accessDenied:
      return switch family(of: browser) {
      case .safari: .fullDiskAccess
      case .gecko: .storeUnreadable
      case .chromium: .keychainRefused
      }
    }
  }

  private static let geckoBrowsers: Set<Browser> = [
    .firefox, .firefoxBeta, .firefoxDeveloperEdition, .firefoxNightly, .zen,
  ]

  static func orderedBrowsers(for spec: BrowserSessionSpec) -> [Browser] {
    let preferred = spec.browserPriority.compactMap(Browser.init(rawValue:))
    var seen = Set<Browser>()
    return (preferred + Browser.defaultImportOrder).filter { seen.insert($0).inserted }
  }

  /// Every sign-in this store holds for the provider, one candidate per header.
  ///
  /// Which cookies are a sign-in, and which of them travel together, is
  /// `BrowserSessionSpec.assembleCookieHeaders` — the same rule Quota iOS applies to the web view
  /// a reader signs in inside, so one account is one header on either device. What is added here
  /// is what only a browser jar has: which browser and profile it came from. The record's path is
  /// never one of them.
  static func candidates(
    records: [BrowserCookieRecord],
    spec: BrowserSessionSpec,
    browserName: String,
    profileName: String,
    now: Date
  ) -> [BrowserSessionCookieCandidate] {
    let cookies = records.map {
      BrowserCookie(name: $0.name, value: $0.value, domain: $0.domain, expiresAt: $0.expires)
    }
    return spec.assembleCookieHeaders(cookies: cookies, now: now)
      .map { candidate(header: $0, browserName: browserName, profileName: profileName) }
  }

  static func candidate(
    header: String,
    browserName: String,
    profileName: String
  ) -> BrowserSessionCookieCandidate {
    let fingerprint = SHA256.hash(data: Data(header.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    return BrowserSessionCookieCandidate(
      cookieHeader: header,
      headerFingerprint: fingerprint,
      browserName: browserName,
      profileName: sanitizedProfileName(profileName)
    )
  }

  static func sanitizedProfileName(_ value: String) -> String {
    let sanitized = String(
      value.unicodeScalars
        .filter { $0.value >= 0x20 && $0.value != 0x7F }
        .prefix(64)
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    return sanitized.isEmpty ? "Default profile" : sanitized
  }
}

enum BrowserApplicationCatalog {
  static func bundleIdentifiers(for browser: Browser) -> [String] {
    byBundleIdentifier.compactMap { $0.value == browser ? $0.key : nil }
  }

  /// Where the installed copy of this browser lives, or nil when it is not installed.
  static func applicationURL(for browser: Browser) -> URL? {
    for identifier in bundleIdentifiers(for: browser) {
      if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
        return url
      }
    }
    return nil
  }

  private static let byBundleIdentifier: [String: Browser] = [
    "ai.perplexity.comet": .comet,
    "app.zen-browser.zen": .zen,
    "com.apple.safari": .safari,
    "com.brave.browser": .brave,
    "com.brave.browser.beta": .braveBeta,
    "com.brave.browser.nightly": .braveNightly,
    "com.google.chrome": .chrome,
    "com.google.chrome.beta": .chromeBeta,
    "com.google.chrome.canary": .chromeCanary,
    "com.microsoft.edgemac": .edge,
    "com.microsoft.edgemac.beta": .edgeBeta,
    "com.microsoft.edgemac.canary": .edgeCanary,
    "com.openai.atlas": .chatgptAtlas,
    "com.vivaldi.vivaldi": .vivaldi,
    "company.thebrowser.browser": .arc,
    "company.thebrowser.dia": .dia,
    "net.imput.helium": .helium,
    "org.chromium.chromium": .chromium,
    "org.mozilla.firefox": .firefox,
    "org.mozilla.firefox.beta": .firefoxBeta,
    "org.mozilla.firefoxdeveloperedition": .firefoxDeveloperEdition,
    "org.mozilla.nightly": .firefoxNightly,
  ]
}
