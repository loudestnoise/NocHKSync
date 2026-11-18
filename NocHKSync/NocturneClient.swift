import Foundation

/// Body for POST /api/v4/HeartRate (array of these). Field names match Nocturne's camelCase JSON.
struct HeartRateUpload: Encodable {
    let timestamp: Date
    let utcOffset: Int?
    let bpm: Int
    let accuracy: Int
    let device: String?
    let app: String
    let dataSource: String
    let syncIdentifier: String
}

/// Body for POST /api/v4/StepCount. `source` 0 means `metric` is a delta for its interval.
struct StepCountUpload: Encodable {
    let timestamp: Date
    let utcOffset: Int?
    let metric: Int
    let source: Int
    let device: String?
    let app: String
    let dataSource: String
    let syncIdentifier: String
}

enum NocturneError: LocalizedError {
    case badURL
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "The Nocturne URL is not valid."
        case let .http(code, body):
            let hint: String
            switch code {
            case 401: hint = "Token rejected. Check the token is correct and not revoked."
            case 403: hint = "Token lacks a required scope (heartrate.readwrite / stepcount.readwrite)."
            case 404: hint = "Endpoint not found. Check the URL points at a Nocturne server."
            default: hint = ""
            }
            return "HTTP \(code). \(hint) \(body.prefix(300))"
        }
    }
}

struct NocturneClient {
    /// Nocturne rejects bulk creates larger than this.
    static let maxBatch = 1000

    let baseURL: URL
    let token: String

    init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Builds a client from what the user typed. A bare host like `nocturne.example.com` is tried
    /// over HTTPS first and over HTTP only when HTTPS cannot connect at all. Any HTTP response,
    /// even 401, counts as reachable; auth problems are left to `checkConnection`.
    static func resolve(input: String, token: String) async throws -> NocturneClient {
        var lastError: Error = NocturneError.badURL
        for url in try candidateURLs(for: input) {
            let client = NocturneClient(baseURL: url, token: token)
            do {
                try await client.probe()
                return client
            } catch let error as URLError {
                lastError = error
            }
        }
        throw lastError
    }

    static func candidateURLs(for input: String) throws -> [URL] {
        var trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        let forms = trimmed.contains("://") ? [trimmed] : ["https://\(trimmed)", "http://\(trimmed)"]
        let urls = forms.compactMap { form -> URL? in
            guard let url = URL(string: form), let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme), url.host?.isEmpty == false else { return nil }
            return url
        }
        guard !urls.isEmpty else { throw NocturneError.badURL }
        return urls
    }

    /// Single request with a short timeout and no retries, used only to see if the scheme works.
    private func probe() async throws {
        var req = request("api/v4/HeartRate", method: "GET")
        req.url = req.url?.appending(queryItems: [URLQueryItem(name: "count", value: "1")])
        req.timeoutInterval = 10
        _ = try await URLSession.shared.data(for: req)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private func request(_ path: String, method: String) -> URLRequest {
        var req = URLRequest(url: baseURL.appending(path: path))
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 60
        return req
    }

    /// Verifies the URL and token by reading one record from each endpoint the app writes to.
    /// Read scopes are implied by the readwrite scopes the token needs.
    func checkConnection() async throws {
        for path in ["api/v4/HeartRate", "api/v4/StepCount"] {
            var req = request(path, method: "GET")
            req.url = req.url?.appending(queryItems: [URLQueryItem(name: "count", value: "1")])
            try await send(req)
        }
    }

    func uploadHeartRates(_ items: [HeartRateUpload]) async throws {
        try await post("api/v4/HeartRate", items)
    }

    func uploadStepCounts(_ items: [StepCountUpload]) async throws {
        try await post("api/v4/StepCount", items)
    }

    private func post<T: Encodable>(_ path: String, _ items: [T]) async throws {
        for start in stride(from: 0, to: items.count, by: Self.maxBatch) {
            let chunk = Array(items[start ..< min(start + Self.maxBatch, items.count)])
            var req = request(path, method: "POST")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try Self.encoder.encode(chunk)
            try await send(req)
        }
    }

    /// Sends with up to three attempts, retrying only on rate limiting, server errors, and network failures.
    private func send(_ req: URLRequest) async throws {
        var attempt = 0
        while true {
            attempt += 1
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200 ..< 300).contains(code) { return }
                let retryable = code == 429 || code >= 500
                if !retryable || attempt >= 3 {
                    throw NocturneError.http(code, String(decoding: data, as: UTF8.self))
                }
            } catch let error as URLError {
                if attempt >= 3 { throw error }
            }
            try await Task.sleep(for: .seconds(Double(attempt * 2)))
        }
    }
}
