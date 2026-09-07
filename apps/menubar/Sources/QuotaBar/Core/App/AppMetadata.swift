import Foundation

enum AppMetadata {
  static var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "Development"
  }

  static var versionLabel: String {
    let raw = version.trimmingCharacters(in: .whitespacesAndNewlines)
    if raw.isEmpty { return "Development" }
    return raw.hasPrefix("v") ? raw : "v\(raw)"
  }

  static let websiteURL = URL(string: "https://quota.gotry.io")!
  static let accountURL = URL(string: "https://quota.gotry.io/my")!
  /// Where a subscription is changed or cancelled once there is one.
  static let manageSubscriptionURL = URL(string: "https://quota.gotry.io/my/settings")!
  /// The website Settings grouping where a signed-in account redeems a Quota Pro code.
  static let redeemCodeURL = URL(string: "https://quota.gotry.io/my/settings#sync-title")!
  static let feedbackURL = URL(string: "https://github.com/gotry-io/Quota/issues")!
}
