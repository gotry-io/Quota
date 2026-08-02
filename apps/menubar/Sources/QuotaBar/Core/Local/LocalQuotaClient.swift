import Foundation

enum LocalQuotaClientError: LocalizedError {
  case helperMissing
  case launchFailed
  case invalidOutput

  var errorDescription: String? {
    switch self {
    case .helperMissing:
      "The bundled QuotaCLI helper is missing. Reinstall QuotaBar."
    case .launchFailed:
      "QuotaCLI could not collect local provider quota."
    case .invalidOutput:
      "QuotaCLI returned data that QuotaBar could not read."
    }
  }
}

protocol LocalQuotaCollecting: Sendable {
  func collect() async throws -> QuotaCollectionReport
}

actor LocalQuotaClient: LocalQuotaCollecting {
  private let executableURL: URL

  init(executableURL: URL? = nil, bundle: Bundle = .main) throws {
    if let executableURL {
      self.executableURL = executableURL
      return
    }

    let helperURL = bundle.bundleURL
      .appending(path: "Contents")
      .appending(path: "Helpers")
      .appending(path: "quotacli")
    guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
      throw LocalQuotaClientError.helperMissing
    }
    self.executableURL = helperURL
  }

  func collect() throws -> QuotaCollectionReport {
    let process = Process()
    let standardOutput = Pipe()

    process.executableURL = executableURL
    process.arguments = ["quota", "--provider", "all", "--format", "json"]
    process.standardOutput = standardOutput
    process.standardError = FileHandle.nullDevice

    do {
      try process.run()
    } catch {
      throw LocalQuotaClientError.launchFailed
    }

    let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    guard process.terminationReason == .exit,
      process.terminationStatus == 0 || process.terminationStatus == 1
    else {
      throw LocalQuotaClientError.launchFailed
    }

    do {
      let report = try QuotaWireCodec.makeDecoder().decode(QuotaCollectionReport.self, from: output)
      guard report.schemaVersion == 1 else {
        throw LocalQuotaClientError.invalidOutput
      }
      return report
    } catch let error as LocalQuotaClientError {
      throw error
    } catch {
      throw LocalQuotaClientError.invalidOutput
    }
  }
}
