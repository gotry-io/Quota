import Foundation
import QuotaWire
import Testing

@testable import Quota

struct DeviceRowContentTests {
  private let now = Date(timeIntervalSince1970: 1_786_723_200)
  private let studioID = "device_secret_studio"

  @Test
  func speaksNameVerdictPlatformAndAge() {
    let content = DeviceRowContent.make(
      AccountDevice(
        id: studioID,
        displayName: "Studio Mac",
        platform: .macos,
        lastSeenAt: now.addingTimeInterval(-45),
        lastObservedAt: now.addingTimeInterval(-90)
      ),
      now: now
    )
    #expect(content.displayName == "Studio Mac")
    #expect(content.verdict == "Active")
    #expect(content.platform == "macOS")
    #expect(content.age.contains("last reading"))
    #expect(
      content.accessibilityLabel
        == "\(content.displayName), \(content.verdict), \(content.platform), \(content.age)"
    )
    #expect(
      content.displayedStrings
        == [content.displayName, content.verdict, content.platform, content.age]
    )
  }

  @Test
  func displayedStringsOmitDeviceId() {
    let content = DeviceRowContent.make(
      AccountDevice(
        id: studioID,
        displayName: "Studio Mac",
        platform: .macos,
        lastSeenAt: now,
        lastObservedAt: now
      ),
      now: now
    )
    let joined = content.displayedStrings.joined(separator: "\n")
    #expect(!joined.contains(studioID))
    #expect(!joined.contains("device_"))
    #expect(!content.accessibilityLabel.contains(studioID))
  }
}
