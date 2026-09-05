import Foundation

public enum Plan: String, Codable {
    case free, paid
}

public struct QuotaBar: Identifiable, Codable, Equatable {
    public var id: String
    public var title: String
    public var used: Double
    public var limit: Double
    public var unit: String
    public var sampled: Bool
    public var resetDescription: String?
    public var percent: Double { limit <= 0 ? 0 : min(100, used / limit * 100) }
    public init(id: String, title: String, used: Double, limit: Double, unit: String, sampled: Bool, resetDescription: String? = nil) {
        self.id = id; self.title = title; self.used = used; self.limit = limit; self.unit = unit; self.sampled = sampled; self.resetDescription = resetDescription
    }
}

public struct UsageSnapshot: Codable, Equatable {
    public var plan: Plan
    public var accountName: String
    public var accountTag: String
    public var bars: [QuotaBar]
    public var fetchedAt: Date
    public var resetDescription: String
    public var aiError: String?
    public var hottest: QuotaBar? { bars.max(by: { $0.percent < $1.percent }) }
    public init(plan: Plan, accountName: String, accountTag: String, bars: [QuotaBar], fetchedAt: Date, resetDescription: String, aiError: String? = nil) {
        self.plan = plan; self.accountName = accountName; self.accountTag = accountTag; self.bars = bars; self.fetchedAt = fetchedAt; self.resetDescription = resetDescription; self.aiError = aiError
    }
}

public enum CloudflareError: Error, LocalizedError {
    case http(Int, String)
    case graphql(String)
    case decode
    public var errorDescription: String? {
        switch self {
        case .http(let c, let b): "HTTP \(c): \(b.prefix(200))"
        case .graphql(let m): m
        case .decode: "Unexpected API response"
        }
    }
}

public enum Limits {
    public static func bars(plan: Plan, workersRequests: Double, cpuMs: Double, kvReads: Double, d1Read: Double, d1Write: Double, doRequests: Double, sampled: Bool) -> [QuotaBar] {
        switch plan {
        case .free:
            [
                QuotaBar(id: "workers", title: "Workers", used: workersRequests, limit: 100_000, unit: "req/day", sampled: sampled),
                QuotaBar(id: "kv", title: "KV reads", used: kvReads, limit: 100_000, unit: "ops/day", sampled: sampled),
                QuotaBar(id: "d1r", title: "D1 reads", used: d1Read, limit: 5_000_000, unit: "rows/day", sampled: sampled),
                QuotaBar(id: "d1w", title: "D1 writes", used: d1Write, limit: 100_000, unit: "rows/day", sampled: sampled),
                QuotaBar(id: "do", title: "Durable Objects", used: doRequests, limit: 100_000, unit: "req/day", sampled: sampled),
            ]
        case .paid:
            [
                QuotaBar(id: "workers", title: "Workers", used: workersRequests, limit: 10_000_000, unit: "req/mo", sampled: sampled),
                QuotaBar(id: "cpu", title: "CPU", used: cpuMs, limit: 30_000_000, unit: "ms/mo", sampled: sampled),
                QuotaBar(id: "kv", title: "KV reads", used: kvReads, limit: 10_000_000, unit: "ops/mo", sampled: sampled),
                QuotaBar(id: "d1r", title: "D1 reads", used: d1Read, limit: 25_000_000_000, unit: "rows/mo", sampled: sampled),
                QuotaBar(id: "d1w", title: "D1 writes", used: d1Write, limit: 50_000_000, unit: "rows/mo", sampled: sampled),
                QuotaBar(id: "do", title: "Durable Objects", used: doRequests, limit: 1_000_000, unit: "req/mo", sampled: sampled),
            ]
        }
    }
}

public enum TokenStore {
    public static var tokenURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/flarebar/token")
    }

    public static func load() -> String? {
        if let t = try? String(contentsOf: tokenURL, encoding: .utf8) {
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let env = ProcessInfo.processInfo.environment["CLOUDFLARE_API_TOKEN"], !env.isEmpty {
            return env
        }
        return wranglerToken()
    }

    public static func save(_ token: String) throws {
        let dir = tokenURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try token.trimmingCharacters(in: .whitespacesAndNewlines).write(to: tokenURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
    }

    static func wranglerToken() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let toml = home.appendingPathComponent("Library/Preferences/.wrangler/config/default.toml")
        guard let text = try? String(contentsOf: toml, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            if line.hasPrefix("oauth_token") {
                let parts = line.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    return parts[1].trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
            }
        }
        return nil
    }
}

public struct CloudflareClient {
    public var token: String
    public init(token: String) { self.token = token }
    private let session = URLSession.shared

    public func snapshot() async throws -> UsageSnapshot {
        let accounts = try await accounts()
        guard let account = accounts.first else { throw CloudflareError.graphql("No accounts on this token") }
        let plan = try await plan(accountTag: account.tag)
        let date = Self.utcDate()
        let since = plan == .free ? date : Self.monthStartUTC()
        let metrics = try await metrics(accountTag: account.tag, since: since, until: date)
        let reset = plan == .free ? "Resets 00:00 UTC" : "Resets next month"
        var snapshot = UsageSnapshot(
            plan: plan,
            accountName: account.name,
            accountTag: account.tag,
            bars: Limits.bars(
                plan: plan,
                workersRequests: metrics.requests,
                cpuMs: metrics.cpuMs,
                kvReads: metrics.kvReads,
                d1Read: metrics.d1Read,
                d1Write: metrics.d1Write,
                doRequests: metrics.doRequests,
                sampled: metrics.sampled
            ),
            fetchedAt: .now,
            resetDescription: reset
        )
        do {
            let query = Self.aiQuery(accountTag: account.tag, date: date)
            let json = try await graphql(query)
            snapshot.bars.append(try Self.aiBar(json))
        } catch {
            snapshot.aiError = error.localizedDescription
        }
        return snapshot
    }

    static func aiQuery(accountTag: String, date: String) -> String {
        """
        query {
          viewer {
            accounts(filter: {accountTag: "\(accountTag)"}) {
              aiInferenceAdaptiveGroups(limit: 1, filter: {datetime_geq: "\(date)T00:00:00Z", datetime_leq: "\(date)T23:59:59Z"}) {
                sum { totalNeurons }
              }
            }
          }
        }
        """
    }

    static func aiBar(_ json: [String: Any]) throws -> QuotaBar {
        guard let accounts = ((json["data"] as? [String: Any])?["viewer"] as? [String: Any])?["accounts"] as? [[String: Any]],
              let rows = accounts.first?["aiInferenceAdaptiveGroups"] as? [[String: Any]]
        else { throw CloudflareError.decode }
        var neurons = 0.0
        for row in rows {
            guard let value = (row["sum"] as? [String: Any])?["totalNeurons"] as? NSNumber,
                  value.doubleValue.isFinite, value.doubleValue >= 0
            else { throw CloudflareError.decode }
            neurons += value.doubleValue
        }
        return QuotaBar(id: "ai", title: "Workers AI", used: neurons, limit: 10_000,
                        unit: "neurons/day", sampled: true, resetDescription: "Resets 00:00 UTC")
    }

    private struct Account { var tag: String; var name: String }

    private func accounts() async throws -> [Account] {
        var req = URLRequest(url: URL(string: "https://api.cloudflare.com/client/v4/accounts?per_page=50")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw CloudflareError.graphql("Token cannot list accounts")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["result"] as? [[String: Any]]
        else { throw CloudflareError.decode }
        return list.compactMap { a in
            guard let tag = a["id"] as? String else { return nil }
            return Account(tag: tag, name: a["name"] as? String ?? tag)
        }
    }

    private func plan(accountTag: String) async throws -> Plan {
        var req = URLRequest(url: URL(string: "https://api.cloudflare.com/client/v4/accounts/\(accountTag)/subscriptions")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode == 403 || http.statusCode == 401 {
            return .free
        }
        guard let http = resp as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else { return .free }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let result = obj?["result"] as? [[String: Any]] ?? []
        let paid = result.contains { row in
            let ratePlan = (row["rate_plan"] as? [String: Any])?["id"] as? String ?? ""
            let product = (row["product"] as? [String: Any])?["public_name"] as? String ?? ""
            return ratePlan == "workers_paid" || product.localizedCaseInsensitiveContains("workers paid")
        }
        return paid ? .paid : .free
    }

    private struct Metrics {
        var requests: Double
        var cpuMs: Double
        var kvReads: Double
        var d1Read: Double
        var d1Write: Double
        var doRequests: Double
        var sampled: Bool
    }

    private func metrics(accountTag: String, since: String, until: String) async throws -> Metrics {
        let q = """
        query {
          viewer {
            accounts(filter: {accountTag: "\(accountTag)"}) {
              workersInvocationsAdaptive(limit: 10000, filter: {datetime_geq: "\(since)T00:00:00Z", datetime_leq: "\(until)T23:59:59Z"}) {
                sum { requests cpuTimeUs }
                avg { sampleInterval }
              }
              d1AnalyticsAdaptiveGroups(limit: 10000, filter: {datetime_geq: "\(since)T00:00:00Z", datetime_leq: "\(until)T23:59:59Z"}) {
                sum { rowsRead rowsWritten }
              }
              kvOperationsAdaptiveGroups(limit: 10000, filter: {datetime_geq: "\(since)T00:00:00Z", datetime_leq: "\(until)T23:59:59Z"}) {
                sum { requests }
                dimensions { actionType }
              }
              durableObjectsInvocationsAdaptiveGroups(limit: 10000, filter: {datetime_geq: "\(since)T00:00:00Z", datetime_leq: "\(until)T23:59:59Z"}) {
                sum { requests }
              }
            }
          }
        }
        """
        let json = try await graphql(q)
        let accounts = ((json["data"] as? [String: Any])?["viewer"] as? [String: Any])?["accounts"] as? [[String: Any]]
        let acc = accounts?.first ?? [:]
        var requests = 0.0, cpuUs = 0.0, sample = 1.0
        for row in acc["workersInvocationsAdaptive"] as? [[String: Any]] ?? [] {
            let sum = row["sum"] as? [String: Any] ?? [:]
            requests += Self.num(sum["requests"])
            cpuUs += Self.num(sum["cpuTimeUs"])
            let avg = row["avg"] as? [String: Any] ?? [:]
            sample = max(sample, Self.num(avg["sampleInterval"]))
        }
        var d1r = 0.0, d1w = 0.0
        for row in acc["d1AnalyticsAdaptiveGroups"] as? [[String: Any]] ?? [] {
            let sum = row["sum"] as? [String: Any] ?? [:]
            d1r += Self.num(sum["rowsRead"])
            d1w += Self.num(sum["rowsWritten"])
        }
        var kv = 0.0
        for row in acc["kvOperationsAdaptiveGroups"] as? [[String: Any]] ?? [] {
            let action = ((row["dimensions"] as? [String: Any])?["actionType"] as? String ?? "").lowercased()
            if action.contains("read") || action.isEmpty {
                kv += Self.num((row["sum"] as? [String: Any])?["requests"])
            }
        }
        var dos = 0.0
        for row in acc["durableObjectsInvocationsAdaptiveGroups"] as? [[String: Any]] ?? [] {
            dos += Self.num((row["sum"] as? [String: Any])?["requests"])
        }
        return Metrics(requests: requests, cpuMs: cpuUs / 1000, kvReads: kv, d1Read: d1r, d1Write: d1w, doRequests: dos, sampled: sample > 1.05)
    }

    private func graphql(_ query: String) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://api.cloudflare.com/client/v4/graphql")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])
        let (data, resp) = try await session.data(for: req)
        let http = resp as? HTTPURLResponse
        if let http, http.statusCode == 401 { throw CloudflareError.http(401, "Token expired. wrangler login or paste a new token.") }
        if let http, !(200 ..< 300).contains(http.statusCode) {
            throw CloudflareError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CloudflareError.decode }
        if let errors = json["errors"] as? [[String: Any]], let first = errors.first {
            throw CloudflareError.graphql(first["message"] as? String ?? "GraphQL error")
        }
        return json
    }

    private static func num(_ v: Any?) -> Double {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        return 0
    }

    public static func utcDate(_ date: Date = .now) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    public static func monthStartUTC(_ date: Date = .now) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d-01", c.year!, c.month!)
    }
}
