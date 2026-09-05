import Foundation

/// Enough of gRPC-web and protobuf to read one billing answer.
///
/// grok.com answers this RPC with a proto this build has no schema for, so the service scans the
/// wire format for the two things it needs — the percent and the reset — by their field paths.
/// The scan is restated here field for field: a phone and a Mac reading the same answer must find
/// the same numbers.
extension GrokWebCollector {
  struct Fixed32Field {
    let path: [UInt64]
    let value: Float
    let order: Int
  }

  struct VarintField {
    let path: [UInt64]
    let value: UInt64
  }

  struct ProtobufScan {
    var fixed32: [Fixed32Field] = []
    var varints: [VarintField] = []

    mutating func merge(_ other: ProtobufScan) {
      fixed32.append(contentsOf: other.fixed32)
      varints.append(contentsOf: other.varints)
    }
  }

  static func dataFrames(_ data: [UInt8]) -> [[UInt8]] {
    var frames: [[UInt8]] = []
    var index = 0
    while index + 5 <= data.count {
      let flags = data[index]
      let length = Int(
        UInt32(data[index + 1]) << 24 | UInt32(data[index + 2]) << 16
          | UInt32(data[index + 3]) << 8 | UInt32(data[index + 4]))
      let start = index + 5
      let end = start + length
      if end > data.count { return [] }
      if flags & 0x80 == 0 { frames.append(Array(data[start..<end])) }
      index = end
    }
    return frames
  }

  static func trailerFields(_ data: [UInt8]) -> [String: String] {
    var fields: [String: String] = [:]
    var index = 0
    while index + 5 <= data.count {
      let flags = data[index]
      let length = Int(
        UInt32(data[index + 1]) << 24 | UInt32(data[index + 2]) << 16
          | UInt32(data[index + 3]) << 8 | UInt32(data[index + 4]))
      let start = index + 5
      let end = start + length
      if end > data.count { break }
      if flags & 0x80 != 0 {
        // Split on the bytes, not on characters: a `String` reads CRLF as one grapheme, and a
        // trailer block separated that way would arrive as a single unreadable line.
        for line in data[start..<end].split(whereSeparator: { $0 == 0x0a || $0 == 0x0d }) {
          guard let text = String(bytes: line, encoding: .utf8),
            let separator = text.firstIndex(of: ":")
          else { continue }
          let key = text[text.startIndex..<separator].trimmingCharacters(in: .whitespaces)
          let value = text[text.index(after: separator)...].trimmingCharacters(in: .whitespaces)
          fields[key.lowercased()] = value
        }
      }
      index = end
    }
    return fields
  }

  static func looksLikeProtobuf(_ data: [UInt8]) -> Bool {
    guard let first = data.first else { return false }
    let fieldNumber = first >> 3
    let wireType = first & 0x07
    return fieldNumber > 0 && [0, 1, 2, 5].contains(wireType)
  }

  static func scanProtobuf(_ data: [UInt8], depth: Int, path: [UInt64]) -> ProtobufScan {
    var scan = ProtobufScan()
    var index = 0
    var order = 0
    while index < data.count {
      let fieldStart = index
      guard let key = readVarint(data, &index) else { break }
      if key == 0 {
        index = fieldStart + 1
        continue
      }
      let fieldPath = path + [key >> 3]
      switch key & 0x07 {
      case 0:
        if let value = readVarint(data, &index) {
          scan.varints.append(VarintField(path: fieldPath, value: value))
        } else {
          index = fieldStart + 1
        }
      case 1:
        if index + 8 > data.count { return scan }
        index += 8
      case 2:
        guard let length = readVarint(data, &index) else {
          index = fieldStart + 1
          continue
        }
        let start = index
        guard length <= UInt64(data.count - start) else {
          index = fieldStart + 1
          continue
        }
        let end = start + Int(length)
        if depth < 4 {
          scan.merge(scanProtobuf(Array(data[start..<end]), depth: depth + 1, path: fieldPath))
        }
        index = end
      case 5:
        if index + 4 > data.count { return scan }
        let bits =
          UInt32(data[index]) | UInt32(data[index + 1]) << 8 | UInt32(data[index + 2]) << 16
          | UInt32(data[index + 3]) << 24
        scan.fixed32.append(
          Fixed32Field(path: fieldPath, value: Float(bitPattern: bits), order: order))
        order += 1
        index += 4
      default:
        index = fieldStart + 1
      }
    }
    return scan
  }

  static func readVarint(_ data: [UInt8], _ index: inout Int) -> UInt64? {
    var value: UInt64 = 0
    var shift: UInt64 = 0
    while index < data.count && shift < 64 {
      let byte = data[index]
      index += 1
      value |= UInt64(byte & 0x7f) << shift
      if byte & 0x80 == 0 { return value }
      shift += 7
    }
    return nil
  }
}
