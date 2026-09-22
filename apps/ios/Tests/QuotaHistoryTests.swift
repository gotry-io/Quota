import Foundation
import os
import QuotaAccount
import QuotaPresentation
import QuotaProviderSessions
import QuotaProviderWeb
import QuotaRelay
import QuotaWire
import Testing

@testable import Quota

/// The exact `PUT /api/v6/device/quota-history` body the journal fixture below produces.
///
/// Five-hour samples bucket at 900 s. 10:00:01, 10:05, 10:07, and 10:14:59 share
/// `2026-09-21T10:00:00Z` and keep 14.5. 10:15:00 is the next bucket at 20. A fractional
/// `resetsAt` is floored to the whole second. A sample from 18 September is outside the 48 h
/// span. A source-scoped window is not named on the wire.
private let pinnedQuotaHistoryUpload = """
{"generation":4,"protocol_version":6,"series":[{"duration_seconds":18000,\
"fingerprint":"account_test","points":[{"bucket_start":"2026-09-21T10:00:00Z",\
"resets_at":"2026-09-21T15:00:00Z","used_percent":14.5},{"bucket_start":\
"2026-09-21T10:15:00Z","resets_at":"2026-09-21T15:00:00Z","used_percent":20}],\
"provider":"codex","window_id":"five_hour"}]}
"""

@MainActor
struct QuotaHistoryTests {
  @Test func aJournalFixturePinsTheUploadBody() async throws {
    let watermarks = MemoryQuotaHistoryWatermarkStore()
    let transport = HistoryTransport()
    let model = historyModel(transport: transport, watermarks: watermarks)

    await model.restore()
    await model.waitForDetachedLaunchWork()

    let uploads = transport.bodies(path: "/api/v6/device/quota-history", method: "PUT")
    #expect(uploads.count == 1)
    #expect(String(decoding: uploads[0], as: UTF8.self) == pinnedQuotaHistoryUpload)
    let stored = try watermarks.load().accounts["account_01"]
    #expect(stored?.observedSync == true)
    #expect(
      stored?.series.first?.newestBucketStart == Fixtures.date("2026-09-21T10:15:00Z")
    )

    await model.quotaHistory.sync()
    #expect(transport.bodies(path: "/api/v6/device/quota-history", method: "PUT").count == 1)
  }

  @Test func historySyncOffClearsTheWatermarkAndSaysNothing() async throws {
    let watermarks = MemoryQuotaHistoryWatermarkStore()
    let transport = HistoryTransport(historyStatus: 409, historyCode: "history_sync_off")
    let model = historyModel(transport: transport, watermarks: watermarks)

    await model.restore()
    await model.waitForDetachedLaunchWork()
    await model.quotaHistory.sync()

    #expect(transport.bodies(path: "/api/v6/device/quota-history", method: "PUT").count == 1)
    let stored = try watermarks.load().accounts["account_01"] ?? .empty
    #expect(stored.observedSync == false)
    #expect(stored.series.isEmpty)
    #expect(model.accountSettings.historySync == false)
    #expect(model.banner == nil)
  }

  @Test func quotaHistoryFullStopsForThisLaunchAndSaysNothing() async throws {
    let watermarks = MemoryQuotaHistoryWatermarkStore()
    let transport = HistoryTransport(historyStatus: 413, historyCode: "quota_history_full")
    let model = historyModel(transport: transport, watermarks: watermarks)

    await model.restore()
    await model.waitForDetachedLaunchWork()
    await model.quotaHistory.sync()

    #expect(transport.bodies(path: "/api/v6/device/quota-history", method: "PUT").count == 1)
    #expect(model.accountSettings.historySync)
    #expect(model.banner == nil)
    let stored = try watermarks.load().accounts["account_01"]
    #expect((stored?.series ?? []).isEmpty)
  }

  @Test func theBackgroundRefreshAwaitsTheHistoryUpload() async throws {
    let transport = HistoryTransport(gateHistory: true)
    let model = historyModel(
      transport: transport,
      watermarks: MemoryQuotaHistoryWatermarkStore()
    )
    let returned = Flag()
    let task = Task { @MainActor in
      await model.refresh(budget: LocalCollector.backgroundBudget)
      returned.set(true)
    }
    var waited = false
    for _ in 0..<100 {
      if transport.isWaitingForHistory {
        waited = true
        break
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(waited)
    #expect(!returned.get())
    transport.releaseHistory()
    await task.value
    #expect(returned.get())
    #expect(transport.bodies(path: "/api/v6/device/quota-history", method: "PUT").count == 1)
  }

  @Test func aReadCachesTheETagAndDrawsFromYourDevices() async throws {
    let reads = MemoryQuotaHistoryReadStore()
    let transport = HistoryTransport()
    let model = historyModel(
      transport: transport,
      watermarks: MemoryQuotaHistoryWatermarkStore(),
      reads: reads
    )
    await model.restore()
    await model.waitForDetachedLaunchWork()
    let subscription = try #require(
      model.subscriptions.first { $0.snapshot.account.fingerprint == "account_test" }
    )

    await model.loadAccountQuotaHistory(for: subscription)
    await model.loadAccountQuotaHistory(for: subscription)

    let gets = transport.requests.filter {
      $0.method == "GET" && $0.path == "/api/v6/account/quota-history"
    }
    #expect(gets.count == 2)
    let first = try #require(gets.first?.url)
    let items = URLComponents(url: first, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    #expect(query["provider"] == "codex")
    #expect(query["fingerprint"] == "account_test")
    #expect(query["since"] == "2026-08-22T00:00:00Z")
    #expect(gets[0].ifNoneMatch == nil)
    #expect(gets[1].ifNoneMatch == "\"history-1\"")
    let samples = model.quotaHistory.samplesBySubscription[subscription.key]
    let content = SubscriptionDetailContent.make(
      subscription: subscription,
      deviceNames: [:],
      historySync: true,
      accountSamples: samples
    )
    #expect(content.drawsAccountHistory)
    #expect(content.historyCaption == "From your devices")
    #expect(content.remainingHistories["five_hour"]?.observedPoints.isEmpty == false)
  }

  @Test func aFailedReadWithNothingCachedKeepsThisIPhone() async throws {
    let transport = HistoryTransport(readStatus: 500)
    let model = historyModel(
      transport: transport,
      watermarks: MemoryQuotaHistoryWatermarkStore()
    )
    await model.restore()
    await model.waitForDetachedLaunchWork()
    let subscription = try #require(
      model.subscriptions.first { $0.snapshot.account.fingerprint == "account_test" }
    )

    await model.loadAccountQuotaHistory(for: subscription)

    #expect(model.quotaHistory.samplesBySubscription[subscription.key] == nil)
    let content = SubscriptionDetailContent.make(
      subscription: subscription,
      deviceNames: [:],
      samples: model.localSamples,
      historySync: true,
      accountSamples: nil
    )
    #expect(!content.drawsAccountHistory)
    #expect(content.historyCaption == "This iPhone")
    #expect(content.displayedStrings.contains("This iPhone"))
    #expect(!content.displayedStrings.contains("From your devices"))
  }

  @Test func anOutOfRangePointIsLeftOutOfTheUpload() async throws {
    let watermarks = MemoryQuotaHistoryWatermarkStore()
    let transport = HistoryTransport()
    let model = historyModel(
      transport: transport,
      watermarks: watermarks,
      journal: journalWithPointsRelayWouldJudge()
    )

    await model.restore()
    await model.waitForDetachedLaunchWork()

    let uploads = transport.bodies(path: "/api/v6/device/quota-history", method: "PUT")
    #expect(uploads.count == 1)
    let points = try uploadPoints(uploads[0])
    #expect(points.map(\.start) == [
      "2026-09-21T10:00:00Z",
      "2026-09-21T10:15:00Z",
      "2026-09-21T12:15:00Z",
    ])
    #expect(points.map(\.used) == [14.5, 20, 33])
    let stored = try #require(try watermarks.load().accounts["account_01"]?.series.first)
    #expect(stored.lastUploaded.map(\.bucketStart) == [Fixtures.date("2026-09-21T12:15:00Z")])
    #expect(stored.lastUploaded.map(\.usedPercent) == [33])
  }

  @Test func accountSeriesAppendsTheLiveReadingAtNow() throws {
    let reset = Fixtures.date("2026-09-21T15:00:00Z")
    let lastChange = Fixtures.date("2026-09-21T10:15:00Z")
    let subscription = historyDetailSubscription(usedPercent: 80)
    let account = [
      "five_hour": [
        QuotaSample(resetsAt: reset, observedAt: lastChange, usedPercent: 40)
      ]
    ]
    let content = SubscriptionDetailContent.make(
      subscription: subscription,
      deviceNames: [:],
      samples: localSeries(usedAt: lastChange, usedPercent: 40),
      now: historyNow,
      historySync: true,
      accountSamples: account
    )
    let history = try #require(content.remainingHistories["five_hour"])
    let last = try #require(history.observedPoints.last)
    #expect(content.drawsAccountHistory)
    #expect(last.date == historyNow)
    #expect(last.remainingPercent == RemainingQuotaFormat.remainingPercent(usedPercent: 80))
    #expect(history.observedPoints.contains { $0.date == lastChange })

    let already = SubscriptionDetailContent.seriesThroughNow(
      ["five_hour": [QuotaSample(resetsAt: reset, observedAt: historyNow, usedPercent: 40)]],
      snapshot: subscription.snapshot,
      now: historyNow
    )
    #expect(already["five_hour"]?.count == 1)
    #expect(already["five_hour"]?.first?.usedPercent == 40)
  }

  @Test func aLocalSeriesIsLeftOnItsOwnSamples() throws {
    let lastChange = Fixtures.date("2026-09-21T10:15:00Z")
    let subscription = historyDetailSubscription(usedPercent: 80)
    let content = SubscriptionDetailContent.make(
      subscription: subscription,
      deviceNames: [:],
      samples: localSeries(usedAt: lastChange, usedPercent: 40),
      now: historyNow,
      historySync: false,
      accountSamples: [
        "five_hour": [
          QuotaSample(
            resetsAt: Fixtures.date("2026-09-21T15:00:00Z"),
            observedAt: lastChange,
            usedPercent: 40
          )
        ]
      ]
    )
    let history = try #require(content.remainingHistories["five_hour"])
    #expect(!content.drawsAccountHistory)
    #expect(content.historyCaption == "This iPhone")
    #expect(history.observedPoints.last?.date == lastChange)
    #expect(
      history.observedPoints.last?.remainingPercent
        == RemainingQuotaFormat.remainingPercent(usedPercent: 40)
    )
  }

  @Test func chunksAreOldestFirstAndAtMostThePointCap() {
    let resets = Fixtures.date("2026-09-21T15:00:00Z")
    let points = (0..<3).map { index in
      QuotaHistoryUploadRequest.Point(
        resetsAt: resets,
        bucketStart: resets.addingTimeInterval(Double(index) * 900),
        usedPercent: Double(index)
      )
    }
    let series = QuotaHistoryUploadRequest.Series(
      provider: .codex,
      fingerprint: "account_test",
      windowId: "five_hour",
      durationSeconds: 18_000,
      points: points
    )
    let chunks = QuotaHistoryChunker.chunks([series], maxPoints: 2)
    #expect(chunks.count == 2)
    #expect(chunks[0].flatMap(\.points).count == 2)
    #expect(chunks[1].flatMap(\.points).count == 1)
    #expect(chunks[0].flatMap(\.points).first?.bucketStart == points[0].bucketStart)
  }
}

// MARK: - Fixture

private let historyNow = Fixtures.date("2026-09-21T12:00:00Z")

@MainActor
private func historyModel(
  transport: HistoryTransport,
  watermarks: MemoryQuotaHistoryWatermarkStore,
  reads: MemoryQuotaHistoryReadStore = MemoryQuotaHistoryReadStore(),
  journal: LocalQuotaSamples? = nil
) -> AppModel {
  let snapshot = historySnapshot()
  let providerSessions = MemoryProviderSessionStore(
    sessions: [
      StoredProviderSession(
        provider: .codex,
        accountFingerprint: "account_test",
        cookieHeader: "session=account_test",
        accountLabel: nil,
        storedAt: historyNow,
        lastValidatedAt: historyNow
      )
    ]
  )
  return AppModel(
    account: AccountClient(
      relay: RelayClient(transport: transport),
      sessionStore: MemoryAccountSessionStore(session: Fixtures.session(deviceID: "device_phone")),
      summaryStore: MemoryAccountSummaryStore(value: nil),
      now: { historyNow }
    ),
    authenticator: ScriptedAuthenticator(result: .failure(AuthorizationError.cancelled)),
    providerSessions: providerSessions,
    localStore: MemoryLocalCollectionStore(),
    sampleStore: MemoryLocalQuotaSampleStore(
      value: journal ?? historyJournal(matching: snapshot)
    ),
    historyWatermarks: watermarks,
    historyReads: reads,
    localCollector: LocalCollector(
      sessions: providerSessions,
      collectors: { provider, _ in HistoryCollector(provider: provider, snapshot: snapshot) },
      now: { historyNow }
    ),
    settingsDefaults: UserDefaults(suiteName: "QuotaTests.History.\(UUID().uuidString)")!,
    syncAccountSettings: true,
    now: { historyNow }
  )
}

private func historySnapshot() -> QuotaSnapshot {
  QuotaSnapshot(
    provider: .codex,
    account: QuotaAccount(fingerprint: "account_test", fingerprintScope: .global),
    windows: [
      QuotaWindow(
        id: "five_hour",
        title: "5 Hours",
        usedPercent: 20,
        resetsAt: Fixtures.date("2026-09-21T15:00:00Z"),
        durationSeconds: 18_000
      )
    ],
    status: .available,
    observedAt: historyNow
  )
}

private func journalWithPointsRelayWouldJudge() -> LocalQuotaSamples {
  var journal = historyJournal(matching: historySnapshot())
  let resets = Fixtures.date("2026-09-21T15:00:00Z")
  let key = LocalQuotaSamples.key(for: historySnapshot())
  let index = journal.windows.firstIndex {
    $0.subscriptionKey == key && $0.windowID == "five_hour"
  }
  guard let index else { return journal }
  journal.windows[index].samples.append(contentsOf: [
    QuotaSample(
      resetsAt: resets,
      observedAt: Fixtures.date("2026-09-21T12:20:00Z"),
      usedPercent: 33
    ),
    QuotaSample(
      resetsAt: resets,
      observedAt: Fixtures.date("2026-09-21T12:30:00Z"),
      usedPercent: 55
    ),
  ])
  return journal
}

private struct UploadPoint {
  var start: String
  var used: Double
}

private func uploadPoints(_ body: Data) throws -> [UploadPoint] {
  let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
  let series = try #require(object["series"] as? [[String: Any]])
  let points = try #require(series.first?["points"] as? [[String: Any]])
  return try points.map { point in
    UploadPoint(
      start: try #require(point["bucket_start"] as? String),
      used: try #require(point["used_percent"] as? Double)
    )
  }
}

private func historyDetailSubscription(usedPercent: Double) -> QuotaSubscription {
  let snapshot = QuotaSnapshot(
    provider: .codex,
    account: QuotaAccount(fingerprint: "account_test", fingerprintScope: .global),
    windows: [
      QuotaWindow(
        id: "five_hour",
        title: "5 Hours",
        usedPercent: usedPercent,
        resetsAt: Fixtures.date("2026-09-21T15:00:00Z"),
        durationSeconds: 18_000
      )
    ],
    status: .available,
    observedAt: historyNow
  )
  return QuotaSubscription(
    key: "account_test",
    provider: .codex,
    snapshot: snapshot,
    sources: [
      QuotaSubscriptionSource(
        deviceID: ThisDevice.sourceID,
        observedAt: historyNow,
        snapshot: snapshot
      )
    ]
  )
}

private func localSeries(usedAt: Date, usedPercent: Double) -> LocalQuotaSamples {
  let snapshot = historyDetailSubscription(usedPercent: usedPercent).snapshot
  return LocalQuotaSamples(
    windows: [
      LocalQuotaSamples.Entry(
        subscriptionKey: LocalQuotaSamples.key(for: snapshot),
        provider: .codex,
        windowID: "five_hour",
        samples: [
          QuotaSample(
            resetsAt: Fixtures.date("2026-09-21T15:00:00Z"),
            observedAt: usedAt,
            usedPercent: usedPercent
          )
        ]
      )
    ]
  )
}

private func historyJournal(matching snapshot: QuotaSnapshot) -> LocalQuotaSamples {
  let resets = Fixtures.date("2026-09-21T15:00:00Z")
  func sample(_ observed: String, _ used: Double, resetsAt: Date = resets) -> QuotaSample {
    QuotaSample(resetsAt: resetsAt, observedAt: Fixtures.date(observed), usedPercent: used)
  }
  let source = QuotaSnapshot(
    provider: .codex,
    account: QuotaAccount(fingerprint: "source_fp", fingerprintScope: .source),
    windows: [
      QuotaWindow(id: "five_hour", title: "5 Hours", usedPercent: 77, durationSeconds: 18_000)
    ],
    status: .available,
    observedAt: historyNow
  )
  return LocalQuotaSamples(
    windows: [
      LocalQuotaSamples.Entry(
        subscriptionKey: LocalQuotaSamples.key(for: snapshot),
        provider: .codex,
        windowID: "five_hour",
        samples: [
          sample("2026-09-18T10:00:00Z", 99),
          sample("2026-09-21T10:00:01Z", 10),
          sample("2026-09-21T10:05:00Z", 13, resetsAt: resets.addingTimeInterval(0.4)),
          sample("2026-09-21T10:07:00Z", 14.5),
          sample("2026-09-21T10:14:59Z", 12),
          sample("2026-09-21T10:15:00Z", 20),
        ]
      ),
      LocalQuotaSamples.Entry(
        subscriptionKey: LocalQuotaSamples.key(for: source),
        provider: .codex,
        windowID: "five_hour",
        samples: [sample("2026-09-21T10:00:00Z", 77)]
      ),
    ]
  )
}

private struct HistoryCollector: ProviderWebCollector {
  static var provider: ProviderID { .codex }
  let provider: ProviderID
  let snapshot: QuotaSnapshot

  func validate(cookieHeader: String) async throws -> ValidatedBrowserSession {
    ValidatedBrowserSession(accountFingerprint: "account_test", accountLabel: nil)
  }

  func collect(cookieHeader: String) async throws -> QuotaSnapshot { snapshot }
}

private final class Flag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  func set(_ value: Bool) {
    lock.lock()
    self.value = value
    lock.unlock()
  }

  func get() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

/// Answers the routes a history refresh touches. The quota-history PUT can wait until released.
private final class HistoryTransport: HTTPTransport, @unchecked Sendable {
  struct Recorded {
    var method: String
    var path: String
    var body: Data?
    var ifNoneMatch: String?
    var url: URL?
  }

  var historyStatus: Int
  var historyCode: String
  var readStatus: Int
  var gateHistory: Bool

  private struct MutableState {
    var recorded: [Recorded] = []
    var historyContinuation: CheckedContinuation<Void, Never>?
    var historyGets = 0
  }

  private let state = OSAllocatedUnfairLock(initialState: MutableState())

  init(
    historyStatus: Int = 200,
    historyCode: String = "",
    readStatus: Int = 200,
    gateHistory: Bool = false
  ) {
    self.historyStatus = historyStatus
    self.historyCode = historyCode
    self.readStatus = readStatus
    self.gateHistory = gateHistory
  }

  var isWaitingForHistory: Bool {
    state.withLock { $0.historyContinuation != nil }
  }

  func releaseHistory() {
    let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
      let continuation = state.historyContinuation
      state.historyContinuation = nil
      return continuation
    }
    continuation?.resume()
  }

  func bodies(path: String, method: String) -> [Data] {
    state.withLock { state in
      state.recorded.filter { $0.path == path && $0.method == method }.compactMap(\.body)
    }
  }

  var requests: [Recorded] {
    state.withLock(\.recorded)
  }

  func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let path = request.url?.path ?? ""
    let method = request.httpMethod ?? "GET"
    if gateHistory, method == "PUT", path == "/api/v6/device/quota-history" {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        state.withLock { $0.historyContinuation = continuation }
      }
    }
    let exchange = response(for: path, method: method)
    state.withLock { state in
      state.recorded.append(
        Recorded(
          method: method,
          path: path,
          body: request.httpBody,
          ifNoneMatch: request.value(forHTTPHeaderField: "If-None-Match"),
          url: request.url
        )
      )
      if method == "GET", path == "/api/v6/account/quota-history" { state.historyGets += 1 }
    }
    let url = request.url ?? URL(string: "https://quota.gotry.io")!
    let http = HTTPURLResponse(
      url: url,
      statusCode: exchange.status,
      httpVersion: "HTTP/1.1",
      headerFields: exchange.headers
    )!
    return (exchange.body, http)
  }

  private func response(
    for path: String,
    method: String
  ) -> (status: Int, body: Data, headers: [String: String]) {
    switch (method, path) {
    case ("GET", "/api/v6/account/summary"):
      return (200, (try? Fixtures.accountSummaryJSON()) ?? Data(), [:])
    case (_, "/api/v2/account/settings"):
      return (200, historySettingsBody(), ["ETag": "\"1\""])
    case ("GET", "/api/v2/device/sync"):
      return (200, deviceSyncBody(), [:])
    case ("PUT", "/api/v6/device/snapshots"):
      return (200, snapshotUploadBody(), [:])
    case ("PUT", "/api/v6/device/quota-history"):
      if historyStatus == 200 { return (200, historyUploadBody(), [:]) }
      return (historyStatus, errorBody(historyCode), [:])
    case ("GET", "/api/v6/account/quota-history"):
      if readStatus != 200 { return (readStatus, Data(), [:]) }
      let gets = state.withLock(\.historyGets)
      if gets == 0 {
        return (200, historyReadBody(), ["ETag": "\"history-1\""])
      }
      return (304, Data(), ["ETag": "\"history-1\""])
    default:
      return (404, Data(), [:])
    }
  }
}

private func historySettingsBody() -> Data {
  Data(
    """
    {"protocol_version":2,"revision":1,"updated_at":"2026-09-21T10:00:00Z",\
    "alerts":{"reset_reminders":true,"pace_alerts":true,"thresholds":{}},\
    "budget":{"amount_usd":null,"alerts":true},"history":{"sync":true}}
    """.utf8
  )
}

private func deviceSyncBody() -> Data {
  Data(
    """
    {"protocol_version":2,"account_id":"account_01","device_id":"device_phone",\
    "device_generation":4,"usage_deleted_before":null,"usage_sync_revision":0}
    """.utf8
  )
}

private func snapshotUploadBody() -> Data {
  Data(
    """
    {"protocol_version":6,"device_id":"device_phone","device_generation":4,\
    "accepted":["codex"],"ignored":[]}
    """.utf8
  )
}

private func historyUploadBody() -> Data {
  Data(
    """
    {"protocol_version":6,"series":[{"provider":"codex","fingerprint":"account_test",\
    "window_id":"five_hour","bucket_start":"2026-09-21T10:15:00Z"}]}
    """.utf8
  )
}

private func historyReadBody() -> Data {
  Data(
    """
    {"protocol_version":6,"sync":true,"windows":{"five_hour":{"duration_seconds":18000,\
    "points":[{"resets_at":"2026-09-21T15:00:00Z","bucket_start":"2026-09-21T10:00:00Z",\
    "used_percent":40}]}}}
    """.utf8
  )
}

private func errorBody(_ code: String) -> Data {
  Data(
    """
    {"error":{"code":"\(code)","message":"no"}}
    """.utf8
  )
}
