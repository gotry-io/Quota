import Foundation
import QuotaAlerts
import QuotaPresentation
import QuotaWire
import Testing

@testable import Quota

#if DEBUG
  @MainActor
  struct UsagePeriodBudgetTests {
    private static let now = VisualFixture.referenceDate

    private func loadedModel(amountUSD: Decimal? = 50) async -> AppModel {
      let model = AppModel.visualFixture(
        .content,
        now: Self.now,
        budgetStore: VisualFixtureContent.budgetStore(amountUSD: amountUSD)
      )
      await model.loadActivity()
      return model
    }

    /// The four the summary folds are read; anything else is added up from the activity days.
    @Test
    func readsTheSummaryForItsFourPeriodsAndFoldsTheRest() async {
      let model = await loadedModel()
      model.usagePeriod = .today
      #expect(!model.usagePeriodIsFolded)
      #expect(model.usagePeriodValue?.totals == model.summary?.usage.today.totals)

      model.usagePeriod = .thisMonth
      #expect(model.usagePeriodIsFolded)
      guard let range = model.usagePeriodRange else {
        Issue.record("This month names a range")
        return
      }
      let expected = UsageDayFold.period(model.activityDays, from: range.from, to: range.to)
      #expect(model.usagePeriodValue?.totals == expected.totals)
      // A folded period has no breakdown: a day carries agents only when asked for on its own.
      #expect(model.usagePeriodValue?.agents.isEmpty == true)
    }

    @Test
    func stepsAWeekBackAndForwardAndStopsAtThisWeek() async {
      let model = await loadedModel()
      model.usagePeriod = .thisWeek
      let thisWeek = model.usagePeriodRange?.from
      model.selectUsagePeriod(model.usagePeriod.previous ?? .thisWeek)
      #expect(model.usagePeriod == .week(offset: 1))
      #expect(model.usagePeriodRange?.from != thisWeek)
      model.selectUsagePeriod(model.usagePeriod.next ?? .thisWeek)
      #expect(model.usagePeriod == .thisWeek)
      #expect(model.usagePeriod.next == nil)
    }

    @Test
    func aCustomRangeFoldsExactlyTheDaysItNames() async {
      let model = await loadedModel()
      let day = model.activityToday
      model.selectUsagePeriod(.custom(from: day, to: day))
      #expect(model.usagePeriodIsFolded)
      let expected = UsageDayFold.period(model.activityDays, from: day, to: day)
      #expect(model.usagePeriodValue?.totals == expected.totals)
    }

    @Test
    func aBudgetMeasuresThisMonthAndNoBudgetMeasuresNothing() async {
      let model = await loadedModel()
      guard let progress = model.budgetProgress else {
        Issue.record("A budget of $50 has progress")
        return
      }
      #expect(progress.budgetUSD == 50)
      #expect(progress.percent >= 0)
      #expect(progress.text.contains("$50.00"))

      let none = await loadedModel(amountUSD: nil)
      #expect(none.budgetProgress == nil)
    }

    @Test
    func aBudgetIsStoredAndReadBack() {
      let defaults = UserDefaults(suiteName: "io.gotry.quota.budget-test")!
      defaults.removePersistentDomain(forName: "io.gotry.quota.budget-test")
      let store = UsageBudgetStore(defaults: defaults)
      #expect(!store.load().isSet)

      store.save(UsageBudget(amountUSD: 40, alerts: false))
      #expect(store.load().amountUSD == 40)
      #expect(!store.load().alerts)

      store.save(UsageBudget(amountUSD: 0, alerts: true))
      #expect(!store.load().isSet)

      let fired = AlertDedupState(
        fired: [
          AlertDedupKey(
            kind: .budget,
            selector: BudgetAlertEvaluator.selector,
            windowID: "2026-09",
            resetsAt: nil,
            threshold: 80
          )
        ],
        readings: []
      )
      store.saveFired(fired)
      #expect(store.loadFired() == fired)
      defaults.removePersistentDomain(forName: "io.gotry.quota.budget-test")
    }
  }
#endif
