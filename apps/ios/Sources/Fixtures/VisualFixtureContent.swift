import Foundation
import QuotaAccount
import QuotaAlerts
import QuotaPresentation
import QuotaProviderSessions
import QuotaProviderStatus
import QuotaRelay
import QuotaWidgetData
import QuotaWire

#if DEBUG
@MainActor
enum VisualFixtureContent {
  static let studioDeviceID = "device_visual_fixture_01"
  static let kitchenDeviceID = "device_visual_fixture_02"
  /// This phone, as the Account lists it. A signed-in phone registers a Device
  /// ([ADR 0041](../../../docs/decisions/0041-ios-is-a-device-when-sync-is-paid.md)), so the
  /// fixture states the row rather than the one Devices used to draw for itself.
  static let phoneDeviceID = "device_visual_fixture_03"
  /// A fixture keeps its budget in its own suite, so a screenshot never reads or writes the
  /// preference a real install has.
  static let budgetSuiteName = "io.gotry.quota.visual-fixture"

  /// A $50 budget with alerts on, which is what the Usage screenshot shows a bar against.
  static func budgetStore(amountUSD: Decimal? = 50) -> UsageBudgetStore {
    let defaults = UserDefaults(suiteName: budgetSuiteName) ?? .standard
    defaults.removePersistentDomain(forName: budgetSuiteName)
    let store = UsageBudgetStore(defaults: defaults)
    store.save(UsageBudget(amountUSD: amountUSD, alerts: true))
    return store
  }

  static func devices(at date: Date) -> [AccountDevice] {
    [
      AccountDevice(
        id: studioDeviceID,
        displayName: "Studio Mac",
        platform: .macos,
        lastSeenAt: date.addingTimeInterval(-45),
        lastObservedAt: date.addingTimeInterval(-90)
      ),
      AccountDevice(
        id: kitchenDeviceID,
        displayName: "Kitchen Mac",
        platform: .macos,
        lastSeenAt: date.addingTimeInterval(-300),
        lastObservedAt: date.addingTimeInterval(-360)
      ),
      AccountDevice(
        id: phoneDeviceID,
        displayName: "Kyle iPhone",
        platform: .ios,
        lastSeenAt: date.addingTimeInterval(-20),
        lastObservedAt: date.addingTimeInterval(-30)
      ),
    ]
  }

  static func incidentStatus(at date: Date) -> [ProviderID: ProviderStatusReading] {
    [
      .claude: ProviderStatusReading(
        provider: .claude,
        indicator: .minor,
        description: "Partial System Outage",
        checkedAt: date
      )
    ]
  }

  static func summary(
    at date: Date
  ) -> AccountSummary {
    let studioID = studioDeviceID
    let kitchenID = kitchenDeviceID
    let subscriptions = [
      codexSubscription(studioID: studioID, kitchenID: kitchenID, at: date),
      subscription(
        provider: .claude,
        deviceID: studioID,
        fingerprint: "visual_claude",
        label: "Team workspace",
        plan: "Max",
        windows: [
          window(
            id: "five_hour",
            title: "5 Hours",
            usedPercent: 47,
            resetsAt: date.addingTimeInterval(9_000),
            durationSeconds: 18_000
          )
        ],
        observedAt: date.addingTimeInterval(-120),
      ),
      subscription(
        provider: .grok,
        deviceID: studioID,
        fingerprint: "visual_grok",
        label: nil,
        plan: "SuperGrok",
        windows: [
          window(
            id: "monthly",
            title: "Monthly",
            usedPercent: 73,
            resetsAt: date.addingTimeInterval(12 * 86_400)
          )
        ],
        observedAt: date.addingTimeInterval(-180),
      ),
    ]

    return AccountSummary(
      account: QuotaUserAccount(
        accountID: "account_visual_octocat",
        displayLabel: "octocat",
        createdAt: date.addingTimeInterval(-30 * 86_400)
      ),
      devices: devices(at: date),
      subscriptions: subscriptions,
      usage: usage(),
      pricingRevision: "pricing_visual_fixture",
      modelCatalogRevision: "models_visual_fixture"
    )
  }

  static func emptySummary(
    at date: Date,
    devices: [AccountDevice] = []
  ) -> AccountSummary {
    AccountSummary(
      account: QuotaUserAccount(
        accountID: "account_visual_empty",
        displayLabel: "octocat",
        createdAt: date.addingTimeInterval(-30 * 86_400)
      ),
      devices: devices,
      subscriptions: [],
      usage: emptyUsage(),
      pricingRevision: "pricing_visual_fixture",
      modelCatalogRevision: "models_visual_fixture"
    )
  }

  private static func usage() -> AccountUsage {
    AccountUsage(
      today: period(
        input: 1_420_500,
        output: 284_120,
        cacheRead: 480_000,
        cacheWrite: 20_000,
        reasoning: 92_400,
        messages: 164,
        microusd: "1489234",
        scale: 1
      ),
      last7Days: period(
        input: 3_800_000,
        output: 760_000,
        cacheRead: 1_000_000,
        cacheWrite: 40_000,
        reasoning: 240_000,
        messages: 410,
        microusd: "3200000",
        scale: 3
      ),
      last30Days: period(
        input: 9_500_000,
        output: 1_900_000,
        cacheRead: 2_500_000,
        cacheWrite: 80_000,
        reasoning: 600_000,
        messages: 980,
        microusd: "8500000",
        scale: 8
      ),
      all: period(
        input: 18_000_000,
        output: 3_600_000,
        cacheRead: 5_000_000,
        cacheWrite: 150_000,
        reasoning: 1_100_000,
        messages: 1_800,
        microusd: "16200000",
        scale: 15
      )
    )
  }

  private static func period(
    input: Int,
    output: Int,
    cacheRead: Int,
    cacheWrite: Int,
    reasoning: Int,
    messages: Int,
    microusd: String,
    scale: Int
  ) -> UsagePeriod {
    UsagePeriod(
      totals: totals(
        input: input,
        output: output,
        cacheRead: cacheRead,
        cacheWrite: cacheWrite,
        reasoning: reasoning,
        messages: messages
      ),
      cost: completeCost(microusd: microusd, rows: messages),
      cacheSaved: UsageCacheSaved(
        amountMicrousd: "412500",
        status: .complete,
        unpricedRows: 0
      ),
      partial: false,
      agents: agents(scale: scale)
    )
  }

  static func dayAgents() -> [UsageAgentUsage] {
    agents(scale: 1)
  }

  private static func agents(scale: Int) -> [UsageAgentUsage] {
    [
      UsageAgentUsage(
        agent: .codex,
        providers: [
          UsageProviderUsage(
            provider: .openai,
            models: [
              model(
                "gpt-4.1", input: 80_000, output: 16_000, messages: 12, microusd: 120_000,
                scale: scale),
              model(
                "gpt-4o", input: 60_000, output: 12_000, messages: 10, microusd: 90_000,
                scale: scale),
              model(
                "gpt-5", input: 200_000, output: 40_000, messages: 28, microusd: 400_000,
                scale: scale),
              model(
                "gpt-5-codex", input: 150_000, output: 30_000, messages: 20, microusd: 280_000,
                scale: scale),
              model(
                "o3", input: 40_000, output: 8_000, messages: 6, microusd: 70_000, scale: scale),
              model(
                "o4-mini", input: 30_000, output: 6_000, messages: 5, microusd: 40_000,
                scale: scale),
              model(
                "other", input: 20_000, output: 4_000, messages: 4, microusd: 15_000, scale: scale
              ),
            ]
          )
        ]
      ),
      UsageAgentUsage(
        agent: .claudeCode,
        providers: [
          UsageProviderUsage(
            provider: .anthropic,
            models: [
              model(
                "claude-sonnet-4", input: 100_000, output: 20_000, messages: 18,
                microusd: 210_000,
                scale: scale),
              model(
                "claude-opus-4", input: 50_000, output: 10_000, messages: 8, microusd: 180_000,
                scale: scale),
            ]
          )
        ]
      ),
      UsageAgentUsage(
        agent: .grok,
        providers: [
          UsageProviderUsage(
            provider: .xai,
            models: [
              model(
                "grok-4", input: 90_000, output: 18_000, messages: 14, microusd: 95_000,
                scale: scale),
              model(
                "grok-3", input: 40_000, output: 8_000, messages: 7, microusd: 30_000,
                scale: scale),
            ]
          )
        ]
      ),
    ]
  }

  private static func model(
    _ name: String,
    input: Int,
    output: Int,
    messages: Int,
    microusd: Int,
    scale: Int
  ) -> UsageModelUsage {
    let scaledInput = input * scale
    let scaledOutput = output * scale
    let scaledMessages = messages * scale
    return UsageModelUsage(
      model: name,
      totals: totals(
        input: scaledInput,
        output: scaledOutput,
        cacheRead: scaledInput / 4,
        cacheWrite: 0,
        reasoning: scaledOutput / 4,
        messages: scaledMessages
      ),
      cost: completeCost(microusd: String(microusd * scale), rows: scaledMessages)
    )
  }

  private static func totals(
    input: Int,
    output: Int,
    cacheRead: Int,
    cacheWrite: Int,
    reasoning: Int,
    messages: Int
  ) -> UsageSummaryTotals {
    UsageSummaryTotals(
      totalTokens: input + output,
      inputTokens: input,
      outputTokens: output,
      cacheReadInputTokens: cacheRead,
      cacheWriteInputTokens: cacheWrite,
      reasoningTokens: reasoning,
      messages: messages
    )
  }

  private static func completeCost(microusd: String, rows: Int) -> UsageCostOutcome {
    UsageCostOutcome(
      mode: .calculate,
      basis: .calculated,
      status: .complete,
      amountMicrousd: microusd,
      catalogRevision: "pricing_visual_fixture",
      calculatedRows: rows,
      reportedRows: 0,
      unpricedRows: 0,
      assumptions: [.agentDefaultChannel],
      unpriced: []
    )
  }

  static func activityDays(ending now: Date) -> [UsageActivityDay] {
    let today = UsageActivityCalendar.utcDay(from: now)
    func day(_ offset: Int, input: Int, output: Int, microusd: String, partial: Bool = false)
      -> UsageActivityDay
    {
      let date = UsageActivityCalendar.addDays(offset, to: today)
      return UsageActivityDay(
        date: date,
        totals: totals(
          input: input,
          output: output,
          cacheRead: input / 4,
          cacheWrite: 0,
          reasoning: output / 4,
          messages: 4
        ),
        cost: completeCost(microusd: microusd, rows: 4),
        partial: partial,
        agents: nil
      )
    }
    return [
      day(0, input: 90_000, output: 18_000, microusd: "95000"),
      day(-1, input: 40_000, output: 8_000, microusd: "30000", partial: true),
      day(-2, input: 10_000, output: 2_000, microusd: "8000"),
      day(-5, input: 200_000, output: 40_000, microusd: "400000"),
      day(-8, input: 5_000, output: 1_000, microusd: "4000"),
      day(-20, input: 80_000, output: 16_000, microusd: "120000"),
      day(-40, input: 30_000, output: 6_000, microusd: "40000"),
      day(-90, input: 150_000, output: 30_000, microusd: "280000"),
      day(-180, input: 20_000, output: 4_000, microusd: "15000"),
    ]
  }

  static func accountPeriodResponse(
    from: String,
    to: String,
    timezone: String = TimeZone.current.identifier,
    usage: UsagePeriod,
    days: [UsageActivityDay],
    truncatedByRetention: Bool = false
  ) -> AccountUsagePeriodResponse {
    let buckets = days.filter { $0.date >= from && $0.date <= to }.map {
      UsagePeriodDayBucket(date: $0.date, totals: $0.totals, cost: $0.cost, partial: $0.partial)
    }
    return AccountUsagePeriodResponse(
      request: UsagePeriodRequest(from: from, to: to, timezone: timezone),
      bounds: UsagePeriodBounds(start: "\(from)T00:00:00Z", end: "\(from)T01:00:00Z"),
      totals: usage.totals,
      cost: usage.cost,
      cacheSaved: usage.cacheSaved,
      days: buckets,
      agents: usage.agents,
      modelSeries: modelSeries(agents: usage.agents, days: buckets),
      coverage: UsagePeriodCoverage(
        partial: usage.partial,
        truncatedByRetention: truncatedByRetention
      ),
      revision: UsagePeriodRevision(
        usageRevision: 1,
        deviceGeneration: 1,
        accountUpdatedAt: nil,
        pricingRevision: "pricing_visual_fixture",
        modelCatalogRevision: "models_visual_fixture",
        foldVersion: 1
      )
    )
  }

  /// A `series=model` answer shaped the way Relay's is: the period's largest models, then
  /// `other`, and each day's tokens and cost split across them. The split leans a little
  /// differently each day so the river reads as a river; it is synthetic, like everything here.
  static func modelSeries(agents: [UsageAgentUsage], days: [UsagePeriodDayBucket])
    -> UsageModelSeries
  {
    let rows = ModelLedger.rows(agents.modelLeaves)
    let named = rows.prefix(UsageModelSeries.limit)
    var entries = named.map { row in
      UsageModelSeriesEntry(
        model: row.key.model,
        provider: InferenceProvider(rawValue: row.key.family.rawValue) ?? .unknown
      )
    }
    var weights = named.map { Double($0.totals.totalTokens) }
    let rest = rows.dropFirst(UsageModelSeries.limit).reduce(0) { $0 + $1.totals.totalTokens }
    if rest > 0 {
      entries.append(UsageModelSeriesEntry(model: UsageModelSeries.otherModel, provider: nil))
      weights.append(Double(rest))
    }
    let seriesDays = days.enumerated().map { dayIndex, day in
      let leaning = weights.enumerated().map { index, weight in
        weight * (1 + 0.45 * sin(Double(dayIndex * 2 + index)))
      }
      let sum = max(leaning.reduce(0, +), 1)
      let dayCost = Double(day.cost.amountMicrousd ?? "0") ?? 0
      let cells = entries.enumerated().compactMap { index, entry -> UsageModelSeriesCell? in
        let share = leaning[index] / sum
        let input = Int(Double(day.totals.inputTokens) * share)
        let output = Int(Double(day.totals.outputTokens) * share)
        guard input + output > 0 else { return nil }
        return UsageModelSeriesCell(
          model: entry.model,
          totalTokens: input + output,
          inputTokens: input,
          outputTokens: output,
          cacheReadInputTokens: input / 4,
          cacheWriteInputTokens: 0,
          costMicrousd: day.cost.amountMicrousd == nil ? nil : String(Int(dayCost * share))
        )
      }
      return UsageModelSeriesDay(date: day.date, partial: day.partial, models: cells)
    }
    return UsageModelSeries(models: entries, days: seriesDays)
  }

  /// Totals for a fixture range that is not one of the four summary periods.
  static func periodUsage(fromDays days: [UsageActivityDay], from: String, to: String)
    -> UsagePeriod
  {
    let selected = days.filter { $0.date >= from && $0.date <= to }
    if selected.isEmpty { return emptyUsage().all }
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    var reasoning = 0
    var messages = 0
    var microusd = 0 as Decimal
    var partial = false
    for day in selected {
      input += day.totals.inputTokens
      output += day.totals.outputTokens
      cacheRead += day.totals.cacheReadInputTokens
      cacheWrite += day.totals.cacheWriteInputTokens
      reasoning += day.totals.reasoningTokens
      messages += day.totals.messages
      partial = partial || day.partial
      if let text = day.cost.amountMicrousd,
        let amount = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
      {
        microusd += amount
      }
    }
    let amount = NSDecimalNumber(decimal: microusd).description(
      withLocale: Locale(identifier: "en_US_POSIX")
    )
    return UsagePeriod(
      totals: totals(
        input: input,
        output: output,
        cacheRead: cacheRead,
        cacheWrite: cacheWrite,
        reasoning: reasoning,
        messages: messages
      ),
      cost: completeCost(microusd: amount, rows: messages),
      cacheSaved: UsageCacheSaved(amountMicrousd: "0", status: .complete, unpricedRows: 0),
      partial: partial,
      agents: []
    )
  }

  private static func emptyUsage() -> AccountUsage {
    let period = UsagePeriod(
      totals: UsageSummaryTotals(
        totalTokens: 0,
        inputTokens: 0,
        outputTokens: 0,
        cacheReadInputTokens: 0,
        cacheWriteInputTokens: 0,
        reasoningTokens: 0,
        messages: 0
      ),
      cost: UsageCostOutcome(
        mode: .calculate,
        basis: .none,
        status: .complete,
        amountMicrousd: nil,
        catalogRevision: nil,
        calculatedRows: 0,
        reportedRows: 0,
        unpricedRows: 0,
        assumptions: [],
        unpriced: []
      ),
      cacheSaved: UsageCacheSaved(amountMicrousd: "0", status: .complete, unpricedRows: 0),
      partial: false,
      agents: []
    )
    return AccountUsage(
      today: period,
      last7Days: period,
      last30Days: period,
      all: period
    )
  }

  /// Codex reports from two Macs so subscription detail can show per-device readings.
  /// Studio Mac is the selected source (newer); Kitchen Mac is the other reading.
  private static func codexSubscription(
    studioID: String,
    kitchenID: String,
    at date: Date
  ) -> QuotaSubscription {
    let studioObserved = date.addingTimeInterval(-90)
    let kitchenObserved = date.addingTimeInterval(-360)
    let studio = QuotaSnapshot(
      provider: .codex,
      account: QuotaAccount(
        fingerprint: "visual_codex",
        label: "pe***@example.com",
        plan: "Plus",
        fingerprintScope: .global
      ),
      windows: [
        window(
          id: "five_hour",
          title: "5 Hours",
          usedPercent: 32,
          resetsAt: date.addingTimeInterval(2_700),
          durationSeconds: 18_000
        ),
        window(
          id: "weekly",
          title: "Weekly",
          usedPercent: 60,
          resetsAt: date.addingTimeInterval(4 * 86_400),
          durationSeconds: 604_800
        ),
        QuotaWindow(
          id: "reset_credits",
          title: "Reset Credits",
          usedPercent: 0,
          remainingValue: 3,
          valueUnit: .count,
          expiries: [QuotaExpiry(expiresAt: date.addingTimeInterval(27 * 86_400), count: 2)]
        ),
      ],
      status: .available,
      observedAt: studioObserved
    )
    let kitchen = QuotaSnapshot(
      provider: .codex,
      account: QuotaAccount(
        fingerprint: "visual_codex",
        label: "pe***@example.com",
        plan: "Plus",
        fingerprintScope: .global
      ),
      windows: [
        window(
          id: "five_hour",
          title: "5 Hours",
          usedPercent: 41,
          resetsAt: date.addingTimeInterval(2_100),
          durationSeconds: 18_000
        ),
        window(
          id: "weekly",
          title: "Weekly",
          usedPercent: 22,
          resetsAt: date.addingTimeInterval(4 * 86_400),
          durationSeconds: 604_800
        ),
      ],
      status: .available,
      observedAt: kitchenObserved
    )
    return QuotaSubscription(
      key: "codex|visual_codex|global|",
      provider: .codex,
      snapshot: studio,
      sources: [
        QuotaSubscriptionSource(
          deviceID: kitchenID, observedAt: kitchenObserved, snapshot: kitchen),
        QuotaSubscriptionSource(deviceID: studioID, observedAt: studioObserved, snapshot: studio),
      ]
    )
  }

  private static func subscription(
    provider: ProviderID,
    deviceID: String,
    fingerprint: String,
    label: String?,
    plan: String?,
    windows: [QuotaWindow],
    observedAt: Date
  ) -> QuotaSubscription {
    let snapshot = QuotaSnapshot(
      provider: provider,
      account: QuotaAccount(
        fingerprint: fingerprint,
        label: label,
        plan: plan,
        fingerprintScope: .global
      ),
      windows: windows,
      status: .available,
      observedAt: observedAt
    )
    return QuotaSubscription(
      key: "\(provider.rawValue)|\(fingerprint)|global|",
      provider: provider,
      snapshot: snapshot,
      sources: [
        QuotaSubscriptionSource(deviceID: deviceID, observedAt: observedAt, snapshot: snapshot)
      ]
    )
  }

  /// What this iPhone read for itself, with no account behind it: one provider account no Mac
  /// reports, so Overview is entirely local.
  static func localCollection(at date: Date) -> LocalCollection {
    LocalCollection(
      collectedAt: date.addingTimeInterval(-45),
      snapshots: [
        snapshot(
          provider: .codex,
          fingerprint: "visual_codex_phone",
          label: "k•••e@example.com",
          plan: "Plus",
          windows: [
            window(
              id: "five_hour",
              title: "5 Hours",
              usedPercent: 58,
              resetsAt: date.addingTimeInterval(5_400),
              durationSeconds: 18_000
            ),
            window(
              id: "weekly",
              title: "Weekly",
              usedPercent: 24,
              resetsAt: date.addingTimeInterval(3 * 86_400),
              durationSeconds: 604_800
            ),
          ],
          observedAt: date.addingTimeInterval(-45)
        ),
        snapshot(
          provider: .claude,
          fingerprint: "visual_claude_phone",
          label: "o•••t@example.com",
          plan: "Pro",
          windows: [
            window(
              id: "five_hour",
              title: "5 Hours",
              usedPercent: 12,
              resetsAt: date.addingTimeInterval(9_000),
              durationSeconds: 18_000
            )
          ],
          observedAt: date.addingTimeInterval(-60)
        ),
      ]
    )
  }

  /// The same account two Macs report, read again on this phone and more recently — so the
  /// merged row is this iPhone's reading and subscription detail lists all three sources.
  static func mergedLocalCollection(at date: Date) -> LocalCollection {
    LocalCollection(
      collectedAt: date.addingTimeInterval(-30),
      snapshots: [
        snapshot(
          provider: .codex,
          fingerprint: "visual_codex",
          label: "pe***@example.com",
          plan: "Plus",
          windows: [
            window(
              id: "five_hour",
              title: "5 Hours",
              usedPercent: 36,
              resetsAt: date.addingTimeInterval(2_700),
              durationSeconds: 18_000
            ),
            window(
              id: "weekly",
              title: "Weekly",
              usedPercent: 18,
              resetsAt: date.addingTimeInterval(4 * 86_400),
              durationSeconds: 604_800
            ),
          ],
          observedAt: date.addingTimeInterval(-30)
        )
      ]
    )
  }

  /// One stored session the provider refused, so the Providers group shows the row that only a
  /// fresh sign-in fixes.
  static func refusedCollection(at date: Date) -> LocalCollection {
    LocalCollection(
      collectedAt: date.addingTimeInterval(-45),
      needsSignIn: ["\(ProviderID.codex.rawValue):codex_personal"]
    )
  }

  private static func snapshot(
    provider: ProviderID,
    fingerprint: String,
    label: String?,
    plan: String?,
    windows: [QuotaWindow],
    observedAt: Date
  ) -> QuotaSnapshot {
    QuotaSnapshot(
      provider: provider,
      account: QuotaAccount(
        fingerprint: fingerprint,
        label: label,
        plan: plan,
        fingerprintScope: .global
      ),
      windows: windows,
      status: .available,
      observedAt: observedAt
    )
  }

  /// The Providers group in its three states at once: a provider with two accounts, one with
  /// a single account, and one with none.
  static func providerSessions(for fixture: VisualFixture, at now: Date) -> [
    StoredProviderSession
  ] {
    guard fixture == .providers || fixture == .loading else { return [] }
    func session(
      _ provider: ProviderID,
      _ fingerprint: String,
      _ label: String,
      checkedSecondsAgo: TimeInterval
    ) -> StoredProviderSession {
      StoredProviderSession(
        provider: provider,
        accountFingerprint: fingerprint,
        cookieHeader: "fixture=not-a-session",
        accountLabel: label,
        storedAt: now.addingTimeInterval(-86_400),
        lastValidatedAt: now.addingTimeInterval(-checkedSecondsAgo)
      )
    }
    // A phone that signed in to two providers and has read neither yet.
    if fixture == .loading {
      return [
        session(.codex, "codex_work", "o•••t@example.com", checkedSecondsAgo: 240),
        session(.claude, "claude_team", "o•••t@example.com", checkedSecondsAgo: 900),
      ]
    }
    return [
      session(.codex, "codex_work", "o•••t@example.com", checkedSecondsAgo: 240),
      session(.codex, "codex_personal", "k•••e@example.com", checkedSecondsAgo: 7_200),
      session(.claude, "claude_team", "o•••t@example.com", checkedSecondsAgo: 900),
    ]
  }

  /// The sample journal a phone that had been collecting all along would hold: a rising curve
  /// inside the window on screen, and the short windows the day already spent.
  static func localSamples(for collection: LocalCollection, at date: Date) -> LocalQuotaSamples {
    var samples = LocalQuotaSamples()
    for snapshot in collection.snapshots {
      for quotaWindow in snapshot.windows {
        guard let resetsAt = quotaWindow.resetsAt, let seconds = quotaWindow.durationSeconds
        else { continue }
        let cadence = Double(seconds)
        let start = resetsAt.addingTimeInterval(-cadence)
        let span = snapshot.observedAt.timeIntervalSince(start)
        guard span > 0 else { continue }
        var entry = LocalQuotaSamples.Entry(
          subscriptionKey: LocalQuotaSamples.key(for: snapshot),
          provider: snapshot.provider,
          windowID: quotaWindow.id,
          samples: []
        )
        // Every window the day already spent, so Today has more than the running one to name.
        if seconds <= 21_600 {
          for (index, peak) in [82.0, 40.0].enumerated() {
            let refilled = start.addingTimeInterval(-cadence * Double(index))
            entry.samples.append(
              QuotaSample(
                resetsAt: refilled,
                observedAt: refilled.addingTimeInterval(-60),
                usedPercent: peak
              )
            )
          }
        }
        for step in 1...4 {
          let fraction = Double(step) / 4
          entry.samples.append(
            QuotaSample(
              resetsAt: resetsAt,
              observedAt: start.addingTimeInterval(span * fraction),
              usedPercent: (quotaWindow.usedPercent * pow(fraction, 1.4) * 100).rounded() / 100
            )
          )
        }
        samples.windows.append(entry)
      }
    }
    return samples
  }

  private static func window(
    id: String,
    title: String,
    usedPercent: Double,
    resetsAt: Date?,
    durationSeconds: Int? = nil
  ) -> QuotaWindow {
    QuotaWindow(
      id: id,
      title: title,
      usedPercent: usedPercent,
      resetsAt: resetsAt,
      durationSeconds: durationSeconds
    )
  }

}

#endif
