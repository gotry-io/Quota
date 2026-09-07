import Foundation
import WidgetKit

/// The publishing half of the App Group snapshot: the app process writes, the extension reads.
public protocol WidgetSnapshotPublishing: Sendable {
  func publish(_ snapshot: WidgetSnapshot) throws
  func clear() throws
}

/// What a build with no App Group container gets. Publishing is then a no-op rather than a crash
/// or a half-written file.
public struct NoOpWidgetSnapshotPublisher: WidgetSnapshotPublishing {
  public init() {}
  public func publish(_ snapshot: WidgetSnapshot) throws {}
  public func clear() throws {}
}

public struct AppGroupWidgetSnapshotPublisher: WidgetSnapshotPublishing {
  private let store: ProtectedFileWidgetSnapshotStore
  private let reloadTimelines: @Sendable () -> Void

  public init(
    containerURL: URL,
    reloadTimelines: @escaping @Sendable () -> Void = {
      WidgetCenter.shared.reloadTimelines(ofKind: WidgetAppGroup.widgetKind)
    }
  ) {
    self.store = ProtectedFileWidgetSnapshotStore(directory: containerURL)
    self.reloadTimelines = reloadTimelines
  }

  public static func make() -> any WidgetSnapshotPublishing {
    guard let container = WidgetAppGroup.containerURL() else {
      return NoOpWidgetSnapshotPublisher()
    }
    return AppGroupWidgetSnapshotPublisher(containerURL: container)
  }

  public func publish(_ snapshot: WidgetSnapshot) throws {
    try store.save(snapshot)
    reloadTimelines()
  }

  public func clear() throws {
    try store.clear()
    reloadTimelines()
  }
}
