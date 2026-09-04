import Foundation
import QuotaAccount
import QuotaAlerts
import QuotaWire
import Testing
import UserNotifications

@testable import Quota

struct IOSAlertSinkTests {
  @Test func dedupKeyIdentifierEncodesSelectorWindowResetAndThreshold() {
    let resetsAt = Date(timeIntervalSince1970: 1_786_300_000)
    #expect(
      AlertDedupKey(
        selector: "ccfc96629357", windowID: "weekly", resetsAt: resetsAt, threshold: 20
      ).requestIdentifier == "threshold:ccfc96629357:weekly:1786300000:20"
    )
    #expect(
      AlertDedupKey(
        selector: "ccfc96629357", windowID: "weekly", resetsAt: resetsAt, threshold: nil
      ).requestIdentifier == "reset:ccfc96629357:weekly:1786300000"
    )
  }

  @Test func thresholdCrossedPostsImmediatelyWithCopyAndDedupIdentifier() throws {
    let center = FakeNotificationCenter()
    let sink = IOSAlertSink(center: center)
    let now = Date(timeIntervalSince1970: 1_786_300_000)
    sink.now = now
    sink.timeZone = TimeZone(secondsFromGMT: 0)!
    sink.calendar = utcCalendar()
    sink.catalog = AlertDeliveryCatalog(entries: [
      "ccfc96629357": .init(providerDisplayName: "Codex", windows: ["weekly": "Weekly"])
    ])

    sink.deliver([
      .thresholdCrossed(
        selector: "ccfc96629357",
        windowID: "weekly",
        threshold: 20,
        remainingPercent: 12,
        resetsAt: now.addingTimeInterval(42 * 60)
      )
    ])

    #expect(center.added.count == 1)
    let request = try #require(center.added.first)
    #expect(
      request.identifier
        == AlertDedupKey(
          selector: "ccfc96629357",
          windowID: "weekly",
          resetsAt: now.addingTimeInterval(42 * 60),
          threshold: 20
        ).requestIdentifier
    )
    #expect(request.content.threadIdentifier == "ccfc96629357")
    #expect(request.content.title == "Codex · Weekly")
    #expect(request.content.body == "12% left · resets in 42m")
    #expect(request.trigger == nil)
  }

  @Test func windowResetPostsImmediatelyWhenNothingIsScheduled() {
    let center = FakeNotificationCenter()
    let sink = IOSAlertSink(center: center)
    sink.catalog = AlertDeliveryCatalog(entries: [
      "ccfc96629357": .init(providerDisplayName: "Codex", windows: ["weekly": "Weekly"])
    ])

    sink.deliver([.windowReset(selector: "ccfc96629357", windowID: "weekly", resetsAt: nil)])

    #expect(center.added.count == 1)
    #expect(center.added.first?.content.title == "Codex · Weekly")
    #expect(center.added.first?.content.body == "Weekly quota reset")
    #expect(center.added.first?.trigger == nil)
  }

  @Test func windowResetIsSkippedWhenAReminderIsAlreadyScheduledForThatWindow() {
    let center = FakeNotificationCenter()
    let sink = IOSAlertSink(center: center)
    sink.catalog = AlertDeliveryCatalog(entries: [
      "ccfc96629357": .init(providerDisplayName: "Codex", windows: ["weekly": "Weekly"])
    ])
    sink.scheduledResetKeys = [IOSAlertSink.resetKey(selector: "ccfc96629357", windowID: "weekly")]

    sink.deliver([
      .windowReset(
        selector: "ccfc96629357",
        windowID: "weekly",
        resetsAt: Date(timeIntervalSince1970: 1_786_400_000)
      )
    ])

    #expect(center.added.isEmpty)
  }
}

struct IOSResetReminderSchedulerTests {
  @Test func availablePrimaryWindowWithAFutureResetIsBookedOnTheCalendar() throws {
    let center = FakeNotificationCenter()
    let calendar = utcCalendar()
    let scheduler = IOSResetReminderScheduler(center: center, calendar: calendar)
    let now = Date(timeIntervalSince1970: 1_786_300_000)
    let resetsAt = now.addingTimeInterval(3_600)
    let selector = "ccfc96629357"
    let catalog = AlertDeliveryCatalog(entries: [
      selector: .init(providerDisplayName: "Codex", windows: ["weekly": "Weekly"])
    ])

    scheduler.reschedule(
      rules: AlertRules(enabled: true, resetReminders: true),
      subscriptions: [
        AlertSubscriptionReading(
          selector: selector,
          status: "available",
          windows: [
            AlertWindowReading(
              id: "weekly",
              title: "Weekly",
              remainingPercent: 40,
              resetsAt: resetsAt,
              primaryCadence: "weekly"
            )
          ]
        )
      ],
      catalog: catalog,
      now: now
    )

    #expect(center.removedAllPendingCount == 1)
    #expect(center.pending.count == 1)
    let request = try #require(center.pending.first)
    #expect(
      request.identifier
        == AlertDedupKey(
          selector: selector, windowID: "weekly", resetsAt: resetsAt, threshold: nil
        ).requestIdentifier
    )
    #expect(request.content.title == "Codex · Weekly")
    #expect(request.content.body == "Weekly quota reset")
    #expect(request.content.threadIdentifier == selector)
    let trigger = try #require(request.trigger as? UNCalendarNotificationTrigger)
    #expect(!trigger.repeats)
    #expect(trigger.dateComponents.year == calendar.component(.year, from: resetsAt))
    #expect(trigger.dateComponents.month == calendar.component(.month, from: resetsAt))
    #expect(trigger.dateComponents.day == calendar.component(.day, from: resetsAt))
    #expect(trigger.dateComponents.hour == calendar.component(.hour, from: resetsAt))
    #expect(trigger.dateComponents.minute == calendar.component(.minute, from: resetsAt))
    #expect(trigger.dateComponents.second == calendar.component(.second, from: resetsAt))
    #expect(scheduler.hasScheduledReset(selector: selector, windowID: "weekly"))
  }

  @Test func aNewReadingReplacesThePreviousReminderForTheSameWindow() throws {
    let center = FakeNotificationCenter()
    let scheduler = IOSResetReminderScheduler(center: center, calendar: utcCalendar())
    let now = Date(timeIntervalSince1970: 1_786_300_000)
    let first = now.addingTimeInterval(3_600)
    let second = now.addingTimeInterval(7_200)
    let selector = "ccfc96629357"
    let catalog = AlertDeliveryCatalog(entries: [
      selector: .init(providerDisplayName: "Codex", windows: ["weekly": "Weekly"])
    ])
    let subscription = { (resetsAt: Date) in
      AlertSubscriptionReading(
        selector: selector,
        status: "available",
        windows: [
          AlertWindowReading(
            id: "weekly",
            title: "Weekly",
            remainingPercent: 40,
            resetsAt: resetsAt,
            primaryCadence: "weekly"
          )
        ]
      )
    }
    let rules = AlertRules(enabled: true, resetReminders: true)

    scheduler.reschedule(
      rules: rules, subscriptions: [subscription(first)], catalog: catalog, now: now)
    let firstID = try #require(center.pending.first?.identifier)

    scheduler.reschedule(
      rules: rules, subscriptions: [subscription(second)], catalog: catalog, now: now)

    #expect(center.removedAllPendingCount == 2)
    #expect(center.pending.count == 1)
    #expect(center.pending.first?.identifier != firstID)
    #expect(
      center.pending.first?.identifier
        == AlertDedupKey(
          selector: selector, windowID: "weekly", resetsAt: second, threshold: nil
        ).requestIdentifier
    )
  }

  @Test func disabledRulesAndSignOutClearEveryPendingReminder() {
    let center = FakeNotificationCenter()
    let scheduler = IOSResetReminderScheduler(center: center, calendar: utcCalendar())
    let now = Date(timeIntervalSince1970: 1_786_300_000)
    let selector = "ccfc96629357"
    let catalog = AlertDeliveryCatalog(entries: [
      selector: .init(providerDisplayName: "Codex", windows: ["weekly": "Weekly"])
    ])
    scheduler.reschedule(
      rules: AlertRules(enabled: true, resetReminders: true),
      subscriptions: [
        AlertSubscriptionReading(
          selector: selector,
          status: "available",
          windows: [
            AlertWindowReading(
              id: "weekly",
              title: "Weekly",
              remainingPercent: 40,
              resetsAt: now.addingTimeInterval(3_600),
              primaryCadence: "weekly"
            )
          ]
        )
      ],
      catalog: catalog,
      now: now
    )
    #expect(!center.pending.isEmpty)

    scheduler.reschedule(
      rules: AlertRules(enabled: false, resetReminders: true),
      subscriptions: [],
      catalog: catalog,
      now: now
    )
    #expect(center.pending.isEmpty)
    #expect(!scheduler.hasScheduledReset(selector: selector, windowID: "weekly"))

    scheduler.reschedule(
      rules: AlertRules(enabled: true, resetReminders: true),
      subscriptions: [
        AlertSubscriptionReading(
          selector: selector,
          status: "available",
          windows: [
            AlertWindowReading(
              id: "weekly",
              title: "Weekly",
              remainingPercent: 40,
              resetsAt: now.addingTimeInterval(3_600),
              primaryCadence: "weekly"
            )
          ]
        )
      ],
      catalog: catalog,
      now: now
    )
    scheduler.removeAll()
    #expect(center.pending.isEmpty)
    #expect(center.removedAllPendingCount >= 3)
  }

  @Test func pastResetsAndUnavailableSubscriptionsAreNotBooked() {
    let center = FakeNotificationCenter()
    let scheduler = IOSResetReminderScheduler(center: center, calendar: utcCalendar())
    let now = Date(timeIntervalSince1970: 1_786_300_000)
    let catalog = AlertDeliveryCatalog(entries: [
      "a": .init(providerDisplayName: "Codex", windows: ["weekly": "Weekly"]),
      "b": .init(providerDisplayName: "Claude Code", windows: ["five_hour": "5 Hours"]),
    ])

    scheduler.reschedule(
      rules: AlertRules(enabled: true, resetReminders: true),
      subscriptions: [
        AlertSubscriptionReading(
          selector: "a",
          status: "available",
          windows: [
            AlertWindowReading(
              id: "weekly",
              title: "Weekly",
              remainingPercent: 40,
              resetsAt: now.addingTimeInterval(-60),
              primaryCadence: "weekly"
            )
          ]
        ),
        AlertSubscriptionReading(
          selector: "b",
          status: "auth_required",
          windows: [
            AlertWindowReading(
              id: "five_hour",
              title: "5 Hours",
              remainingPercent: 10,
              resetsAt: now.addingTimeInterval(3_600),
              primaryCadence: "five_hour"
            )
          ]
        ),
      ],
      catalog: catalog,
      now: now
    )

    #expect(center.pending.isEmpty)
  }
}

@MainActor
struct AlertDeliveryAppModelTests {
  @Test func successfulRefreshPostsThresholdAndBooksResetReminder() async throws {
    let defaults = isolatedAlertDefaults()
    defer { defaults.tearDown() }
    IOSAlertRulesStore(defaults: defaults.store).save(
      AlertRules(enabled: true, resetReminders: true)
    )
    let center = FakeNotificationCenter()
    let now = Fixtures.date("2026-08-14T16:00:00Z")
    let resetsAt = Fixtures.date("2026-08-18T00:00:00Z")
    let model = makeModel(
      session: Fixtures.session(),
      cache: nil,
      exchanges: [
        .init(status: 200, body: try alertSummaryJSON()),
        .init(status: 200, body: try alertSummaryJSON()),
      ],
      alertRulesStore: IOSAlertRulesStore(defaults: defaults.store),
      notificationCenter: center,
      now: { now }
    )

    #expect(await model.refresh())
    let thresholdPosts = center.added.filter { $0.trigger == nil }
    #expect(thresholdPosts.count == 1)
    let threshold = try #require(thresholdPosts.first)
    #expect(
      threshold.identifier
        == AlertDedupKey(
          selector: "ccfc96629357",
          windowID: "weekly",
          resetsAt: resetsAt,
          threshold: 20
        ).requestIdentifier
    )
    #expect(threshold.content.threadIdentifier == "ccfc96629357")
    #expect(threshold.content.title == "Codex · Weekly")
    #expect(center.pending.count == 1)
    let reminder = try #require(center.pending.first)
    #expect(
      reminder.identifier
        == AlertDedupKey(
          selector: "ccfc96629357", windowID: "weekly", resetsAt: resetsAt, threshold: nil
        ).requestIdentifier
    )
    #expect(reminder.content.title == "Codex · Weekly")
    #expect(reminder.content.body == "Weekly quota reset")
    #expect(reminder.trigger is UNCalendarNotificationTrigger)

    #expect(await model.refresh())
    #expect(center.added.filter { $0.trigger == nil }.count == 1)
    #expect(center.pending.count == 1)
    #expect(
      center.pending.first?.identifier
        == AlertDedupKey(
          selector: "ccfc96629357", windowID: "weekly", resetsAt: resetsAt, threshold: nil
        ).requestIdentifier
    )
  }

  @Test func aNewSummaryReplacesTheBookedResetReminder() async throws {
    let defaults = isolatedAlertDefaults()
    defer { defaults.tearDown() }
    IOSAlertRulesStore(defaults: defaults.store).save(
      AlertRules(enabled: true, resetReminders: true)
    )
    let center = FakeNotificationCenter()
    let now = Fixtures.date("2026-08-14T16:00:00Z")
    let firstReset = Fixtures.date("2026-08-18T00:00:00Z")
    let secondReset = Fixtures.date("2026-08-25T00:00:00Z")
    let model = makeModel(
      session: Fixtures.session(),
      cache: nil,
      exchanges: [
        .init(status: 200, body: try alertSummaryJSON(resetsAt: "2026-08-18T00:00:00Z")),
        .init(status: 200, body: try alertSummaryJSON(resetsAt: "2026-08-25T00:00:00Z")),
      ],
      alertRulesStore: IOSAlertRulesStore(defaults: defaults.store),
      notificationCenter: center,
      now: { now }
    )

    #expect(await model.refresh())
    let firstID = try #require(center.pending.first?.identifier)
    #expect(
      firstID
        == AlertDedupKey(
          selector: "ccfc96629357", windowID: "weekly", resetsAt: firstReset, threshold: nil
        ).requestIdentifier
    )

    #expect(await model.refresh())
    #expect(center.removedAllPendingCount == 2)
    #expect(center.pending.count == 1)
    #expect(center.pending.first?.identifier != firstID)
    #expect(
      center.pending.first?.identifier
        == AlertDedupKey(
          selector: "ccfc96629357", windowID: "weekly", resetsAt: secondReset, threshold: nil
        ).requestIdentifier
    )
  }

  @Test func logoutRemovesEveryPendingReminder() async throws {
    let defaults = isolatedAlertDefaults()
    defer { defaults.tearDown() }
    IOSAlertRulesStore(defaults: defaults.store).save(
      AlertRules(enabled: true, resetReminders: true)
    )
    let center = FakeNotificationCenter()
    let model = makeModel(
      session: Fixtures.session(),
      cache: CachedAccountSummary(
        summary: try WireCodec.decode(AccountSummary.self, from: try alertSummaryJSON()),
        fetchedAt: Fixtures.date("2026-08-14T15:00:00Z")
      ),
      exchanges: [
        .init(status: 200, body: try alertSummaryJSON()),
        .init(status: 204, body: Data()),
      ],
      alertRulesStore: IOSAlertRulesStore(defaults: defaults.store),
      notificationCenter: center,
      now: { Fixtures.date("2026-08-14T16:00:00Z") }
    )

    #expect(await model.refresh())
    #expect(!center.pending.isEmpty)

    await model.logout()
    #expect(center.pending.isEmpty)
    #expect(center.removedAllPendingCount >= 2)
  }
}

final class FakeNotificationCenter: NotificationCentering, @unchecked Sendable {
  var authorizationStatusValue: UNAuthorizationStatus = .notDetermined
  var requestAuthorizationGranted = true
  var requestedOptions: UNAuthorizationOptions?
  var added: [UNNotificationRequest] = []
  var pending: [UNNotificationRequest] = []
  var removedAllPendingCount = 0

  func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
    requestedOptions = options
    if requestAuthorizationGranted {
      authorizationStatusValue = .authorized
    } else {
      authorizationStatusValue = .denied
    }
    return requestAuthorizationGranted
  }

  func authorizationStatus() async -> UNAuthorizationStatus {
    authorizationStatusValue
  }

  func add(_ request: UNNotificationRequest) {
    added.append(request)
    if request.trigger != nil {
      pending.removeAll { $0.identifier == request.identifier }
      pending.append(request)
    }
  }

  func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
    pending.removeAll { identifiers.contains($0.identifier) }
  }

  func removeAllPendingNotificationRequests() {
    removedAllPendingCount += 1
    pending.removeAll()
  }
}

private func utcCalendar() -> Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(secondsFromGMT: 0)!
  return calendar
}
