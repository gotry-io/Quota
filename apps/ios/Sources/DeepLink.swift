import Foundation

enum DeepLink: Equatable, Sendable {
  case overview
  case subscription(id: String)
  /// The end of a browser sign-in that finished outside `ASWebAuthenticationSession`.
  ///
  /// An emailed sign-in link is opened in the system browser, not in the session sheet, so the
  /// authorization callback reaches the app the way any link to it does. The URL itself is not
  /// carried here: `OAuthCallback` reads it against the attempt this app is waiting on.
  case oauthCallback

  private static let scheme = "io.gotry.quota"

  /// `io.gotry.quota:/overview`, `io.gotry.quota:/subscriptions/<selection_id>`, and
  /// `io.gotry.quota:/oauth/callback`. `selection_id` is twelve lowercase hex digits after
  /// percent-decoding each path segment.
  static func parse(_ url: URL) -> DeepLink? {
    guard let scheme = url.scheme, scheme.caseInsensitiveCompare(Self.scheme) == .orderedSame else {
      return nil
    }
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return nil
    }
    if let host = components.host, !host.isEmpty {
      return nil
    }

    var segments: [String] = []
    for raw in components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true) {
      guard let decoded = String(raw).removingPercentEncoding else { return nil }
      segments.append(decoded)
    }

    if segments == ["overview"] {
      return .overview
    }
    if segments == ["oauth", "callback"] {
      return .oauthCallback
    }
    if segments.count == 2, segments[0] == "subscriptions" {
      let id = segments[1]
      guard isSelectionID(id) else { return nil }
      return .subscription(id: id)
    }
    return nil
  }

  /// `^[0-9a-f]{12}$`
  private static func isSelectionID(_ value: String) -> Bool {
    guard value.count == 12 else { return false }
    return value.utf8.allSatisfy { byte in
      (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
    }
  }
}

enum AppTab: Hashable, Sendable, CaseIterable {
  case overview
  case usage
  case devices
  case settings

  var title: String {
    switch self {
    case .overview: "Overview"
    case .usage: "Usage"
    case .devices: "Devices"
    case .settings: "Settings"
    }
  }

  var systemImage: String {
    switch self {
    case .overview: "gauge.with.dots.needle.33percent"
    case .usage: "chart.bar"
    case .devices: "laptopcomputer"
    case .settings: "gearshape"
    }
  }
}
