import Foundation

/// What a desktop widget can ask QuotaBar to show. The paths are the ones every Quota widget
/// draws ([ADR 0014](../../../../../docs/decisions/0014-nonsecret-ios-widget-snapshot.md)); only
/// the scheme differs, because each app registers its own.
enum QuotaBarDeepLink: Equatable, Sendable {
  case overview
  case subscription(id: String)

  static let scheme = "quotabar"

  /// `quotabar:/overview` and `quotabar:/subscriptions/<selection_id>`. `selection_id` is twelve
  /// lowercase hex digits after percent-decoding each path segment.
  static func parse(_ url: URL) -> QuotaBarDeepLink? {
    guard let scheme = url.scheme, scheme.caseInsensitiveCompare(Self.scheme) == .orderedSame
    else { return nil }
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return nil
    }
    if let host = components.host, !host.isEmpty {
      return nil
    }

    var segments: [String] = []
    for raw in components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true)
    {
      guard let decoded = String(raw).removingPercentEncoding else { return nil }
      segments.append(decoded)
    }

    if segments == ["overview"] {
      return .overview
    }
    if segments.count == 2, segments[0] == "subscriptions", isSelectionID(segments[1]) {
      return .subscription(id: segments[1])
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
