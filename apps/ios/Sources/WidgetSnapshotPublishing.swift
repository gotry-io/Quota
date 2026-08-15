import Foundation
import QuotaWidgetData
import WidgetKit

protocol WidgetSnapshotPublishing: Sendable {
  func publish(_ snapshot: WidgetSnapshot) throws
  func clear() throws
}

struct NoOpWidgetSnapshotPublisher: WidgetSnapshotPublishing {
  func publish(_ snapshot: WidgetSnapshot) throws {}
  func clear() throws {}
}

struct AppGroupWidgetSnapshotPublisher: WidgetSnapshotPublishing {
  static let appGroupIdentifier = "group.io.gotry.quota"
  static let widgetKind = "io.gotry.quota.overview"

  private let store: ProtectedFileWidgetSnapshotStore
  private let reloadTimelines: @Sendable () -> Void

  init(
    containerURL: URL,
    reloadTimelines: @escaping @Sendable () -> Void = {
      WidgetCenter.shared.reloadTimelines(ofKind: AppGroupWidgetSnapshotPublisher.widgetKind)
    }
  ) {
    self.store = ProtectedFileWidgetSnapshotStore(directory: containerURL)
    self.reloadTimelines = reloadTimelines
  }

  static func make() -> any WidgetSnapshotPublishing {
    guard
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: appGroupIdentifier
      )
    else {
      return NoOpWidgetSnapshotPublisher()
    }
    return AppGroupWidgetSnapshotPublisher(containerURL: container)
  }

  func publish(_ snapshot: WidgetSnapshot) throws {
    try store.save(snapshot)
    reloadTimelines()
  }

  func clear() throws {
    try store.clear()
    reloadTimelines()
  }
}
