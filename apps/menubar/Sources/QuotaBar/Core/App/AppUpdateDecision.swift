import Foundation

enum AppUpdateRelation: String, Equatable, Sendable {
  case newer
  case same
  case older
  case invalid
}

struct AppUpdateAsset: Equatable, Sendable {
  let url: URL
  let sha256: String
}

struct AppUpdateFeed: Equatable, Sendable {
  let schemaVersion: Int
  let product: String
  let version: String
  let notes: String?
  let dmg: AppUpdateAsset?
  let zip: AppUpdateAsset?
}

struct AppUpdateOffer: Equatable, Sendable {
  let version: String
  let notes: String?
  let asset: AppUpdateAsset
  let kind: Kind

  enum Kind: String, Equatable, Sendable {
    case dmg
    case zip
  }
}

enum AppUpdateDecision {
  static let productID = "quotabar"
  static let schemaVersion = 1

  static func compare(_ current: String, to candidate: String) -> AppUpdateRelation {
    guard let left = parseVersion(current), let right = parseVersion(candidate) else {
      return .invalid
    }
    if left.numbers != right.numbers {
      return left.numbers.lexicographicallyPrecedes(right.numbers) ? .older : .newer
    }
    switch (left.prerelease, right.prerelease) {
    case (nil, nil):
      return .same
    case (nil, .some):
      return .newer
    case (.some, nil):
      return .older
    case let (.some(leftPre), .some(rightPre)):
      if leftPre == rightPre { return .same }
      return leftPre.lexicographicallyPrecedes(rightPre) ? .older : .newer
    }
  }

  static func parseFeed(_ data: Data) -> AppUpdateFeed? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    guard
      let schemaVersion = root["schema_version"] as? Int,
      schemaVersion == Self.schemaVersion,
      let product = root["product"] as? String,
      product == productID,
      let version = root["version"] as? String,
      parseVersion(version) != nil
    else {
      return nil
    }
    let assets = root["assets"] as? [String: Any]
    return AppUpdateFeed(
      schemaVersion: schemaVersion,
      product: product,
      version: version,
      notes: nonempty(root["notes"] as? String),
      dmg: parseAsset(assets?["dmg"]),
      zip: parseAsset(assets?["zip"])
    )
  }

  static func offer(currentVersion: String, feed: AppUpdateFeed) -> AppUpdateOffer? {
    guard compare(currentVersion, to: feed.version) == .older else { return nil }
    if let dmg = feed.dmg {
      return AppUpdateOffer(version: feed.version, notes: feed.notes, asset: dmg, kind: .dmg)
    }
    if let zip = feed.zip {
      return AppUpdateOffer(version: feed.version, notes: feed.notes, asset: zip, kind: .zip)
    }
    return nil
  }

  /// Prefer the newest parseable feed so a stale website document cannot hide a later release.
  static func offer(currentVersion: String, feedDocuments: [Data]) -> AppUpdateOffer? {
    selectOffer(currentVersion: currentVersion, feeds: feedDocuments.compactMap(parseFeed))
  }

  static func selectOffer(currentVersion: String, feeds: [AppUpdateFeed]) -> AppUpdateOffer? {
    feeds.compactMap { offer(currentVersion: currentVersion, feed: $0) }.max { left, right in
      compare(left.version, to: right.version) == .older
    }
  }

  static func parseVersion(_ raw: String) -> (numbers: [Int], prerelease: String?)? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let core: String
    let prerelease: String?
    if let hyphen = trimmed.firstIndex(of: "-") {
      core = String(trimmed[..<hyphen])
      prerelease = String(trimmed[trimmed.index(after: hyphen)...])
      if prerelease?.isEmpty == true { return nil }
    } else {
      core = trimmed
      prerelease = nil
    }
    let parts = core.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, let major = Int(parts[0]), let minor = Int(parts[1]),
      let patch = Int(parts[2]), major >= 0, minor >= 0, patch >= 0
    else {
      return nil
    }
    return ([major, minor, patch], prerelease)
  }

  private static func parseAsset(_ value: Any?) -> AppUpdateAsset? {
    guard
      let object = value as? [String: Any],
      let urlString = object["url"] as? String,
      let url = URL(string: urlString),
      let scheme = url.scheme?.lowercased(),
      scheme == "https",
      let sha256 = object["sha256"] as? String,
      sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    else {
      return nil
    }
    return AppUpdateAsset(url: url, sha256: sha256)
  }

  private static func nonempty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else {
      return nil
    }
    return trimmed
  }
}
