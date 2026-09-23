import Foundation
import Observation
import QuotaAccount
import QuotaPresentation
import QuotaRelay
import QuotaWire

/// Splits an upload into chunks of at most 2 000 points and under 256 KiB, oldest first.
///
/// Each point is encoded once. A running sum plus the request and series overhead decides
/// where a chunk ends, and the real body is measured once per chunk. A chunk that is still
/// over the cap is split.
enum QuotaHistoryChunker {
  static func chunks(
    _ series: [QuotaHistoryUploadRequest.Series],
    maxPoints: Int = QuotaHistoryUploadRequest.maximumPoints,
    maxBytes: Int = QuotaHistoryUploadRequest.maximumBytes
  ) -> [[QuotaHistoryUploadRequest.Series]] {
    let flat = flatten(series)
    guard !flat.isEmpty else { return [] }
    let pointSizes = flat.map { pointBytes($0.point) }
    var headerBytes: [String: Int] = [:]
    func header(_ item: Item) -> Int {
      let key = seriesKey(item)
      if let known = headerBytes[key] { return known }
      let bytes = seriesHeaderBytes(item)
      headerBytes[key] = bytes
      return bytes
    }

    var ranges: [Range<Int>] = []
    var start = 0
    var bytes = requestShellBytes
    var seriesCount = 0
    var pointsInSeries: [String: Int] = [:]

    for index in flat.indices {
      let item = flat[index]
      let key = seriesKey(item)
      let seen = pointsInSeries[key, default: 0]
      let addition: Int
      if seen == 0 {
        let comma = seriesCount > 0 ? 1 : 0
        addition = comma + header(item) + pointSizes[index]
      } else {
        addition = 1 + pointSizes[index]
      }
      let count = index - start
      let overflows =
        count > 0 && (count >= maxPoints || !fits(bytes, adding: addition, limit: maxBytes))
      if overflows {
        ranges.append(start..<index)
        start = index
        pointsInSeries = [key: 1]
        seriesCount = 1
        bytes = sum(requestShellBytes, header(item), pointSizes[index])
        continue
      }
      if seen == 0 { seriesCount += 1 }
      pointsInSeries[key] = seen + 1
      bytes = sum(bytes, addition)
    }
    if start < flat.count {
      ranges.append(start..<flat.count)
    }

    var chunks: [[QuotaHistoryUploadRequest.Series]] = []
    for range in ranges {
      let items = Array(flat[range])
      for piece in splitToFit(items, maxPoints: maxPoints, maxBytes: maxBytes) {
        chunks.append(group(piece))
      }
    }
    return chunks
  }

  /// `Int.max` is the widest generation, so a chunk that fits here also fits the generation
  /// Relay just answered.
  private static func encodedBytes(_ items: [Item]) -> Int {
    let request = QuotaHistoryUploadRequest(generation: Int.max, series: group(items))
    return (try? WireCodec.encodeRequest(request).count) ?? Int.max
  }

  private static func splitToFit(
    _ items: [Item],
    maxPoints: Int,
    maxBytes: Int
  ) -> [[Item]] {
    guard !items.isEmpty else { return [] }
    if items.count <= maxPoints && encodedBytes(items) <= maxBytes {
      return [items]
    }
    guard items.count > 1 else { return [items] }
    let limit = min(items.count, maxPoints)
    var low = 1
    var high = limit - 1
    var best = 1
    while low <= high {
      let mid = low + (high - low) / 2
      if encodedBytes(Array(items.prefix(mid))) <= maxBytes {
        best = mid
        low = mid + 1
      } else {
        high = mid - 1
      }
    }
    let head = Array(items.prefix(best))
    let tail = Array(items.dropFirst(best))
    return [head] + splitToFit(tail, maxPoints: maxPoints, maxBytes: maxBytes)
  }

  private static func fits(_ current: Int, adding extra: Int, limit: Int) -> Bool {
    let (total, overflow) = current.addingReportingOverflow(extra)
    return !overflow && total <= limit
  }

  private static func sum(_ values: Int...) -> Int {
    values.reduce(0) { partial, value in
      let (total, overflow) = partial.addingReportingOverflow(value)
      return overflow ? Int.max : total
    }
  }

  private static let requestShellBytes: Int = {
    let request = QuotaHistoryUploadRequest(generation: Int.max, series: [])
    return (try? WireCodec.encodeRequest(request).count) ?? 0
  }()

  private static func pointBytes(_ point: QuotaHistoryUploadRequest.Point) -> Int {
    (try? WireCodec.encodeRequest(point).count) ?? Int.max
  }

  private static func seriesHeaderBytes(_ item: Item) -> Int {
    let series = QuotaHistoryUploadRequest.Series(
      provider: item.provider,
      fingerprint: item.fingerprint,
      windowId: item.windowId,
      durationSeconds: item.durationSeconds,
      points: []
    )
    return (try? WireCodec.encodeRequest(series).count) ?? Int.max
  }

  private static func flatten(_ series: [QuotaHistoryUploadRequest.Series]) -> [Item] {
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
    return flat
  }

  private static func seriesKey(_ item: Item) -> String {
    "\(item.provider.rawValue)\u{0}\(item.fingerprint)\u{0}\(item.windowId)"
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

  /// Nil is no document yet: do not upload and do not clear. False clears. True uploads.
  @ObservationIgnored var historySync: @MainActor () -> Bool? = { nil }
  @ObservationIgnored var noteSyncOff: @MainActor () -> Void = {}
  @ObservationIgnored var localSamples: @MainActor () -> LocalQuotaSamples = { LocalQuotaSamples() }
  @ObservationIgnored var snapshots: @MainActor () -> [QuotaSnapshot] = { [] }
  /// Wire caps. Tests pass a smaller point cap so one journal fills more than one request.
  @ObservationIgnored var maximumPointsPerChunk = QuotaHistoryUploadRequest.maximumPoints
  @ObservationIgnored var maximumBytesPerChunk = QuotaHistoryUploadRequest.maximumBytes

  @ObservationIgnored private var stoppedForFull = false
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var chain: Task<Void, Never> = Task {}
  /// A failed upload. The next pass skips bucketing until this is a minute old.
  @ObservationIgnored private var lastUploadFailure: Date?
  private static let uploadBackoff: TimeInterval = 60

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
  ///
  /// The chain is an unstructured task so the calls stay ordered. Cancelling this call is
  /// forwarded into that task, which is what a background refresh's expiration handler needs
  /// in order to stop before the next chunk.
  func sync() async {
    let previous = chain
    let next = Task { @MainActor in
      await previous.value
      guard !Task.isCancelled else { return }
      await self.performSync()
    }
    chain = next
    await withTaskCancellationHandler {
      await next.value
    } onCancel: {
      next.cancel()
    }
  }

  /// Forget watermarks and cached reads. Sign-out and a lost session both call this.
  func clear() {
    generation += 1
    stoppedForFull = false
    lastUploadFailure = nil
    samplesBySubscription = [:]
    try? watermarks.clear()
    try? reads.clear()
  }

  /// Read the Account series for one subscription. Switch off, or a failed read with nothing
  /// cached, leaves no samples so the chart stays on today's local path.
  func load(_ subscription: QuotaSubscription) async {
    let generation = generation
    let key = subscription.key
    switch historySync() {
    case .some(false):
      samplesBySubscription.removeValue(forKey: key)
      return
    case .none:
      return
    case .some(true):
      break
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
    let file = (try? reads.load()) ?? .empty
    let cached = file.entry(
      accountID: session.accountID,
      provider: provider.rawValue,
      fingerprint: accountIdentity.fingerprint
    )
    if let cached {
      publish(Self.samplesByWindow(cached.body), for: key)
    }
    let etag = cached?.sinceMatches(since) == true ? cached?.etag : nil
    do {
      let outcome = try await account.fetchQuotaHistory(
        provider: provider,
        fingerprint: accountIdentity.fingerprint,
        since: since,
        etag: etag
      )
      guard generation == self.generation else { return }
      switch outcome {
      case .notModified:
        if cached == nil { samplesBySubscription.removeValue(forKey: key) }
      case .fresh(let body, let etag):
        var stored = (try? reads.load()) ?? file
        stored.replace(
          QuotaHistoryReadCacheFile.Entry(
            accountID: session.accountID,
            provider: provider.rawValue,
            fingerprint: accountIdentity.fingerprint,
            since: since,
            etag: etag,
            body: body
          )
        )
        try? reads.save(stored)
        publish(Self.samplesByWindow(body), for: key)
      }
    } catch {
      guard generation == self.generation else { return }
      if cached == nil { samplesBySubscription.removeValue(forKey: key) }
    }
  }

  private func performSync() async {
    if Task.isCancelled { return }
    let generation = generation
    guard let session = try? await account.loadSession(),
      session.activation == .active,
      session.deviceID != nil
    else { return }
    guard generation == self.generation else { return }
    let accountID = session.accountID
    var file = (try? watermarks.load()) ?? .empty
    var accountState = file.accounts[accountID] ?? .empty
    switch historySync() {
    case .none:
      return
    case .some(false):
      guard accountState.observedSync || !accountState.series.isEmpty else { return }
      file.accounts[accountID] = .empty
      guard generation == self.generation else { return }
      try? watermarks.save(file)
      return
    case .some(true):
      break
    }
    guard !stoppedForFull else { return }
    let started = now()
    if let failed = lastUploadFailure, started.timeIntervalSince(failed) < Self.uploadBackoff {
      return
    }
    // Relay lost rows of a series behind this iPhone (the switch went off and on between two
    // refreshes): that series is backfilled again, once per pass.
    var rebackfilled = false
    while true {
      if Task.isCancelled { return }
      let now = rebackfilled ? self.now() : started
      let backfill = !accountState.observedSync
      let built = buildSeries(
        snapshots: snapshots(),
        samples: localSamples(),
        state: accountState,
        backfill: backfill,
        now: now
      )
      // One out-of-range point makes Relay refuse the whole PUT.
      let chunks = Self.uploadableBatches(
        QuotaHistoryChunker.chunks(
          built,
          maxPoints: maximumPointsPerChunk,
          maxBytes: maximumBytesPerChunk
        ),
        now: now
      )
      if chunks.isEmpty {
        accountState.observedSync = true
        file.accounts[accountID] = accountState
        guard generation == self.generation else { return }
        try? watermarks.save(file)
        lastUploadFailure = nil
        return
      }
      if Task.isCancelled { return }
      let batch = await account.uploadQuotaHistory(chunks: chunks)
      guard generation == self.generation else { return }
      let answeredAt = self.now()
      if batch.cancelled {
        guard !batch.responses.isEmpty else { return }
        _ = apply(
          chunks: chunks,
          responses: batch.responses,
          to: &accountState,
          judge: !rebackfilled,
          now: answeredAt
        )
        file.accounts[accountID] = accountState
        try? watermarks.save(file)
        return
      }
      if batch.error == .historySyncOff {
        file.accounts[accountID] = .empty
        try? watermarks.save(file)
        noteSyncOff()
        return
      }
      let lost = apply(
        chunks: chunks,
        responses: batch.responses,
        to: &accountState,
        judge: !rebackfilled,
        now: answeredAt
      )
      if batch.error == nil {
        accountState.observedSync = true
        lastUploadFailure = nil
      } else {
        lastUploadFailure = answeredAt
      }
      file.accounts[accountID] = accountState
      try? watermarks.save(file)
      if batch.error == .quotaHistoryFull {
        stoppedForFull = true
      }
      guard batch.error == nil, !lost.isEmpty, !rebackfilled else { return }
      rebackfilled = true
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
      guard let buckets, !buckets.isEmpty else { continue }
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

  /// Remembers what each answered chunk stored. With `judge`, a series whose rows Relay no
  /// longer holds
  /// (``QuotaHistorySync/rowsLost(recordedOldest:watermark:chunkOldest:answer:durationSeconds:now:)``)
  /// is forgotten instead, for this and every later chunk, so the next pass backfills it.
  private func apply(
    chunks: [[QuotaHistoryUploadRequest.Series]],
    responses: [QuotaHistoryUploadResponse],
    to state: inout QuotaHistoryWatermarkFile.Account,
    judge: Bool,
    now: Date
  ) -> Set<String> {
    var lost: Set<String> = []
    for (chunk, response) in zip(chunks, responses) {
      for series in chunk {
        let key = Self.seriesKey(series.provider.rawValue, series.fingerprint, series.windowId)
        if lost.contains(key) { continue }
        let answered = response.series.first {
          $0.provider == series.provider && $0.fingerprint == series.fingerprint
            && $0.windowId == series.windowId
        }
        let stored = state.series.first {
          Self.seriesKey($0.provider, $0.fingerprint, $0.windowID) == key
        }
        // The record and the watermark from before this chunk is remembered.
        if judge, let chunkOldest = series.points.map(\.bucketStart).min(),
          QuotaHistorySync.rowsLost(
            recordedOldest: stored?.oldestBucketStart,
            watermark: stored?.newestBucketStart,
            chunkOldest: chunkOldest,
            answer: answered.map { .oldest($0.oldestBucketStart) } ?? .absent,
            durationSeconds: series.durationSeconds,
            now: now
          )
        {
          lost.insert(key)
          state.series.removeAll {
            Self.seriesKey($0.provider, $0.fingerprint, $0.windowID) == key
          }
          continue
        }
        apply(series: series, answered: answered, to: &state, now: now)
      }
    }
    return lost
  }

  private func apply(
    series: QuotaHistoryUploadRequest.Series,
    answered: QuotaHistoryUploadResponse.SeriesWatermark?,
    to state: inout QuotaHistoryWatermarkFile.Account,
    now: Date
  ) {
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
    if let earliest = series.points.map(\.bucketStart).min() {
      stored.oldestBucketStart = QuotaHistorySync.reseedOldest(
        stored.oldestBucketStart,
        chunkOldest: earliest,
        durationSeconds: series.durationSeconds,
        now: now
      )
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

  private static func seriesKey(_ provider: String, _ fingerprint: String, _ windowID: String)
    -> String
  {
    "\(provider)\u{0}\(fingerprint)\u{0}\(windowID)"
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
