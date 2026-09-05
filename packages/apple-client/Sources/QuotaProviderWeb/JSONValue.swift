import Foundation

/// A parsed provider document. The collectors read provider JSON exactly the way the Rust
/// service reads it — a missing key, a key of the wrong type, and a key that is `null` are three
/// different answers — so they read this rather than `Any` out of `JSONSerialization`.
public enum JSONValue: Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public init?(data: Data) {
    guard
      let parsed = try? JSONSerialization.jsonObject(
        with: data, options: [.fragmentsAllowed])
    else { return nil }
    self = JSONValue(any: parsed)
  }

  init(any value: Any) {
    switch value {
    case is NSNull:
      self = .null
    case let number as NSNumber:
      // `JSONSerialization` gives booleans back as `NSNumber`; only the boolean type id
      // separates `true` from `1`.
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        self = .bool(number.boolValue)
      } else {
        self = .number(number.doubleValue)
      }
    case let text as String:
      self = .string(text)
    case let items as [Any]:
      self = .array(items.map(JSONValue.init(any:)))
    case let entries as [String: Any]:
      self = .object(entries.mapValues(JSONValue.init(any:)))
    default:
      self = .null
    }
  }

  /// The value at `key`, or `nil` when this is not an object or does not name it. A key present
  /// and `null` answers `.null`, which is how an account says it has no such window.
  func get(_ key: String) -> JSONValue? {
    guard case .object(let entries) = self else { return nil }
    return entries[key]
  }

  /// The first of `keys` this object names, for the providers that spell one field two ways.
  func get(any keys: [String]) -> JSONValue? {
    keys.lazy.compactMap { self.get($0) }.first
  }

  var arrayValue: [JSONValue]? {
    guard case .array(let items) = self else { return nil }
    return items
  }

  var rawString: String? {
    guard case .string(let text) = self else { return nil }
    return text
  }

  var isObject: Bool {
    if case .object = self { return true }
    return false
  }

  var isNull: Bool { self == .null }

  var isTrue: Bool { self == .bool(true) }
}

enum ProviderJSON {
  /// A non-empty trimmed string, the service's `string`.
  static func string(_ value: JSONValue?) -> String? {
    guard case .string(let text)? = value else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// A finite number, spelled as a number or as the text of one.
  static func number(_ value: JSONValue?) -> Double? {
    switch value {
    case .number(let number): return number.isFinite ? number : nil
    case .string(let text):
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, let number = Double(trimmed), number.isFinite else { return nil }
      return number
    default: return nil
    }
  }

  static func clampPercent(_ value: Double) -> Double {
    value.isFinite ? min(max(value, 0), 100) : 0
  }

  /// An instant, as unix seconds, unix milliseconds, or RFC 3339 text.
  static func date(_ value: JSONValue?) -> Int? {
    switch value {
    case .number(let number): return numericDate(number)
    case .string(let text):
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { return nil }
      if let number = Double(trimmed) { return numericDate(number) }
      return rfc3339(trimmed)
    default: return nil
    }
  }

  private static func numericDate(_ value: Double) -> Int? {
    guard value.isFinite, value > 0 else { return nil }
    return Int((value > 10_000_000_000 ? (value / 1000).rounded(.down) : value.rounded(.down)))
  }

  /// The service's own RFC 3339 reader, restated: it accepts the offsets and fractional seconds
  /// providers actually send and refuses everything else, so both devices agree on what an
  /// unreadable instant is.
  static func rfc3339(_ value: String) -> Int? {
    let separator = value.contains("T") ? "T" : " "
    guard let split = value.range(of: separator) else { return nil }
    let date = String(value[value.startIndex..<split.lowerBound])
    var timeAndZone = String(value[split.upperBound...])
    let dateParts = date.split(separator: "-", omittingEmptySubsequences: false)
    guard dateParts.count == 3,
      let year = Int(dateParts[0]), let month = Int(dateParts[1]), let day = Int(dateParts[2])
    else { return nil }
    var offset = 0
    if timeAndZone.hasSuffix("Z") {
      timeAndZone.removeLast()
    } else if let marker = timeAndZone.lastIndex(where: { $0 == "+" || $0 == "-" }) {
      let zone = String(timeAndZone[timeAndZone.index(after: marker)...])
      let sign = timeAndZone[marker] == "-" ? -1 : 1
      let zoneParts = zone.split(separator: ":", omittingEmptySubsequences: false)
      guard let hours = Int(zoneParts.first ?? "") else { return nil }
      let minutes = zoneParts.count > 1 ? Int(zoneParts[1]) : 0
      guard let minutes else { return nil }
      offset = sign * (hours * 3600 + minutes * 60)
      timeAndZone = String(timeAndZone[timeAndZone.startIndex..<marker])
    } else {
      return nil
    }
    let timeParts = timeAndZone.split(separator: ":", omittingEmptySubsequences: false)
    guard timeParts.count >= 3, let hour = Int(timeParts[0]), let minute = Int(timeParts[1]),
      let second = Int(timeParts[2].split(separator: ".", omittingEmptySubsequences: false)[0])
    else { return nil }
    guard month > 0, month <= 12, day > 0, day <= 31, hour <= 23, minute <= 59, second <= 60
    else { return nil }
    return daysFromCivil(year: year, month: month, day: day) * 86_400
      + hour * 3600 + minute * 60 + second - offset
  }

  static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
    let year = year - (month <= 2 ? 1 : 0)
    let era = year >= 0 ? year / 400 : (year - 399) / 400
    let yearOfEra = year - era * 400
    let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return era * 146_097 + dayOfEra - 719_468
  }

  static func durationSeconds(start: Int?, end: Int?) -> Int? {
    guard let start, let end else { return nil }
    let seconds = end - start
    return seconds >= 0 ? seconds : nil
  }

  /// A lowercase ASCII-alphanumeric identifier, the service's `slug`.
  static func slug(_ value: String, separator: Character) -> String {
    var output = ""
    for character in value {
      if character.isASCII, character.isLetter || character.isNumber {
        output.append(Character(character.lowercased()))
      } else if !output.isEmpty, output.last != separator {
        output.append(separator)
      }
    }
    while output.last == separator { output.removeLast() }
    return output
  }

  private static let planSlugLimit = 64

  static func planSlug(_ display: String?) -> String? {
    guard let display else { return nil }
    let slug = slug(display, separator: "_")
    return !slug.isEmpty && slug.count <= planSlugLimit ? slug : nil
  }

  /// Title-case a window name, keeping the acronyms the service keeps.
  static func displayWindowTitle(_ raw: String) -> String {
    raw.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
      .map { part -> String in
        switch part.lowercased() {
        case "gpt": return "GPT"
        case "api": return "API"
        case "oauth": return "OAuth"
        case "usd": return "USD"
        case "cli": return "CLI"
        default:
          return part.prefix(1).uppercased() + part.dropFirst().lowercased()
        }
      }
      .joined(separator: " ")
  }
}
