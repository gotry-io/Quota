import Foundation

@testable import Quota

final class RecordingBackgroundRefreshScheduler: BackgroundRefreshScheduling, @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var scheduleCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func scheduleNextRefresh() {
    lock.lock()
    count += 1
    lock.unlock()
  }
}
