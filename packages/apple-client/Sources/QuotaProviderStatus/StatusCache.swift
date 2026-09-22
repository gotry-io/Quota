import Foundation
import QuotaWire

public struct ProtectedFileProviderStatusStore: ProviderStatusStoring, Sendable {
  public let fileURL: URL

  public init(directory: URL) {
    self.fileURL = directory.appendingPathComponent("provider-status.json", isDirectory: false)
  }

  public static func applicationSupport() throws -> ProtectedFileProviderStatusStore {
    let root = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let directory = root.appendingPathComponent("Quota", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutable = directory
    try? mutable.setResourceValues(values)
    return ProtectedFileProviderStatusStore(directory: directory)
  }

  public func load() throws -> [ProviderStatusReading]? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
    let data = try Data(contentsOf: fileURL)
    return try WireCodec.decode([ProviderStatusReading].self, from: data)
  }

  public func save(_ readings: [ProviderStatusReading]) throws {
    let data = try WireCodec.encode(readings)
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    #if os(iOS)
      try data.write(
        to: fileURL,
        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
      )
    #else
      try data.write(to: fileURL, options: [.atomic])
    #endif
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutable = fileURL
    try? mutable.setResourceValues(values)
  }

  public func clear() throws {
    if FileManager.default.fileExists(atPath: fileURL.path) {
      try FileManager.default.removeItem(at: fileURL)
    }
  }
}
