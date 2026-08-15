import Foundation

public enum WidgetSnapshotStoreError: Error, Equatable, Sendable {
  case tooLarge
}

/// Atomic on-disk store for `WidgetSnapshot`. Callers supply the directory; the store owns the filename.
public struct ProtectedFileWidgetSnapshotStore: Sendable {
  public static let fileName = "widget-snapshot-v1.json"
  public static let maximumLoadBytes = 64 * 1024

  public let fileURL: URL

  public init(directory: URL) {
    self.fileURL = directory.appendingPathComponent(Self.fileName, isDirectory: false)
  }

  public func load() throws -> WidgetSnapshot? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
    let handle = try FileHandle(forReadingFrom: fileURL)
    let data: Data
    do {
      data = try handle.read(upToCount: Self.maximumLoadBytes + 1) ?? Data()
      try handle.close()
    } catch {
      try? handle.close()
      throw error
    }
    guard data.count <= Self.maximumLoadBytes else {
      throw WidgetSnapshotStoreError.tooLarge
    }
    return try WidgetSnapshotCodec.decode(data)
  }

  public func save(_ value: WidgetSnapshot) throws {
    let data = try WidgetSnapshotCodec.encode(value)
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
