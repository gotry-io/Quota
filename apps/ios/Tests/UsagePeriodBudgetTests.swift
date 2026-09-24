import Foundation
import QuotaAlerts
import QuotaPresentation
import QuotaWire
import Testing

@testable import Quota

#if DEBUG
  @MainActor
  struct UsagePeriodBudgetTests {
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
