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

protocol BrowserSessionImporting: Sendable {
  func candidates(
    spec: BrowserSessionSpec,
    browser: Browser,
    now: Date,
    deadline: Date
  ) async -> [BrowserSessionCookieCandidate]
}

struct BrowserSessionImporter: BrowserSessionImporting, Sendable {
  private static let maximumStores = 64
  private static let maximumCandidates = 32
  private static let maximumCookieHeaderBytes = 8_192

  func candidates(
    spec: BrowserSessionSpec,
    browser: Browser,
    now: Date,
    deadline: Date
  ) async -> [BrowserSessionCookieCandidate] {
    let task = Task<[BrowserSessionCookieCandidate], Never>.detached(priority: .utility) {
      guard !Task.isCancelled, Date() < deadline else { return [] }
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
      for store in stores {
        guard !Task.isCancelled, Date() < deadline else { return [] }
        guard
          let records = try? client.records(matching: query, in: store, logger: nil)
        else { continue }
        for record in records {
          guard !Task.isCancelled, Date() < deadline,
            candidates.count < Self.maximumCandidates,
            let candidate = Self.candidate(
              record: record,
              browserName: browser.displayName,
              profileName: store.profile.name,
              allowedHosts: allowedHosts,
              allowedNames: allowedNames,
              now: now
            ),
            seen.insert(candidate.headerFingerprint).inserted
          else { continue }
          candidates.append(candidate)
        }
        if candidates.count == Self.maximumCandidates { break }
      }
      return candidates
    }
    return await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
  }

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
    let host = record.domain.hasPrefix(".") ? String(record.domain.dropFirst()) : record.domain
    guard
      allowedHosts.contains(host.lowercased()),
      allowedNames.contains(record.name),
      record.expires.map({ $0 > now }) != false
    else { return nil }
    let header = "\(record.name)=\(record.value)"
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
