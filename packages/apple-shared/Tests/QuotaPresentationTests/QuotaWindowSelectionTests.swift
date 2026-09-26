import Foundation
import QuotaPresentation
import Testing

struct QuotaWindowSelectionTests {
  private struct Window: ResettingQuotaWindow, Equatable {
    let title: String
    let usedPercent: Double
    var resetsAt: Date? = nil
    var remainingValue: Double? = nil
    var limitValue: Double? = nil
    var remainingUnit: RemainingQuotaUnit? = nil
  }

  private struct Subscription: Equatable {
    let name: String
    let current: Bool
    let windows: [Window]
  }

  private static let now = Date(timeIntervalSince1970: 1_790_000_000)

  private static func at(hours: Double) -> Date { now.addingTimeInterval(hours * 3_600) }

  /// A stale subscription answers for nothing however low it is; an amount-of-limit window
  /// (`$2.00 of $40.00`) and a balance have no meter to compete with; a tie goes to the first.
  @Test func theTightestIsTheLowestMeteredWindowOfACurrentSubscription() {
    let subscriptions = [
      Subscription(name: "stale", current: false, windows: [Window(title: "5h", usedPercent: 99)]),
      Subscription(
        name: "cursor", current: true,
        windows: [
          Window(
            title: "Included", usedPercent: 95, remainingValue: 2, limitValue: 40,
            remainingUnit: .usd),
          Window(title: "Wallet", usedPercent: 0, remainingValue: 1),
          Window(title: "Other Models", usedPercent: 70),
        ]),
      Subscription(
        name: "codex", current: true, windows: [Window(title: "Weekly", usedPercent: 70)]),
    ]
    let choice = TightestWindow.choose(
      in: subscriptions, isCurrent: \.current, windows: \.windows)
    #expect(choice?.subscription.name == "cursor")
    #expect(choice?.window.title == "Other Models")
    #expect(choice?.remainingPercent == 30)
  }

  /// A 10-hour window 40% through stands at 60; one with too little elapsed or used, or no
  /// cadence, draws no tick, matching where the pace rule gives no line.
  @Test func theEvenPaceTickIsTheShareOfTheWindowStillAhead() {
    let reading = QuotaPaceReading(
      usedPercent: 50, resetsAt: Self.at(hours: 6), cadenceSeconds: 36_000, isBalanceOnly: false)
    #expect(EvenPacePosition.remainingPercent(reading, now: Self.now) == 60)
    let justStarted = QuotaPaceReading(
      usedPercent: 50, resetsAt: Self.at(hours: 9.9), cadenceSeconds: 36_000, isBalanceOnly: false)
    #expect(EvenPacePosition.remainingPercent(justStarted, now: Self.now) == nil)
    let noCadence = QuotaPaceReading(
      usedPercent: 50, resetsAt: Self.at(hours: 6), cadenceSeconds: nil, isBalanceOnly: false)
    #expect(EvenPacePosition.remainingPercent(noCadence, now: Self.now) == nil)
  }

  /// Windows resetting in the same minute share one mark coloured by the lower remaining; a
  /// reset past seven days, one already passed, and a stale subscription draw nothing.
  @Test func nextResetsGroupsAMinuteAndKeepsSevenDaysOfCurrentSubscriptions() {
    let weekly = Window(title: "Weekly", usedPercent: 20, resetsAt: Self.at(hours: 30))
    let opus = Window(
      title: "Weekly Opus", usedPercent: 60, resetsAt: Self.at(hours: 30).addingTimeInterval(20))
    let fiveHour = Window(title: "5 Hours", usedPercent: 10, resetsAt: Self.at(hours: 2))
    let subscriptions = [
      Subscription(
        name: "claude", current: true,
        windows: [
          weekly, fiveHour, opus,
          Window(title: "Monthly", usedPercent: 0, resetsAt: Self.at(hours: 24 * 7 + 1)),
          Window(title: "Passed", usedPercent: 0, resetsAt: Self.at(hours: -1)),
        ]),
      Subscription(
        name: "stale", current: false,
        windows: [Window(title: "5 Hours", usedPercent: 0, resetsAt: Self.at(hours: 1))]),
      Subscription(
        name: "copilot", current: true,
        windows: [Window(title: "Monthly", usedPercent: 0, resetsAt: Self.at(hours: 24 * 8))]),
    ]
    let lanes = NextResets.lanes(
      in: subscriptions, isCurrent: \.current, windows: \.windows, now: Self.now)
    #expect(lanes.map(\.subscription.name) == ["claude"])
    #expect(
      lanes[0].resets == [
        NextResetInstant(at: Self.at(hours: 2), windows: [fiveHour], lowestRemainingPercent: 90),
        NextResetInstant(
          at: Self.at(hours: 30), windows: [weekly, opus], lowestRemainingPercent: 40),
      ])
  }
}
