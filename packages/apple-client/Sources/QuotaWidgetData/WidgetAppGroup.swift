import Foundation

/// The one App Group every Quota widget reads and every Quota app writes, and the one widget
/// kind they reload. iOS and macOS keep separate containers on separate devices; the file format
/// inside them is the same (`docs/decisions/0014-nonsecret-ios-widget-snapshot.md`).
public enum WidgetAppGroup {
  /// A Developer ID Mac app may only join a group whose identifier starts with its Team ID, so
  /// QuotaBar's container is the prefixed spelling of the group iOS joins as
  /// `group.io.gotry.quota`.
  #if os(macOS)
    public static let identifier = "86Y537ZF24.group.io.gotry.quota"
  #else
    public static let identifier = "group.io.gotry.quota"
  #endif

  public static let widgetKind = "io.gotry.quota.overview"

  /// `nil` when this build is not a member of the group — an ad-hoc signed local QuotaBar, for
  /// one, whose App Group capability the re-signature drops.
  public static func containerURL(
    fileManager: FileManager = .default
  ) -> URL? {
    fileManager.containerURL(forSecurityApplicationGroupIdentifier: identifier)
  }
}
