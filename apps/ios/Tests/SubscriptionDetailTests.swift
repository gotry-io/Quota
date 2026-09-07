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
      deviceNames: deviceNames(),
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
      deviceNames: [studioID: "Studio Mac"],
      now: now
    )
    #expect(content.sources.map(\.displayName) == ["Studio Mac", "Device"])
  }

  @Test
  func displayedStringsOmitDeviceIdFingerprintAndKey() {
    let content = SubscriptionDetailContent.make(
      subscription: subscription(sources: kitchenThenStudio()),
      deviceNames: deviceNames(),
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
  func emptySourcesPrintNoDeviceReadingsYet() {
    let content = SubscriptionDetailContent.make(
      subscription: QuotaSubscription(
        key: key,
        provider: .codex,
        snapshot: snapshot(usedPercent: 32, observedAt: now),
        sources: []
      ),
      deviceNames: deviceNames(),
      now: now
    )
    #expect(content.sources.isEmpty)
    #expect(content.displayedStrings.contains("No device readings yet."))
    #expect(!content.displayedStrings.contains("Reporting"))
  }

  @Test
  func emptyWindowsPrintNoQuotaWindowsYet() {
    let empty = QuotaSnapshot(
      provider: .codex,
      account: QuotaAccount(
        fingerprint: fingerprint,
        label: "pe***@example.com",
        plan: "Plus",
        fingerprintScope: .global
      ),
      windows: [],
      status: .available,
      observedAt: now
    )
    let content = SubscriptionDetailContent.make(
      subscription: QuotaSubscription(
        key: key, provider: .codex, snapshot: empty, sources: []),
      deviceNames: deviceNames(),
      now: now
    )
    #expect(content.windows.isEmpty)
    #expect(content.displayedStrings.contains("No quota windows yet."))
    #expect(content.displayedStrings.contains("No device readings yet."))
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
      deviceNames: deviceNames(),
      now: now
    )
    #expect(content.sources[0].remaining == "68%")
    #expect(content.sources[0].isReporting)
    #expect(content.sources[1].remaining == nil)
    #expect(!content.sources[1].isReporting)
  }

  /// The reading this phone took draws its own curve; the same reading arriving from a Mac
  /// does not, because this phone kept no samples of it (ADR 0042).
  @Test
  func onlyThisPhonesOwnReadingCarriesAHistory() {
    let observed = now.addingTimeInterval(-60)
    let reading = snapshot(usedPercent: 58, observedAt: observed, durationSeconds: 18_000)
    let local = QuotaSubscription(
      key: key,
      provider: .codex,
      snapshot: reading,
      sources: [
        QuotaSubscriptionSource(
          deviceID: ThisDevice.sourceID, observedAt: observed, snapshot: reading)
      ]
    )
    var samples = LocalQuotaSamples()
    let start = now.addingTimeInterval(2_700 - 18_000)
    for (offset, used) in [(3_600.0, 20.0), (7_200.0, 38.0), (12_540.0, 58.0)] {
      samples.windows.append(
        LocalQuotaSamples.Entry(
          provider: .codex,
          windowID: "five_hour",
          samples: [
            QuotaSample(
              resetsAt: now.addingTimeInterval(2_700),
              observedAt: start.addingTimeInterval(offset),
              usedPercent: used
            )
          ]
        )
      )
    }
    samples.windows = [
      LocalQuotaSamples.Entry(
        provider: .codex,
        windowID: "five_hour",
        samples: samples.windows.flatMap(\.samples)
      )
    ]

    let mine = SubscriptionDetailContent.make(
      subscription: local,
      deviceNames: [:],
      samples: samples,
      now: now,
      utcOffsetSeconds: 0
    )
    let history = try! #require(mine.histories["five_hour"])
    #expect(history.points.count == 3)
    #expect(history.projection != nil)
    #expect(mine.todayLine != nil)
    #expect(mine.displayedStrings.contains(mine.todayLine ?? ""))

    let fromAMac = QuotaSubscription(
      key: key,
      provider: .codex,
      snapshot: reading,
      sources: [
        QuotaSubscriptionSource(deviceID: studioID, observedAt: observed, snapshot: reading)
      ]
    )
    let theirs = SubscriptionDetailContent.make(
      subscription: fromAMac,
      deviceNames: deviceNames(),
      samples: samples,
      now: now,
      utcOffsetSeconds: 0
    )
    #expect(theirs.histories.isEmpty)
    #expect(theirs.todayLine == nil)
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
    let selected =
      sources.first { $0.deviceID == studioID }?.snapshot
      ?? snapshot(usedPercent: 32, observedAt: now)
    return QuotaSubscription(
      key: key,
      provider: .codex,
      snapshot: selected,
      sources: sources
    )
  }

  private func snapshot(
    usedPercent: Double,
    observedAt: Date,
    durationSeconds: Int? = nil
  ) -> QuotaSnapshot {
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
          resetsAt: now.addingTimeInterval(2_700),
          durationSeconds: durationSeconds
        )
      ],
      status: .available,
      observedAt: observedAt
    )
  }

  private func deviceNames() -> [String: String] {
    [studioID: "Studio Mac", kitchenID: "Kitchen Mac"]
  }
}
