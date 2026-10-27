// Every web request in Courtside goes through `fetch(_:)`: the ESPN schedule, 720pier pages and
// sign-in, .torrent files, team logos. Torrent peer/tracker traffic is the only exception
// (libtorrent opens its own connections).
//
// This file is yours: change the inside of `fetch` however you like, as long as it keeps the
// contract below. Everything else in the app builds on it (Web.swift adds retries and decoding).
//
//   - Return every HTTP answer, errors included: 404/403/500 come back as `status`, not as a throw.
//   - Throw only when there is no answer at all (offline, timeout, connection refused).
//   - Keep cookies per site between calls and send them back, like a browser (sign-ins stick).
//   - Follow redirects; `url` in the response is where it ended up.

import Foundation

public struct WebRequest: Sendable {
  public var url: URL
  public var method: String = "GET"           // "GET" or "POST"
  public var form: [String: String]? = nil    // POST body, sent as application/x-www-form-urlencoded
  public var headers: [String: String] = [:]  // extra headers when needed, e.g. "Referer"
  public var timeout: TimeInterval = 25       // seconds

  public init(url: URL, method: String = "GET", form: [String: String]? = nil,
              headers: [String: String] = [:], timeout: TimeInterval = 25) {
    self.url = url; self.method = method; self.form = form; self.headers = headers; self.timeout = timeout
  }
}

public struct WebResponse: Sendable {
  public let status: Int                      // HTTP status: 200, 404, 403…
  public let url: URL                         // final address after redirects
  public let headers: [String: String]        // response headers (e.g. Content-Type)
  public let body: Data                       // raw bytes; callers decode text/JSON/images

  public init(status: Int, url: URL, headers: [String: String], body: Data) {
    self.status = status; self.url = url; self.headers = headers; self.body = body
  }
}

public func fetch(_ request: WebRequest) async throws -> WebResponse {
  var r = URLRequest(url: request.url, timeoutInterval: request.timeout)
  r.httpMethod = request.method
  for (name, value) in request.headers { r.setValue(value, forHTTPHeaderField: name) }
  if let form = request.form {
    r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    r.httpBody = formEncode(form).data(using: .utf8)
  }
  let (data, response) = try await session.data(for: r)
  guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
  var headers: [String: String] = [:]
  for (k, v) in http.allHeaderFields { headers[String(describing: k)] = String(describing: v) }
  return WebResponse(status: http.statusCode, url: http.url ?? request.url, headers: headers, body: data)
}

// URLSession keeps cookies in the shared store and follows redirects by default.
private let session: URLSession = {
  let c = URLSessionConfiguration.default
  c.httpCookieStorage = .shared
  c.httpCookieAcceptPolicy = .always
  c.httpShouldSetCookies = true
  c.requestCachePolicy = .reloadIgnoringLocalCacheData
  return URLSession(configuration: c)
}()

private func formEncode(_ form: [String: String]) -> String {
  let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
  let enc = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
  return form.map { "\(enc($0.key))=\(enc($0.value))" }.joined(separator: "&")
}
