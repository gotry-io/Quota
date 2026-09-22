import Foundation
import Observation
import QuotaAccount
import QuotaPresentation
import QuotaRelay
import QuotaWire

/// Splits an upload into chunks of at most 2 000 points and under 256 KiB, oldest first.
enum QuotaHistoryChunker {
  static func chunks(
    _ series: [QuotaHistoryUploadRequest.Series],
    maxPoints: Int = QuotaHistoryUploadRequest.maximumPoints,
    maxBytes: Int = QuotaHistoryUploadRequest.maximumBytes
  ) -> [[QuotaHistoryUploadRequest.Series]] {
    var flat: [Item] = []
    for series in series {
      for point in series.points {
        flat.append(
          Item(
            provider: series.provider,
            fingerprint: series.fingerprint,
            windowId: series.windowId,
            durationSeconds: series.durationSeconds,
            point: point
          )
        )
      }
    }
    flat.sort { lhs, rhs in
      if lhs.point.bucketStart != rhs.point.bucketStart {
        return lhs.point.bucketStart < rhs.point.bucketStart
      }
      if lhs.point.resetsAt != rhs.point.resetsAt {
        return lhs.point.resetsAt < rhs.point.resetsAt
      }
      if lhs.provider.rawValue != rhs.provider.rawValue {
        return lhs.provider.rawValue < rhs.provider.rawValue
      }
      if lhs.fingerprint != rhs.fingerprint { return lhs.fingerprint < rhs.fingerprint }
      return lhs.windowId < rhs.windowId
    }
    var chunks: [[Item]] = []
    var current: [Item] = []
    for item in flat {
      let candidate = current + [item]
      let overflows = candidate.count > maxPoints || encodedCount(candidate) > maxBytes
      if overflows && !current.isEmpty {
        chunks.append(current)
        current = [item]
      } else {
        current = candidate
      }
    }
    if !current.isEmpty { chunks.append(current) }
    return chunks.map(group)
  }

  /// Size of the body as it would be sent. `Int.max` is the widest generation, so a chunk that
  /// fits here also fits the generation Relay just answered.
  private static func encodedCount(_ items: [Item]) -> Int {
    let request = QuotaHistoryUploadRequest(generation: Int.max, series: group(items))
    return (try? WireCodec.encodeRequest(request).count) ?? Int.max
  }

  private static func group(_ items: [Item]) -> [QuotaHistoryUploadRequest.Series] {
    var order: [String] = []
    var grouped: [String: QuotaHistoryUploadRequest.Series] = [:]
    for item in items {
      let key = "\(item.provider.rawValue)\u{0}\(item.fingerprint)\u{0}\(item.windowId)"
      if grouped[key] == nil {
        order.append(key)
        grouped[key] = QuotaHistoryUploadRequest.Series(
          provider: item.provider,
          fingerprint: item.fingerprint,
          windowId: item.windowId,
          durationSeconds: item.durationSeconds,
          points: []
        )
      }
      grouped[key]?.points.append(item.point)
    }
    return order.compactMap { grouped[$0] }
  }

  private struct Item {
    var provider: ProviderID
    var fingerprint: String
    var windowId: String
    var durationSeconds: Int
    var point: QuotaHistoryUploadRequest.Point
  }
}

/// Uploads this iPhone's journal while the Account switch is on, and reads one subscription's
/// merged series for the detail chart.
@MainActor
@Observable
final class QuotaHistoryCoordinator {
  private let account: AccountClient
  private let watermarks: any QuotaHistoryWatermarkStoring
  private let reads: any QuotaHistoryReadStoring
  private let now: @Sendable () -> Date

  /// Subscription key → window id → samples folded from the Account series.
  private(set) var samplesBySubscription: [String: [String: [QuotaSample]]] = [:]

  @ObservationIgnored var historySync: @MainActor () -> Bool = { false }
  @ObservationIgnored var noteSyncOff: @MainActor () -> Void = {}
  @ObservationIgnored var localSamples: @MainActor () -> LocalQuotaSamples = { LocalQuotaSamples() }
  @ObservationIgnored var snapshots: @MainActor () -> [QuotaSnapshot] = { [] }

  @ObservationIgnored private var stoppedForFull = false
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var chain: Task<Void, Never> = Task {}

  init(
    account: AccountClient,
    watermarks: any QuotaHistoryWatermarkStoring,
    reads: any QuotaHistoryReadStoring,
    now: @escaping @Sendable () -> Date
  ) {
    self.account = account
    self.watermarks = watermarks
    self.reads = reads
    self.now = now
  }

  /// One upload pass. Overlapping calls run one after another, never two PUTs at once.
  func sync() async {
    let previous = chain
    let next = Task { @MainActor in
      await previous.value
      await self.performSync()
    }
    chain = next
    await next.value
  }

  /// Forget watermarks and cached reads. Sign-out and a lost session both call this.
  func clear() {
    generation += 1
    stoppedForFull = false
    samplesBySubscription = [:]
    try? watermarks.clear()
    try? reads.clear()
  }

  /// Read the Account series for one subscription. Switch off, or a failed read with nothing
  /// cached, leaves no samples so the chart stays on today's local path.
  func load(_ subscription: QuotaSubscription) async {
    let generation = generation
    let key = subscription.key
    guard historySync() else {
      samplesBySubscription.removeValue(forKey: key)
      return
    }
    let accountIdentity = subscription.snapshot.account
    guard accountIdentity.fingerprintScope == .global,
      WireValidation.isOpaqueID(accountIdentity.fingerprint)
    else {
      samplesBySubscription.removeValue(forKey: key)
      return
    }
    guard let session = try? await account.loadSession() else { return }
    guard generation == self.generation else { return }
    let since = Self.readSince(now())
    let provider = subscription.snapshot.provider
    let cached = (try? reads.load())?.entry(
      accountID: session.accountID,
      provider: provider.rawValue,
      fingerprint: accountIdentity.fingerprint,
      since: since
    )
    if let cached {
      publish(Self.samplesByWindow(cached.body), for: key)
    }
    do {
      let outcome = try await account.fetchQuotaHistory(
        provider: provider,
        fingerprint: accountIdentity.fingerprint,
        since: since,
        etag: cached?.etag
      )
      guard generation == self.generation else { return }
      switch outcome {
      case .notModified:
        if cached == nil { samplesBySubscription.removeValue(forKey: key) }
      case .fresh(let body, let etag):
        var file = (try? reads.load()) ?? .empty
        file.entries.removeAll {
          $0.matches(
            accountID: session.accountID,
            provider: provider.rawValue,
            fingerprint: accountIdentity.fingerprint,
            since: since
          )
        }
        file.entries.append(
          QuotaHistoryReadCacheFile.Entry(
            accountID: session.accountID,
            provider: provider.rawValue,
            fingerprint: accountIdentity.fingerprint,
            since: since,
            etag: etag,
            body: body
          )
        )
        try? reads.save(file)
        publish(Self.samplesByWindow(body), for: key)
      }
    } catch {
      guard generation == self.generation else { return }
      if cached == nil { samplesBySubscription.removeValue(forKey: key) }
    }
  }

  private func performSync() async {
    let generation = generation
    guard let session = try? await account.loadSession(),
      session.activation == .active,
      session.deviceID != nil
    else { return }
    guard generation == self.generation else { return }
    let accountID = session.accountID
    var file = (try? watermarks.load()) ?? .empty
    var accountState = file.accounts[accountID] ?? .empty
    guard historySync() else {
      guard accountState.observedSync || !accountState.series.isEmpty else { return }
      file.accounts[accountID] = .empty
      guard generation == self.generation else { return }
      try? watermarks.save(file)
      return
    }
    guard !stoppedForFull else { return }
    let backfill = !accountState.observedSync
    let now = now()
    let built = buildSeries(
      snapshots: snapshots(),
      samples: localSamples(),
      state: accountState,
      backfill: backfill,
      now: now
    )
    // One out-of-range point makes Relay refuse the whole PUT.
    let chunks = Self.uploadableBatches(QuotaHistoryChunker.chunks(built), now: now)
    if chunks.isEmpty {
      accountState.observedSync = true
      file.accounts[accountID] = accountState
      guard generation == self.generation else { return }
      try? watermarks.save(file)
      return
    }
    let batch = await account.uploadQuotaHistory(chunks: chunks)
    guard generation == self.generation else { return }
    if batch.error == .historySyncOff {
      file.accounts[accountID] = .empty
      try? watermarks.save(file)
      noteSyncOff()
      return
    }
    for (chunk, response) in zip(chunks, batch.responses) {
      apply(chunk: chunk, response: response, to: &accountState)
    }
    if batch.error == nil {
      accountState.observedSync = true
    }
    file.accounts[accountID] = accountState
    try? watermarks.save(file)
    if batch.error == .quotaHistoryFull {
      stoppedForFull = true
    }
  }

  private func publish(_ samples: [String: [QuotaSample]], for key: String) {
    if samples.values.contains(where: { !$0.isEmpty }) {
      samplesBySubscription[key] = samples
    } else {
      samplesBySubscription.removeValue(forKey: key)
    }
  }

  private func buildSeries(
    snapshots: [QuotaSnapshot],
    samples: LocalQuotaSamples,
    state: QuotaHistoryWatermarkFile.Account,
    backfill: Bool,
    now: Date
  ) -> [QuotaHistoryUploadRequest.Series] {
    var byKey: [String: QuotaSnapshot] = [:]
    for snapshot in snapshots where snapshot.account.fingerprintScope == .global {
      guard WireValidation.isOpaqueID(snapshot.account.fingerprint) else { continue }
      byKey[LocalQuotaSamples.key(for: snapshot)] = snapshot
    }
    var series: [QuotaHistoryUploadRequest.Series] = []
    for entry in samples.windows {
      guard let snapshot = byKey[entry.subscriptionKey],
        let window = snapshot.windows.first(where: { $0.id == entry.windowID }),
        let duration = window.durationSeconds, duration >= 0,
        WireValidation.isBillingDimension(entry.windowID)
      else { continue }
      let normalized = entry.samples.map {
        QuotaSample(
          resetsAt: Self.wholeSeconds($0.resetsAt),
          observedAt: $0.observedAt,
          usedPercent: $0.usedPercent
        )
      }
      let stored = state.series.first {
        $0.provider == snapshot.provider.rawValue
          && $0.fingerprint == snapshot.account.fingerprint
          && $0.windowID == entry.windowID
      }
      let lastUploaded: [QuotaHistorySync.Bucket]
      let relevant: [QuotaSample]
      if backfill || stored?.newestBucketStart == nil {
        relevant = normalized
        lastUploaded = []
      } else {
        let watermark = stored?.newestBucketStart
        relevant = normalized.filter { sample in
          guard let watermark else { return true }
          let start = Self.bucketStart(sample.observedAt, durationSeconds: duration)
          return start >= watermark
        }
        lastUploaded = stored?.lastUploaded ?? []
      }
      let buckets = QuotaHistorySync.bucket(
        samples: relevant,
        durationSeconds: duration,
        now: now,
        lastUploaded: lastUploaded
      )
      guard !buckets.isEmpty else { continue }
      series.append(
        QuotaHistoryUploadRequest.Series(
          provider: snapshot.provider,
          fingerprint: snapshot.account.fingerprint,
          windowId: entry.windowID,
          durationSeconds: duration,
          points: buckets.map {
            QuotaHistoryUploadRequest.Point(
              resetsAt: $0.resetsAt,
              bucketStart: $0.bucketStart,
              usedPercent: $0.usedPercent
            )
          }
        )
      )
    }
    return series
  }

  /// ``QuotaHistorySync/uploadable(_:durationSeconds:now:)`` on every series of every batch.
  /// An empty series is not sent, and a batch that becomes empty is not sent.
  private static func uploadableBatches(
    _ chunks: [[QuotaHistoryUploadRequest.Series]],
    now: Date
  ) -> [[QuotaHistoryUploadRequest.Series]] {
    chunks.compactMap { chunk in
      let series = chunk.compactMap { uploadable($0, now: now) }
      return series.isEmpty ? nil : series
    }
  }

  private static func uploadable(
    _ series: QuotaHistoryUploadRequest.Series,
    now: Date
  ) -> QuotaHistoryUploadRequest.Series? {
    let kept = QuotaHistorySync.uploadable(
      series.points.map {
        QuotaHistorySync.Bucket(
          resetsAt: $0.resetsAt,
          bucketStart: $0.bucketStart,
          usedPercent: $0.usedPercent
        )
      },
      durationSeconds: series.durationSeconds,
      now: now
    )
    guard !kept.isEmpty else { return nil }
    return QuotaHistoryUploadRequest.Series(
      provider: series.provider,
      fingerprint: series.fingerprint,
      windowId: series.windowId,
      durationSeconds: series.durationSeconds,
      points: kept.map {
        QuotaHistoryUploadRequest.Point(
          resetsAt: $0.resetsAt,
          bucketStart: $0.bucketStart,
          usedPercent: $0.usedPercent
        )
      }
    )
  }

  private func apply(
    chunk: [QuotaHistoryUploadRequest.Series],
    response: QuotaHistoryUploadResponse,
    to state: inout QuotaHistoryWatermarkFile.Account
  ) {
    for series in chunk {
      let answered = response.series.first {
        $0.provider == series.provider && $0.fingerprint == series.fingerprint
          && $0.windowId == series.windowId
      }
      var stored = state.series.first {
        $0.provider == series.provider.rawValue && $0.fingerprint == series.fingerprint
          && $0.windowID == series.windowId
      } ?? QuotaHistoryWatermarkFile.Series(
        provider: series.provider.rawValue,
        fingerprint: series.fingerprint,
        windowID: series.windowId,
        newestBucketStart: nil,
        lastUploaded: []
      )
      if let newest = answered?.newestBucketStart {
        if let current = stored.newestBucketStart {
          stored.newestBucketStart = max(current, newest)
        } else {
          stored.newestBucketStart = newest
        }
      } else if let latest = series.points.map(\.bucketStart).max() {
        if let current = stored.newestBucketStart {
          stored.newestBucketStart = max(current, latest)
        } else {
          stored.newestBucketStart = latest
        }
      }
      for point in series.points {
        let bucket = QuotaHistorySync.Bucket(
          resetsAt: point.resetsAt,
          bucketStart: point.bucketStart,
          usedPercent: point.usedPercent
        )
        if let index = stored.lastUploaded.firstIndex(where: { $0.resetsAt == bucket.resetsAt }) {
          if bucket.bucketStart >= stored.lastUploaded[index].bucketStart {
            stored.lastUploaded[index] = bucket
          }
        } else {
          stored.lastUploaded.append(bucket)
        }
      }
      if let index = state.series.firstIndex(where: {
        $0.provider == stored.provider && $0.fingerprint == stored.fingerprint
          && $0.windowID == stored.windowID
      }) {
        state.series[index] = stored
      } else {
        state.series.append(stored)
      }
    }
  }

  private static func samplesByWindow(
    _ body: QuotaHistoryReadResponse
  ) -> [String: [QuotaSample]] {
    guard body.sync else { return [:] }
    return body.windows.mapValues { window in
      QuotaHistorySync.samples(
        from: window.points.map {
          QuotaHistorySync.Bucket(
            resetsAt: $0.resetsAt,
            bucketStart: $0.bucketStart,
            usedPercent: $0.usedPercent
          )
        }
      )
    }
  }

  /// `since` floored to the UTC day, then 30 days back, so one day of opens share an ETag.
  static func readSince(_ now: Date) -> Date {
    let day: TimeInterval = 86_400
    let dayStart = (now.timeIntervalSince1970 / day).rounded(.down) * day
    return Date(timeIntervalSince1970: dayStart - 30 * day)
  }

  private static func wholeSeconds(_ date: Date) -> Date {
    Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
  }

  /// Same floor `QuotaHistorySync.bucket` uses: `floor(observed / size) × size`.
  private static func bucketStart(_ observed: Date, durationSeconds: Int) -> Date {
    let size = Double(QuotaHistorySync.bucketSeconds(durationSeconds: durationSeconds))
    let epoch = observed.timeIntervalSince1970
    return Date(timeIntervalSince1970: (epoch / size).rounded(.down) * size)
  }
}
