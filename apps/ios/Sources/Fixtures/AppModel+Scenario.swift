import Foundation
import QuotaAccount
import QuotaAlerts
import QuotaProviderSessions
import QuotaRelay
import QuotaWidgetData

#if DEBUG
  extension AppModel {
    /// Build a model from a visual scenario. Does not touch network or Keychain.
    /// Pass an explicit `now` (tests: `VisualFixture.referenceDate`; launch: reference date
    /// unless `--visual-clock wall`).
    static func visualFixture(
      _ fixture: VisualFixture,
      now: Date,
      clockIsFixed: Bool = true,
      selectionSaltStore: any SelectionSaltStore = InMemorySelectionSaltStore(),
      budgetStore: UsageBudgetStore = VisualFixtureContent.budgetStore()
    ) -> AppModel {
      visualFixture(
        fixture,
        now: { now },
        clockIsFixed: clockIsFixed,
        selectionSaltStore: selectionSaltStore,
        budgetStore: budgetStore
      )
    }

    static func visualFixture(
      _ fixture: VisualFixture,
      now: @escaping @Sendable () -> Date,
      clockIsFixed: Bool = true,
      selectionSaltStore: any SelectionSaltStore = InMemorySelectionSaltStore(),
      budgetStore: UsageBudgetStore = VisualFixtureContent.budgetStore()
    ) -> AppModel {
      let instant = now()
      let scenario = VisualScenario.make(fixture, now: instant)
      let settingsDefaults = UserDefaults(
        suiteName: "Quota.VisualSettings.\(UUID().uuidString)"
      )!
      let model = AppModel(
        account: AccountClient(
          relay: RelayClient(transport: FixtureBlockedHTTPTransport()),
          sessionStore: MemoryAccountSessionStore(),
          summaryStore: MemoryAccountSummaryStore(),
          settingsStore: MemoryAccountSettingsStore(),
          now: now
        ),
        authenticator: FixtureBlockedAuthenticator(),
        widgetPublisher: NoOpWidgetSnapshotPublisher(),
        selectionSaltStore: selectionSaltStore,
        activity: FixtureActivityLoader(
          days: scenario.activityLoaderDays,
          populatedAgents: VisualFixtureContent.dayAgents(),
          usage: scenario.activityLoaderUsage,
          now: instant
        ),
        providerSessions: MemoryProviderSessionStore(sessions: scenario.providerSessions),
        localStore: MemoryLocalCollectionStore(),
        localCollector: LocalCollector(
          sessions: MemoryProviderSessionStore(),
          collectors: { _, _ in nil },
          now: now
        ),
        budgetStore: budgetStore,
        settingsDefaults: settingsDefaults,
        syncAccountSettings: true,
        now: now
      )
      scenario.apply(to: model, clockIsFixed: clockIsFixed)
      model.resolvePendingSubscriptionSelection()
      return model
    }
  }
#endif
