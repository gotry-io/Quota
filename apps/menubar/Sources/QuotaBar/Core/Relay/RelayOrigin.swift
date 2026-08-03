import Foundation

enum RelayOriginError: LocalizedError, Equatable, Sendable {
  case invalidURL
  case insecureURL

  var errorDescription: String? {
    switch self {
    case .invalidURL:
      "Enter a Relay origin without credentials, a path, query, or fragment."
    case .insecureURL:
      "Relay connections require HTTPS except for loopback development Relays."
    }
  }
}

enum RelayOrigin {
  static func canonicalURL(from rawValue: String) throws -> URL {
    guard !rawValue.isEmpty,
      rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
      !rawValue.contains(where: \Character.isWhitespace),
      !rawValue.contains("?"),
      !rawValue.contains("#"),
      var components = URLComponents(string: rawValue),
      let rawScheme = components.scheme,
      let rawHost = components.host,
      components.user == nil,
      components.password == nil,
      components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/",
      components.percentEncodedQuery == nil,
      components.percentEncodedFragment == nil
    else {
      throw RelayOriginError.invalidURL
    }

    let scheme = rawScheme.lowercased()
    let parsedHost = rawHost.lowercased()
    let host =
      parsedHost.hasPrefix("[") && parsedHost.hasSuffix("]")
      ? String(parsedHost.dropFirst().dropLast())
      : parsedHost
    guard scheme == "https" || scheme == "http", !host.isEmpty else {
      throw RelayOriginError.invalidURL
    }
    if scheme == "http" && !isLoopback(host) {
      throw RelayOriginError.insecureURL
    }

    components.scheme = scheme
    components.host = parsedHost
    components.path = ""
    if (scheme == "https" && components.port == 443)
      || (scheme == "http" && components.port == 80)
    {
      components.port = nil
    }

    guard let url = components.url, url.host != nil else {
      throw RelayOriginError.invalidURL
    }
    return url
  }

  static func canonicalURL(from url: URL) throws -> URL {
    try canonicalURL(from: url.absoluteString)
  }

  private static func isLoopback(_ host: String) -> Bool {
    host == "localhost" || host == "127.0.0.1" || host == "::1"
  }
}
