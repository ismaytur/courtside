// Conveniences on top of `fetch(_:)` (Fetch.swift): retries with backoff, and decoding into text,
// JSON or bytes. Nothing here talks to the network directly.

import Foundation

public struct WebError: LocalizedError {
  public let status: Int
  public let url: URL
  public var errorDescription: String? { "HTTP \(status) from \(url.host ?? url.absoluteString)" }
}

public enum Web {
  /// `fetch` with retries: a thrown error (no answer) or a 5xx is tried again, 0.8 s, 1.6 s, …
  public static func send(_ request: WebRequest, retries: Int = 2) async throws -> WebResponse {
    for attempt in 0... {
      do {
        let res = try await fetch(request)
        if res.status >= 500, attempt < retries { try await pause(attempt); continue }
        return res
      } catch {
        if attempt >= retries || error is CancellationError { throw error }
        try await pause(attempt)
      }
    }
    fatalError("unreachable")
  }

  /// GET as bytes; nil on 404, throws on other errors.
  public static func data(_ url: URL, headers: [String: String] = [:]) async throws -> Data? {
    let res = try await send(WebRequest(url: url, headers: headers))
    if res.status == 404 { return nil }
    guard (200..<400).contains(res.status) else { throw WebError(status: res.status, url: url) }
    return res.body
  }

  /// GET as text (UTF-8 unless the site says otherwise); nil on 404.
  public static func text(_ url: URL, headers: [String: String] = [:]) async throws -> String? {
    guard let body = try await data(url, headers: headers) else { return nil }
    return String(decoding: body, as: UTF8.self)
  }

  /// GET and decode JSON.
  public static func json<T: Decodable>(_ type: T.Type, _ url: URL) async throws -> T {
    guard let body = try await data(url) else { throw WebError(status: 404, url: url) }
    return try JSONDecoder().decode(type, from: body)
  }

  /// POST a form (e.g. a sign-in); the response comes back whatever its status.
  public static func postForm(_ url: URL, _ form: [String: String], headers: [String: String] = [:]) async throws -> WebResponse {
    try await send(WebRequest(url: url, method: "POST", form: form, headers: headers), retries: 0)
  }

  private static func pause(_ attempt: Int) async throws {
    try await Task.sleep(nanoseconds: UInt64(800_000_000 * (attempt + 1)))
  }
}
