# ADR 0053: One alert delivery package for both Apple apps

- Status: Accepted
- Date: 2026-09-18
- Related: [ADR 0043](./0043-one-widget-view-package-for-both-platforms.md),
  [ADR 0014](./0014-nonsecret-ios-widget-snapshot.md)
- Amended: 2026-09-21 by [ADR 0061](./0061-alert-policy-and-the-budget-follow-the-account.md):
  the shipped UserDefaults keys remain; they are now a local copy of Account policy. `enabled`
  and dedup state stay per device.

## Context

Quota iOS and QuotaBar evaluate the same remaining-quota rules through `QuotaAlerts` and post the
same `AlertCopy` through `UNUserNotificationCenter`. Until now each app owned its own copy of the
delivery layer: the notification-center slice, the sink, the reset-reminder scheduler, the
UserDefaults adapter for `AlertRules`, and the owner-only JSON state file.

After renaming `Alert` → `Notification` and dropping the `IOS` prefix, the two copies drifted by
the amount a second owner always drifts. `AlertSink` versus `NotificationSink` differed by 32
lines, `IOSResetReminderScheduler` versus `ResetReminderScheduler` by 22, `NotificationCentering`
by one class name and a doc comment, `IOSAlertStateStore` versus `NotificationStateStore` by the
file name, directory, and `#if os(iOS)` protection flags, and `IOSAlertRulesStore` versus
`NotificationRules` by the UserDefaults key prefix. ADR 0043 already refused a second widget
description for the same reason.

Quota iOS 0.0.3 ships UserDefaults keys `alerts.enabled|resetReminders|paceAlerts|thresholds` and
the state file `<Application Support>/alert-state.json`. QuotaBar 0.2.2 ships
`notifications.enabled|resetReminders|paceAlerts|thresholds` and
`<Application Support>/QuotaBar/notification-state.json`. Those names are released constraints.

A widget extension still must not link UserNotifications or hold alert state
([ADR 0014](./0014-nonsecret-ios-widget-snapshot.md)).

## Decision

`packages/apple-shared` grows a `QuotaAlertDelivery` target and product. It depends on
`QuotaAlerts` and `QuotaPresentation` and links `UserNotifications`, which exists on both
platforms. `QuotaAlerts` itself stays Foundation-only and does not link UserNotifications.

The package owns one public copy of each delivery type, taking the QuotaBar naming except where
the package is named after alerts:

- `NotificationCentering`, `SystemNotificationCenter`, `NoOpNotificationCenter`
- `AlertDeliveryCatalog`
- `AlertSink`, `NoOpAlertSink`, `UserNotificationAlertSink`
- `ResetReminderScheduler`
- `AlertStateStore`, `InMemoryAlertStateStore`, `FileAlertStateStore`
- `AlertRulesStore`

`FileAlertStateStore` takes `init(fileURL: URL)` and writes mode 0600, complete file protection
on iOS, and excluded-from-backup. It has no `applicationSupport()` factory: each app builds its
own URL. `AlertRulesStore` takes `init(defaults:keyPrefix:)` and names keys
`"\(keyPrefix).enabled"`, `.resetReminders`, `.paceAlerts`, and `.thresholds`.

Quota iOS constructs `AlertRulesStore(keyPrefix: "alerts")` and
`FileAlertStateStore(fileURL: applicationSupport/alert-state.json)`. QuotaBar constructs
`AlertRulesStore(keyPrefix: "notifications")` and
`FileAlertStateStore(fileURL: applicationSupport/QuotaBar/notification-state.json)`. There is no
fallback read of the other app's keys or file.

Each app keeps what is not delivery: Quota iOS keeps `AlertCoordinator`, which maps
`QuotaSubscription` to readings. QuotaBar keeps `NotificationOverview`,
`NotificationSettingsSubscription`, `NotificationsSettingsCopy`, and `NotificationRules` as the
Notifications page's threshold-choice list plus that app's `AlertRulesStore` factory.

Widget extensions do not link `QuotaAlertDelivery`.

## Consequences

- A delivery change is now one change. An iOS-only or macOS-only protection rule has to say which
  platform it is for, in the shared store, where the other platform's behaviour is visible next to
  it.
- Shipped UserDefaults keys and state file names stay what those releases wrote. Changing a prefix
  or file name is a new decision, not an addition to this one. After
  [ADR 0061](./0061-alert-policy-and-the-budget-follow-the-account.md) those keys are a local copy
  of the Account settings document (`resetReminders`, `paceAlerts`, `thresholds`, and the budget
  amount and its alert switch). `enabled` is still this device's notification permission, and the
  state file is still this device's dedup.
- `packages/apple-shared` is no longer Foundation-only in every target. Presentation, alerts, and
  observation merge stay Foundation-only; delivery is the target that talks to UserNotifications.
