import Darwin
import Foundation

enum DiagnosticLevel: String, CaseIterable, Identifiable {
    case error, warning, info, debug, trace
    var id: String { rawValue }
    var title: String {
        switch self {
        case .error: return "错误"
        case .warning: return "警告"
        case .info: return "信息"
        case .debug: return "调试"
        case .trace: return "详细"
        }
    }
    var priority: Int {
        switch self { case .error: return 0; case .warning: return 1; case .info: return 2; case .debug: return 3; case .trace: return 4 }
    }
}

/// Events are a closed list: never pass account names, paths, tokens, API keys,
/// URLs, process output or conversation content into the diagnostic file.
enum DiagnosticEvent: String {
    case started = "应用启动"
    case refreshStarted = "开始读取 Codex 状态"
    case refreshFinished = "读取 Codex 状态完成"
    case refreshFailed = "读取 Codex 状态失败"
    case settingsSaved = "设置已保存"
    case settingsFailed = "设置保存失败"
    case profileSaved = "配置已保存"
    case profileSaveFailed = "配置保存失败"
    case profileRemoved = "配置已移除"
    case profileRemoveFailed = "配置移除失败"
    case switchStarted = "开始切换登录"
    case switchFinished = "切换登录完成"
    case switchFailed = "切换登录失败"
    case loggingEnabled = "诊断日志已启用"
    case loggingDisabled = "诊断日志已停用"
}

enum DiagnosticReason: String {
    case codexNotFound = "codex_not_found", timeout, codexUnavailable = "codex_unavailable", configChanged = "config_changed"
    case loginFailed = "login_failed", loginCancelled = "login_cancelled", identityMismatch = "identity_mismatch"
    case missingCredential = "missing_credential", invalidCredential = "invalid_credential", credentialFile = "credential_file"
    case credentialStoreUnsupported = "credential_store_unsupported", environmentOverride = "environment_override"
    case restrictedLogin = "restricted_login", customEndpoint = "custom_endpoint", configOverridden = "config_overridden"
    case runningCodex = "running_codex", processCheck = "process_check", desktopQuit = "desktop_quit"
    case invalidDirectory = "invalid_directory", destinationHasProfiles = "destination_has_profiles", destinationHasCredentials = "destination_has_credentials", other

    static func classify(_ error: Error) -> DiagnosticReason {
        if error is NewChatGPTAccountError { return .identityMismatch }
        if let error = error as? CodexError {
            switch error {
            case .notInstalled: return .codexNotFound
            case .timeout: return .timeout
            case .serverUnavailable, .requestFailed: return .codexUnavailable
            case .changedExternally: return .configChanged
            case .authenticationFailed, .invalidAuthURL, .browserUnavailable, .deviceLoginUnavailable, .partialLogin, .loginRestored, .credentialBackupUncertain: return .loginFailed
            case .loginCancelled: return .loginCancelled
            case .differentAccount: return .identityMismatch
            case .invalidCredentials: return .invalidCredential
            case .unsupportedCredentialStore: return .credentialStoreUnsupported
            case .environmentOverride: return .environmentOverride
            case .loginRestricted: return .restrictedLogin
            case .customOpenAIEndpoint: return .customEndpoint
            case .overridden: return .configOverridden
            case .codexStillRunning: return .runningCodex
            case .processCheckFailed: return .processCheck
            case .desktopQuitFailed: return .desktopQuit
            case .missingHelper, .providerInUse: return .other
            }
        }
        if let error = error as? StoreError {
            switch error {
            case .missingSecret: return .missingCredential
            case .invalidSecret: return .invalidCredential
            case .credentialFile: return .credentialFile
            case .invalidDirectory: return .invalidDirectory
            case .destinationHasProfiles: return .destinationHasProfiles
            case .destinationHasCredentials: return .destinationHasCredentials
            }
        }
        return .other
    }
}

final class DiagnosticLog {
    private let lock = NSLock()
    private var directory: URL
    private var enabled: Bool
    private var level: DiagnosticLevel

    init(directory: URL, enabled: Bool, level: DiagnosticLevel) {
        self.directory = directory; self.enabled = enabled; self.level = level
    }

    func configure(directory: URL, enabled: Bool, level: DiagnosticLevel) {
        lock.lock(); defer { lock.unlock() }
        self.directory = directory; self.enabled = enabled; self.level = level
    }

    private func openFile() throws -> (Int32, URL) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("diagnostics.log")
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StoreError.invalidDirectory }
        return (fd, url)
    }

    func fileForOpening() throws -> URL {
        lock.lock(); defer { lock.unlock() }
        let (fd, url) = try openFile(); _ = close(fd)
        return url
    }

    func record(_ event: DiagnosticEvent, level eventLevel: DiagnosticLevel = .info, reason: DiagnosticReason? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard enabled, eventLevel.priority <= level.priority, let (fd, _) = try? openFile() else { return }
        defer { _ = close(fd) }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let suffix = reason.map { " reason=" + $0.rawValue } ?? ""
        let line = Data("\(timestamp) [\(eventLevel.rawValue.uppercased())] \(event.rawValue)\(suffix)\n".utf8)
        line.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
    }
}
