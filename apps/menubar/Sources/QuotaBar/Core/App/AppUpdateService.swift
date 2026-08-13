import CryptoKit
import Foundation

enum AppUpdateStatus: Equatable, Sendable {
  case idle
  case checking
  case available
  case current
  case failed
  case applying
}

struct AppUpdateService: Sendable {
  var feedURLs: [URL]
  var session: URLSession
  var destinationURL: @Sendable () -> URL

  static let primaryFeedURL = URL(string: "https://quota.gotry.io/updates/menubar.json")!
  static let releaseFeedURL = URL(
    string: "https://github.com/gotry-io/Quota/releases/latest/download/menubar-update.json")!

  init(
    feedURLs: [URL] = [primaryFeedURL, releaseFeedURL],
    session: URLSession = .shared,
    destinationURL: @escaping @Sendable () -> URL = {
      Bundle.main.bundleURL
    }
  ) {
    self.feedURLs = feedURLs
    self.session = session
    self.destinationURL = destinationURL
  }

  func check(currentVersion: String) async -> AppUpdateOffer? {
    for url in feedURLs {
      guard let (data, response) = try? await session.data(from: url),
        (response as? HTTPURLResponse)?.statusCode == 200,
        let feed = AppUpdateDecision.parseFeed(data)
      else {
        continue
      }
      if let offer = AppUpdateDecision.offer(currentVersion: currentVersion, feed: feed) {
        return offer
      }
      return nil
    }
    return nil
  }

  func apply(_ offer: AppUpdateOffer) async throws {
    let archive = try await download(offer.asset)
    try verify(archive, sha256: offer.asset.sha256)
    switch offer.kind {
    case .dmg:
      try await installDMG(archive)
    case .zip:
      try await installZip(archive)
    }
  }

  private func download(_ asset: AppUpdateAsset) async throws -> URL {
    let (temp, _) = try await session.download(from: asset.url)
    let folder = FileManager.default.temporaryDirectory
      .appending(path: "QuotaBarUpdate-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let destination = folder.appending(path: asset.url.lastPathComponent)
    try FileManager.default.moveItem(at: temp, to: destination)
    return destination
  }

  private func verify(_ file: URL, sha256: String) throws {
    let data = try Data(contentsOf: file, options: .mappedIfSafe)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard digest == sha256 else {
      throw AppUpdateError.checksumMismatch
    }
  }

  private func installDMG(_ dmg: URL) async throws {
    let mount = FileManager.default.temporaryDirectory
      .appending(path: "QuotaBarMount-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
    try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-mountpoint", mount.path])
    defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
    guard let app = try findApp(in: mount) else {
      throw AppUpdateError.archiveMissingApp
    }
    try scheduleReplace(app)
  }

  private func installZip(_ zip: URL) async throws {
    let extracted = FileManager.default.temporaryDirectory
      .appending(path: "QuotaBarUnzip-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
    try run("/usr/bin/ditto", ["-xk", zip.path, extracted.path])
    guard let app = try findApp(in: extracted) else {
      throw AppUpdateError.archiveMissingApp
    }
    try scheduleReplace(app)
  }

  private func findApp(in root: URL) throws -> URL? {
    let contents = try FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: nil)
    if let match = contents.first(where: { $0.lastPathComponent == "QuotaBar.app" }) {
      return match
    }
    for child in contents where child.hasDirectoryPath {
      if let nested = try findApp(in: child) { return nested }
    }
    return nil
  }

  private func scheduleReplace(_ replacement: URL) throws {
    let destination = destinationURL()
    let script = FileManager.default.temporaryDirectory
      .appending(path: "quotabar-apply-\(UUID().uuidString).sh")
    let body = """
      #!/bin/bash
      set -euo pipefail
      for _ in $(seq 1 50); do
        if ! /usr/bin/pgrep -xq QuotaBar; then
          break
        fi
        sleep 0.2
      done
      /usr/bin/ditto --rsrc --extattr --acl "$1" "$2"
      /usr/bin/open "$2"
      """
    try body.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [script.path, replacement.path, destination.path]
    try process.run()
  }

  @discardableResult
  private func run(_ launchPath: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw AppUpdateError.installFailed
    }
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
  }
}

enum AppUpdateError: Error {
  case checksumMismatch
  case archiveMissingApp
  case installFailed
}
