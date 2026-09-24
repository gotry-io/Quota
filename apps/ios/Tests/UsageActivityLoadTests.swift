import Foundation
import QuotaAccount
import QuotaRelay
import QuotaWire
import Testing

@testable import Quota

@MainActor
struct UsageActivityLoadTests {
  @Test
  func restoreDoesNotFetchActivity() async {
    let loader = ScriptedActivityLoader(results: [])
    let model = makeActivityAppModel(loader: loader, session: true)
    await model.restore()
    #expect(await loader.calls.isEmpty)
    #expect(model.usage.activityChart == .idle)
  }

  @Test
  func returningToTheForegroundReloadsLoadedActivity() async {
    let loader = ScriptedActivityLoader(results: [
      .activity(AccountUsageActivityResponse(days: [emptyDay("2026-08-14")])),
      .activity(AccountUsageActivityResponse(days: [emptyDay("2026-08-13")])),
    ])
    let model = makeActivityAppModel(loader: loader, session: true)
    model.phase = .signedIn
    await model.usage.loadActivity()
    #expect(await loader.calls.count == 1)
    await model.setForeground(true)
    #expect(await loader.calls.count == 2)
    guard case .loaded(let days) = model.usage.activityChart else {
      Issue.record("expected loaded chart, got \(model.usage.activityChart)")
      return
    }
    #expect(days.map(\.date) == ["2026-08-13"])
  }

  @Test
  func logoutClearsActivityMemory() async {
    let loader = ScriptedActivityLoader(results: [
      .activity(AccountUsageActivityResponse(days: [emptyDay("2026-08-14")]))
    ])
    let model = makeActivityAppModel(loader: loader, session: true)
    model.phase = .signedIn
    await model.usage.loadActivity()
    await model.usage.openActivityDay(date: "2026-08-14")
    await model.logout()
    #expect(model.usage.activityChart == .idle)
    #expect(model.usage.activityDaySheet == nil)
    #expect(model.usage.usagePeriod == .last30Days)
  }
}
