import Foundation
import os

/// Intervals around restore, status, summary, local collection and upload, plus first/fresh content.
enum LaunchSignposts {
  static let signposter = OSSignposter(subsystem: "io.gotry.quota", category: "launch")

  static func begin(_ name: StaticString) -> OSSignpostIntervalState {
    signposter.beginInterval(name)
  }

  static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
    signposter.endInterval(name, state)
  }

  static func event(_ name: StaticString) {
    signposter.emitEvent(name)
  }
}
