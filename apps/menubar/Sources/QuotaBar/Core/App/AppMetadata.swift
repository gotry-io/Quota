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
  static let feedbackURL = URL(string: "https://github.com/gotry-io/Quota/issues")!
}
