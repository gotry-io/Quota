import AppKit
import CryptoKit
import Foundation
import SweetCookieKit

struct BrowserApplicationChoice: Identifiable, Equatable, Sendable {
  let browser: Browser
  let applicationURL: URL
  let title: String

  var id: String { browser.rawValue }
}

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

/// One refused read, in the two facts a reader and the Support page both need.
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
  private static let maximumCookieHeaderBytes = 8_192

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
      let allowedHosts = Set(spec.cookieHosts)
      let allowedNames = Set(spec.cookieNames)
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
        let grouped = Self.groupedCandidates(
          records: records,
          browserName: browser.displayName,
          profileName: store.profile.name,
          allowedHosts: allowedHosts,
          allowedNames: allowedNames,
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

  /// A store that is simply not there is not a refusal: that browser has never been used.
  ///
  /// The two refusals macOS actually issues come from different gatekeepers. Safari's jar sits
  /// behind Full Disk Access; a Chrome-family jar is encrypted with a Keychain item the user
  /// has to release. Firefox has neither, so an unreadable profile is just that.
  static func denialReason(for error: any Error, browser: Browser) -> BrowserAccessDenialReason? {
    guard let cookieError = error as? BrowserCookieError else { return .storeUnreadable }
    switch cookieError {
    case .notFound:
      return nil
    case .loadFailed:
      return .storeUnreadable
    case .accessDenied:
      if browser == .safari { return .fullDiskAccess }
      return geckoBrowsers.contains(browser) ? .storeUnreadable : .keychainRefused
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

  static func candidate(
    record: BrowserCookieRecord,
    browserName: String,
    profileName: String,
    allowedHosts: Set<String>,
    allowedNames: Set<String>,
    now: Date
  ) -> BrowserSessionCookieCandidate? {
    guard
      let pair = allowlistedPair(
        record: record,
        allowedHosts: allowedHosts,
        allowedNames: allowedNames,
        now: now
      )
    else { return nil }
    return candidate(
      pairs: [(pair.name, pair.value)],
      browserName: browserName,
      profileName: profileName
    )
  }

  static func candidate(
    pairs: [(name: String, value: String)],
    browserName: String,
    profileName: String
  ) -> BrowserSessionCookieCandidate? {
    let header = pairs
      .sorted { $0.name < $1.name }
      .map { "\($0.name)=\($0.value)" }
      .joined(separator: "; ")
    guard !header.isEmpty, header.utf8.count <= maximumCookieHeaderBytes else { return nil }
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

  static func allowlistedPair(
    record: BrowserCookieRecord,
    allowedHosts: Set<String>,
    allowedNames: Set<String>,
    now: Date
  ) -> (name: String, value: String, host: String)? {
    let host = record.domain.hasPrefix(".") ? String(record.domain.dropFirst()) : record.domain
    guard
      allowedHosts.contains(host.lowercased()),
      allowedNames.contains(record.name),
      record.expires.map({ $0 > now }) != false,
      !record.value.isEmpty
    else { return nil }
    return (record.name, record.value, host.lowercased())
  }

  /// One candidate per allowlisted name per host.
  ///
  /// Every name the catalog declares names a whole session on its own, so two of them are two
  /// sign-ins to choose between, never two halves of one. Hosts are never combined either: a
  /// cookie set on `cursor.com` and one set on `authenticator.cursor.sh` are separate readings.
  static func groupedCandidates(
    records: [BrowserCookieRecord],
    browserName: String,
    profileName: String,
    allowedHosts: Set<String>,
    allowedNames: Set<String>,
    now: Date
  ) -> [BrowserSessionCookieCandidate] {
    var byHost: [String: [(name: String, value: String)]] = [:]
    var seenByHost: [String: Set<String>] = [:]
    for record in records {
      guard
        let pair = allowlistedPair(
          record: record,
          allowedHosts: allowedHosts,
          allowedNames: allowedNames,
          now: now
        )
      else { continue }
      var seenNames = seenByHost[pair.host] ?? []
      guard seenNames.insert(pair.name).inserted else { continue }
      seenByHost[pair.host] = seenNames
      byHost[pair.host, default: []].append((pair.name, pair.value))
    }
    return byHost.keys.sorted().flatMap { host in
      (byHost[host] ?? []).sorted { $0.name < $1.name }.compactMap { pair in
        candidate(pairs: [pair], browserName: browserName, profileName: profileName)
      }
    }
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

@MainActor
protocol BrowserApplicationRouting {
  func defaultApplication(for url: URL) -> URL?
  func applications(for url: URL) -> [URL]
  func open(_ url: URL, with applicationURL: URL) async -> Bool
}

@MainActor
struct WorkspaceBrowserApplicationRouter: BrowserApplicationRouting {
  func defaultApplication(for url: URL) -> URL? {
    NSWorkspace.shared.urlForApplication(toOpen: url)
  }

  func applications(for url: URL) -> [URL] {
    NSWorkspace.shared.urlsForApplications(toOpen: url)
  }

  func open(_ url: URL, with applicationURL: URL) async -> Bool {
    let configuration = NSWorkspace.OpenConfiguration()
    return await withCheckedContinuation { continuation in
      NSWorkspace.shared.open(
        [url], withApplicationAt: applicationURL, configuration: configuration
      ) { _, error in
        continuation.resume(returning: error == nil)
      }
    }
  }
}

enum BrowserApplicationCatalog {
  static func choice(for applicationURL: URL, allowed: [Browser]) -> BrowserApplicationChoice? {
    guard
      let bundleIdentifier = Bundle(url: applicationURL)?.bundleIdentifier?.lowercased(),
      let browser = byBundleIdentifier[bundleIdentifier],
      allowed.contains(browser)
    else { return nil }
    return BrowserApplicationChoice(
      browser: browser,
      applicationURL: applicationURL,
      title: browser.displayName
    )
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
