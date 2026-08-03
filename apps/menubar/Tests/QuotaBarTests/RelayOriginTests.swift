import Foundation
import Testing

@testable import QuotaBar

@Test
func canonicalizesRelayOrigins() throws {
  #expect(
    try RelayOrigin.canonicalURL(from: "HTTPS://Example.COM:443/").absoluteString
      == "https://example.com"
  )
  #expect(
    try RelayOrigin.canonicalURL(from: "http://localhost:80/").absoluteString
      == "http://localhost"
  )
  #expect(
    try RelayOrigin.canonicalURL(from: "http://127.0.0.1:8787").absoluteString
      == "http://127.0.0.1:8787"
  )
  #expect(
    try RelayOrigin.canonicalURL(from: "http://[::1]:8787/").absoluteString
      == "http://[::1]:8787"
  )
}

@Test(
  arguments: [
    "",
    " quota.example.com",
    "https://quota.example.com ",
    "https://user:secret@quota.example.com",
    "https://quota.example.com/api",
    "https://quota.example.com/./",
    "https://quota.example.com/%2e/",
    "https://quota.example.com?",
    "https://quota.example.com?mode=controller",
    "https://quota.example.com#",
    "ftp://quota.example.com",
    "quota.example.com",
  ]
)
func rejectsNonOriginRelayURLs(rawValue: String) {
  #expect(throws: RelayOriginError.self) {
    try RelayOrigin.canonicalURL(from: rawValue)
  }
}

@Test(arguments: ["http://example.com", "http://192.168.1.2", "http://localhost.example.com"])
func rejectsRemotePlaintextRelayURLs(rawValue: String) {
  #expect(throws: RelayOriginError.insecureURL) {
    try RelayOrigin.canonicalURL(from: rawValue)
  }
}
