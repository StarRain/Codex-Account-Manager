import AppKit
import Foundation

enum CodexError: LocalizedError {
    case notInstalled, serverUnavailable, timeout, requestFailed, changedExternally, authenticationFailed, loginCancelled, invalidAuthURL, browserUnavailable, deviceLoginUnavailable, overridden, partialLogin, loginRestored, missingHelper, providerInUse, environmentOverride, unsupportedCredentialStore, invalidCredentials, customOpenAIEndpoint, differentAccount, codexStillRunning, processCheckFailed, desktopQuitFailed, loginRestricted, credentialBackupUncertain
    var errorDescription: String? {
        switch self {
        case .notInstalled: return "找不到 Codex CLI。请安装 Codex，并确保 codex 在常用路径中。"
        case .serverUnavailable: return "无法启动 Codex 服务，请检查本机配置。"
        case .timeout: return "Codex 响应超时，请重试。"
        case .requestFailed: return "Codex 未能完成操作，请检查配置和组织策略。"
        case .changedExternally: return "Codex 配置在操作期间发生变化，请刷新后重试。"
        case .authenticationFailed: return "Codex 登录未完成，请重试。"
        case .loginCancelled: return "登录未完成或已取消。"
        case .invalidAuthURL: return "Codex 返回了无效的登录地址。"
        case .browserUnavailable: return "无法打开浏览器，登录已取消。"
        case .deviceLoginUnavailable: return "无法启动设备代码登录。请确认 ChatGPT 安全设置中已启用设备代码登录，或改用浏览器登录。"
        case .overridden: return "配置已写入，但被更高优先级的设置覆盖。请检查组织或项目配置。"
        case .partialLogin: return "切换未完成，当前登录或 Codex 配置可能已改变。请检查当前状态后重试。"
        case .loginRestored: return "切换未完成，已恢复原登录凭据。请检查 Codex 配置后重试。"
        case .missingHelper: return "找不到应用内的凭据读取程序。"
        case .providerInUse: return "请先切换到其他配置，再删除当前使用的第三方服务。"
        case .environmentOverride: return "当前环境通过变量或组织身份控制登录，无法可靠切换。请先检查 Codex 身份设置。"
        case .unsupportedCredentialStore: return "当前 Codex 凭据不是文件存储，暂不支持保存或切换官方账号。未更改登录状态。"
        case .invalidCredentials: return "无法安全识别 Codex 登录凭据，未更改登录状态。请检查或重新登录。"
        case .customOpenAIEndpoint: return "Codex 的 OpenAI 地址被自定义，无法确认是否为官方服务地址。请先检查 openai_base_url。"
        case .differentAccount: return "登录的账号或工作区与所选账号不一致，CAM 未切换当前 Codex 登录。请重新选择账号。"
        case .codexStillRunning: return "请先退出正在运行的 Codex 桌面版和 CLI，再从菜单切换。切换后重新打开。"
        case .processCheckFailed: return "无法检查运行中的 Codex 进程，未更改登录状态。"
        case .desktopQuitFailed: return "无法退出 Codex 桌面版，未更改登录状态。请先手动退出后重试。"
        case .loginRestricted: return "Codex 登录方式或工作区受到限制，暂不支持切换；未更改登录状态。"
        case .credentialBackupUncertain: return "账号资料保存未完成，无法确认已保存凭据是否恢复。CAM 未切换当前登录，请检查账号后重试。"
        }
    }
}

enum ChatGPTLoginMethod: String, CaseIterable, Identifiable {
    case browser, deviceCode
    var id: String { rawValue }
    var title: String { self == .browser ? "浏览器登录" : "设备代码登录" }
    var codexType: String { self == .browser ? "chatgpt" : "chatgptDeviceCode" }
}

struct ChatGPTLoginInstructions {
    let method: ChatGPTLoginMethod
    let url: URL
    let userCode: String?
}

struct AuthorizedChatGPTAccount {
    let current: CurrentCodex
    let credentials: CredentialSnapshot
    let quota: AccountQuota?
    // Identity of the live login observed before starting this isolated flow.
    var previousChatGPTFingerprint: String? = nil
}

// All cancellation state is protected by the lock and shared with the login worker.
final class LoginCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
}

enum CodexHome {
    static func resolve(environment: [String: String], userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let configured = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = configured.flatMap { $0.isEmpty ? nil : $0 } ?? userHome.appendingPathComponent(".codex", isDirectory: true).path
        return URL(fileURLWithPath: NSString(string: value).expandingTildeInPath, isDirectory: true).standardizedFileURL
    }
}

enum CodexExecutable {
    static func find(environment: [String: String]) throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init) +
            [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        if let explicit = environment["CODEX_SWITCHER_CODEX_PATH"] {
            guard FileManager.default.isExecutableFile(atPath: explicit) else { throw CodexError.notInstalled }
            return URL(fileURLWithPath: explicit)
        }
        for path in paths {
            let candidate = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("codex")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        throw CodexError.notInstalled
    }
}

/// A short-lived official app-server connection. Raw replies stay in memory and
/// are never logged or returned to the UI without selecting safe fields.
final class AppServerClient {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let condition = NSCondition()
    private var buffer = Data()
    private var messages: [[String: Any]] = []
    private var stopped = false
    private var nextID = 0

    init(executable: URL, environment: [String: String], currentDirectory: URL? = nil) throws {
        process.executableURL = executable
        process.arguments = ["app-server"]
        process.environment = environment
        process.currentDirectoryURL = currentDirectory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.receive(handle.availableData) }
        do { try process.run() } catch { output.fileHandleForReading.readabilityHandler = nil; throw CodexError.serverUnavailable }
        do {
            _ = try request("initialize", ["clientInfo": ["name": "codex_switcher", "version": "0.1.0"]], timeout: 15)
            try send(["method": "initialized", "params": [:]])
        } catch { close(); throw error }
    }

    private func receive(_ data: Data) {
        condition.lock(); defer { condition.unlock() }
        if data.isEmpty { stopped = true; condition.broadcast(); return }
        buffer.append(data)
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer[..<end]
            buffer.removeSubrange(...end)
            if let message = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] {
                messages.append(message)
                if messages.count > 500 { messages.removeFirst(messages.count - 500) }
            }
        }
        condition.broadcast()
    }

    private func send(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(10)
        do { try input.fileHandleForWriting.write(contentsOf: data) } catch { throw CodexError.serverUnavailable }
    }

    private func wait(timeout: TimeInterval, matching: ([String: Any]) -> Bool) throws -> [String: Any] {
        let until = Date().addingTimeInterval(timeout)
        condition.lock(); defer { condition.unlock() }
        while true {
            if let index = messages.firstIndex(where: matching) { return messages.remove(at: index) }
            if stopped { throw CodexError.serverUnavailable }
            guard condition.wait(until: until) else { throw CodexError.timeout }
        }
    }

    func request(_ method: String, _ params: [String: Any]?, timeout: TimeInterval = 15) throws -> [String: Any] {
        nextID += 1; let id = nextID
        var requestMessage: [String: Any] = ["id": id, "method": method]
        if let params { requestMessage["params"] = params }
        try send(requestMessage)
        let message = try wait(timeout: timeout) { ($0["id"] as? Int) == id }
        guard message["error"] == nil, let result = message["result"] as? [String: Any] else { throw CodexError.requestFailed }
        return result
    }

    func waitForLogin(id: String, timeout: TimeInterval = 300) throws {
        let message = try wait(timeout: timeout) {
            guard $0["method"] as? String == "account/login/completed", let params = $0["params"] as? [String: Any] else { return false }
            return params["loginId"] as? String == id
        }
        guard let params = message["params"] as? [String: Any], params["success"] as? Bool == true else { throw CodexError.loginCancelled }
    }

    func close() {
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        try? output.fileHandleForReading.close()
    }
    deinit { if process.isRunning { close() } }
}

struct CodexService {
    var environment: [String: String] = ProcessInfo.processInfo.environment
    var executableOverride: URL?
    var helperPath: String? = Bundle.main.executableURL?.path
    var preserveSharedHistory: Bool = true
    var preferAvailableSharedHistory: Bool = false

    private func executable() throws -> URL { try executableOverride ?? CodexExecutable.find(environment: environment) }

    func fileCredentials() -> FileCredentials {
        FileCredentials(home: CodexHome.resolve(environment: environment))
    }

    private func ensureNoManagedIdentity() throws {
        let controlled = ["CODEX_API_KEY", "OPENAI_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_FEDERATION_RULE_ID", "OPENAI_IDENTITY_TOKEN_FILE", "OPENAI_WORKLOAD_IDENTITY_CONTEXT"]
        guard !controlled.contains(where: { !(environment[$0] ?? "").isEmpty }) else { throw CodexError.environmentOverride }
    }

    /// Read the current credential only at an explicit switch, before anything
    /// is overwritten, so that it can be preserved in a separate file.
    func snapshotCurrent() throws -> (CurrentCodex, CredentialSnapshot?) {
        try ensureNoManagedIdentity()
        let current = try readCurrent()
        guard current.accountAvailable else { throw CodexError.invalidCredentials }
        guard current.credentialStore == "file" else { throw CodexError.unsupportedCredentialStore }
        guard !current.customOpenAIEndpoint else { throw CodexError.customOpenAIEndpoint }
        guard !current.authRestricted else { throw CodexError.loginRestricted }
        let snapshot = try fileCredentials().read()
        if let accountType = current.accountType {
            guard let snapshot,
                  (accountType == "chatgpt" && snapshot.kind == .chatgpt || accountType == "apiKey" && snapshot.kind == .openai),
                  snapshot.fingerprint == current.credentialFingerprint else { throw CodexError.changedExternally }
        } else if snapshot != nil {
            throw CodexError.invalidCredentials
        }
        return (current, snapshot)
    }

    func activateSavedChatGPT(_ profile: CodexProfile, credential: String, expectedPrevious: Data?) throws {
        try ensureNoManagedIdentity()
        let incoming = try CredentialSnapshot(bytes: Data(credential.utf8))
        guard incoming.kind == .chatgpt, incoming.fingerprint == profile.accountID else { throw CodexError.invalidCredentials }
        try applyCredential(incoming, profile: profile, expectedPrevious: expectedPrevious)
    }

    /// Never replace credentials written by another process when a switch fails.
    private func applyCredential(_ incoming: CredentialSnapshot, profile: CodexProfile, expectedPrevious: Data?) throws {
        let (_, snapshot) = try snapshotCurrent()
        guard snapshot?.bytes == expectedPrevious else { throw CodexError.changedExternally }
        let files = fileCredentials()
        try files.replace(expected: snapshot?.bytes, with: incoming.bytes)
        do {
            let server = try client(); defer { server.close() }
            try writeConfiguration(profile, using: server)
            let verified = try readCurrent(using: server)
            let type = incoming.kind == .chatgpt ? "chatgpt" : "apiKey"
            guard verified.accountAvailable, verified.accountType == type,
                  verified.credentialFingerprint == incoming.fingerprint,
                  try files.raw() == incoming.bytes else { throw CodexError.changedExternally }
        } catch {
            // When there was no previous file, do not delete one that another
            // process could have replaced between a check and unlink.
            if let previous = snapshot?.bytes {
                do {
                    try files.replace(expected: incoming.bytes, with: previous)
                    guard try files.raw() == previous else { throw CodexError.changedExternally }
                } catch { throw CodexError.partialLogin }
                throw CodexError.loginRestored
            }
            throw CodexError.partialLogin
        }
    }

    private func isolatedLoginHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cam-login-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let config = home.appendingPathComponent("config.toml")
            try Data("cli_auth_credentials_store = \"file\"\n".utf8).write(to: config, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
            return home
        } catch {
            try? FileManager.default.removeItem(at: home)
            throw error
        }
    }

    private func preparedEnvironment(executable: URL) -> [String: String] {
        var result = environment
        if let configured = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !configured.isEmpty {
            result["CODEX_HOME"] = fileCredentials().home.path
        } else {
            result.removeValue(forKey: "CODEX_HOME")
        }
        let inherited = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let additions = [executable.deletingLastPathComponent().path, home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        var seen = Set<String>()
        result["PATH"] = (inherited + additions).filter { seen.insert($0).inserted }.joined(separator: ":")
        return result
    }

    private func client(currentDirectory: URL? = nil) throws -> AppServerClient {
        let executable = try executable()
        return try AppServerClient(executable: executable, environment: preparedEnvironment(executable: executable), currentDirectory: currentDirectory)
    }

    func readCurrent() throws -> CurrentCodex {
        let server = try client(); defer { server.close() }
        return try readCurrent(using: server)
    }

    /// Let Codex perform an independent OAuth login without changing the live
    /// Codex Home or borrowing the live account's refresh token.
    func authorizeAdditionalChatGPT(method: ChatGPTLoginMethod, cancellation: LoginCancellation,
                                    onAuthenticated: () -> Void = {},
                                    onInstructions: (ChatGPTLoginInstructions) -> Bool) throws -> AuthorizedChatGPTAccount {
        guard !cancellation.isCancelled else { throw CodexError.loginCancelled }
        let (active, _) = try snapshotCurrent()
        guard active.quotaEndpointIsOfficial else { throw CodexError.customOpenAIEndpoint }
        guard !cancellation.isCancelled else { throw CodexError.loginCancelled }

        let home = try isolatedLoginHome()
        defer { try? FileManager.default.removeItem(at: home) }

        var isolated = self
        isolated.environment["CODEX_HOME"] = home.path
        let server = try isolated.client(currentDirectory: home); defer { server.close() }
        guard !cancellation.isCancelled else { throw CodexError.loginCancelled }
        let result: [String: Any]
        do { result = try server.request("account/login/start", ["type": method.codexType]) }
        catch {
            if cancellation.isCancelled { throw CodexError.loginCancelled }
            if method == .deviceCode, case CodexError.requestFailed = error { throw CodexError.deviceLoginUnavailable }
            throw error
        }
        guard let loginID = result["loginId"] as? String, !loginID.isEmpty else { throw CodexError.authenticationFailed }
        var completed = false
        defer { if !completed { _ = try? server.request("account/login/cancel", ["loginId": loginID], timeout: 2) } }
        guard result["type"] as? String == method.codexType else { throw CodexError.authenticationFailed }
        let rawURL = result[method == .browser ? "authUrl" : "verificationUrl"] as? String
        guard let rawURL, let url = URL(string: rawURL), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", ["auth.openai.com", "chatgpt.com"].contains(parts.host?.lowercased() ?? ""),
              parts.user == nil, parts.password == nil, parts.port == nil || parts.port == 443 else { throw CodexError.invalidAuthURL }
        let code = method == .deviceCode ? result["userCode"] as? String : nil
        if method == .deviceCode {
            guard let code, (4...32).contains(code.utf8.count),
                  code.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil else { throw CodexError.authenticationFailed }
        }
        guard !cancellation.isCancelled else { throw CodexError.loginCancelled }
        guard onInstructions(ChatGPTLoginInstructions(method: method, url: url, userCode: code)) else {
            throw cancellation.isCancelled ? CodexError.loginCancelled : CodexError.browserUnavailable
        }
        let deadline = Date().addingTimeInterval(900)
        while true {
            guard !cancellation.isCancelled else { throw CodexError.loginCancelled }
            guard Date() < deadline else { throw CodexError.timeout }
            do { try server.waitForLogin(id: loginID, timeout: 1); break }
            catch CodexError.timeout { continue }
            catch CodexError.loginCancelled {
                throw cancellation.isCancelled ? CodexError.loginCancelled : CodexError.authenticationFailed
            }
        }
        completed = true
        guard !cancellation.isCancelled else { throw CodexError.loginCancelled }
        onAuthenticated()
        let before = try isolated.readCurrent(using: server)
        guard before.accountAvailable, before.accountType == "chatgpt", before.credentialStore == "file",
              let first = try isolated.fileCredentials().read(), first.kind == .chatgpt,
              first.fingerprint == before.credentialFingerprint else { throw CodexError.invalidCredentials }

        // The new login is still isolated, so its quota can be read without
        // refreshing or activating any other account's credentials.
        let quotaResult = try? server.request("account/rateLimits/read", nil, timeout: 12)
        guard !cancellation.isCancelled else { throw CodexError.loginCancelled }
        let current = try isolated.readCurrent(using: server)
        guard current.accountType == "chatgpt", current.credentialFingerprint == first.fingerprint,
              let credentials = try isolated.fileCredentials().read(), credentials.fingerprint == first.fingerprint else { throw CodexError.changedExternally }
        let quota: AccountQuota?
        if let quotaResult, let reported = quotaResult["accountId"] as? String, reported != credentials.chatgptAccountID {
            quota = nil
        } else { quota = quotaResult.flatMap { AccountQuota.parse($0) } }
        return AuthorizedChatGPTAccount(current: current, credentials: credentials, quota: quota,
                                        previousChatGPTFingerprint: active.accountType == "chatgpt" ? active.credentialFingerprint : nil)
    }

    /// Read limits for the same login before and after the network request.
    /// A credential change must never attach one account's usage to another.
    func readCurrentQuota(expected: CurrentCodex) throws -> AccountQuota? {
        func sameLogin(_ left: CurrentCodex, _ right: CurrentCodex) -> Bool {
            guard left.accountAvailable, right.accountAvailable, left.accountType == "chatgpt", right.accountType == "chatgpt" else { return false }
            // Email alone cannot distinguish multiple workspaces for one user.
            return left.credentialFingerprint != nil && left.credentialFingerprint == right.credentialFingerprint
        }
        let server = try client(); defer { server.close() }
        let before = try readCurrent(using: server)
        guard before.quotaEndpointIsOfficial, sameLogin(expected, before) else { throw CodexError.changedExternally }
        let result = try server.request("account/rateLimits/read", nil, timeout: 12)
        let after = try readCurrent(using: server)
        guard after.quotaEndpointIsOfficial, sameLogin(expected, after), sameLogin(before, after) else { throw CodexError.changedExternally }
        if let reportedID = result["accountId"] as? String,
           let snapshot = try? fileCredentials().read(), let selectedID = snapshot.chatgptAccountID,
           reportedID != selectedID { throw CodexError.changedExternally }
        return AccountQuota.parse(result)
    }

    private func officialChatGPTBase(_ address: String) -> Bool {
        guard let parts = URLComponents(string: address), parts.scheme?.lowercased() == "https",
              parts.host?.lowercased() == "chatgpt.com", parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.port == nil || parts.port == 443 else { return false }
        return ["", "/", "/backend-api", "/backend-api/"].contains(parts.path)
    }

    /// Recognize the official-only shared bucket used by existing CC Switch
    /// configurations. Reject custom endpoints, headers and credentials rather
    /// than ever sending an official login to an unverified provider.
    private func isOfficialSharedBucket(_ values: [String: Any], provider: String) -> Bool {
        guard provider == "custom", let providers = values["model_providers"] as? [String: Any],
              let custom = providers[provider] as? [String: Any],
              custom["name"] as? String == "OpenAI", custom["requires_openai_auth"] as? Bool == true,
              custom["supports_websockets"] as? Bool == true, custom["wire_api"] as? String == "responses" else { return false }
        let allowed: Set<String> = ["name", "base_url", "env_key", "env_key_instructions", "experimental_bearer_token", "auth", "aws", "wire_api", "query_params", "http_headers", "env_http_headers", "request_max_retries", "stream_max_retries", "stream_idle_timeout_ms", "websocket_connect_timeout_ms", "requires_openai_auth", "supports_websockets", "supports_standalone_web_search"]
        guard Set(custom.keys).isSubset(of: allowed) else { return false }
        let routingKeys = ["base_url", "env_key", "env_key_instructions", "experimental_bearer_token", "auth", "aws", "query_params", "http_headers", "env_http_headers"]
        return routingKeys.allSatisfy { custom[$0] == nil || custom[$0] is NSNull }
    }

    private func readCurrent(using server: AppServerClient) throws -> CurrentCodex {
        let config = try server.request("config/read", ["includeLayers": true])
        let values = config["config"] as? [String: Any] ?? [:]
        let layers = config["layers"] as? [[String: Any]] ?? []
        let userLayer = layers.first { (($0["name"] as? [String: Any])?["type"] as? String) == "user" }
        let provider = values["model_provider"] as? String ?? "openai"
        let openAIAddress = layers.lazy.compactMap { ($0["config"] as? [String: Any])?["openai_base_url"] as? String }.first
        let customOpenAIEndpoint: Bool = {
            guard let openAIAddress else { return false }
            guard let url = URLComponents(string: openAIAddress), url.scheme == "https", url.host?.lowercased() == "api.openai.com",
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.port == nil || url.port == 443 else { return true }
            return !["", "/", "/v1", "/v1/"].contains(url.path)
        }()
        let sharedOfficialAvailable = !customOpenAIEndpoint && isOfficialSharedBucket(values, provider: "custom")
        let sharedOfficialProvider = provider == "custom" && sharedOfficialAvailable
        let address = layers.lazy.compactMap { layer -> String? in
            guard let settings = layer["config"] as? [String: Any] else { return nil }
            if provider == "openai" { return settings["openai_base_url"] as? String }
            let providers = settings["model_providers"] as? [String: Any]
            return (providers?[provider] as? [String: Any])?["base_url"] as? String
        }.first
        let host: String? = address.flatMap { value in
            guard let parts = URLComponents(string: value), parts.user == nil, parts.password == nil,
                  let hostname = parts.host, !hostname.isEmpty else { return nil }
            return hostname + (parts.port.map { ":\($0)" } ?? "")
        }
        let accountResult = try? server.request("account/read", ["refreshToken": false])
        let account = accountResult?["account"] as? [String: Any]
        let credentialStore = values["cli_auth_credentials_store"] as? String ?? "unknown"
        let fileSnapshot = credentialStore == "file" ? (try? fileCredentials().read()) : nil
        let credentialFingerprint = fileSnapshot?.fingerprint
        let displayName: String? = {
            guard account?["type"] as? String == "chatgpt", let snapshot = fileSnapshot, snapshot.kind == .chatgpt else { return nil }
            if let reportedEmail = account?["email"] as? String, let tokenEmail = snapshot.email,
               reportedEmail.caseInsensitiveCompare(tokenEmail) != .orderedSame { return nil }
            return snapshot.displayName
        }()
        let configuredChatGPTURLs = layers.compactMap { ($0["config"] as? [String: Any])?["chatgpt_base_url"] as? String }
            + [values["chatgpt_base_url"] as? String, environment["CHATGPT_BASE_URL"], environment["CODEX_CHATGPT_BASE_URL"]].compactMap { $0 }
        return CurrentCodex(account: account?["email"] as? String, accountType: account?["type"] as? String,
                            provider: provider, providerHost: host, model: values["model"] as? String,
                            configVersion: userLayer?["version"] as? String, configAvailable: true, accountAvailable: accountResult != nil,
                            credentialStore: credentialStore, credentialFingerprint: credentialFingerprint,
                            customOpenAIEndpoint: customOpenAIEndpoint,
                            authRestricted: values["forced_login_method"] as? String != nil || values["forced_chatgpt_workspace_id"] as? String != nil,
                            usesSharedOfficialProvider: sharedOfficialProvider,
                            hasSharedOfficialProvider: sharedOfficialAvailable,
                            accountPlanType: account?["type"] as? String == "chatgpt" ? account?["planType"] as? String : nil,
                            quotaEndpointIsOfficial: configuredChatGPTURLs.allSatisfy(officialChatGPTBase),
                            accountDisplayName: displayName)
    }

    private func writeConfiguration(_ profile: CodexProfile, using server: AppServerClient) throws {
        let before = try readCurrent(using: server)
        let useShared = preserveSharedHistory && (before.usesSharedOfficialProvider || (preferAvailableSharedHistory && before.hasSharedOfficialProvider))
        let provider = profile.kind == .provider ? profile.providerID : (useShared ? "custom" : "openai")
        var edits: [[String: Any]] = [["keyPath": "model_provider", "mergeStrategy": "replace", "value": provider]]
        // Selecting an account does not silently reset the user's model.
        if profile.kind == .provider || profile.model != nil {
            edits.append(["keyPath": "model", "mergeStrategy": "replace", "value": profile.model as Any? ?? NSNull()])
        }
        if profile.kind == .provider {
            guard let baseURL = profile.baseURL else { throw ProfileValidationError.invalidURL }
            var definition: [String: Any] = ["name": profile.name, "base_url": baseURL, "wire_api": "responses"]
            if profile.hasSecret {
                guard let helperPath else { throw CodexError.missingHelper }
                definition["auth"] = ["command": helperPath, "args": ["--credential-helper", profile.id.uuidString.lowercased()]]
            }
            edits.append(["keyPath": "model_providers.\(provider)", "mergeStrategy": "replace", "value": definition])
        }
        var params: [String: Any] = ["edits": edits]
        if let version = before.configVersion { params["expectedVersion"] = version }
        let result = try server.request("config/batchWrite", params)
        if result["status"] as? String == "okOverridden" { throw CodexError.overridden }
    }

    func removeProvider(_ profile: CodexProfile) throws {
        guard profile.kind == .provider else { return }
        let server = try client(); defer { server.close() }
        let before = try readCurrent(using: server)
        guard before.provider != profile.providerID else { throw CodexError.providerInUse }
        var params: [String: Any] = ["edits": [["keyPath": "model_providers.\(profile.providerID)", "mergeStrategy": "replace", "value": NSNull()]]]
        if let version = before.configVersion { params["expectedVersion"] = version }
        let result = try server.request("config/batchWrite", params)
        if result["status"] as? String == "okOverridden" { throw CodexError.overridden }
    }

    private func loginAPI(secret: String, currentDirectory: URL) throws {
        let process = Process(); let pipe = Pipe()
        let executable = try executable()
        process.executableURL = executable; process.arguments = ["login", "--with-api-key"]
        process.environment = preparedEnvironment(executable: executable); process.currentDirectoryURL = currentDirectory
        process.standardInput = pipe; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run(); try pipe.fileHandleForWriting.write(contentsOf: Data((secret + "\n").utf8)); try pipe.fileHandleForWriting.close() }
        catch { if process.isRunning { process.terminate() }; throw CodexError.authenticationFailed }
        guard finished.wait(timeout: .now() + 90) == .success else { process.terminate(); process.waitUntilExit(); throw CodexError.timeout }
        guard process.terminationStatus == 0 else { throw CodexError.authenticationFailed }
    }

    func activateAPIKey(_ profile: CodexProfile, secret: String, expectedPrevious: Data?) throws {
        try ensureNoManagedIdentity()
        guard profile.kind == .openai, !secret.isEmpty else { throw StoreError.missingSecret }
        let (_, before) = try snapshotCurrent()
        guard before?.bytes == expectedPrevious else { throw CodexError.changedExternally }
        let home = try isolatedLoginHome()
        defer { try? FileManager.default.removeItem(at: home) }
        var isolated = self
        isolated.environment["CODEX_HOME"] = home.path
        try isolated.loginAPI(secret: secret, currentDirectory: home)
        guard let incoming = try isolated.fileCredentials().read(), incoming.kind == .openai,
              incoming.fingerprint == CredentialSnapshot.fingerprint("api\0" + secret) else { throw CodexError.invalidCredentials }
        try applyCredential(incoming, profile: profile, expectedPrevious: expectedPrevious)
    }

    // Legacy providers remain available for existing profiles; official
    // account login always goes through the isolated authorization flow.
    func activate(_ profile: CodexProfile, secret: String?, openLoginURL: (URL) -> Bool) throws {
        try ensureNoManagedIdentity()
        if profile.kind == .openai {
            guard let secret, !secret.isEmpty else { throw StoreError.missingSecret }
            let (_, snapshot) = try snapshotCurrent()
            try activateAPIKey(profile, secret: secret, expectedPrevious: snapshot?.bytes)
            return
        }
        guard profile.kind == .provider else { throw CodexError.requestFailed }
        let server = try client(); defer { server.close() }
        try writeConfiguration(profile, using: server)
    }
}
