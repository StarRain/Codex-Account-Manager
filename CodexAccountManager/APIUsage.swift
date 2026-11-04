import Foundation

struct APIUsageSettings: Codable, Equatable {
    var projectID: String?
    var apiKeyID: String?

    static func validated(projectID: String, apiKeyID: String) throws -> Self {
        func identifier(_ value: String, prefix: String, error: APIUsageError) throws -> String? {
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            guard value.hasPrefix(prefix), value.count <= 200,
                  value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { throw error }
            return value
        }
        return try Self(projectID: identifier(projectID, prefix: "proj_", error: .invalidProjectID),
                        apiKeyID: identifier(apiKeyID, prefix: "key_", error: .invalidAPIKeyID))
    }

    static func validatedAdminKey(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("sk-admin-"), value.count > 9, value.utf8.count <= 16_384,
              value.utf8.allSatisfy({ (33...126).contains($0) }) else { throw APIUsageError.invalidAdminKey }
        return value
    }

    var scopeTitle: String {
        if let apiKeyID { return L("指定 Key · \(apiKeyID)") }
        if let projectID { return L("项目 · \(projectID)") }
        return L("整个组织")
    }
}

struct APITokenUsage: Codable, Equatable {
    var inputTokens: Int64 = 0
    var outputTokens: Int64 = 0
    var requests: Int64 = 0
    var cachedInputTokens: Int64?
}

struct APICost: Codable, Equatable {
    var amounts: [String: Decimal]

    var formatted: String {
        guard !amounts.isEmpty else { return "0" }
        let formatter = NumberFormatter()
        formatter.locale = Localization.language.locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 6
        return amounts.keys.sorted().map { currency in
            let amount = NSDecimalNumber(decimal: amounts[currency]!)
            return "\(formatter.string(from: amount) ?? amount.stringValue) \(currency.uppercased())"
        }.joined(separator: " · ")
    }
}

struct APIProjectRateLimit: Codable, Equatable, Identifiable {
    let id: String
    let model: String
    let requestsPerMinute: Int64
    let tokensPerMinute: Int64
    var requestsPerDay: Int64?
    var imagesPerMinute: Int64?
    var audioMegabytesPerMinute: Int64?
    var batchInputTokensPerDay: Int64?

    enum CodingKeys: String, CodingKey {
        case id, model
        case requestsPerMinute = "max_requests_per_1_minute"
        case tokensPerMinute = "max_tokens_per_1_minute"
        case requestsPerDay = "max_requests_per_1_day"
        case imagesPerMinute = "max_images_per_1_minute"
        case audioMegabytesPerMinute = "max_audio_megabytes_per_1_minute"
        case batchInputTokensPerDay = "batch_1_day_max_input_tokens"
    }

    var summary: String {
        var values = ["RPM \(APIUsageFormat.count(requestsPerMinute))", "TPM \(APIUsageFormat.count(tokensPerMinute))"]
        if let requestsPerDay { values.append("RPD \(APIUsageFormat.count(requestsPerDay))") }
        if let imagesPerMinute { values.append("IPM \(APIUsageFormat.count(imagesPerMinute))") }
        if let audioMegabytesPerMinute { values.append("MB/min \(APIUsageFormat.count(audioMegabytesPerMinute))") }
        if let batchInputTokensPerDay { values.append(L("批处理 Token/天 \(APIUsageFormat.count(batchInputTokensPerDay))")) }
        return values.joined(separator: " · ")
    }
}

struct APIUsageValue<Value: Codable & Equatable>: Codable, Equatable {
    let value: Value
    let updatedAt: Date
}

struct APIUsageSnapshot: Codable, Equatable {
    let monthStart: Date
    var usage: APIUsageValue<APITokenUsage>?
    var cost: APIUsageValue<APICost>?
    var rateLimits: APIUsageValue<[APIProjectRateLimit]>?

    var latestUpdate: Date? { [usage?.updatedAt, cost?.updatedAt, rateLimits?.updatedAt].compactMap { $0 }.max() }
}

enum APIUsageSection: String, CaseIterable, Identifiable {
    case cost, usage, rateLimits
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cost: return L("费用")
        case .usage: return L("生成用量")
        case .rateLimits: return L("项目速率上限")
        }
    }
}

struct APIUsagePresentation {
    var snapshot: APIUsageSnapshot?
    var isLoading = false
    var errors: [APIUsageSection: APIUsageError] = [:]
}

enum APIUsageError: Error, LocalizedError, Equatable {
    case invalidAdminKey, missingAdminKey, invalidProjectID, invalidAPIKeyID
    case authentication, permissionDenied, invalidScope, rateLimited, network, invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidAdminKey: return L("请输入有效的 Admin API Key（sk-admin- 开头）。")
        case .missingAdminKey: return L("未找到管理员密钥，请重新配置用量查询。")
        case .invalidProjectID: return L("项目 ID 应以 proj_ 开头，仅包含字母、数字、下划线或连字符。")
        case .invalidAPIKeyID: return L("Key ID 应以 key_ 开头；请填写 ID，而不是 sk- 开头的密钥。")
        case .authentication: return L("管理员密钥无效或已失效，请更新查询配置。")
        case .permissionDenied: return L("管理员密钥没有查询权限，请检查所属组织和权限。")
        case .invalidScope: return L("查询范围不可用，请检查项目 ID 和 Key ID。")
        case .rateLimited: return L("查询过于频繁，请稍后刷新。")
        case .network: return L("无法连接 OpenAI，请稍后刷新。")
        case .invalidResponse: return L("OpenAI 返回的数据不完整，请稍后刷新。")
        }
    }
}

enum APIUsageFormat {
    static func monthStart(at date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.dateInterval(of: .month, for: date)!.start
    }

    static func month(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: date) + " · UTC"
    }

    static func count(_ value: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Localization.language.locale
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

struct APIUsageFetchResult {
    let monthStart: Date
    let fetchedAt: Date
    let usage: Result<APITokenUsage, APIUsageError>
    let cost: Result<APICost, APIUsageError>
    let rateLimits: Result<[APIProjectRateLimit], APIUsageError>?

    func merging(_ previous: APIUsageSnapshot?) -> APIUsagePresentation {
        var snapshot = previous.flatMap { $0.monthStart == monthStart ? $0 : nil } ?? APIUsageSnapshot(monthStart: monthStart)
        var errors: [APIUsageSection: APIUsageError] = [:]
        switch usage {
        case .success(let value): snapshot.usage = APIUsageValue(value: value, updatedAt: fetchedAt)
        case .failure(let error): errors[.usage] = error
        }
        switch cost {
        case .success(let value): snapshot.cost = APIUsageValue(value: value, updatedAt: fetchedAt)
        case .failure(let error): errors[.cost] = error
        }
        switch rateLimits {
        case .success(let value): snapshot.rateLimits = APIUsageValue(value: value, updatedAt: fetchedAt)
        case .failure(let error): errors[.rateLimits] = error
        case nil: snapshot.rateLimits = nil
        }
        return APIUsagePresentation(snapshot: snapshot, errors: errors)
    }
}

private final class APIUsageRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Read-only administration requests. Neither the user's Codex provider URL nor
/// its model API key is used here, and credentials never follow redirects.
struct OpenAIUsageClient {
    static let usageURL = URL(string: "https://platform.openai.com/usage")!
    static let adminKeysURL = URL(string: "https://platform.openai.com/settings/organization/admin-keys")!
    private let session: URLSession
    private let redirectBlocker = APIUsageRedirectBlocker()

    init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 45
            self.session = URLSession(configuration: configuration)
        }
    }

    func fetch(settings: APIUsageSettings, adminKey: String, now: Date = Date()) async -> APIUsageFetchResult {
        let start = APIUsageFormat.monthStart(at: now)
        let query = [URLQueryItem(name: "start_time", value: String(Int(start.timeIntervalSince1970))),
                     URLQueryItem(name: "end_time", value: String(max(Int(start.timeIntervalSince1970) + 1, Int(now.timeIntervalSince1970)))),
                     URLQueryItem(name: "bucket_width", value: "1d"), URLQueryItem(name: "limit", value: "31")]
            + settings.projectID.map { [URLQueryItem(name: "project_ids", value: $0)] }.orEmpty
            + settings.apiKeyID.map { [URLQueryItem(name: "api_key_ids", value: $0)] }.orEmpty
        async let usage = capture { try await tokenUsage(query: query, adminKey: adminKey) }
        async let cost = capture { try await costs(query: query, adminKey: adminKey) }
        async let limits = projectLimits(settings: settings, adminKey: adminKey)
        return await APIUsageFetchResult(monthStart: start, fetchedAt: now, usage: usage, cost: cost, rateLimits: limits)
    }

    private func capture<T>(_ operation: () async throws -> T) async -> Result<T, APIUsageError> {
        do { return .success(try await operation()) }
        catch let error as APIUsageError { return .failure(error) }
        catch { return .failure(.network) }
    }

    private func request<T: Decodable>(_ path: String, query: [URLQueryItem], adminKey: String) async throws -> T {
        try Task.checkCancellation()
        let key = try APIUsageSettings.validatedAdminKey(adminKey)
        var url = URLComponents(string: "https://api.openai.com/v1/" + path)!
        url.queryItems = query
        var request = URLRequest(url: url.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, rawResponse) = try await session.data(for: request, delegate: redirectBlocker)
        try Task.checkCancellation()
        guard let response = rawResponse as? HTTPURLResponse, response.url == request.url else { throw APIUsageError.invalidResponse }
        switch response.statusCode {
        case 200: break
        case 401: throw APIUsageError.authentication
        case 403: throw APIUsageError.permissionDenied
        case 400, 404: throw APIUsageError.invalidScope
        case 429: throw APIUsageError.rateLimited
        default: throw APIUsageError.network
        }
        guard data.count <= 4_194_304 else { throw APIUsageError.invalidResponse }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw APIUsageError.invalidResponse }
    }

    private struct Bucket<Row: Decodable>: Decodable { let results: [Row] }
    private struct Page<Row: Decodable>: Decodable {
        let data: [Bucket<Row>]
        let has_more: Bool
        let next_page: String?
    }

    private func rows<Row: Decodable>(_ path: String, query: [URLQueryItem], adminKey: String) async throws -> [Row] {
        var rows: [Row] = [], cursor: String?
        var seen = Set<String>()
        for _ in 0..<100 {
            let page: Page<Row> = try await request(path, query: query + cursor.map { [URLQueryItem(name: "page", value: $0)] }.orEmpty, adminKey: adminKey)
            rows.append(contentsOf: page.data.flatMap(\.results))
            guard page.has_more else { return rows }
            guard let next = page.next_page, !next.isEmpty, seen.insert(next).inserted else { throw APIUsageError.invalidResponse }
            cursor = next
        }
        throw APIUsageError.invalidResponse
    }

    private struct TokenRow: Decodable {
        let input_tokens: Int64
        let output_tokens: Int64
        let num_model_requests: Int64
        let input_cached_tokens: Int64?
    }

    private func tokenUsage(query: [URLQueryItem], adminKey: String) async throws -> APITokenUsage {
        let rows: [TokenRow] = try await rows("organization/usage/completions", query: query, adminKey: adminKey)
        func sum(_ values: [Int64]) throws -> Int64 {
            try values.reduce(0) { total, value in
                let (sum, overflow) = total.addingReportingOverflow(value)
                guard value >= 0, !overflow else { throw APIUsageError.invalidResponse }
                return sum
            }
        }
        let cached = rows.compactMap(\.input_cached_tokens)
        return try APITokenUsage(inputTokens: sum(rows.map(\.input_tokens)), outputTokens: sum(rows.map(\.output_tokens)),
                                 requests: sum(rows.map(\.num_model_requests)),
                                 cachedInputTokens: !rows.isEmpty && cached.count == rows.count ? sum(cached) : nil)
    }

    private struct CostRow: Decodable {
        struct Amount: Decodable { let value: Decimal; let currency: String }
        let amount: Amount
    }

    private func costs(query: [URLQueryItem], adminKey: String) async throws -> APICost {
        let rows: [CostRow] = try await rows("organization/costs", query: query, adminKey: adminKey)
        var amounts: [String: Decimal] = [:]
        for row in rows {
            let currency = row.amount.currency.lowercased()
            guard currency.range(of: "^[a-z]{3}$", options: .regularExpression) != nil, !row.amount.value.isNaN else { throw APIUsageError.invalidResponse }
            let total = (amounts[currency] ?? 0) + row.amount.value
            guard !total.isNaN else { throw APIUsageError.invalidResponse }
            amounts[currency] = total
        }
        return APICost(amounts: amounts)
    }

    private func projectLimits(settings: APIUsageSettings, adminKey: String) async -> Result<[APIProjectRateLimit], APIUsageError>? {
        guard let project = settings.projectID else { return nil }
        return await capture {
            _ = try APIUsageSettings.validated(projectID: project, apiKeyID: settings.apiKeyID ?? "")
            struct Page: Decodable { let data: [APIProjectRateLimit]; let has_more: Bool; let last_id: String? }
            var values: [APIProjectRateLimit] = [], cursor: String?
            var seen = Set<String>()
            for _ in 0..<100 {
                let query = [URLQueryItem(name: "limit", value: "100")] + cursor.map { [URLQueryItem(name: "after", value: $0)] }.orEmpty
                let page: Page = try await request("organization/projects/\(project)/rate_limits", query: query, adminKey: adminKey)
                guard page.data.allSatisfy({ !$0.id.isEmpty && !$0.model.isEmpty && $0.requestsPerMinute >= 0 && $0.tokensPerMinute >= 0 }) else { throw APIUsageError.invalidResponse }
                values.append(contentsOf: page.data)
                guard page.has_more else { return values.sorted { $0.model < $1.model } }
                guard let next = page.last_id, !next.isEmpty, seen.insert(next).inserted else { throw APIUsageError.invalidResponse }
                cursor = next
            }
            throw APIUsageError.invalidResponse
        }
    }
}

private extension Optional where Wrapped == [URLQueryItem] {
    var orEmpty: [URLQueryItem] { self ?? [] }
}
