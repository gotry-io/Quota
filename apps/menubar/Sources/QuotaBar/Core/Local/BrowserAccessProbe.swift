import AppKit
import Foundation
import QuotaBarKeychainShim
import Security
import SweetCookieKit

/// Whether a Chromium Safe Storage Keychain item can be read without showing UI.
enum BrowserKeychainAccess: Equatable, Sendable {
  case allowed
  case interactionRequired
  case notFound
  case failure
}

/// One installed browser, and whether QuotaBar may open its cookie jar right now.
struct BrowserAccessStatus: Equatable, Identifiable, Sendable {
  enum State: Equatable, Sendable {
    /// A Gecko profile, Safari with Full Disk Access, or a Chromium jar whose Keychain item
    /// already lists QuotaBar.
    case readable
    case needsFullDiskAccess
    case needsKeychain
    /// A Chromium browser that has not created its Safe Storage item: nothing to grant, and
    /// nothing to read until it runs.
    case unavailable
  }

  let browser: Browser
  let state: State

  var id: String { browser.rawValue }
  var isReadable: Bool { state == .readable }
  var family: BrowserSessionFamily { BrowserSessionImporter.family(of: browser) }

  var need: BrowserAccessNeed? {
    switch state {
    case .needsFullDiskAccess: BrowserAccessNeed(browser: browser, kind: .fullDiskAccess)
    case .needsKeychain: BrowserAccessNeed(browser: browser, kind: .keychain)
    case .readable, .unavailable: nil
    }
  }
}

/// One macOS grant Scan browsers still needs before that browser's jar can be read.
struct BrowserAccessNeed: Equatable, Identifiable, Sendable {
  enum Kind: Equatable, Sendable {
    case fullDiskAccess
    case keychain
  }

  let browser: Browser
  let kind: Kind

  var id: String { "\(kind)-\(browser.rawValue)" }
}

/// Every installed browser QuotaBar could read, and the grants still outstanding.
struct BrowserAccessSnapshot: Equatable, Sendable {
  var statuses: [BrowserAccessStatus]
  /// This session opened the Full Disk Access pane and Safari is still unreadable. macOS
  /// applies that grant to a process when it starts, so the next step is a relaunch — whether
  /// or not the person has added QuotaBar yet, which this process cannot tell.
  var awaitingRelaunch: Bool

  var needs: [BrowserAccessNeed] { statuses.compactMap(\.need) }
  var allowedBrowsers: Set<Browser> { Set(statuses.filter(\.isReadable).map(\.browser)) }
  var hasOutstandingGrants: Bool { !needs.isEmpty }

  func allowsReading(_ browser: Browser) -> Bool {
    allowedBrowsers.contains(browser)
  }

  func status(for browser: Browser) -> BrowserAccessStatus? {
    statuses.first { $0.browser == browser }
  }
}

@MainActor
protocol BrowserAccessProbing: Sendable {
  func isInstalled(_ browser: Browser) -> Bool
  func hasFullDiskAccess() -> Bool
  /// Answers without UI. The only place the Keychain prompt may appear is
  /// `requestKeychainAccess(for:)`, and only because a person asked.
  func keychainAccess(for browser: Browser) -> BrowserKeychainAccess
  func requestKeychainAccess(for browser: Browser) async -> BrowserKeychainAccess
  func snapshot(browsers: [Browser], fullDiskAccessSettingsOpened: Bool) -> BrowserAccessSnapshot
}

extension BrowserAccessProbing {
  func snapshot(
    browsers: [Browser] = Browser.defaultImportOrder,
    fullDiskAccessSettingsOpened: Bool = false
  ) -> BrowserAccessSnapshot {
    BrowserAccessEvaluation.snapshot(
      browsers: browsers,
      fullDiskAccessSettingsOpened: fullDiskAccessSettingsOpened,
      isInstalled: isInstalled,
      hasFullDiskAccess: hasFullDiskAccess,
      keychainAccess: keychainAccess
    )
  }
}

enum BrowserAccessEvaluation {
  static func snapshot(
    browsers: [Browser],
    fullDiskAccessSettingsOpened: Bool,
    isInstalled: (Browser) -> Bool,
    hasFullDiskAccess: () -> Bool,
    keychainAccess: (Browser) -> BrowserKeychainAccess
  ) -> BrowserAccessSnapshot {
    var statuses: [BrowserAccessStatus] = []
    // Asked once: the answer is a property of this process, not of the browser.
    var fullDiskAccess: Bool?
    for browser in browsers {
      guard isInstalled(browser) else { continue }
      let state: BrowserAccessStatus.State
      switch BrowserSessionImporter.family(of: browser) {
      case .gecko:
        state = .readable
      case .safari:
        let granted = fullDiskAccess ?? hasFullDiskAccess()
        fullDiskAccess = granted
        state = granted ? .readable : .needsFullDiskAccess
      case .chromium:
        switch keychainAccess(browser) {
        case .allowed: state = .readable
        case .interactionRequired: state = .needsKeychain
        case .notFound, .failure: state = .unavailable
        }
      }
      statuses.append(BrowserAccessStatus(browser: browser, state: state))
    }
    let safariStillClosed = statuses.contains { $0.state == .needsFullDiskAccess }
    return BrowserAccessSnapshot(
      statuses: statuses,
      awaitingRelaunch: fullDiskAccessSettingsOpened && safariStillClosed
    )
  }
}

/// Test and injected-client default: every browser is readable so machine TCC cannot leak in.
struct UnrestrictedBrowserAccessProbe: BrowserAccessProbing {
  func isInstalled(_ browser: Browser) -> Bool { true }
  func hasFullDiskAccess() -> Bool { true }
  func keychainAccess(for browser: Browser) -> BrowserKeychainAccess { .allowed }
  func requestKeychainAccess(for browser: Browser) async -> BrowserKeychainAccess { .allowed }
}

/// Chromium Safe Storage is a legacy login-keychain item; the SDK notes that
/// `kSecUseAuthenticationUIFail` only applies to the Data Protection keychain, so the silent
/// probe goes through a process-wide `SecKeychainSetUserInteractionAllowed(false)` in the C shim.
/// The one read that may show the prompt is `requestKeychainAccess(for:)`.
struct SystemBrowserAccessProbe: BrowserAccessProbing {
  func isInstalled(_ browser: Browser) -> Bool {
    BrowserApplicationCatalog.applicationURL(for: browser) != nil
  }

  func hasFullDiskAccess() -> Bool {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let candidates = [
      home.appendingPathComponent("Library/Safari"),
      home.appendingPathComponent(
        "Library/Containers/com.apple.Safari/Data/Library/Cookies"),
    ]
    for url in candidates where FileManager.default.fileExists(atPath: url.path) {
      do {
        _ = try FileManager.default.contentsOfDirectory(atPath: url.path)
        return true
      } catch {
        return false
      }
    }
    let stocks = home.appendingPathComponent("Library/Containers/com.apple.stocks")
    do {
      _ = try FileManager.default.contentsOfDirectory(atPath: stocks.path)
      return true
    } catch {
      return false
    }
  }

  func keychainAccess(for browser: Browser) -> BrowserKeychainAccess {
    var sawInteraction = false
    for label in Self.labels(for: browser) {
      switch Self.access(
        status: quotabar_copy_generic_password_status(label.service, label.account))
      {
      case .allowed:
        return .allowed
      case .interactionRequired:
        sawInteraction = true
      case .notFound, .failure:
        continue
      }
    }
    return sawInteraction ? .interactionRequired : .notFound
  }

  func requestKeychainAccess(for browser: Browser) async -> BrowserKeychainAccess {
    let labels = Self.labels(for: browser)
    // The ACL dialog blocks the calling thread until the person answers it, so it must not
    // hold the main actor. The secret it releases is dropped on the spot.
    return await Task.detached(priority: .userInitiated) {
      for label in labels {
        let query: [String: Any] = [
          kSecClass as String: kSecClassGenericPassword,
          kSecAttrService as String: label.service,
          kSecAttrAccount as String: label.account,
          kSecMatchLimit as String: kSecMatchLimitOne,
          kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        result = nil
        switch Self.access(status: status) {
        case .notFound: continue
        case let answer: return answer
        }
      }
      return .notFound
    }.value
  }

  nonisolated private static func labels(for browser: Browser) -> [(service: String, account: String)] {
    browser.safeStorageLabels.isEmpty ? Browser.safeStorageLabels : browser.safeStorageLabels
  }

  nonisolated private static func access(status: OSStatus) -> BrowserKeychainAccess {
    switch status {
    case errSecSuccess:
      .allowed
    // The legacy keychain answers a refused ACL with errSecAuthFailed when UI is off, and with
    // errSecUserCanceled when the person chose Deny.
    case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
      .interactionRequired
    case errSecItemNotFound:
      .notFound
    default:
      .failure
    }
  }
}
