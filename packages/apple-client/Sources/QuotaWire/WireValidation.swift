import Foundation

public enum WireValidation {
  public static func isOpaqueID(_ value: String) -> Bool {
    isWireIdentifier(value, maximum: 128, includesPlus: false)
  }

  static func isBillingDimension(_ value: String, maximum: Int = 64) -> Bool {
    isWireIdentifier(value, maximum: maximum, includesPlus: true)
  }

  static func isTrimmedText(_ value: String, maximum: Int) -> Bool {
    !value.isEmpty && value.count <= maximum
      && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public static func isSecret(_ value: String) -> Bool {
    (16...2_048).contains(value.count)
  }

  public static func isIOSAccessToken(_ value: String) -> Bool {
    isSecret(value) && value.hasPrefix(QuotaIOSOAuth.accessTokenPrefix)
  }

  public static func isIOSRefreshToken(_ value: String) -> Bool {
    isSecret(value) && value.hasPrefix(QuotaIOSOAuth.refreshTokenPrefix)
  }

  public static func isPKCEVerifier(_ value: String) -> Bool {
    value.range(of: #"^[A-Za-z0-9._~-]{43,128}$"#, options: .regularExpression) != nil
  }

  public static func isClientState(_ value: String) -> Bool {
    value.range(of: #"^[A-Za-z0-9._~-]{16,256}$"#, options: .regularExpression) != nil
  }

  public static func isCalendarDate(_ value: String) -> Bool {
    guard value.count == 10 else { return false }
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .iso8601)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.isLenient = false
    return formatter.date(from: value).map { formatter.string(from: $0) == value } ?? false
  }

  static func isUTCHour(_ value: String) -> Date? {
    guard value.count == 20, value.hasSuffix(":00:00Z") else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    guard let instant = formatter.date(from: value), formatter.string(from: instant) == value else {
      return nil
    }
    return instant
  }

  static func isNonnegativeInteger(_ value: String) -> Bool {
    guard !value.isEmpty, value.count <= 32,
      value.utf8.allSatisfy({ (48...57).contains($0) })
    else { return false }
    return value == "0" || value.first != "0"
  }

  static func isModel(_ value: String) -> Bool {
    guard !value.isEmpty, value.unicodeScalars.count <= 128 else { return false }
    return value.unicodeScalars.allSatisfy { scalar in
      !((0...31).contains(scalar.value) || (127...159).contains(scalar.value))
    }
  }

  static func isTimezone(_ value: String) -> Bool {
    guard !value.isEmpty, value.count <= 64 else { return false }
    return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { component in
      !component.isEmpty
        && component.utf8.allSatisfy { byte in
          isASCIIAlphaNumeric(byte) || byte == 46 || byte == 95 || byte == 43 || byte == 45
        }
    }
  }

  static func safeSum(_ values: [Int]) -> Int? {
    var total = 0
    for value in values {
      let (next, overflow) = total.addingReportingOverflow(value)
      guard !overflow, next <= WireCodec.jsonSafeIntegerMaximum else { return nil }
      total = next
    }
    return total
  }

  static func isSafeNonnegative(_ value: Int) -> Bool {
    (0...WireCodec.jsonSafeIntegerMaximum).contains(value)
  }

  static func isSafePositive(_ value: Int) -> Bool {
    (1...WireCodec.jsonSafeIntegerMaximum).contains(value)
  }

  private static func isWireIdentifier(_ value: String, maximum: Int, includesPlus: Bool) -> Bool {
    guard let first = value.utf8.first, !value.isEmpty, value.count <= maximum,
      isASCIIAlphaNumeric(first)
    else { return false }
    return value.utf8.allSatisfy { byte in
      isASCIIAlphaNumeric(byte) || byte == 46 || byte == 58 || byte == 95 || byte == 45
        || (includesPlus && byte == 43)
    }
  }

  private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
  }
}
