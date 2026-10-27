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

public struct WebRequest {
    public var url: URL
    public var method: String = "GET"            // "GET" or "POST"
    public var form: [String: String]? = nil     // POST body, sent as application/x-www-form-urlencoded
    public var headers: [String: String] = [:]   // extra headers (can override User-Agent, Referer, etc.)
    public var timeout: TimeInterval = 25        // seconds

    public init(url: URL, method: String = "GET", form: [String: String]? = nil, headers: [String: String] = [:], timeout: TimeInterval = 25) {
        self.url = url
        self.method = method
        self.form = form
        self.headers = headers
        self.timeout = timeout
    }
}

public struct WebResponse {
    public let status: Int                       // HTTP status: 200, 404, 403…
    public let url: URL                          // final address after redirects
    public let headers: [String: String]         // response headers (e.g. Content-Type)
    public let body: Data                        // raw bytes
}

// Shared session configured with `.ephemeral` (in-memory cookies, cleared on app restart).
private let sharedSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.httpAdditionalHeaders = [
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2.1 Safari/605.1.15",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9,ru;q=0.8"
    ]
    return URLSession(configuration: config)
}()

public func fetch(_ request: WebRequest) async throws -> WebResponse {
    var urlRequest = URLRequest(url: request.url)
    urlRequest.httpMethod = request.method
    urlRequest.timeoutInterval = request.timeout

    // 1. Apply request-specific headers (overrides session defaults if keys match)
    for (key, value) in request.headers {
        urlRequest.setValue(value, forHTTPHeaderField: key)
    }

    // 2. Handle form encoding with strict RFC 3986 unreserved character set
    if let form = request.form {
        urlRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        var formAllowed = CharacterSet.alphanumerics
        formAllowed.insert(charactersIn: "-._~")
        
        let bodyString = form.map { key, value in
            let escapedKey = key.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? key
            let escapedValue = value.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? value
            return "\(escapedKey)=\(escapedValue)"
        }.joined(separator: "&")
        
        urlRequest.httpBody = bodyString.data(using: .utf8)
    }

    do {
        let (data, response) = try await sharedSession.data(for: urlRequest)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        // Safely extract all header fields into [String: String]
        var headersDict: [String: String] = [:]
        for (key, value) in httpResponse.allHeaderFields {
            if let k = key as? String {
                headersDict[k] = String(describing: value)
            }
        }

        return WebResponse(
            status: httpResponse.statusCode,
            url: httpResponse.url ?? request.url,
            headers: headersDict,
            body: data
        )
        
    } catch {
        throw error
    }
}
