import Foundation
import QuotaPresentation
import QuotaWire
import Testing

@testable import Quota

struct QuotaResetCountdownTests {
  private let now = Date(timeIntervalSince1970: 1_786_723_200)
  private let utc = TimeZone(secondsFromGMT: 0)!

  @Test
  func missingOrPastResetHasNoRow() {
    #expect(QuotaFormat.countdown(resetsAt: nil, now: now) == nil)
    #expect(QuotaFormat.countdown(resetsAt: now, now: now) == nil)
    #expect(QuotaFormat.countdown(resetsAt: now.addingTimeInterval(-1), now: now) == nil)
  }

  @Test
  func underADayIsALiveTimer() {
    let end = now.addingTimeInterval(2_700)
    #expect(QuotaFormat.countdown(resetsAt: end, now: now) == .live(end: end))
    let justUnderADay = now.addingTimeInterval(86_400 - 1)
    #expect(QuotaFormat.countdown(resetsAt: justUnderADay, now: now) == .live(end: justUnderADay))
  }

  @Test
  func aDayOrMoreUsesSharedResetCopy() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    let end = now.addingTimeInterval(86_400)
    let copy = QuotaFormat.countdown(
      resetsAt: end, now: now, timeZone: utc, calendar: calendar)
    #expect(copy == .copy("Resets Sat 16:00"))
  }
}

struct SubscriptionDetailContentTests {
  private let now = Date(timeIntervalSince1970: 1_786_723_200)
  private let studioID = "device_secret_studio"
  private let kitchenID = "device_secret_kitchen"
  private let fingerprint = "fp_secret_codex"
  private let key = "codex|fp_secret_codex|global|"

  @Test
  func sourcesSortNewestFirstAndMarkTheSelectedSourceReporting() {
    let content = SubscriptionDetailContent.make(
      subscription: subscription(sources: kitchenThenStudio()),
      devices: devices(),
      now: now
    )
    #expect(content.sources.map(\.displayName) == ["Studio Mac", "Kitchen Mac"])
    #expect(content.sources.map(\.isReporting) == [true, false])
    #expect(content.sources[0].remaining == "68%")
    #expect(content.sources[1].remaining == "59%")
  }

  @Test
  func missingDeviceNameIsDevice() {
    let content = SubscriptionDetailContent.make(
      subscription: subscription(sources: kitchenThenStudio()),
      devices: [
        AccountDevice(
          id: studioID,
          displayName: "Studio Mac",
          platform: .macos,
          lastSeenAt: now,
          lastObservedAt: now
        )
      ],
      now: now
    )
    #expect(content.sources.map(\.displayName) == ["Studio Mac", "Device"])
  }

  @Test
  func displayedStringsOmitDeviceIdFingerprintAndKey() {
    let content = SubscriptionDetailContent.make(
      subscription: subscription(sources: kitchenThenStudio()),
      devices: devices(),
      now: now
    )
    let joined = content.displayedStrings.joined(separator: "\n")
    #expect(!joined.contains(studioID))
    #expect(!joined.contains(kitchenID))
    #expect(!joined.contains(fingerprint))
    #expect(!joined.contains(key))
    #expect(!joined.contains("device_"))
    #expect(!joined.contains("fp_"))
    #expect(content.displayedStrings.contains("Reporting"))
    #expect(content.displayedStrings.contains("Studio Mac"))
    #expect(content.displayedStrings.contains("Kitchen Mac"))
    #expect(content.providerName == "Codex")
  }

  @Test
  func sourceWithoutSnapshotHasNoRemainingAndIsNotInvented() {
    let studio = snapshot(usedPercent: 32, observedAt: now.addingTimeInterval(-90))
    let sources = [
      QuotaSubscriptionSource(
        deviceID: kitchenID, observedAt: now.addingTimeInterval(-360), snapshot: nil),
      QuotaSubscriptionSource(deviceID: studioID, observedAt: studio.observedAt, snapshot: studio),
    ]
    let content = SubscriptionDetailContent.make(
      subscription: QuotaSubscription(
        key: key, provider: .codex, snapshot: studio, sources: sources),
      devices: devices(),
      now: now
    )
    #expect(content.sources[0].remaining == "68%")
    #expect(content.sources[0].isReporting)
    #expect(content.sources[1].remaining == nil)
    #expect(!content.sources[1].isReporting)
  }

  private func kitchenThenStudio() -> [QuotaSubscriptionSource] {
    let studio = snapshot(usedPercent: 32, observedAt: now.addingTimeInterval(-90))
    let kitchen = snapshot(usedPercent: 41, observedAt: now.addingTimeInterval(-360))
    return [
      QuotaSubscriptionSource(
        deviceID: kitchenID, observedAt: kitchen.observedAt, snapshot: kitchen),
      QuotaSubscriptionSource(deviceID: studioID, observedAt: studio.observedAt, snapshot: studio),
    ]
  }

  private func subscription(sources: [QuotaSubscriptionSource]) -> QuotaSubscription {
    let selected = sources.first { $0.deviceID == studioID }?.snapshot
      ?? snapshot(usedPercent: 32, observedAt: now)
    return QuotaSubscription(
      key: key,
      provider: .codex,
      snapshot: selected,
      sources: sources
    )
  }

  private func snapshot(usedPercent: Double, observedAt: Date) -> QuotaSnapshot {
    QuotaSnapshot(
      provider: .codex,
      account: QuotaAccount(
        fingerprint: fingerprint,
        label: "pe***@example.com",
        plan: "Plus",
        fingerprintScope: .global
      ),
      windows: [
        QuotaWindow(
          id: "five_hour",
          title: "5 Hours",
          usedPercent: usedPercent,
          resetsAt: now.addingTimeInterval(2_700)
        )
      ],
      status: .available,
      observedAt: observedAt
    )
  }

  private func devices() -> [AccountDevice] {
    [
      AccountDevice(
        id: studioID,
        displayName: "Studio Mac",
        platform: .macos,
        lastSeenAt: now,
        lastObservedAt: now
      ),
      AccountDevice(
        id: kitchenID,
        displayName: "Kitchen Mac",
        platform: .macos,
        lastSeenAt: now.addingTimeInterval(-300),
        lastObservedAt: now.addingTimeInterval(-360)
      ),
    ]
  }
}
