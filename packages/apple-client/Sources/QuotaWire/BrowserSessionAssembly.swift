import Foundation

/// One cookie a store holds, in the four facts that decide whether it is part of a sign-in.
///
/// Where it came from is not one of them: a Mac reads a browser's SQLite jar and a phone reads
/// the cookie store of the web view the reader signed in inside, and both must arrive at the same
/// header for the same account.
public struct BrowserCookie: Equatable, Sendable {
  public let name: String
  public let value: String
  public let domain: String
  public let expiresAt: Date?

  public init(name: String, value: String, domain: String, expiresAt: Date?) {
    self.name = name
    self.value = value
    self.domain = domain
    self.expiresAt = expiresAt
  }

  /// The host this cookie is for, with the leading dot a domain cookie carries removed.
  public var host: String {
    let stripped = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
    return stripped.lowercased()
  }
}

extension BrowserSessionSpec {
  /// A header longer than this is not a session anyone will accept, so it is not offered as one.
  public static let maximumCookieHeaderBytes = 8_192

  /// Every complete sign-in these cookies hold, each as one `Cookie` header value.
  ///
  /// Most allowlisted names are a whole session on their own, so two of them are two sign-ins and
  /// stay separate headers — Cursor's `wos-session` and `WorkosCursorSessionToken` are never
  /// combined. Two exceptions travel together because neither half is a session by itself: a
  /// cookie a browser split into numbered chunks (`…session-token.0`, `.1`), and Grok's `sso` /
  /// `sso-rw`, which are one session's two halves. A cookie that only names the account or
  /// organization a session is acting as rides along with every header on its host. Hosts are
  /// never combined.
  ///
  /// Which of these is the account the reader means is not decided here: the provider is asked.
  public func assembleCookieHeaders(cookies: [BrowserCookie], now: Date) -> [String] {
    let allowedHosts = Set(cookieHosts.map { $0.lowercased() })
    let allowedNames = Set(cookieNames)
    var byHost: [String: [BrowserCookie]] = [:]
    var seenByHost: [String: Set<String>] = [:]
    for cookie in cookies {
      guard
        allowedHosts.contains(cookie.host),
        allowedNames.contains(cookie.name),
        cookie.expiresAt.map({ $0 > now }) != false,
        !cookie.value.isEmpty
      else { continue }
      var seenNames = seenByHost[cookie.host] ?? []
      guard seenNames.insert(cookie.name).inserted else { continue }
      seenByHost[cookie.host] = seenNames
      byHost[cookie.host, default: []].append(cookie)
    }
    var headers: [String] = []
    for host in byHost.keys.sorted() {
      let hostCookies = byHost[host] ?? []
      let context = hostCookies.filter { Self.isContextCookie($0.name) }
      var families: [String: [BrowserCookie]] = [:]
      var standalones: [BrowserCookie] = []
      for cookie in hostCookies where !Self.isContextCookie(cookie.name) {
        if let family = Self.complementaryFamily(for: cookie.name) {
          families[family, default: []].append(cookie)
        } else {
          standalones.append(cookie)
        }
      }
      for family in families.keys.sorted() {
        guard let header = Self.cookieHeader((families[family] ?? []) + context) else { continue }
        headers.append(header)
      }
      for cookie in standalones.sorted(by: { $0.name < $1.name }) {
        guard let header = Self.cookieHeader([cookie] + context) else { continue }
        headers.append(header)
      }
    }
    return headers
  }

  /// One `Cookie` header, or nil when there is nothing to send or too much of it.
  public static func cookieHeader(_ cookies: [BrowserCookie]) -> String? {
    let header =
      cookies
      .sorted { $0.name < $1.name }
      .map { "\($0.name)=\($0.value)" }
      .joined(separator: "; ")
    guard !header.isEmpty, header.utf8.count <= maximumCookieHeaderBytes else { return nil }
    return header
  }

  /// The name of the sign-in a cookie is one half of, or `nil` when it is a whole one.
  public static func complementaryFamily(for name: String) -> String? {
    if name == "sso" || name == "sso-rw" {
      return "sso"
    }
    guard
      let separator = name.lastIndex(of: "."),
      separator < name.index(before: name.endIndex)
    else { return nil }
    let suffix = name[name.index(after: separator)...]
    guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else { return nil }
    return String(name[..<separator])
  }

  /// A cookie that says which account or organization a session is acting as. It is not a
  /// sign-in, so it never stands alone; it rides along with the sessions on its host.
  public static func isContextCookie(_ name: String) -> Bool {
    name == "_account" || name == "lastActiveOrg"
  }
}
