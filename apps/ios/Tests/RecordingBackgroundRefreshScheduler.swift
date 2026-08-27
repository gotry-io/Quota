import Foundation

@testable import Quota

final class RecordingBackgroundRefreshScheduler: BackgroundRefreshScheduling, @unchecked Sendable {
  private let lock = NSLock()
  private var scheduled = 0
  private var cancelled = 0

  var scheduleCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return scheduled
  }

  var cancelCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  func scheduleNextRefresh() {
    lock.lock()
    scheduled += 1
    lock.unlock()
  }

  func cancelPendingRefresh() {
    lock.lock()
    cancelled += 1
    lock.unlock()
  }
}
