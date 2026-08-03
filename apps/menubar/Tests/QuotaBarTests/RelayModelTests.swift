import Foundation
import Testing

@testable import QuotaBar

@Test
func decodesFractionalAndOffsetISODateTimes() throws {
  let data = Data(
    #"{"fractional":"2026-08-03T10:20:30.123Z","offset":"2026-08-03T18:20:30+08:00"}"#.utf8
  )

  let value = try QuotaWireCodec.makeDecoder().decode(DateFixture.self, from: data)

  #expect(value.fractional.timeIntervalSince1970 == 1_785_752_430.123)
  #expect(value.offset.timeIntervalSince1970 == 1_785_752_430)
}

@Test
func decodesControllerSnapshotObservations() throws {
  let response = try QuotaWireCodec.makeDecoder().decode(
    ControllerSnapshotListResponse.self,
    from: validObservationResponse
  )

  let observation = try #require(response.observations.first)
  #expect(observation.deviceID == "device_01")
  #expect(observation.sequence == 7)
  #expect(observation.snapshot.provider == .codex)
  #expect(observation.snapshot.windows.first?.id == "five_hour")
}

@Test
func decodesRelayDevices() throws {
  let data = Data(
    #"""
    {
      "devices": [{
        "device_id": "device_01",
        "display_name": "Build Mac",
        "created_at": "2026-08-03T10:20:30.123Z",
        "last_seen_at": "2026-08-03T18:20:30+08:00",
        "last_sequence": 7,
        "revoked_at": null
      }]
    }
    """#.utf8
  )

  let response = try QuotaWireCodec.makeDecoder().decode(DeviceListResponse.self, from: data)

  let device = try #require(response.devices.first)
  #expect(device.id == "device_01")
  #expect(device.displayName == "Build Mac")
  #expect(device.lastSequence == 7)
  #expect(device.revokedAt == nil)
}

@Test(arguments: ["\"device_id\":\"\"", "\"sequence\":-1", "\"used_percent\":101"])
func rejectsInvalidControllerObservations(replacement: String) throws {
  let original: String
  switch replacement {
  case "\"device_id\":\"\"":
    original = "\"device_id\":\"device_01\""
  case "\"sequence\":-1":
    original = "\"sequence\":7"
  default:
    original = "\"used_percent\":20"
  }
  let invalid = try #require(String(data: validObservationResponse, encoding: .utf8))
    .replacingOccurrences(of: original, with: replacement)

  #expect(throws: DecodingError.self) {
    try QuotaWireCodec.makeDecoder().decode(
      ControllerSnapshotListResponse.self,
      from: Data(invalid.utf8)
    )
  }
}

@Test(arguments: ["\"device_id\":\"\"", "\"last_sequence\":-2"])
func rejectsInvalidRelayDevices(replacement: String) {
  let original = replacement.contains("device_id")
    ? "\"device_id\":\"device_01\""
    : "\"last_sequence\":7"
  let valid =
    #"{"devices":[{"device_id":"device_01","display_name":"Mac","created_at":"2026-08-03T10:20:30Z","last_seen_at":null,"last_sequence":7,"revoked_at":null}]}"#

  #expect(throws: DecodingError.self) {
    try QuotaWireCodec.makeDecoder().decode(
      DeviceListResponse.self,
      from: Data(valid.replacingOccurrences(of: original, with: replacement).utf8)
    )
  }
}

@Test
func rejectsUnsupportedWireSchemaVersions() {
  let envelope = Data(
    #"{"schema_version":2,"device_id":"device_01","sequence":0,"captured_at":"2026-08-03T10:20:30Z","snapshots":[]}"#.utf8
  )
  let report = Data(
    #"{"schema_version":2,"captured_at":"2026-08-03T10:20:30Z","results":[]}"#.utf8
  )

  #expect(throws: DecodingError.self) {
    try QuotaWireCodec.makeDecoder().decode(QuotaSnapshotEnvelope.self, from: envelope)
  }
  #expect(throws: DecodingError.self) {
    try QuotaWireCodec.makeDecoder().decode(QuotaCollectionReport.self, from: report)
  }
}

private struct DateFixture: Decodable {
  let fractional: Date
  let offset: Date
}

private let validObservationResponse = Data(
  #"""
  {
    "observations": [{
      "device_id":"device_01",
      "sequence":7,
      "captured_at":"2026-08-03T10:20:30.123Z",
      "snapshot":{
        "provider":"codex",
        "account":{"fingerprint":"account_01","fingerprint_scope":"global"},
        "windows":[{"id":"five_hour","title":"5 hour","used_percent":20}],
        "source":"codex_api",
        "status":"available",
        "observed_at":"2026-08-03T18:20:30+08:00"
      },
      "updated_at":"2026-08-03T10:20:31Z"
    }]
  }
  """#.utf8
)
