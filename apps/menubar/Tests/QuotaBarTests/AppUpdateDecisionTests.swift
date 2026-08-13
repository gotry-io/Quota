import Foundation
import Testing

@testable import QuotaBar

struct AppUpdateDecisionTests {
  @Test
  func comparesReleasedAndPrereleaseVersions() {
    #expect(AppUpdateDecision.compare("0.0.9", to: "0.0.10") == .older)
    #expect(AppUpdateDecision.compare("0.0.10", to: "0.0.9") == .newer)
    #expect(AppUpdateDecision.compare("0.0.9", to: "0.0.9") == .same)
    #expect(AppUpdateDecision.compare("0.0.9-beta.1", to: "0.0.9") == .older)
    #expect(AppUpdateDecision.compare("0.0.9", to: "0.0.9-beta.1") == .newer)
    #expect(AppUpdateDecision.compare("not-a-version", to: "0.0.9") == .invalid)
    #expect(AppUpdateDecision.compare("0.0.9", to: "1.2") == .invalid)
  }

  @Test
  func parseFeedRejectsInvalidDocuments() {
    #expect(AppUpdateDecision.parseFeed(Data("{".utf8)) == nil)
    #expect(AppUpdateDecision.parseFeed(json(["schema_version": 2, "product": "quotabar", "version": "0.0.10"])) == nil)
    #expect(AppUpdateDecision.parseFeed(json(["schema_version": 1, "product": "other", "version": "0.0.10"])) == nil)
    #expect(AppUpdateDecision.parseFeed(json(["schema_version": 1, "product": "quotabar", "version": "bad"])) == nil)
  }

  @Test
  func offerRequiresANewerVersionAndAUsableAsset() throws {
    let current = try #require(
      AppUpdateDecision.parseFeed(
        json(feed(version: "0.0.9", includeDMG: true, includeZip: true))))
    #expect(AppUpdateDecision.offer(currentVersion: "0.0.9", feed: current) == nil)

    let older = try #require(
      AppUpdateDecision.parseFeed(json(feed(version: "0.0.8", includeDMG: true))))
    #expect(AppUpdateDecision.offer(currentVersion: "0.0.9", feed: older) == nil)

    let invalid = AppUpdateFeed(
      schemaVersion: 1, product: "quotabar", version: "0.0.10", notes: nil, dmg: nil, zip: nil)
    #expect(AppUpdateDecision.offer(currentVersion: "0.0.9", feed: invalid) == nil)

    let newer = try #require(
      AppUpdateDecision.parseFeed(
        json(feed(version: "0.0.10", includeDMG: true, includeZip: true, notes: "Fixes"))))
    let offer = try #require(AppUpdateDecision.offer(currentVersion: "0.0.9", feed: newer))
    #expect(offer.version == "0.0.10")
    #expect(offer.kind == .dmg)
    #expect(offer.notes == "Fixes")
    #expect(offer.asset.sha256.count == 64)
  }

  @Test
  func zipIsOfferedWhenDMGIsAbsent() throws {
    let feed = try #require(
      AppUpdateDecision.parseFeed(json(self.feed(version: "1.2.3", includeZip: true))))
    let offer = try #require(AppUpdateDecision.offer(currentVersion: "1.2.2", feed: feed))
    #expect(offer.kind == .zip)
  }

  private func feed(
    version: String,
    includeDMG: Bool = false,
    includeZip: Bool = false,
    notes: String? = nil
  ) -> [String: Any] {
    var assets: [String: Any] = [:]
    if includeDMG {
      assets["dmg"] = [
        "url": "https://github.com/gotry-io/Quota/releases/download/menubar-v\(version)/QuotaBar-macos-arm64.dmg",
        "sha256": String(repeating: "ab", count: 32),
      ]
    }
    if includeZip {
      assets["zip"] = [
        "url": "https://github.com/gotry-io/Quota/releases/download/menubar-v\(version)/QuotaBar-\(version)-macos-arm64.zip",
        "sha256": String(repeating: "cd", count: 32),
      ]
    }
    var root: [String: Any] = [
      "schema_version": 1,
      "product": "quotabar",
      "version": version,
      "assets": assets,
    ]
    if let notes {
      root["notes"] = notes
    }
    return root
  }

  private func json(_ value: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: value)
  }
}
