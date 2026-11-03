import AppKit
import Darwin
import Foundation
import ServiceManagement

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self { case .system: return L("跟随系统"); case .light: return L("浅色"); case .dark: return L("深色") }
    }
    var symbol: String {
        switch self { case .system: return "desktopcomputer"; case .light: return "sun.max"; case .dark: return "moon" }
    }
    var nsAppearance: NSAppearance? {
        switch self { case .system: return nil; case .light: return NSAppearance(named: .aqua); case .dark: return NSAppearance(named: .darkAqua) }
    }
}

private struct QuotaIdentity: Equatable {
    let fingerprint: String?
    let email: String?
}

struct AccountLoginProgress {
    let method: ChatGPTLoginMethod
    var instructions: ChatGPTLoginInstructions?
    var isCancelling = false
    var isSaving = false
}

@MainActor
final class AppState: ObservableObject {
    @Published var profiles: [CodexProfile] = []
    @Published var current: CurrentCodex = .unavailable
    @Published var busy = false
    @Published var message = ""
    @Published var isError = false
    @Published var page: Page = .menu
    @Published var editing: CodexProfile?
    @Published var editingCurrent: CurrentCodex?
    @Published var codexHome = ""
    @Published var codexPath = ""
    @Published var preserveSharedHistory = true
    @Published private(set) var profileDirectory = ""
    @Published private(set) var loggingEnabled = true
    @Published private(set) var logLevel: DiagnosticLevel = .info
    @Published private(set) var appearance: AppAppearance = .system
    @Published private(set) var language: AppLanguage = .simplifiedChinese
    @Published private(set) var launchAtLogin = false
    @Published private(set) var silentLaunch = false
    @Published private(set) var closeToMenuBar = true
    @Published private(set) var pendingProfileID: UUID?
    @Published private(set) var pendingReauthentication = false
    @Published private(set) var currentQuota: AccountQuota?
    @Published private(set) var currentStatusLoading = false
    @Published private(set) var currentQuotaLoading = false
    @Published private(set) var currentQuotaFailed = false
    @Published private(set) var updateStatus: UpdateCheckStatus = .idle
    @Published private(set) var quotaByAccount: [String: AccountQuota] = [:]
    @Published private(set) var accountLogin: AccountLoginProgress?
    var onActivationFailure: ((String) -> Void)?
    var onRequestActivation: ((CodexProfile, Bool) -> Void)?
    var onAppearanceChanged: ((AppAppearance) -> Void)?
    var onLanguageChanged: ((AppLanguage) -> Void)?

    enum Page { case menu, manage, add, settings }
    let demo: Bool
    let detectedCodexHome: String
    private let launchEnvironment: [String: String]
    private var storage: ProfileStore
    private var credentials: SavedCredentialFiles { SavedCredentialFiles(root: storage.directory) }
    private let preferences: UserDefaults
    private let diagnostics: DiagnosticLog
    private let updateChecker: GitHubUpdateChecker
    private let refreshGroup = DispatchGroup()
    private var refreshGeneration = 0
    private var planRecoveryAttempts = Set<UUID>()
    private var nameRecoveryAttempts = Set<UUID>()
    private var quotaIdentity: QuotaIdentity?
    private var quotaGeneration = 0
    private var quotaLastAttempt: Date?
    private var loginCancellation: LoginCancellation?
    private var demoAPIKeys: [UUID: String] = [:]

    init(demo: Bool = false, storage: ProfileStore? = nil, preferences: UserDefaults = .standard,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         updateChecker: GitHubUpdateChecker = GitHubUpdateChecker()) {
        let storedPath = demo ? nil : preferences.string(forKey: ProfileStore.preferenceKey)
        let previousDirectory = storedPath.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
        let selectedStore: ProfileStore
        if let storage {
            selectedStore = storage
        } else if demo {
            selectedStore = .standard()
        } else {
            selectedStore = ProfileStore(directory: previousDirectory ?? ProfileStore.standard().directory)
        }
        let enabled = demo ? false : (preferences.object(forKey: "diagnosticEnabled") as? Bool ?? true)
        let level = DiagnosticLevel(rawValue: preferences.string(forKey: "diagnosticLevel") ?? "info") ?? .info
        self.demo = demo; self.storage = selectedStore; self.preferences = preferences
        self.updateChecker = updateChecker
        let selectedLanguage = demo ? AppLanguage.simplifiedChinese : (AppLanguage(rawValue: preferences.string(forKey: "language") ?? "") ?? .simplifiedChinese)
        language = selectedLanguage
        Localization.select(selectedLanguage)
        self.launchEnvironment = environment
        self.detectedCodexHome = CodexHome.resolve(environment: environment).path
        self.diagnostics = DiagnosticLog(directory: selectedStore.directory, enabled: enabled, level: level)
        profileDirectory = demo ? "~/.cam" : selectedStore.directory.path
        loggingEnabled = demo ? true : enabled; logLevel = level
        codexHome = demo ? "" : (preferences.string(forKey: "codexHome") ?? "")
        codexPath = demo ? "" : (preferences.string(forKey: "codexPath") ?? "")
        preserveSharedHistory = demo ? true : (preferences.object(forKey: "preserveSharedHistory") as? Bool ?? true)
        appearance = demo ? (CommandLine.arguments.contains("--dark") ? .dark : CommandLine.arguments.contains("--light") ? .light : .system)
            : (AppAppearance(rawValue: preferences.string(forKey: "appearance") ?? "system") ?? .system)
        silentLaunch = !demo && preferences.bool(forKey: "silentLaunch")
        closeToMenuBar = demo ? true : (preferences.object(forKey: "closeToMenuBar") as? Bool ?? true)
        if !demo {
            let status = SMAppService.mainApp.status
            launchAtLogin = status == .enabled || status == .requiresApproval
        }
        if !demo, let id = preferences.string(forKey: "pendingProfileID") { pendingProfileID = UUID(uuidString: id) }
        pendingReauthentication = !demo && preferences.bool(forKey: "pendingReauthentication")
        if demo {
            profiles = [
                CodexProfile(id: UUID(uuidString: "f711f011-7a76-48a1-ac10-a5a752ba3cd1")!, name: "个人账号", kind: .chatgpt, model: nil, baseURL: nil, hasSecret: true, accountEmail: "demo@example.invalid", accountID: "demo-account", accountPlanType: "plus"),
                CodexProfile(id: UUID(uuidString: "f711f011-7a76-48a1-ac10-a5a752ba3cd3")!, name: "工作账号", kind: .chatgpt, model: nil, baseURL: nil, hasSecret: true, accountEmail: "work@example.invalid", accountID: "demo-work", accountPlanType: "business"),
                CodexProfile(id: UUID(uuidString: "f711f011-7a76-48a1-ac10-a5a752ba3cd2")!, name: "工作 API Key", kind: .openai, model: nil, baseURL: nil, hasSecret: true),
            ]
            demoAPIKeys[profiles[2].id] = "sk-demo-only-not-real"
            current = CurrentCodex(account: "demo@example.invalid", accountType: "chatgpt", provider: "openai", model: "默认", configVersion: nil, configAvailable: true, accountAvailable: true, credentialStore: "file", credentialFingerprint: "demo-account", accountPlanType: "plus")
            let now = Date()
            currentQuota = AccountQuota(buckets: [QuotaBucket(id: "codex", title: nil, windows: [
                QuotaWindow(id: "primary", usedPercent: 22, durationMinutes: 300, resetsAt: now.addingTimeInterval(9_000)),
                QuotaWindow(id: "secondary", usedPercent: 48, durationMinutes: 10_080, resetsAt: now.addingTimeInterval(259_200))
            ], credits: nil, individualLimit: nil, reached: nil)], resetCredits: nil, updatedAt: now)
            if let currentQuota { quotaByAccount["demo-account"] = currentQuota }
            quotaByAccount["demo-work"] = AccountQuota(buckets: [QuotaBucket(id: "codex", title: nil, windows: [
                QuotaWindow(id: "primary", usedPercent: 35, durationMinutes: 300, resetsAt: now.addingTimeInterval(7_200)),
                QuotaWindow(id: "secondary", usedPercent: 20, durationMinutes: 10_080, resetsAt: now.addingTimeInterval(345_600))
            ], credits: nil, individualLimit: nil, reached: nil)], resetCredits: nil, updatedAt: now.addingTimeInterval(-900))
        } else {
            diagnostics.record(.started)
            do {
                profiles = try selectedStore.load()
                for profile in profiles where profile.kind == .chatgpt {
                    if let identity = profile.accountID, let quota = profile.lastQuota {
                        if let previous = quotaByAccount[identity], previous.updatedAt > quota.updatedAt { continue }
                        quotaByAccount[identity] = quota
                    }
                }
            } catch { setMessage(L("无法读取已保存的配置，请检查本机文件。"), error: true); diagnostics.record(.settingsFailed, level: .error) }
            refresh()
        }
    }

    func setAppearance(_ value: AppAppearance) {
        appearance = value
        if !demo { preferences.set(value.rawValue, forKey: "appearance") }
        onAppearanceChanged?(value)
    }

    func setLanguage(_ value: AppLanguage) {
        guard value != language else { return }
        Localization.select(value)
        language = value
        if !demo { preferences.set(value.rawValue, forKey: "language") }
        if !busy { setMessage("") }
        onLanguageChanged?(value)
    }

    func checkForUpdates() {
        guard updateStatus != .checking else { return }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        updateStatus = .checking
        updateChecker.check(currentVersion: version) { [weak self] result in
            DispatchQueue.main.async { self?.updateStatus = result }
        }
    }

    func setSilentLaunch(_ enabled: Bool) {
        silentLaunch = enabled
        if !demo { preferences.set(enabled, forKey: "silentLaunch") }
    }

    func setCloseToMenuBar(_ enabled: Bool) {
        closeToMenuBar = enabled
        if !demo { preferences.set(enabled, forKey: "closeToMenuBar") }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard !demo else { launchAtLogin = enabled; return }
        do {
            let service = SMAppService.mainApp
            if enabled { try service.register() } else { try service.unregister() }
            launchAtLogin = service.status == .enabled || service.status == .requiresApproval
            if enabled && service.status == .requiresApproval {
                setMessage(L("请在系统设置的登录项中允许此应用开机启动。"))
            }
        } catch {
            let status = SMAppService.mainApp.status
            launchAtLogin = status == .enabled || status == .requiresApproval
            setMessage(L("无法更改开机自启，请检查系统设置中的登录项。"), error: true)
        }
    }

    private func service() -> CodexService {
        var environment = launchEnvironment
        let home = codexHome.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = codexPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !home.isEmpty { environment["CODEX_HOME"] = NSString(string: home).expandingTildeInPath }
        if !path.isEmpty { environment["CAM_CODEX_PATH"] = NSString(string: path).expandingTildeInPath }
        var service = CodexService(environment: environment, preserveSharedHistory: preserveSharedHistory)
        let effectiveHome = service.fileCredentials().home.standardizedFileURL.resolvingSymlinksInPath().path
        service.preferAvailableSharedHistory = preferences.string(forKey: "sharedHistoryHome") == effectiveHome
        return service
    }

    func setPreserveSharedHistory(_ enabled: Bool) {
        guard !demo else { preserveSharedHistory = enabled; setMessage(L("演示模式不会保存设置。")); return }
        guard !busy, current.configAvailable else { return }
        if current.usesSharedOfficialProvider {
            let home = service().fileCredentials().home.standardizedFileURL.resolvingSymlinksInPath().path
            preferences.set(home, forKey: "sharedHistoryHome")
        }
        preserveSharedHistory = enabled
        preferences.set(enabled, forKey: "preserveSharedHistory")
        diagnostics.record(.settingsSaved)
        setMessage(L("会话设置已保存，将在下次切换账号时生效。"))
    }

    func setDiagnostics(enabled: Bool, level: DiagnosticLevel) {
        if demo { loggingEnabled = enabled; logLevel = level; setMessage(L("演示模式不会保存设置。")); return }
        if loggingEnabled && !enabled { diagnostics.record(.loggingDisabled) }
        let wasEnabled = loggingEnabled
        loggingEnabled = enabled; logLevel = level
        preferences.set(enabled, forKey: "diagnosticEnabled")
        preferences.set(level.rawValue, forKey: "diagnosticLevel")
        diagnostics.configure(directory: storage.directory, enabled: enabled, level: level)
        if enabled && !wasEnabled { diagnostics.record(.loggingEnabled) }
    }

    func openDiagnosticLog() {
        guard !demo else { setMessage(L("演示模式不会打开真实日志。")); return }
        do {
            let file = try diagnostics.fileForOpening()
            guard NSWorkspace.shared.open(file) else { throw StoreError.invalidDirectory }
        } catch { setMessage(L("无法打开诊断日志，请检查存储目录。"), error: true) }
    }

    func setMessage(_ text: String, error: Bool = false) { message = text; isError = error }

    func requestActivation(_ profile: CodexProfile, reauthenticate: Bool = false) {
        guard reauthenticate || !isCurrent(profile) else { return }
        if let onRequestActivation { onRequestActivation(profile, reauthenticate) }
        else { activate(profile, reauthenticate: reauthenticate) }
    }

    func scheduleActivation(_ profile: CodexProfile, reauthenticate: Bool) {
        pendingProfileID = profile.id; pendingReauthentication = reauthenticate
        preferences.set(profile.id.uuidString, forKey: "pendingProfileID")
        preferences.set(reauthenticate, forKey: "pendingReauthentication")
        setMessage(L("已暂存 \(profileDisplayName(profile))。退出 Codex 后自动切换。"))
    }

    func cancelPending() {
        pendingProfileID = nil; pendingReauthentication = false
        preferences.removeObject(forKey: "pendingProfileID")
        preferences.removeObject(forKey: "pendingReauthentication")
    }

    func matchesCurrentLogin(_ profile: CodexProfile) -> Bool {
        guard current.configAvailable, current.accountAvailable, let fingerprint = current.credentialFingerprint else { return false }
        if profile.kind == .chatgpt { return current.accountType == "chatgpt" && profile.accountID == fingerprint }
        if profile.kind == .openai { return current.accountType == "apiKey" && profile.secretFingerprint == fingerprint }
        return false
    }

    func isCurrent(_ profile: CodexProfile) -> Bool { current.isOfficialProvider && matchesCurrentLogin(profile) }

    func accountPlanType(for profile: CodexProfile) -> String? {
        guard profile.kind == .chatgpt else { return nil }
        return matchesCurrentLogin(profile) ? (current.accountPlanType ?? profile.accountPlanType) : profile.accountPlanType
    }

    func profileDisplayName(_ profile: CodexProfile) -> String {
        guard profile.kind == .chatgpt else { return profile.name }
        let previouslyDefaultedToEmail = profile.accountEmail.map { profile.name.caseInsensitiveCompare($0) == .orderedSame } ?? false
        let usesOfficialName = profile.hasCustomName == false || (profile.hasCustomName == nil && previouslyDefaultedToEmail)
        guard usesOfficialName else { return profile.name }
        return (matchesCurrentLogin(profile) ? current.accountDisplayName : nil) ?? profile.accountDisplayName ?? profile.name
    }

    var currentQuotaPresentation: QuotaPresentation {
        QuotaPresentation(value: currentQuota, isLoading: currentQuotaLoading, failed: currentQuotaFailed, isCached: false)
    }

    var quotaRefreshInProgress: Bool { currentStatusLoading || currentQuotaLoading }

    func quotaPresentation(for profile: CodexProfile) -> QuotaPresentation {
        if matchesCurrentLogin(profile) { return currentQuotaPresentation }
        let quota = profile.accountID.flatMap { quotaByAccount[$0] }
        return QuotaPresentation(value: quota, isLoading: false, failed: false, isCached: true)
    }

    var currentHasProfile: Bool { profiles.contains(where: matchesCurrentLogin) }

    var currentLoginDisplayItem: CurrentLoginItem? {
        guard let item = current.currentLoginItem else { return nil }
        guard let profile = profiles.first(where: matchesCurrentLogin) else { return item }
        let name = profileDisplayName(profile)
        let email: String? = {
            guard item.kind == .chatgpt else { return nil }
            let value = (current.account ?? profile.accountEmail)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.flatMap { $0.isEmpty || $0.caseInsensitiveCompare(name) == .orderedSame ? nil : $0 }
        }()
        return CurrentLoginItem(kind: item.kind, name: name,
                                accountPlanType: item.kind == .chatgpt ? accountPlanType(for: profile) : nil,
                                accountEmail: email)
    }

    func currentLoginWithoutProfile(for kind: ProfileKind) -> CurrentLoginItem? {
        guard !currentHasProfile, let item = current.currentLoginItem, item.kind == kind else { return nil }
        return item
    }

    func shouldDisplayProfile(_ profile: CodexProfile) -> Bool {
        if profile.hasSecret || matchesCurrentLogin(profile) { return true }
        if profile.kind == .chatgpt { return profile.accountID == nil }
        if profile.kind == .openai { return profile.secretFingerprint == nil }
        return true
    }

    func savedAPIKey(for id: UUID) throws -> String {
        guard let profile = profiles.first(where: { $0.id == id }), profile.kind == .openai, profile.hasSecret else {
            throw StoreError.missingSecret
        }
        let key: String
        if demo {
            guard let value = demoAPIKeys[id] else { throw StoreError.missingSecret }
            key = value
        } else {
            key = try credentials.loadAPIKey(id: id)
        }
        if let fingerprint = profile.secretFingerprint, CredentialSnapshot.fingerprint("api\0" + key) != fingerprint {
            throw StoreError.invalidSecret
        }
        return key
    }

    func currentAPIKey(for selected: CurrentCodex) throws -> String {
        guard selected.accountAvailable, selected.accountType == "apiKey", let fingerprint = selected.credentialFingerprint else {
            throw CodexError.invalidCredentials
        }
        guard selected.credentialStore == "file" else { throw CodexError.unsupportedCredentialStore }
        if demo {
            guard let profile = profiles.first(where: { $0.kind == .openai && $0.secretFingerprint == fingerprint }),
                  let key = demoAPIKeys[profile.id] else { throw StoreError.missingSecret }
            return key
        }
        return try service().currentFileAPIKey(matching: fingerprint)
    }

    private func sameName(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines)
            .compare(rhs.trimmingCharacters(in: .whitespacesAndNewlines), options: [.caseInsensitive, .widthInsensitive]) == .orderedSame
    }

    private func ensureUniqueName(_ name: String, excludingProfileID: UUID? = nil, excludingCurrent: Bool = false) throws {
        let duplicate = profiles.contains { profile in
            profile.id != excludingProfileID && shouldDisplayProfile(profile) &&
                !(excludingCurrent && matchesCurrentLogin(profile)) && sameName(name, profileDisplayName(profile))
        }
        if duplicate { throw ProfileValidationError.duplicateName }
        if !excludingCurrent, !currentHasProfile, let currentName = current.currentLoginItem?.name, sameName(name, currentName) {
            throw ProfileValidationError.duplicateName
        }
    }

    func beginEditingCurrentAlias() {
        guard !busy, current.currentLoginItem != nil, current.credentialFingerprint != nil else { return }
        editing = nil; editingCurrent = current; setMessage(""); page = .add
    }

    func saveCurrentAlias(_ name: String) {
        guard !busy, let selected = editingCurrent, let fingerprint = selected.credentialFingerprint else { return }
        let alias: String
        do {
            alias = try ProfileValidator.validated(name: name, kind: .chatgpt, model: "", baseURL: "", secret: "").0
            if let currentName = selected.currentLoginItem?.name, !sameName(alias, currentName) {
                try ensureUniqueName(alias, excludingCurrent: true)
            }
        }
        catch { setMessage(error.localizedDescription, error: true); return }
        if demo {
            do {
                profiles = try profilesWithCurrentAlias(alias, current: selected, profiles: profiles)
                editingCurrent = nil; page = .manage; setMessage("")
            } catch { setMessage(error.localizedDescription, error: true) }
            return
        }
        busy = true; invalidateCurrentRefresh(); setMessage(L("正在保存别名…"))
        let service = service(), storage = storage, startingProfiles = profiles
        DispatchQueue.global(qos: .userInitiated).async {
            var next = startingProfiles
            let result = Result {
                let (actual, snapshot) = try service.snapshotCurrent()
                guard actual.accountType == selected.accountType, actual.credentialFingerprint == fingerprint,
                      snapshot?.fingerprint == fingerprint else { throw CodexError.changedExternally }
                next = try profilesWithCurrentAlias(alias, current: actual, profiles: next)
                try storage.save(next)
            }
            let updatedProfiles = next
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success:
                    self.profiles = updatedProfiles; self.editingCurrent = nil; self.page = .manage
                    self.diagnostics.record(.profileSaved); self.setMessage("")
                    self.refresh()
                case .failure(let error):
                    self.diagnostics.record(.profileSaveFailed, level: .error, reason: .classify(error))
                    self.setMessage(error.localizedDescription, error: true)
                }
            }
        }
    }

    func refresh(retryMissingPlanTypes: Bool = false) {
        guard !demo, !busy else { return }
        if retryMissingPlanTypes { planRecoveryAttempts.removeAll(); nameRecoveryAttempts.removeAll() }
        recoverMissingAccountPlans()
        recoverMissingAccountNames()
        refreshGeneration += 1
        let generation = refreshGeneration
        currentStatusLoading = true
        let service = service()
        diagnostics.record(.refreshStarted, level: .trace)
        refreshGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { self.refreshGroup.leave() }
            let result = Result { try service.readCurrent() }
            DispatchQueue.main.async {
                guard self.refreshGeneration == generation else { return }
                self.currentStatusLoading = false
                guard !self.busy else { return }
                switch result {
                case .success(let value):
                    self.current = value
                    self.refreshQuota(for: value, force: retryMissingPlanTypes)
                    if value.usesSharedOfficialProvider && self.preserveSharedHistory {
                        let home = service.fileCredentials().home.standardizedFileURL.resolvingSymlinksInPath().path
                        self.preferences.set(home, forKey: "sharedHistoryHome")
                    }
                    self.diagnostics.record(.refreshFinished, level: .debug)
                case .failure(let error):
                    self.current = .unavailable
                    self.clearCurrentQuota()
                    self.diagnostics.record(.refreshFailed, level: .error, reason: .classify(error))
                    self.setMessage(error.localizedDescription, error: true)
                }
            }
        }
    }

    private func invalidateCurrentRefresh() {
        refreshGeneration += 1
        currentStatusLoading = false
    }

    private func clearCurrentQuota() {
        quotaGeneration += 1
        quotaIdentity = nil; quotaLastAttempt = nil
        currentQuota = nil; currentQuotaLoading = false; currentQuotaFailed = false
    }

    private func refreshQuota(for account: CurrentCodex, force: Bool) {
        guard account.accountAvailable, account.accountType == "chatgpt", account.quotaEndpointIsOfficial,
              account.credentialFingerprint != nil else {
            clearCurrentQuota()
            if account.accountAvailable && account.accountType == "chatgpt" { currentQuotaFailed = true }
            return
        }
        let identity = QuotaIdentity(fingerprint: account.credentialFingerprint, email: account.account)
        if identity != quotaIdentity {
            quotaGeneration += 1
            quotaIdentity = identity; quotaLastAttempt = nil
            currentQuota = identity.fingerprint.flatMap { quotaByAccount[$0] }
            currentQuotaLoading = false; currentQuotaFailed = false
        }
        if !force && (currentQuotaLoading || quotaLastAttempt.map({ Date().timeIntervalSince($0) < 60 }) == true) { return }
        quotaGeneration += 1
        let generation = quotaGeneration
        quotaLastAttempt = Date(); currentQuotaLoading = true; currentQuotaFailed = false
        let service = service(), refreshGroup = refreshGroup
        refreshGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { refreshGroup.leave() }
            let result = Result { try service.readCurrentQuota(expected: account) }
            DispatchQueue.main.async {
                guard self.quotaGeneration == generation, self.quotaIdentity == identity else { return }
                self.currentQuotaLoading = false
                guard !self.busy else { self.quotaLastAttempt = nil; return }
                switch result {
                case .success(let quota?):
                    self.currentQuota = quota
                    self.currentQuotaFailed = false
                    if let fingerprint = identity.fingerprint {
                        self.quotaByAccount[fingerprint] = quota
                        var next = self.profiles
                        for index in next.indices where next[index].kind == .chatgpt && next[index].accountID == fingerprint {
                            next[index].lastQuota = quota
                        }
                        if next != self.profiles {
                            do { try self.storage.save(next); self.profiles = next }
                            catch { self.diagnostics.record(.settingsFailed, level: .error, reason: .classify(error)) }
                        }
                    }
                case .success(nil), .failure:
                    self.currentQuotaFailed = true
                }
            }
        }
    }

    private func recoverMissingAccountPlans() {
        let candidates = profiles.filter {
            $0.kind == .chatgpt && $0.hasSecret && $0.accountID != nil && $0.accountPlanType == nil && !planRecoveryAttempts.contains($0.id)
        }
        guard !candidates.isEmpty else { return }
        planRecoveryAttempts.formUnion(candidates.map(\.id))
        let keys = credentials
        DispatchQueue.global(qos: .utility).async {
            let recovered = recoverAccountPlanTypes(candidates) { try keys.load(id: $0) }
            DispatchQueue.main.async {
                if self.busy {
                    self.planRecoveryAttempts.subtract(candidates.map(\.id))
                    return
                }
                var next = self.profiles
                for candidate in candidates {
                    guard let plan = recovered[candidate.id], let index = next.firstIndex(where: { $0.id == candidate.id }),
                          next[index].accountID == candidate.accountID, next[index].accountPlanType == nil else { continue }
                    next[index].accountPlanType = plan
                }
                // Recovery is an in-memory display aid. Normal saves persist
                // metadata; opening the panel never rewrites existing profiles.
                if next != self.profiles { self.profiles = next }
            }
        }
    }

    private func recoverMissingAccountNames() {
        let candidates = profiles.filter {
            $0.kind == .chatgpt && $0.hasSecret && $0.accountID != nil && $0.accountDisplayName == nil && !nameRecoveryAttempts.contains($0.id)
        }
        guard !candidates.isEmpty else { return }
        nameRecoveryAttempts.formUnion(candidates.map(\.id))
        let keys = credentials
        DispatchQueue.global(qos: .utility).async {
            let recovered = recoverAccountDisplayNames(candidates) { try keys.load(id: $0) }
            DispatchQueue.main.async {
                if self.busy {
                    self.nameRecoveryAttempts.subtract(candidates.map(\.id))
                    return
                }
                var next = self.profiles
                for candidate in candidates {
                    guard let name = recovered[candidate.id], let index = next.firstIndex(where: { $0.id == candidate.id }),
                          next[index].accountID == candidate.accountID, next[index].accountDisplayName == nil else { continue }
                    next[index].accountDisplayName = name
                }
                if next != self.profiles { self.profiles = next }
            }
        }
    }

    func savePreferences(home: String, path: String, directory: String) {
        guard !demo else { setMessage(L("演示模式不会保存设置。")); return }
        guard !busy else { return }
        do {
            let homeValue = home.trimmingCharacters(in: .whitespacesAndNewlines)
            let pathValue = path.trimmingCharacters(in: .whitespacesAndNewlines)
            let input = directory.trimmingCharacters(in: .whitespacesAndNewlines)
            let expanded = input.isEmpty ? ProfileStore.standard().directory.path : NSString(string: input).expandingTildeInPath
            guard expanded.hasPrefix("/"), (homeValue.isEmpty || NSString(string: homeValue).expandingTildeInPath.hasPrefix("/")),
                  (pathValue.isEmpty || NSString(string: pathValue).expandingTildeInPath.hasPrefix("/")) else { throw StoreError.invalidDirectory }
            let nextStore = try storage.copyProfiles(to: URL(fileURLWithPath: expanded, isDirectory: true), profiles: profiles)
            let storageChanged = nextStore.directory.resolvingSymlinksInPath().path != storage.directory.resolvingSymlinksInPath().path
            storage = nextStore; profileDirectory = nextStore.directory.path
            codexHome = homeValue; codexPath = pathValue
            preferences.set(profileDirectory, forKey: ProfileStore.preferenceKey)
            preferences.set(codexHome, forKey: "codexHome")
            preferences.set(codexPath, forKey: "codexPath")
            diagnostics.configure(directory: nextStore.directory, enabled: loggingEnabled, level: logLevel)
            diagnostics.record(.settingsSaved)
            page = .menu; setMessage(storageChanged ? L("应用目录已保存，原配置文件保留。") : L("目录设置已保存。")); refresh()
        } catch {
            diagnostics.record(.settingsFailed, level: .error, reason: .classify(error))
            setMessage(error.localizedDescription, error: true)
        }
    }

    func add(name: String, kind: ProfileKind, model: String, baseURL: String, secret: String) -> Bool {
        do {
            guard kind != .chatgpt else { setMessage(L("请先完成官方账号登录。"), error: true); return false }
            let (title, selectedModel, address, key) = try ProfileValidator.validated(name: name, kind: kind, model: model, baseURL: baseURL, secret: secret)
            try ensureUniqueName(title)
            let profile = CodexProfile(id: UUID(), name: title, kind: kind, model: selectedModel, baseURL: address, hasSecret: key != nil,
                                       secretFingerprint: kind == .openai ? key.map { CredentialSnapshot.fingerprint("api\0" + $0) } : nil)
            if !demo {
                if let key { try credentials.save(key, id: profile.id) }
                do { try storage.save(profiles + [profile]) }
                catch { if key != nil { try? credentials.delete(id: profile.id) }; throw error }
            } else if kind == .openai, let key {
                demoAPIKeys[profile.id] = key
            }
            profiles.append(profile); page = .manage
            if !demo { diagnostics.record(.profileSaved) }
            setMessage(demo ? L("已添加模拟配置。") : L("配置已保存。"))
            return true
        } catch { if !demo { diagnostics.record(.profileSaveFailed, level: .error, reason: .classify(error)) }; setMessage(error.localizedDescription, error: true); return false }
    }

    func beginChatGPTLogin(_ method: ChatGPTLoginMethod, openBrowser: Bool = true) {
        guard !busy, page == .add, editing == nil else { return }
        guard !demo else { setMessage(L("演示模式不会添加真实账号。"), error: true); return }
        busy = true; invalidateCurrentRefresh()
        let cancellation = LoginCancellation()
        loginCancellation = cancellation
        accountLogin = AccountLoginProgress(method: method)
        setMessage(L("正在启动\(method.title)…"))
        let service = service(), keys = credentials, storage = storage, startingProfiles = profiles, refreshGroup = refreshGroup
        DispatchQueue.global(qos: .userInitiated).async {
            var next = startingProfiles
            let result = Result { () -> AuthorizedChatGPTAccount in
                guard refreshGroup.wait(timeout: .now() + 20) == .success else { throw CodexError.processCheckFailed }
                let account = try service.authorizeAdditionalChatGPT(method: method, cancellation: cancellation, onAuthenticated: {
                    DispatchQueue.main.async {
                        guard self.loginCancellation === cancellation, !cancellation.isCancelled else { return }
                        self.setMessage(L("登录成功，正在读取账号信息…"))
                    }
                }) { instructions in
                    DispatchQueue.main.sync {
                        guard self.loginCancellation === cancellation, !cancellation.isCancelled else { return false }
                        self.accountLogin?.instructions = instructions
                        if !openBrowser {
                            self.setMessage(L("请复制登录链接，在要使用的浏览器中打开并完成登录。"))
                        } else if NSWorkspace.shared.open(instructions.url) {
                            self.setMessage(method == .browser ? L("请在浏览器登录要添加的账号。") : L("请在授权网页登录要添加的账号并输入设备代码。"))
                        } else {
                            self.setMessage(L("未能自动打开浏览器，请打开或复制登录链接。"), error: true)
                        }
                        // Keep the authorization alive if the user chooses a
                        // different browser or the default browser fails to open.
                        return true
                    }
                }
                try ensureNewChatGPTAccount(account, profiles: next)
                let maySave = DispatchQueue.main.sync {
                    guard self.loginCancellation === cancellation, !cancellation.isCancelled else { return false }
                    self.accountLogin?.isSaving = true
                    self.setMessage(L("登录成功，正在保存账号…"))
                    return true
                }
                guard maySave else { throw CodexError.loginCancelled }
                _ = try saveAuthorizedChatGPTAccount(account, profiles: &next, keys: keys, storage: storage)
                return account
            }
            let updated = next
            DispatchQueue.main.async {
                guard self.loginCancellation === cancellation else { return }
                self.loginCancellation = nil; self.accountLogin = nil; self.busy = false
                switch result {
                case .success(let account):
                    self.profiles = updated
                    if let quota = account.quota { self.quotaByAccount[account.credentials.fingerprint] = quota }
                    self.page = .manage
                    self.diagnostics.record(.profileSaved)
                    self.setMessage(L("账号已添加。"))
                    self.refresh()
                case .failure(let error):
                    if case CodexError.loginCancelled = error {
                        self.page = .manage; self.setMessage(L("已取消添加账号。"))
                    } else {
                        self.diagnostics.record(.profileSaveFailed, level: .error, reason: .classify(error))
                        self.setMessage(error.localizedDescription, error: true)
                    }
                }
            }
        }
    }

    func cancelChatGPTLogin() {
        guard let cancellation = loginCancellation, accountLogin?.isSaving != true else { return }
        cancellation.cancel()
        accountLogin?.isCancelling = true
        setMessage(L("正在取消登录…"))
    }

    func update(_ existing: CodexProfile, name: String, model: String, baseURL: String, secret: String) -> Bool {
        do {
            let replacementSecret = existing.kind == .chatgpt ? "" : secret.trimmingCharacters(in: .whitespacesAndNewlines)
            let validationKey = existing.kind == .openai && (existing.hasSecret || matchesCurrentLogin(existing)) && replacementSecret.isEmpty ? "existing-key" : replacementSecret
            let (title, selectedModel, address, _) = try ProfileValidator.validated(name: name, kind: existing.kind, model: model, baseURL: baseURL, secret: validationKey)
            guard let index = profiles.firstIndex(where: { $0.id == existing.id }) else { throw StoreError.missingSecret }
            if !sameName(title, profileDisplayName(profiles[index])) {
                try ensureUniqueName(title, excludingProfileID: existing.id)
            }
            let updated = CodexProfile(id: existing.id, name: title, kind: existing.kind, model: selectedModel,
                                       baseURL: address, hasSecret: existing.hasSecret || !replacementSecret.isEmpty,
                                       accountEmail: existing.accountEmail, accountID: existing.accountID,
                                       secretFingerprint: existing.kind == .openai && !replacementSecret.isEmpty ? CredentialSnapshot.fingerprint("api\0" + replacementSecret) : existing.secretFingerprint,
                                       accountPlanType: profiles[index].accountPlanType, lastQuota: profiles[index].lastQuota,
                                       accountDisplayName: profiles[index].accountDisplayName,
                                       hasCustomName: existing.kind == .chatgpt ? true : existing.hasCustomName)
            var next = profiles; next[index] = updated
            if !demo {
                let keys = credentials
                let previous = !replacementSecret.isEmpty ? try previousCredential(keys: keys, id: existing.id) : nil
                if !replacementSecret.isEmpty { try keys.save(replacementSecret, id: existing.id) }
                do { try storage.save(next) }
                catch {
                    if !replacementSecret.isEmpty {
                        try restoreCredential(keys: keys, id: existing.id, previous: previous)
                    }
                    throw error
                }
            } else if existing.kind == .openai && !replacementSecret.isEmpty {
                demoAPIKeys[existing.id] = replacementSecret
            }
            profiles = next; editing = nil; page = .manage
            if !demo { diagnostics.record(.profileSaved) }
            setMessage("")
            return true
        } catch { if !demo { diagnostics.record(.profileSaveFailed, level: .error, reason: .classify(error)) }; setMessage(error.localizedDescription, error: true); return false }
    }

    func remove(_ profile: CodexProfile) {
        guard !busy else { return }
        guard !isCurrent(profile) else { setMessage(L("当前使用中的配置不能删除，请先切换到其他配置。"), error: true); return }
        let remaining = profiles.filter { $0.id != profile.id }
        if demo { profiles = remaining; demoAPIKeys.removeValue(forKey: profile.id); discardUnreferencedQuota(profile, remaining: remaining); setMessage(L("模拟配置已移除。")); return }
        busy = true; invalidateCurrentRefresh(); setMessage(L("正在移除配置…"))
        let service = service(), storage = storage, keys = credentials
        DispatchQueue.global(qos: .userInitiated).async {
            var metadataRemoved = false
            let result = Result {
                try service.removeProvider(profile)
                try storage.save(remaining); metadataRemoved = true
                if profile.hasSecret { try keys.delete(id: profile.id) }
            }
            DispatchQueue.main.async {
                self.busy = false
                if metadataRemoved {
                    self.profiles = remaining
                    self.discardUnreferencedQuota(profile, remaining: remaining)
                    if self.pendingProfileID == profile.id { self.cancelPending() }
                }
                switch result {
                case .success: self.diagnostics.record(.profileRemoved); self.setMessage(L("配置已移除。"))
                case .failure(let error): self.diagnostics.record(.profileRemoveFailed, level: .error, reason: .classify(error)); self.setMessage(L("未能完整移除配置：") + error.localizedDescription, error: true)
                }
                self.refresh()
            }
        }
    }

    private func discardUnreferencedQuota(_ profile: CodexProfile, remaining: [CodexProfile]) {
        guard let identity = profile.accountID,
              !remaining.contains(where: { $0.kind == .chatgpt && $0.accountID == identity }) else { return }
        quotaByAccount.removeValue(forKey: identity)
    }

    func activate(_ profile: CodexProfile, reauthenticate: Bool = false, closing applications: [NSRunningApplication] = [], reopenURL: URL? = nil, fromPending: Bool = false) {
        guard !busy else { return }
        if demo { setMessage(L("演示模式不会修改 Codex 配置或登录状态。")); return }
        if applications.isEmpty && NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").contains(where: { !$0.isTerminated }) {
            let message = CodexError.codexStillRunning.localizedDescription
            setMessage(message, error: true); onActivationFailure?(message); return
        }
        busy = true
        diagnostics.record(.switchStarted)
        invalidateCurrentRefresh()
        let needsLogin = profile.kind == .chatgpt && (!profile.hasSecret || reauthenticate)
        let cancellation = needsLogin ? LoginCancellation() : nil
        if let cancellation {
            loginCancellation = cancellation
            accountLogin = AccountLoginProgress(method: .browser)
        }
        setMessage(needsLogin ? L("正在准备官方浏览器登录…") : L("正在切换默认配置…"))
        let service = service(); let keys = credentials; let storage = storage; let startingProfiles = profiles; let cachedQuotas = quotaByAccount; let refreshGroup = refreshGroup
        DispatchQueue.global(qos: .userInitiated).async {
            var next = startingProfiles
            var attemptedClose = false
            let result = Result {
                if !applications.isEmpty {
                    attemptedClose = true
                    let accepted = DispatchQueue.main.sync { applications.allSatisfy { $0.isTerminated || $0.terminate() } }
                    guard accepted else { throw CodexError.desktopQuitFailed }
                    let deadline = Date().addingTimeInterval(20)
                    while applications.contains(where: { !$0.isTerminated }) && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
                    guard applications.allSatisfy(\.isTerminated) else { throw CodexError.desktopQuitFailed }
                }
                guard refreshGroup.wait(timeout: .now() + 20) == .success else { throw CodexError.processCheckFailed }
                try requireNoRunningCodexCLI()
                let previous = try preserveCurrentAccount(service: service, profiles: &next, keys: keys, storage: storage, cachedQuotas: cachedQuotas)
                if profile.kind == .chatgpt && profile.hasSecret && !reauthenticate {
                    try service.activateSavedChatGPT(profile, credential: keys.load(id: profile.id), expectedPrevious: previous)
                } else if let cancellation {
                    _ = try reauthorizeChatGPTAccount(service: service, profileID: profile.id, expectedPrevious: previous,
                                                       profiles: &next, keys: keys, storage: storage, cancellation: cancellation,
                                                       onAuthenticated: {
                        DispatchQueue.main.async {
                            guard self.loginCancellation === cancellation, !cancellation.isCancelled else { return }
                            self.setMessage(L("登录成功，正在核对账号…"))
                        }
                    }, onInstructions: { instructions in
                        DispatchQueue.main.sync {
                            guard self.loginCancellation === cancellation, !cancellation.isCancelled else { return false }
                            self.accountLogin?.instructions = instructions
                            if NSWorkspace.shared.open(instructions.url) {
                                self.setMessage(L("请在浏览器登录所选账号。"))
                            } else {
                                self.setMessage(L("未能自动打开浏览器，请复制登录链接。"), error: true)
                            }
                            return true
                        }
                    }, willCommit: {
                        try requireNoRunningCodexCLI()
                        let maySave = DispatchQueue.main.sync {
                            guard self.loginCancellation === cancellation, !cancellation.isCancelled else { return false }
                            guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").contains(where: { !$0.isTerminated }) else { return false }
                            self.accountLogin?.isSaving = true
                            self.setMessage(L("账号已核对，正在保存并切换…"))
                            return true
                        }
                        guard maySave else { throw cancellation.isCancelled ? CodexError.loginCancelled : CodexError.codexStillRunning }
                    })
                } else if profile.kind == .openai {
                    try service.activateAPIKey(profile, secret: keys.load(id: profile.id), expectedPrevious: previous)
                } else {
                    guard try service.fileCredentials().raw() == previous else { throw CodexError.changedExternally }
                    try service.activate(profile, secret: nil) { _ in false }
                }
            }
            let updatedProfiles = next
            DispatchQueue.main.async {
                if attemptedClose, let reopenURL, applications.contains(where: \.isTerminated) {
                    NSWorkspace.shared.openApplication(at: reopenURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                        if error != nil { DispatchQueue.main.async { self.onActivationFailure?(L("无法自动重新打开 Codex，请从应用程序中手动打开。")) } }
                    }
                }
                self.profiles = updatedProfiles
                if let cancellation, self.loginCancellation === cancellation { self.loginCancellation = nil; self.accountLogin = nil }
                self.busy = false
                switch result {
                case .success:
                    self.diagnostics.record(.switchFinished)
                    if fromPending && self.pendingProfileID == profile.id { self.cancelPending() }
                    self.setMessage(reopenURL == nil ? L("已切换。重新打开 Codex 后生效。") : L("已切换，正在重新打开 Codex。"))
                case .failure(let error):
                    if case CodexError.loginCancelled = error {
                        self.setMessage(L("已取消重新登录。"))
                    } else {
                        self.diagnostics.record(.switchFailed, level: .error, reason: .classify(error))
                        self.setMessage(error.localizedDescription, error: true)
                        self.onActivationFailure?(error.localizedDescription)
                    }
                }
                self.refresh()
            }
        }
    }
}

private func requireNoRunningCodexCLI() throws {
    let check = Process()
    check.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    check.arguments = ["-i", "-u", String(getuid()), "-x", "codex|codex-app-server|codex-app-serve"]
    check.standardOutput = FileHandle.nullDevice
    check.standardError = FileHandle.nullDevice
    let finished = DispatchSemaphore(value: 0)
    check.terminationHandler = { _ in finished.signal() }
    do { try check.run() } catch { throw CodexError.processCheckFailed }
    guard finished.wait(timeout: .now() + 5) == .success else {
        check.terminate(); check.waitUntilExit(); throw CodexError.processCheckFailed
    }
    if check.terminationStatus == 0 { throw CodexError.codexStillRunning }
    guard check.terminationStatus == 1 else { throw CodexError.processCheckFailed }
}

/// Persist only an alias for the active identity; credentials are backed up on switch.
func profilesWithCurrentAlias(_ alias: String, current: CurrentCodex, profiles: [CodexProfile]) throws -> [CodexProfile] {
    guard current.accountAvailable, let fingerprint = current.credentialFingerprint, !fingerprint.isEmpty else { throw CodexError.invalidCredentials }
    let kind: ProfileKind
    switch current.accountType {
    case "chatgpt": kind = .chatgpt
    case "apiKey": kind = .openai
    default: throw CodexError.invalidCredentials
    }
    var next = profiles
    if let index = next.firstIndex(where: {
        $0.kind == kind && (kind == .chatgpt ? $0.accountID : $0.secretFingerprint) == fingerprint
    }) {
        next[index].name = alias
        next[index].hasCustomName = true
    } else {
        next.append(CodexProfile(id: UUID(), name: alias, kind: kind, model: nil, baseURL: nil, hasSecret: false,
                                 accountEmail: kind == .chatgpt ? current.account : nil,
                                 accountID: kind == .chatgpt ? fingerprint : nil,
                                 secretFingerprint: kind == .openai ? fingerprint : nil,
                                 accountPlanType: kind == .chatgpt ? ChatGPTPlan.knownValue(current.accountPlanType) : nil,
                                 accountDisplayName: kind == .chatgpt ? current.accountDisplayName : nil,
                                 hasCustomName: true))
    }
    return next
}

/// Recover display metadata from older saved credentials without changing them.
/// The workspace fingerprint must match, even when email addresses are equal.
func recoverAccountPlanTypes(_ profiles: [CodexProfile], load: (UUID) throws -> String) -> [UUID: String] {
    var result: [UUID: String] = [:]
    for profile in profiles where profile.kind == .chatgpt && profile.hasSecret && profile.accountPlanType == nil {
        guard let expected = profile.accountID,
              let value = try? load(profile.id),
              let snapshot = try? CredentialSnapshot(bytes: Data(value.utf8)),
              snapshot.kind == .chatgpt, snapshot.fingerprint == expected,
              let plan = snapshot.accountPlanType else { continue }
        result[profile.id] = plan
    }
    return result
}

/// Read an optional official display name only from the matching account and workspace.
func recoverAccountDisplayNames(_ profiles: [CodexProfile], load: (UUID) throws -> String) -> [UUID: String] {
    var result: [UUID: String] = [:]
    for profile in profiles where profile.kind == .chatgpt && profile.hasSecret && profile.accountDisplayName == nil {
        guard let expected = profile.accountID, let value = try? load(profile.id),
              let snapshot = try? CredentialSnapshot(bytes: Data(value.utf8)),
              snapshot.kind == .chatgpt, snapshot.fingerprint == expected,
              let name = snapshot.displayName else { continue }
        result[profile.id] = name
    }
    return result
}

private func matchingCredentialDisplayName(_ snapshot: CredentialSnapshot, current: CurrentCodex) -> String? {
    guard current.accountType == "chatgpt", snapshot.kind == .chatgpt,
          current.credentialFingerprint == snapshot.fingerprint else { return nil }
    if let reportedEmail = current.account, let tokenEmail = snapshot.email,
       reportedEmail.caseInsensitiveCompare(tokenEmail) != .orderedSame { return nil }
    return current.accountDisplayName ?? snapshot.displayName
}

enum NewChatGPTAccountError: LocalizedError {
    case alreadySaved, alreadyCurrent

    var errorDescription: String? {
        switch self {
        case .alreadySaved:
            return L("该账号已添加。请登录其他账号；如需更新登录，请在账号菜单中选择“重新登录”。")
        case .alreadyCurrent:
            return L("这是当前正在使用的账号，请登录其他账号。")
        }
    }
}

/// Compare the user and workspace together; the same email may have more than
/// one workspace. Do not replace a saved credential from an add operation.
func ensureNewChatGPTAccount(_ account: AuthorizedChatGPTAccount, profiles: [CodexProfile]) throws {
    let fingerprint = account.credentials.fingerprint
    if profiles.contains(where: { $0.kind == .chatgpt && $0.hasSecret && $0.accountID == fingerprint }) {
        throw NewChatGPTAccountError.alreadySaved
    }
    if account.previousChatGPTFingerprint == fingerprint {
        throw NewChatGPTAccountError.alreadyCurrent
    }
}

private func previousCredential(keys: CredentialStoring, id: UUID) throws -> String? {
    do { return try keys.load(id: id) }
    catch StoreError.missingSecret { return nil }
}

private func restoreCredential(keys: CredentialStoring, id: UUID, previous: String?) throws {
    do {
        if let previous { try keys.save(previous, id: id) }
        else { try keys.delete(id: id) }
    } catch { throw CodexError.credentialBackupUncertain }
}

/// Reauthentication must match the selected user AND workspace before it can
/// update either the saved credential or the live Codex login.
@discardableResult
func reauthorizeChatGPTAccount(service: CodexService, profileID: UUID, expectedPrevious: Data?,
                               profiles: inout [CodexProfile], keys: CredentialStoring, storage: ProfileStore,
                               cancellation: LoginCancellation, onAuthenticated: () -> Void = {},
                               onInstructions: (ChatGPTLoginInstructions) -> Bool,
                               willCommit: () throws -> Void = {}) throws -> AuthorizedChatGPTAccount {
    let account = try service.authorizeAdditionalChatGPT(method: .browser, cancellation: cancellation,
                                                          onAuthenticated: onAuthenticated, onInstructions: onInstructions)
    let credentials = account.credentials
    guard let index = profiles.firstIndex(where: { $0.id == profileID && $0.kind == .chatgpt }),
          credentials.kind == .chatgpt, account.current.accountType == "chatgpt",
          account.current.credentialFingerprint == credentials.fingerprint,
          let value = String(data: credentials.bytes, encoding: .utf8) else { throw CodexError.invalidCredentials }
    if let expectedIdentity = profiles[index].accountID, expectedIdentity != credentials.fingerprint {
        throw CodexError.differentAccount
    }
    guard !profiles.contains(where: { $0.id != profileID && $0.kind == .chatgpt && $0.accountID == credentials.fingerprint }) else {
        throw NewChatGPTAccountError.alreadySaved
    }
    guard !cancellation.isCancelled else { throw CodexError.loginCancelled }
    guard try service.fileCredentials().raw() == expectedPrevious else { throw CodexError.changedExternally }
    try willCommit()
    guard !cancellation.isCancelled else { throw CodexError.loginCancelled }

    let oldValue = try previousCredential(keys: keys, id: profileID)
    var next = profiles
    next[index].hasSecret = true
    next[index].accountID = credentials.fingerprint
    next[index].accountEmail = account.current.account ?? credentials.email ?? next[index].accountEmail
    next[index].accountDisplayName = matchingCredentialDisplayName(credentials, current: account.current) ?? next[index].accountDisplayName
    next[index].accountPlanType = ChatGPTPlan.knownValue(account.current.accountPlanType) ?? credentials.accountPlanType ?? next[index].accountPlanType
    if let quota = account.quota, next[index].lastQuota.map({ $0.updatedAt < quota.updatedAt }) ?? true {
        next[index].lastQuota = quota
    }
    try keys.save(value, id: profileID)
    do { try storage.save(next) }
    catch {
        try restoreCredential(keys: keys, id: profileID, previous: oldValue)
        throw error
    }
    // Retain the newly authorized credential even if applying it fails.
    profiles = next
    try service.activateSavedChatGPT(next[index], credential: value, expectedPrevious: expectedPrevious)
    return account
}

/// Save only a completed, isolated login. Duplicate detection uses the
/// account and workspace identity rather than email alone.
@discardableResult
func saveAuthorizedChatGPTAccount(_ account: AuthorizedChatGPTAccount, profiles: inout [CodexProfile],
                                  keys: CredentialStoring, storage: ProfileStore) throws -> Bool {
    let credentials = account.credentials
    guard credentials.kind == .chatgpt, account.current.accountType == "chatgpt",
          account.current.credentialFingerprint == credentials.fingerprint,
          let value = String(data: credentials.bytes, encoding: .utf8) else { throw CodexError.invalidCredentials }
    let index = profiles.firstIndex { $0.kind == .chatgpt && $0.accountID == credentials.fingerprint }
    let id = index.map { profiles[$0].id } ?? UUID()
    let previous = try index.flatMap { _ in try previousCredential(keys: keys, id: id) }
    var next = profiles
    let email = [account.current.account, credentials.email].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty && $0.count <= 320 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }
    let plan = ChatGPTPlan.knownValue(account.current.accountPlanType) ?? credentials.accountPlanType
    let displayName = matchingCredentialDisplayName(credentials, current: account.current)
    if let index {
        next[index].hasSecret = true
        next[index].accountEmail = email ?? next[index].accountEmail
        next[index].accountDisplayName = displayName ?? next[index].accountDisplayName
        next[index].accountPlanType = plan ?? next[index].accountPlanType
        if let quota = account.quota, next[index].lastQuota.map({ $0.updatedAt < quota.updatedAt }) ?? true {
            next[index].lastQuota = quota
        }
    } else {
        next.append(CodexProfile(id: id, name: displayName ?? email ?? "官方账号", kind: .chatgpt, model: nil, baseURL: nil,
                                 hasSecret: true, accountEmail: email, accountID: credentials.fingerprint,
                                 accountPlanType: plan, lastQuota: account.quota, accountDisplayName: displayName, hasCustomName: false))
    }
    try keys.save(value, id: id)
    do { try storage.save(next) }
    catch {
        try restoreCredential(keys: keys, id: id, previous: previous)
        throw error
    }
    profiles = next
    return index != nil
}

/// Preserve the live account before a switch, including one not yet added to
/// the app. Credentials are stored separately from profile metadata.
@discardableResult
func preserveCurrentAccount(service: CodexService, profiles: inout [CodexProfile], keys: CredentialStoring, storage: ProfileStore,
                            cachedQuotas: [String: AccountQuota] = [:]) throws -> Data? {
    let (current, snapshot) = try service.snapshotCurrent()
    guard let snapshot else { return nil }
    let index = profiles.firstIndex { profile in
        profile.kind == snapshot.kind && (snapshot.kind == .chatgpt ? profile.accountID : profile.secretFingerprint) == snapshot.fingerprint
    }
    let id = index.map { profiles[$0].id } ?? UUID()
    let previousValue = try index.flatMap { _ in try previousCredential(keys: keys, id: id) }
    let value: String
    if snapshot.kind == .chatgpt {
        guard let encoded = String(data: snapshot.bytes, encoding: .utf8) else { throw CodexError.invalidCredentials }
        value = encoded
    } else {
        guard let object = try? JSONSerialization.jsonObject(with: snapshot.bytes) as? [String: Any],
              let key = object["OPENAI_API_KEY"] as? String, !key.isEmpty else { throw CodexError.invalidCredentials }
        value = key
    }
    try keys.save(value, id: id)
    var next = profiles
    if let index {
        next[index].hasSecret = true
        if snapshot.kind == .chatgpt {
            next[index].accountEmail = current.account ?? snapshot.email ?? next[index].accountEmail
            next[index].accountDisplayName = matchingCredentialDisplayName(snapshot, current: current) ?? next[index].accountDisplayName
            next[index].accountPlanType = ChatGPTPlan.knownValue(current.accountPlanType) ?? snapshot.accountPlanType ?? next[index].accountPlanType
            if let quota = cachedQuotas[snapshot.fingerprint], next[index].lastQuota.map({ $0.updatedAt < quota.updatedAt }) ?? true {
                next[index].lastQuota = quota
            }
        }
    } else {
        let displayName = matchingCredentialDisplayName(snapshot, current: current)
        next.append(CodexProfile(id: id, name: snapshot.kind == .chatgpt ? (displayName ?? current.account ?? snapshot.email ?? "当前官方账号") : "当前 API Key",
                                 kind: snapshot.kind, model: nil, baseURL: nil, hasSecret: true,
                                 accountEmail: snapshot.kind == .chatgpt ? (current.account ?? snapshot.email) : nil,
                                 accountID: snapshot.kind == .chatgpt ? snapshot.fingerprint : nil,
                                 secretFingerprint: snapshot.kind == .openai ? snapshot.fingerprint : nil,
                                 accountPlanType: snapshot.kind == .chatgpt ? (ChatGPTPlan.knownValue(current.accountPlanType) ?? snapshot.accountPlanType) : nil,
                                 lastQuota: snapshot.kind == .chatgpt ? cachedQuotas[snapshot.fingerprint] : nil,
                                 accountDisplayName: displayName,
                                 hasCustomName: snapshot.kind == .chatgpt ? false : nil))
    }
    do { try storage.save(next) }
    catch {
        try restoreCredential(keys: keys, id: id, previous: previousValue)
        throw error
    }
    profiles = next
    return snapshot.bytes
}
