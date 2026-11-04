import Foundation
import XCTest
@testable import CodexAccountManager

private final class UsageURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (Int, String)
    private static let lock = NSLock()
    private static var handler: Handler?

    static func install(_ handler: Handler?) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handler
        Self.lock.unlock()
        do {
            guard let handler else { throw URLError(.cancelled) }
            let (status, body) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class APIUsageTests: XCTestCase {
    private let key = "sk-admin-local-test-only"
    private let now = ISO8601DateFormatter().date(from: "2026-11-04T03:00:00Z")!
    private let emptyPage = #"{"data":[],"has_more":false,"next_page":null}"#
    private let usagePage = #"{"data":[{"results":[{"input_tokens":100,"output_tokens":20,"num_model_requests":3,"input_cached_tokens":40}]}],"has_more":false,"next_page":null}"#
    private let costPage = #"{"data":[{"results":[{"amount":{"value":0.1,"currency":"usd"}}]}],"has_more":false,"next_page":null}"#

    override func tearDown() {
        UsageURLProtocol.install(nil)
        super.tearDown()
    }

    private func client(_ handler: @escaping UsageURLProtocol.Handler) -> OpenAIUsageClient {
        UsageURLProtocol.install(handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UsageURLProtocol.self]
        return OpenAIUsageClient(session: URLSession(configuration: configuration))
    }

    func testQueriesUseOnlyAdminKeyAndAggregateAllPagesWithExactMoney() async throws {
        let client = client { [key] request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.scheme, "https")
            XCTAssertEqual(request.url?.host, "api.openai.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + key)
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
            if request.url!.path.hasSuffix("/rate_limits") {
                XCTAssertEqual(request.url?.path, "/v1/organization/projects/proj_test/rate_limits")
                if value("after") == nil {
                    return (200, #"{"data":[{"id":"rl-a","model":"model-a","max_requests_per_1_minute":500,"max_tokens_per_1_minute":100000}],"has_more":true,"last_id":"rl-a"}"#)
                }
                XCTAssertEqual(value("after"), "rl-a")
                return (200, #"{"data":[{"id":"rl-b","model":"model-b","max_requests_per_1_minute":100,"max_tokens_per_1_minute":20000,"max_requests_per_1_day":1000}],"has_more":false}"#)
            }
            XCTAssertEqual(value("project_ids"), "proj_test")
            XCTAssertEqual(value("api_key_ids"), "key_test")
            XCTAssertEqual(value("bucket_width"), "1d")
            XCTAssertEqual(value("limit"), "31")
            XCTAssertEqual(value("start_time"), String(Int(self.now.timeIntervalSince1970) - 3 * 86400 - 3 * 3600))
            XCTAssertEqual(value("end_time"), String(Int(self.now.timeIntervalSince1970)))
            if request.url!.path.hasSuffix("/costs") {
                if value("page") == nil {
                    return (200, #"{"data":[{"results":[{"amount":{"value":0.1,"currency":"usd"}}]}],"has_more":true,"next_page":"cost+page/2="}"#)
                }
                XCTAssertEqual(value("page"), "cost+page/2=")
                return (200, #"{"data":[{"results":[{"amount":{"value":0.2,"currency":"usd"}}]}],"has_more":false}"#)
            }
            if value("page") == nil {
                return (200, #"{"data":[{"results":[{"input_tokens":100,"output_tokens":20,"num_model_requests":3,"input_cached_tokens":40}]}],"has_more":true,"next_page":"usage-page-2"}"#)
            }
            XCTAssertEqual(value("page"), "usage-page-2")
            return (200, #"{"data":[{"results":[{"input_tokens":50,"output_tokens":5,"num_model_requests":1,"input_cached_tokens":10}]}],"has_more":false}"#)
        }
        let result = await client.fetch(settings: APIUsageSettings(projectID: "proj_test", apiKeyID: "key_test"), adminKey: key, now: now)
        XCTAssertEqual(try result.usage.get(), APITokenUsage(inputTokens: 150, outputTokens: 25, requests: 4, cachedInputTokens: 50))
        XCTAssertEqual(try result.cost.get().amounts, ["usd": Decimal(string: "0.3")!])
        XCTAssertEqual(try result.rateLimits?.get().map(\.model), ["model-a", "model-b"])
    }

    func testEmptyResultsAreZeroButMissingValuesAreUnavailable() async throws {
        let empty = client { _ in (200, self.emptyPage) }
        let settings = APIUsageSettings()
        let result = await empty.fetch(settings: settings, adminKey: key, now: now)
        XCTAssertEqual(try result.usage.get(), APITokenUsage())
        XCTAssertEqual(try result.cost.get().amounts, [:])
        XCTAssertNil(result.rateLimits)

        let incomplete = client { _ in (200, #"{"data":[{"results":[{}]}],"has_more":false}"#) }
        let missing = await incomplete.fetch(settings: settings, adminKey: key, now: now)
        XCTAssertEqual(missing.merging(nil).errors, [.cost: .invalidResponse, .usage: .invalidResponse])
        XCTAssertNil(missing.merging(nil).snapshot?.cost)
        XCTAssertNil(missing.merging(nil).snapshot?.usage)
    }

    func testMissingPaginationCursorDoesNotPublishPartialTotals() async {
        let client = client { request in
            let body = request.url!.path.hasSuffix("/costs") ? self.costPage : self.usagePage
            return (200, body.replacingOccurrences(of: "\"has_more\":false", with: "\"has_more\":true"))
        }
        let result = await client.fetch(settings: APIUsageSettings(), adminKey: key, now: now)
        let presentation = result.merging(nil)
        XCTAssertEqual(presentation.errors[.usage], .invalidResponse)
        XCTAssertEqual(presentation.errors[.cost], .invalidResponse)
        XCTAssertNil(presentation.snapshot?.usage)
    }

    func testRepeatedCursorTerminatesWithoutPublishingPartialTotals() async {
        let client = client { _ in (200, #"{"data":[],"has_more":true,"next_page":"repeat"}"#) }
        let result = await client.fetch(settings: APIUsageSettings(), adminKey: key, now: now)
        XCTAssertEqual(result.merging(nil).errors[.cost], .invalidResponse)
    }

    func testPartialFailurePreservesOnlyCurrentMonthsPreviousValues() async throws {
        let client = client { request in
            request.url!.path.hasSuffix("/costs") ? (200, self.costPage) : (403, #"{"error":{"message":"sk-admin-do-not-display"}}"#)
        }
        let result = await client.fetch(settings: APIUsageSettings(), adminKey: key, now: now)
        let oldDate = now.addingTimeInterval(-600)
        let previous = APIUsageSnapshot(monthStart: APIUsageFormat.monthStart(at: now),
            usage: APIUsageValue(value: APITokenUsage(inputTokens: 99), updatedAt: oldDate))
        let presentation = result.merging(previous)
        XCTAssertEqual(presentation.snapshot?.usage?.value.inputTokens, 99)
        XCTAssertEqual(presentation.snapshot?.usage?.updatedAt, oldDate)
        XCTAssertEqual(presentation.errors[.usage], .permissionDenied)
        XCTAssertEqual(presentation.snapshot?.cost?.value.amounts["usd"], Decimal(string: "0.1"))
        XCTAssertFalse(presentation.errors[.usage]!.localizedDescription.contains("sk-admin-do-not-display"))
        let lastMonth = APIUsageSnapshot(monthStart: APIUsageFormat.monthStart(at: now.addingTimeInterval(-31 * 86400)), usage: previous.usage)
        XCTAssertNil(result.merging(lastMonth).snapshot?.usage)
    }

    func testAuthenticationAndNetworkFailuresAreActionable() async {
        for (status, expected) in [(401, APIUsageError.authentication), (403, .permissionDenied), (404, .invalidScope), (429, .rateLimited), (503, .network)] {
            let client = client { _ in (status, "untrusted error details") }
            let result = await client.fetch(settings: APIUsageSettings(), adminKey: key, now: now)
            XCTAssertEqual(result.merging(nil).errors[.cost], expected)
        }
    }

    func testNegativeAndOverflowingTokensAreRejected() async {
        for tokens in ["-1", "9223372036854775807"] {
            let body = "{\"data\":[{\"results\":[{\"input_tokens\":\(tokens),\"output_tokens\":0,\"num_model_requests\":1},{\"input_tokens\":1,\"output_tokens\":0,\"num_model_requests\":1}]}],\"has_more\":false}"
            let client = client { request in request.url!.path.hasSuffix("/costs") ? (200, self.emptyPage) : (200, body) }
            let result = await client.fetch(settings: APIUsageSettings(), adminKey: key, now: now)
            XCTAssertEqual(result.merging(nil).errors[.usage], .invalidResponse)
        }
    }

    func testAdminCredentialsStaySeparateAndMigrateWithoutOverwritingConflicts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cam-admin-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = ProfileStore(directory: root.appendingPathComponent("source"))
        let credentials = SavedCredentialFiles(root: source.directory)
        let profile = CodexProfile(id: UUID(), name: "API", kind: .openai, hasSecret: true, apiUsageSettings: APIUsageSettings())
        try credentials.save("sk-proj-local-test", id: profile.id)
        try credentials.saveAdminKey(key, id: profile.id)
        try source.save([profile])
        XCTAssertEqual(try credentials.loadAPIKey(id: profile.id), "sk-proj-local-test")
        let adminFile = credentials.directory.appendingPathComponent(profile.id.uuidString.lowercased() + ".admin.json")
        XCTAssertThrowsError(try CredentialSnapshot(bytes: Data(contentsOf: adminFile)))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: adminFile.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(try String(contentsOf: source.file).contains(key))

        let destination = try source.copyProfiles(to: root.appendingPathComponent("destination"), profiles: [profile])
        let copied = SavedCredentialFiles(root: destination.directory)
        XCTAssertEqual(try copied.loadAdminKey(id: profile.id), key)
        XCTAssertEqual(try copied.loadAPIKey(id: profile.id), "sk-proj-local-test")
        try copied.saveAdminKey("sk-admin-other-test", id: profile.id)
        XCTAssertThrowsError(try source.copyProfiles(to: destination.directory, profiles: [profile]))
        XCTAssertEqual(try copied.loadAdminKey(id: profile.id), "sk-admin-other-test")
        try copied.deleteAdminKey(id: profile.id)
        XCTAssertNil(try copied.loadAdminKey(id: profile.id))
        XCTAssertEqual(try copied.loadAPIKey(id: profile.id), "sk-proj-local-test")
    }

    func testQueryConfigurationRejectsSecretsAsIDsAndHeaderInjection() throws {
        XCTAssertThrowsError(try APIUsageSettings.validatedAdminKey("sk-proj-not-admin"))
        XCTAssertThrowsError(try APIUsageSettings.validatedAdminKey("sk-admin-key\nInjected: yes"))
        XCTAssertThrowsError(try APIUsageSettings.validated(projectID: "proj_../../other", apiKeyID: ""))
        XCTAssertThrowsError(try APIUsageSettings.validated(projectID: "", apiKeyID: "sk-proj-secret"))
        XCTAssertEqual(try APIUsageSettings.validated(projectID: " proj_example ", apiKeyID: " key_example "),
                       APIUsageSettings(projectID: "proj_example", apiKeyID: "key_example"))
    }

    @MainActor
    func testConfigurationSurvivesRenameAndIsClearedWhenModelKeyChanges() throws {
        let state = AppState(demo: true)
        let profile = try XCTUnwrap(state.profiles.first { $0.kind == .openai })
        try state.configureAPIUsage(for: profile.id, adminKey: key, projectID: "proj_test", apiKeyID: "key_test")
        XCTAssertNotNil(state.apiUsagePresentation(for: profile.id).snapshot?.usage)
        XCTAssertTrue(state.update(profile, name: "Renamed API", model: "", baseURL: "", secret: ""))
        let renamed = try XCTUnwrap(state.profiles.first { $0.id == profile.id })
        XCTAssertEqual(renamed.apiUsageSettings?.apiKeyID, "key_test")
        XCTAssertTrue(state.update(renamed, name: renamed.name, model: "", baseURL: "", secret: "sk-proj-replacement"))
        XCTAssertNil(state.profiles.first { $0.id == profile.id }?.apiUsageSettings)
        XCTAssertNil(state.apiUsagePresentation(for: profile.id).snapshot)
    }

    @MainActor
    func testSavingQueryConfigurationFetchesAndPersistsWithoutTouchingCodexLogin() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cam-api-state-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "local.cam.api-tests." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(false, forKey: "diagnosticEnabled")
        let home = root.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let original = Data(#"{"OPENAI_API_KEY":"sk-proj-current-test"}"#.utf8)
        try original.write(to: home.appendingPathComponent("auth.json"))
        let store = ProfileStore(directory: root.appendingPathComponent("profiles"))
        let profile = CodexProfile(id: UUID(), name: "API", kind: .openai, hasSecret: true)
        try store.save([profile])
        let files = SavedCredentialFiles(root: store.directory)
        try files.save("sk-proj-saved-test", id: profile.id)
        let client = client { request in request.url!.path.hasSuffix("/costs") ? (200, self.costPage) : (200, self.usagePage) }
        let state = AppState(storage: store, preferences: preferences,
                             environment: ["CODEX_HOME": home.path, "CAM_CODEX_PATH": "/nonexistent/codex"], apiUsageClient: client)
        try state.configureAPIUsage(for: profile.id, adminKey: key, projectID: "", apiKeyID: "")
        for _ in 0..<100 where state.apiUsagePresentation(for: profile.id).isLoading {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(state.apiUsagePresentation(for: profile.id).isLoading)
        XCTAssertEqual(state.apiUsagePresentation(for: profile.id).snapshot?.usage?.value.inputTokens, 100)
        XCTAssertEqual(try store.load().first?.lastAPIUsage?.usage?.value.requests, 3)
        XCTAssertEqual(try files.loadAdminKey(id: profile.id), key)
        XCTAssertEqual(try Data(contentsOf: home.appendingPathComponent("auth.json")), original)
        XCTAssertEqual(try files.loadAPIKey(id: profile.id), "sk-proj-saved-test")
        try state.removeAPIUsageConfiguration(for: profile.id)
        XCTAssertNil(try files.loadAdminKey(id: profile.id))
        XCTAssertNil(try store.load().first?.apiUsageSettings)
        XCTAssertNil(state.apiUsagePresentation(for: profile.id).snapshot)
    }

    func testMonthUsesUTCAndOldProfileFormatStillLoads() throws {
        let date = ISO8601DateFormatter().date(from: "2026-11-01T00:30:00+08:00")!
        XCTAssertEqual(APIUsageFormat.month(APIUsageFormat.monthStart(at: date)), "2026-10 · UTC")
        let data = Data("{\"id\":\"\(UUID().uuidString)\",\"name\":\"old\",\"kind\":\"openai\",\"hasSecret\":true}".utf8)
        let profile = try JSONDecoder().decode(CodexProfile.self, from: data)
        XCTAssertNil(profile.apiUsageSettings)
        XCTAssertNil(profile.lastAPIUsage)
    }
}
