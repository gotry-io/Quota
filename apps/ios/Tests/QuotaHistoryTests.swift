import Foundation
import os
import QuotaAccount
import QuotaAlerts
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
    #expect(model.accountSettings.historySync == true)
    #expect(model.banner == nil)
    let stored = try watermarks.load().accounts["account_01"]
    let series = stored?.series ?? []
    #expect(series.isEmpty)
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
    await transport.waitUntilHistoryIsHeld()
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

  @Test func aWindowTheAccountHasNoPointsForStillDrawsThisIPhone() throws {
    let lastChange = Fixtures.date("2026-09-21T10:15:00Z")
    let subscription = historyDetailSubscription(usedPercent: 80)
    let content = SubscriptionDetailContent.make(
      subscription: subscription,
      deviceNames: [:],
      samples: localSeries(usedAt: lastChange, usedPercent: 40),
      now: historyNow,
      historySync: true,
      accountSamples: ["weekly": [
        QuotaSample(
          resetsAt: Fixtures.date("2026-09-28T00:00:00Z"),
          observedAt: lastChange,
          usedPercent: 12
        )
      ]]
    )
    #expect(content.drawsAccountHistory)
    let history = try #require(content.remainingHistories["five_hour"])
    #expect(history.observedPoints.contains { $0.date == lastChange })
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

  @Test func twoThousandFiveHundredPointsChunkWellUnderASecond() throws {
    let resets = Fixtures.date("2026-09-21T15:00:00Z")
    let points = (0..<2_500).map { index in
      QuotaHistoryUploadRequest.Point(
        resetsAt: resets,
        bucketStart: resets.addingTimeInterval(Double(index) * 900),
        usedPercent: Double(index % 100)
      )
    }
    let series = QuotaHistoryUploadRequest.Series(
      provider: .codex,
      fingerprint: "account_test",
      windowId: "five_hour",
      durationSeconds: 18_000,
      points: points
    )
    let clock = ContinuousClock()
    let started = clock.now
    let chunks = QuotaHistoryChunker.chunks([series])
    #expect(clock.now - started < .seconds(1))
    #expect(chunks.count > 1)
    let flat = chunks.flatMap { $0.flatMap(\.points) }
    #expect(flat.count == 2_500)
    #expect(flat.first?.bucketStart == points[0].bucketStart)
    #expect(flat.last?.bucketStart == points[2_499].bucketStart)
    for chunk in chunks {
      let count = chunk.flatMap(\.points).count
      #expect(count <= QuotaHistoryUploadRequest.maximumPoints)
      #expect(!chunk.isEmpty)
      let body = try WireCodec.encodeRequest(
        QuotaHistoryUploadRequest(generation: Int.max, series: chunk)
      )
      #expect(body.count <= QuotaHistoryUploadRequest.maximumBytes)
    }
  }

  @Test func aTightByteCapSplitsWithoutExceedingIt() throws {
    let resets = Fixtures.date("2026-09-21T15:00:00Z")
    let points = (0..<4).map { index in
      QuotaHistoryUploadRequest.Point(
        resetsAt: resets,
        bucketStart: resets.addingTimeInterval(Double(index) * 900),
        usedPercent: 10
      )
    }
    let series = QuotaHistoryUploadRequest.Series(
      provider: .codex,
      fingerprint: "account_test",
      windowId: "five_hour",
      durationSeconds: 18_000,
      points: points
    )
    let one = try WireCodec.encodeRequest(
      QuotaHistoryUploadRequest(
        generation: Int.max,
        series: [
          QuotaHistoryUploadRequest.Series(
            provider: .codex,
            fingerprint: "account_test",
            windowId: "five_hour",
            durationSeconds: 18_000,
            points: [points[0]]
          )
        ]
      )
    )
    let chunks = QuotaHistoryChunker.chunks([series], maxBytes: one.count)
    #expect(chunks.count == 4)
    #expect(chunks.flatMap { $0.flatMap(\.points) }.count == 4)
    for chunk in chunks {
      let body = try WireCodec.encodeRequest(
        QuotaHistoryUploadRequest(generation: Int.max, series: chunk)
      )
      #expect(body.count <= one.count)
    }
  }

  @Test func aFailedSettingsReadWithCachedSyncOnDoesNotBackfill() async throws {
    let watermarks = MemoryQuotaHistoryWatermarkStore()
    let resets = Fixtures.date("2026-09-21T15:00:00Z")
    let newest = Fixtures.date("2026-09-21T10:15:00Z")
    try watermarks.save(
      QuotaHistoryWatermarkFile(
        accounts: [
          "account_01": QuotaHistoryWatermarkFile.Account(
            observedSync: true,
            series: [
              QuotaHistoryWatermarkFile.Series(
                provider: "codex",
                fingerprint: "account_test",
                windowID: "five_hour",
                newestBucketStart: newest,
                lastUploaded: [
                  QuotaHistorySync.Bucket(
                    resetsAt: resets,
                    bucketStart: newest,
                    usedPercent: 20
                  )
                ]
              )
            ]
          )
        ]
      )
    )
    let transport = HistoryTransport(settingsStatus: 500)
    let model = historyModel(
      transport: transport,
      watermarks: watermarks,
      settings: cachedHistorySettings(sync: true)
    )

    await model.restore()
    await model.waitForDetachedLaunchWork()

    #expect(model.accountSettings.historySync == true)
    let stored = try #require(watermarks.load().accounts["account_01"])
    #expect(stored.observedSync)
    #expect(!stored.series.isEmpty)
    #expect(historyPutBodies(transport).allSatisfy { !$0.contains("2026-09-21T10:00:00Z") })

    transport.settingsStatus = 200
    await model.refresh()
    await model.waitForDetachedLaunchWork()
    await model.quotaHistory.sync()

    #expect(model.accountSettings.historySync == true)
    #expect(historyPutBodies(transport).allSatisfy { !$0.contains("2026-09-21T10:00:00Z") })
    #expect(try watermarks.load().accounts["account_01"]?.observedSync == true)
  }

  @Test func aNewerOldestFromRelayBackfillsThatSeriesAgainOnce() async throws {
    let watermarks = MemoryQuotaHistoryWatermarkStore()
    let earlier = Fixtures.date("2026-09-21T10:00:00Z")
    let newest = Fixtures.date("2026-09-21T10:15:00Z")
    // This on-period already uploaded 10:00. The switch then went off and on on the website,
    // so the first answer's oldest is the 10:15 bucket this upload sends.
    try watermarks.save(
      QuotaHistoryWatermarkFile(
        accounts: [
          "account_01": QuotaHistoryWatermarkFile.Account(
            observedSync: true,
            series: [
              QuotaHistoryWatermarkFile.Series(
                provider: "codex",
                fingerprint: "account_test",
                windowID: "five_hour",
                newestBucketStart: newest,
                lastUploaded: [],
                oldestBucketStart: earlier
              )
            ]
          )
        ]
      )
    )
    let transport = HistoryTransport(
      historyOldest: ["2026-09-21T10:15:00Z", "2026-09-21T10:00:00Z"]
    )
    let model = historyModel(transport: transport, watermarks: watermarks)

    await model.restore()
    await model.waitForDetachedLaunchWork()

    let bodies = historyPutBodies(transport)
    #expect(bodies.count == 2)
    #expect(bodies.first.map { !$0.contains("2026-09-21T10:00:00Z") } == true)
    #expect(bodies.last.map { $0.contains("2026-09-21T10:00:00Z") } == true)
    let stored = try #require(watermarks.load().accounts["account_01"]?.series.first)
    #expect(stored.oldestBucketStart == earlier)
    #expect(stored.newestBucketStart == newest)

    // Relay holds the span again: nothing new is sent.
    await model.quotaHistory.sync()
    #expect(historyPutBodies(transport).count == 2)
  }

  @Test func aRecordPastItsSpanFallsBackToTheWatermarkBeforeThisChunk() async throws {
    let watermarks = MemoryQuotaHistoryWatermarkStore()
    let resets = Fixtures.date("2026-09-21T15:00:00Z")
    let confirmed = Fixtures.date("2026-09-21T10:00:00Z")
    // The recorded oldest is 48 h old, so it is no longer evidence. Relay confirmed the 10:00
    // bucket, which is already uploaded, so this pass sends only 10:15; an answer that names
    // 10:15 as the oldest says the 10:00 row went.
    try watermarks.save(
      QuotaHistoryWatermarkFile(
        accounts: [
          "account_01": QuotaHistoryWatermarkFile.Account(
            observedSync: true,
            series: [
              QuotaHistoryWatermarkFile.Series(
                provider: "codex",
                fingerprint: "account_test",
                windowID: "five_hour",
                newestBucketStart: confirmed,
                lastUploaded: [
                  QuotaHistorySync.Bucket(
                    resetsAt: resets,
                    bucketStart: confirmed,
                    usedPercent: 14.5
                  )
                ],
                oldestBucketStart: Fixtures.date("2026-09-19T10:00:00Z")
              )
            ]
          )
        ]
      )
    )
    let transport = HistoryTransport(
      historyOldest: ["2026-09-21T10:15:00Z", "2026-09-21T10:00:00Z"]
    )
    let model = historyModel(transport: transport, watermarks: watermarks)

    await model.restore()
    await model.waitForDetachedLaunchWork()

    let bodies = historyPutBodies(transport)
    #expect(bodies.count == 2)
    #expect(bodies.first.map { !$0.contains("2026-09-21T10:00:00Z") } == true)
    #expect(bodies.last.map { $0.contains("2026-09-21T10:00:00Z") } == true)
    let stored = try #require(watermarks.load().accounts["account_01"]?.series.first)
    #expect(stored.oldestBucketStart == confirmed)
  }

  @Test func cachedSyncOnOfflineKeepsTheToggleAndTheAccountSeries() async throws {
    let reads = MemoryQuotaHistoryReadStore()
    try reads.save(
      QuotaHistoryReadCacheFile(entries: [
        historyReadEntry(since: Fixtures.date("2026-08-21T00:00:00Z"))
      ])
    )
    let transport = HistoryTransport(readStatus: 500, settingsStatus: 500)
    let model = historyModel(
      transport: transport,
      watermarks: MemoryQuotaHistoryWatermarkStore(),
      reads: reads,
      settings: cachedHistorySettings(sync: true)
    )

    await model.restore()
    await model.waitForDetachedLaunchWork()
    #expect(model.accountSettings.historySync == true)
    #expect(model.showsShareQuotaHistory)
    let subscription = try #require(
      model.subscriptions.first { $0.snapshot.account.fingerprint == "account_test" }
    )

    await model.loadAccountQuotaHistory(for: subscription)

    let samples = model.quotaHistory.samplesBySubscription[subscription.key]
    let content = SubscriptionDetailContent.make(
      subscription: subscription,
      deviceNames: [:],
      samples: model.localSamples,
      historySync: model.accountSettings.historySync == true,
      accountSamples: samples
    )
    #expect(content.drawsAccountHistory)
    #expect(content.historyCaption == "From your devices")
    #expect(content.remainingHistories["five_hour"]?.observedPoints.isEmpty == false)
    #expect(try reads.load().entries.count == 1)
  }

  @Test func theHistorySwitchIsHiddenUntilTheSessionIsActive() {
    let model = historyModel(
      transport: HistoryTransport(),
      watermarks: MemoryQuotaHistoryWatermarkStore()
    )
    #expect(!model.showsShareQuotaHistory)
    model.poseSession(activation: .pending, deviceID: "device_phone")
    #expect(!model.showsShareQuotaHistory)
    model.poseSession(activation: .active, deviceID: "device_phone")
    #expect(model.showsShareQuotaHistory)
  }

  @Test func aPendingHistorySyncOnSurvivesHistorySyncOff() async throws {
    let transport = HistoryTransport(
      historyStatus: 409,
      historyCode: "history_sync_off",
      settingsPUTStatus: 500
    )
    let model = historyModel(
      transport: transport,
      watermarks: MemoryQuotaHistoryWatermarkStore()
    )
    poseHistory(model)

    await model.accountSettings.apply(.setHistorySync(true))

    #expect(transport.bodies(path: "/api/v6/device/quota-history", method: "PUT").count == 1)
    #expect(model.accountSettings.historySync == true)
    #expect(model.accountSettings.pending.map(\.edit) == [.setHistorySync(true)])
  }

  @Test func cancellingTheOuterTaskStopsBeforeTheNextChunk() async throws {
    let transport = HistoryTransport(holdFirstHistoryPut: true)
    let model = historyModel(
      transport: transport,
      watermarks: MemoryQuotaHistoryWatermarkStore(),
      settings: cachedHistorySettings(sync: true)
    )
    poseHistory(model)
    await model.accountSettings.seedHistorySyncFromCache()
    model.quotaHistory.maximumPointsPerChunk = 1
    #expect(model.accountSettings.historySync == true)

    let task = Task { @MainActor in
      await model.quotaHistory.sync()
    }
    await transport.waitUntilHistoryIsHeld()
    task.cancel()
    transport.releaseHistory()
    await task.value
    #expect(transport.bodies(path: "/api/v6/device/quota-history", method: "PUT").count == 1)
  }

  @Test func aFailedUploadDoesNotBucketAgainWithinAMinute() async throws {
    let clock = MutableDate(historyNow)
    let transport = HistoryTransport(historyStatus: 500, historyCode: "unavailable")
    let model = historyModel(
      transport: transport,
      watermarks: MemoryQuotaHistoryWatermarkStore(),
      now: { clock.date }
    )

    await model.restore()
    await model.waitForDetachedLaunchWork()
    let puts = transport.bodies(path: "/api/v6/device/quota-history", method: "PUT").count
    let syncs = deviceSyncCount(transport)
    #expect(puts == 1)

    await model.quotaHistory.sync()
    #expect(transport.bodies(path: "/api/v6/device/quota-history", method: "PUT").count == puts)
    #expect(deviceSyncCount(transport) == syncs)

    clock.date = historyNow.addingTimeInterval(61)
    await model.quotaHistory.sync()
    #expect(transport.bodies(path: "/api/v6/device/quota-history", method: "PUT").count == puts + 1)
    #expect(deviceSyncCount(transport) == syncs + 1)
  }

  @Test func theReadCacheKeepsOneEntryAndDecodesTheFileOnce() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "quota-history-read-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let older = historyReadEntry(since: Fixtures.date("2026-08-21T00:00:00Z"))
    let newer = historyReadEntry(since: Fixtures.date("2026-08-22T00:00:00Z"))
    var legacy = QuotaHistoryReadCacheFile(entries: [older, newer])
    legacy.replace(newer)
    #expect(legacy.entries.count == 1)
    let raw = QuotaHistoryReadCacheFile(entries: [older, newer])
    let store = FileQuotaHistoryReadStore(directory: directory)
    try WireCodec.encode(raw).write(to: store.fileURL)
    let loaded = try store.load()
    #expect(loaded.entries.count == 1)
    #expect(loaded.entry(
      accountID: "account_01",
      provider: "codex",
      fingerprint: "account_test"
    )?.since == newer.since)
    try Data("nope".utf8).write(to: store.fileURL)
    let again = try store.load()
    #expect(again == loaded)
  }
}

// MARK: - Fixture

private let historyNow = Fixtures.date("2026-09-21T12:00:00Z")

@MainActor
private func historyModel(
  transport: HistoryTransport,
  watermarks: MemoryQuotaHistoryWatermarkStore,
  reads: MemoryQuotaHistoryReadStore = MemoryQuotaHistoryReadStore(),
  journal: LocalQuotaSamples? = nil,
  settings: CachedAccountSettings? = nil,
  now: @escaping @Sendable () -> Date = { historyNow }
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
      settingsStore: MemoryAccountSettingsStore(value: settings),
      now: now
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
    now: now
  )
}

@MainActor
private func poseHistory(_ model: AppModel) {
  model.pose(
    phase: .signedIn,
    sessionActivation: .active,
    sessionDeviceID: "device_phone",
    summary: nil,
    fetchedAt: nil,
    fromCache: false,
    isRefreshing: false,
    banner: nil,
    expiredMessage: nil,
    localCollection: LocalCollection(collectedAt: historyNow, snapshots: [historySnapshot()]),
    localSamples: historyJournal(matching: historySnapshot()),
    selectedTab: .quota,
    presentsSignIn: false,
    identities: .idle,
    providerStatus: [:],
    skipsRestore: true,
    isOfflineFixture: false,
    displayClockIsFixed: true
  )
}

private func cachedHistorySettings(sync: Bool) -> CachedAccountSettings {
  CachedAccountSettings(
    accountID: "account_01",
    etag: "\"1\"",
    document: AccountSettingsDocument(
      revision: 1,
      updatedAt: historyNow,
      alerts: AccountSettingsDocument.Alerts(
        resetReminders: true,
        paceAlerts: true,
        thresholds: [:]
      ),
      budget: AccountSettingsDocument.Budget(amountUSD: nil, alerts: true),
      history: AccountSettingsDocument.History(sync: sync),
      historyPresent: true
    )
  )
}

private func historyReadEntry(since: Date) -> QuotaHistoryReadCacheFile.Entry {
  QuotaHistoryReadCacheFile.Entry(
    accountID: "account_01",
    provider: "codex",
    fingerprint: "account_test",
    since: since,
    etag: "\"history-1\"",
    body: QuotaHistoryReadResponse(
      sync: true,
      windows: [
        "five_hour": QuotaHistoryReadResponse.Window(
          durationSeconds: 18_000,
          points: [
            QuotaHistoryUploadRequest.Point(
              resetsAt: Fixtures.date("2026-09-21T15:00:00Z"),
              bucketStart: Fixtures.date("2026-09-21T10:00:00Z"),
              usedPercent: 40
            )
          ]
        )
      ]
    )
  )
}

private func historyPutBodies(_ transport: HistoryTransport) -> [String] {
  transport.bodies(path: "/api/v6/device/quota-history", method: "PUT").map {
    String(decoding: $0, as: UTF8.self)
  }
}

private func deviceSyncCount(_ transport: HistoryTransport) -> Int {
  transport.requests.filter { $0.method == "GET" && $0.path == "/api/v2/device/sync" }.count
}

private final class MutableDate: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date

  init(_ date: Date) {
    value = date
  }

  var date: Date {
    get {
      lock.lock()
      defer { lock.unlock() }
      return value
    }
    set {
      lock.lock()
      value = newValue
      lock.unlock()
    }
  }
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
  var settingsStatus: Int
  var settingsPUTStatus: Int
  var holdFirstHistoryPut: Bool
  /// The `oldest_bucket_start` each quota-history PUT answers, in order. Past the end, the
  /// 10:00 bucket the journal fixture backfills.
  var historyOldest: [String]

  private struct MutableState {
    var recorded: [Recorded] = []
    var historyContinuation: CheckedContinuation<Void, Never>?
    var heldWaiters: [CheckedContinuation<Void, Never>] = []
    var historyGets = 0
    var historyPuts = 0
  }

  private let state = OSAllocatedUnfairLock(initialState: MutableState())

  init(
    historyStatus: Int = 200,
    historyCode: String = "",
    readStatus: Int = 200,
    gateHistory: Bool = false,
    settingsStatus: Int = 200,
    settingsPUTStatus: Int = 200,
    holdFirstHistoryPut: Bool = false,
    historyOldest: [String] = []
  ) {
    self.historyStatus = historyStatus
    self.historyCode = historyCode
    self.readStatus = readStatus
    self.gateHistory = gateHistory
    self.settingsStatus = settingsStatus
    self.settingsPUTStatus = settingsPUTStatus
    self.holdFirstHistoryPut = holdFirstHistoryPut
    self.historyOldest = historyOldest
  }

  /// Returns once a quota-history PUT is being held.
  func waitUntilHistoryIsHeld() async {
    await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
      let held = state.withLock { state -> Bool in
        if state.historyContinuation != nil { return true }
        state.heldWaiters.append(waiter)
        return false
      }
      if held { waiter.resume() }
    }
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
    if method == "PUT", path == "/api/v6/device/quota-history" {
      let ordinal = state.withLock { state -> Int in
        state.historyPuts += 1
        return state.historyPuts
      }
      let hold = (holdFirstHistoryPut && ordinal == 1) || gateHistory
      if hold {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
          let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.historyContinuation = continuation
            defer { state.heldWaiters.removeAll() }
            return state.heldWaiters
          }
          for waiter in waiters { waiter.resume() }
        }
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
      if method == "PUT", settingsPUTStatus != 200 {
        return (settingsPUTStatus, errorBody("unavailable"), [:])
      }
      if method == "GET", settingsStatus != 200 {
        return (settingsStatus, errorBody("unavailable"), [:])
      }
      return (200, historySettingsBody(), ["ETag": "\"1\""])
    case ("GET", "/api/v2/device/sync"):
      return (200, deviceSyncBody(), [:])
    case ("PUT", "/api/v6/device/snapshots"):
      return (200, snapshotUploadBody(), [:])
    case ("PUT", "/api/v6/device/quota-history"):
      if historyStatus == 200 {
        let ordinal = state.withLock(\.historyPuts)
        let oldest =
          historyOldest.indices.contains(ordinal - 1)
          ? historyOldest[ordinal - 1] : "2026-09-21T10:00:00Z"
        return (200, historyUploadBody(oldest: oldest), [:])
      }
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

private func historyUploadBody(oldest: String) -> Data {
  Data(
    """
    {"protocol_version":6,"series":[{"provider":"codex","fingerprint":"account_test",\
    "window_id":"five_hour","bucket_start":"2026-09-21T10:15:00Z",\
    "oldest_bucket_start":"\(oldest)"}]}
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
