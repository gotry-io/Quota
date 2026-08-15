import Foundation
import QuotaWidgetData

@testable import Quota

final class RecordingWidgetSnapshotPublisher: WidgetSnapshotPublishing, @unchecked Sendable {
  enum Event: Equatable, Sendable {
    case publish(WidgetSnapshot)
    case clear
  }

  private let lock = NSLock()
  private(set) var events: [Event] = []

  var publishCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return events.reduce(0) { partial, event in
      if case .publish = event { return partial + 1 }
      return partial
    }
  }

  var clearCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return events.reduce(0) { partial, event in
      if case .clear = event { return partial + 1 }
      return partial
    }
  }

  var lastPublished: WidgetSnapshot? {
    lock.lock()
    defer { lock.unlock() }
    for event in events.reversed() {
      switch event {
      case .publish(let snapshot):
        return snapshot
      case .clear:
        return nil
      }
    }
    return nil
  }

  func publish(_ snapshot: WidgetSnapshot) throws {
    lock.lock()
    events.append(.publish(snapshot))
    lock.unlock()
  }

  func clear() throws {
    lock.lock()
    events.append(.clear)
    lock.unlock()
  }

  func reset() {
    lock.lock()
    events = []
    lock.unlock()
  }
}
