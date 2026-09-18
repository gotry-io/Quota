import Foundation

/// Provider display names and window titles the sink needs to write `AlertCopy`.
public struct AlertDeliveryCatalog: Equatable, Sendable {
  public struct Entry: Equatable, Sendable {
    public var providerDisplayName: String
    public var windows: [String: String]

    public init(providerDisplayName: String, windows: [String: String]) {
      self.providerDisplayName = providerDisplayName
      self.windows = windows
    }
  }

  public var entries: [String: Entry]

  public static let empty = AlertDeliveryCatalog(entries: [:])

  public init(entries: [String: Entry]) {
    self.entries = entries
  }

  public func providerDisplayName(selector: String) -> String? {
    entries[selector]?.providerDisplayName
  }

  public func windowTitle(selector: String, windowID: String) -> String? {
    entries[selector]?.windows[windowID]
  }
}
