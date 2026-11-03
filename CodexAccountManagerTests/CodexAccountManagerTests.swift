import AppKit
import Combine
import Foundation
import XCTest
@testable import CodexAccountManager

private final class MemoryCredentials: CredentialStoring {
    var values: [UUID: String] = [:]
    var shouldFail = false
    func save(_ secret: String, id: UUID) throws {
        if shouldFail { throw StoreError.missingSecret }
        values[id] = secret
    }
    func load(id: UUID) throws -> String {
        guard let value = values[id] else { throw StoreError.missingSecret }
        return value
    }
    func delete(id: UUID) throws { values.removeValue(forKey: id) }
}

private final class EditShortcutProbe: NSObject {
    var received: [String] = []
    @objc func selectAll(_ sender: Any?) { received.append("selectAll") }
    @objc func copy(_ sender: Any?) { received.append("copy") }
    @objc func paste(_ sender: Any?) { received.append("paste") }
    @objc func cut(_ sender: Any?) { received.append("cut") }
}

private final class UpdateURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard request.url == GitHubUpdateChecker.apiURL,
              request.httpMethod == "GET",
              request.value(forHTTPHeaderField: "Authorization") == nil,
              request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json" else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(url: GitHubUpdateChecker.apiURL, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
        let body = Data(#"{"tag_name":"v99.0.0","draft":false,"prerelease":false}"#.utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class CodexAccountManagerTests: XCTestCase {
    func testLocalizationHandlesLanguagesAndInterpolatedValues() {
        XCTAssertEqual(AppLanguage.allCases.map(\.title), ["简体中文", "繁體中文", "English"])
        XCTAssertEqual(Localization.text("账号管理", language: .simplifiedChinese), "账号管理")
        XCTAssertEqual(Localization.text("账号管理", language: .traditionalChinese), "帳號管理")
        XCTAssertEqual(Localization.text("账号管理", language: .english), "Account management")
        XCTAssertEqual(Localization.text("剩余 {0}%", arguments: ["47"], language: .english), "47% remaining")
        XCTAssertEqual(Localization.text("删除 {0}", arguments: ["A {1}"], language: .english), "Delete A {1}")
        XCTAssertEqual(Localization.text("{0} 小时", arguments: ["1"], language: .english), "1 hour")
    }

    func testCreditDisplayUsesConsistentLabelsAndPreservesReportedPrecision() {
        let previous = Localization.language
        defer { Localization.select(previous) }
        Localization.select(.simplifiedChinese)
        XCTAssertEqual(localizedQuotaCredits("积分：0.0000"), "积分：0")
        XCTAssertEqual(localizedQuotaCredits("积分：502.9410890000"), "积分：502.941089")
        XCTAssertEqual(localizedQuotaCredits("积分：0.0005"), "积分：0.0005")
        XCTAssertEqual(localizedQuotaCredits("积分：不限"), "积分：不限")
        XCTAssertEqual(localizedQuotaCredits("积分可用"), "积分：可用")
        XCTAssertEqual(localizedQuotaCredits("无可用积分"), "积分：不可用")
        Localization.select(.english)
        XCTAssertEqual(localizedQuotaCredits("积分：0.0000"), "Credits: 0")
        XCTAssertEqual(localizedQuotaCredits("积分可用"), "Credits: available")
    }

    func testReleaseVersionsAndUpdateResponseHandling() throws {
        XCTAssertGreaterThan(try XCTUnwrap(ReleaseVersion("v1.10")), try XCTUnwrap(ReleaseVersion("1.9.9")))
        XCTAssertEqual(ReleaseVersion("1.0"), ReleaseVersion("1.0.0"))
        XCTAssertNil(ReleaseVersion("v1.0-beta"))
        XCTAssertNil(ReleaseVersion("1..0"))
        XCTAssertNil(ReleaseVersion("1.1234567890"))

        func response(_ status: Int, _ body: String = "") -> UpdateCheckStatus {
            let response = HTTPURLResponse(url: GitHubUpdateChecker.apiURL, statusCode: status,
                                           httpVersion: nil, headerFields: nil)!
            return GitHubUpdateChecker.result(currentVersion: "0.5.0", data: Data(body.utf8), response: response, error: nil)
        }
        let newer = #"{"tag_name":"v0.6.0","draft":false,"prerelease":false}"#
        let same = #"{"tag_name":"0.5.0","draft":false,"prerelease":false}"#
        let prerelease = #"{"tag_name":"v0.6.0","draft":false,"prerelease":true}"#
        XCTAssertEqual(response(200, newer), .available("0.6.0"))
        XCTAssertEqual(response(200, same), .upToDate)
        XCTAssertEqual(response(200, prerelease), .failed(.invalidResponse))
        XCTAssertEqual(response(200, "{}"), .failed(.invalidResponse))
        XCTAssertEqual(response(404), .noRelease)
        XCTAssertEqual(response(403), .failed(.rateLimited))
        XCTAssertEqual(response(429), .failed(.rateLimited))
        XCTAssertEqual(response(500), .failed(.network))
        XCTAssertEqual(GitHubUpdateChecker.result(currentVersion: "0.5.0", data: nil, response: nil,
                                                   error: URLError(.notConnectedToInternet)), .failed(.network))
    }

    @MainActor
    func testManualUpdateCheckRequestsGitHubAndPublishesResult() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let state = AppState(demo: true, updateChecker: GitHubUpdateChecker(session: session))
        let completed = expectation(description: "Update result is published")
        let subscription = state.$updateStatus.sink { status in
            if status == .available("99.0.0") { completed.fulfill() }
        }
        state.checkForUpdates()
        XCTAssertEqual(state.updateStatus, .checking)
        await fulfillment(of: [completed], timeout: 3)
        XCTAssertEqual(state.updateStatus, .available("99.0.0"))
        subscription.cancel()
    }

    @MainActor
    func testLanguageSelectionPersistsAndLocalizesCachedQuota() throws {
        let previous = Localization.language
        defer { Localization.select(previous) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cam-language-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "local.cam.language-test." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(root.path, forKey: "codexHome")
        preferences.set(try fixture("mock_codex").path, forKey: "codexPath")
        preferences.set(false, forKey: "diagnosticEnabled")
        let store = ProfileStore(directory: root.appendingPathComponent("metadata"))
        let state = AppState(demo: false, storage: store, preferences: preferences)
        var observed: AppLanguage?
        state.onLanguageChanged = { observed = $0 }
        state.setLanguage(.english)
        XCTAssertEqual(observed, .english)
        XCTAssertEqual(preferences.string(forKey: "language"), AppLanguage.english.rawValue)
        XCTAssertEqual(localizedQuotaCredits("积分：502.9"), "Credits: 502.9")
        XCTAssertEqual(Localization.text("工作区积分不足"), "Workspace credits depleted")
        XCTAssertEqual(QuotaWindow(id: "primary", usedPercent: 0, durationMinutes: 60, resetsAt: nil).title, "1 hour")

        let restored = AppState(demo: false, storage: store, preferences: preferences)
        XCTAssertEqual(restored.language, .english)
        restored.setLanguage(.traditionalChinese)
        XCTAssertEqual(Localization.text("界面语言"), "介面語言")
        XCTAssertEqual(localizedQuotaCredits("积分：502.9"), "積分：502.9")
    }

    func testPanelMenusStayInsideWindowAtEdges() {
        let container = CGSize(width: 512, height: 480)
        let menus = [CGSize(width: 190, height: 82), CGSize(width: 180, height: 118)]
        let anchors = [
            CGRect(x: 472, y: 10, width: 32, height: 32),
            CGRect(x: 472, y: 430, width: 32, height: 32),
            CGRect(x: 0, y: 0, width: 24, height: 24),
        ]
        for menu in menus {
            for anchor in anchors {
                let frame = CGRect(origin: PanelMenuPlacement.origin(anchor: anchor, container: container, menu: menu), size: menu)
                XCTAssertGreaterThanOrEqual(frame.minX, 8)
                XCTAssertGreaterThanOrEqual(frame.minY, 8)
                XCTAssertLessThanOrEqual(frame.maxX, container.width - 8)
                XCTAssertLessThanOrEqual(frame.maxY, container.height - 8)
            }
            let bottom = PanelMenuPlacement.origin(anchor: anchors[1], container: container, menu: menu)
            XCTAssertLessThan(bottom.y + menu.height, anchors[1].minY)
        }
    }

    func testActionIconsLoadFromAppBundleAsTemplates() {
        XCTAssertTrue(Branding.editIcon?.isTemplate == true)
        XCTAssertTrue(Branding.switchAccountIcon?.isTemplate == true)
    }

    @MainActor
    func testStandardEditShortcutsReachTheResponder() throws {
        let menu = makeStandardEditMenu()
        let target = EditShortcutProbe()
        let panel = PanelSplitViewController(state: AppState(demo: true))
        for (key, expected) in [("a", "selectAll"), ("c", "copy"), ("v", "paste"), ("x", "cut")] {
            let item = try XCTUnwrap(menu.items.first { $0.keyEquivalent == key })
            XCTAssertNil(item.target, "The focused editor must receive the action")
            item.target = target
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                                                       timestamp: 0, windowNumber: 0, context: nil,
                                                       characters: key, charactersIgnoringModifiers: key,
                                                       isARepeat: false, keyCode: 0))
            XCTAssertFalse(panel.handleShortcut(key))
            XCTAssertTrue(menu.performKeyEquivalent(with: event))
            XCTAssertEqual(target.received.last, expected)
        }
    }

    @MainActor
    func testCurrentLoginAppearsInItsGroupWithoutDuplicatingSavedProfile() throws {
        let state = AppState(demo: true)
        let saved = try XCTUnwrap(state.profiles.first)
        XCTAssertTrue(state.isCurrent(saved))
        XCTAssertTrue(state.currentHasProfile)
        XCTAssertNil(state.currentLoginWithoutProfile(for: .chatgpt))

        state.current.account = "new@example.invalid"
        state.current.credentialFingerprint = "new-account"
        let current = try XCTUnwrap(state.currentLoginWithoutProfile(for: .chatgpt))
        XCTAssertEqual(current.name, "new@example.invalid")
        XCTAssertNil(state.currentLoginWithoutProfile(for: .openai))
        XCTAssertFalse(state.isCurrent(saved))

        // An email alone is not enough to identify a saved workspace.
        state.current.account = saved.accountEmail
        state.current.credentialFingerprint = nil
        XCTAssertFalse(state.currentHasProfile)
        XCTAssertNotNil(state.currentLoginWithoutProfile(for: .chatgpt))
        XCTAssertFalse(state.isCurrent(saved))

        state.current.accountType = "apiKey"
        state.current.credentialFingerprint = "new-key"
        XCTAssertNil(state.currentLoginWithoutProfile(for: .chatgpt))
        XCTAssertEqual(state.currentLoginWithoutProfile(for: .openai)?.name, "当前 API Key")
        state.current.accountAvailable = false
        XCTAssertNil(state.currentLoginWithoutProfile(for: .openai))
    }

    @MainActor
    func testCurrentLoginDisplayMatchesOnlyTheActiveCredential() throws {
        let state = AppState(demo: true)
        let chat = try XCTUnwrap(state.profiles.first { $0.kind == .chatgpt })
        var display = try XCTUnwrap(state.currentLoginDisplayItem)
        XCTAssertEqual(display.kind, .chatgpt)
        XCTAssertEqual(display.name, "个人账号")
        XCTAssertEqual(display.accountEmail, "demo@example.invalid")
        XCTAssertEqual(display.accountPlanType, "plus")

        state.current.credentialFingerprint = "different-account"
        state.current.account = "other@example.invalid"
        state.current.accountDisplayName = "官方名称"
        display = try XCTUnwrap(state.currentLoginDisplayItem)
        XCTAssertEqual(display.name, "官方名称")
        XCTAssertEqual(display.accountEmail, "other@example.invalid")
        XCTAssertNotEqual(display.name, chat.name)

        let keyIndex = try XCTUnwrap(state.profiles.firstIndex { $0.kind == .openai })
        state.profiles[keyIndex].secretFingerprint = "active-key"
        state.current.accountType = "apiKey"
        state.current.credentialFingerprint = "active-key"
        display = try XCTUnwrap(state.currentLoginDisplayItem)
        XCTAssertEqual(display.kind, .openai)
        XCTAssertEqual(display.name, "工作 API Key")
        XCTAssertNil(display.accountEmail)
        XCTAssertNil(display.accountPlanType)

        state.current.credentialFingerprint = "unsaved-key"
        XCTAssertEqual(state.currentLoginDisplayItem?.name, "当前 API Key")
        state.current.accountAvailable = false
        XCTAssertNil(state.currentLoginDisplayItem)
    }

    @MainActor
    func testCurrentProfileCannotBeSwitchedOrDeletedButCanBeReauthenticated() throws {
        let state = AppState(demo: true)
        let saved = try XCTUnwrap(state.profiles.first)
        var requests: [Bool] = []
        state.onRequestActivation = { _, reauthenticate in requests.append(reauthenticate) }
        state.requestActivation(saved)
        XCTAssertTrue(requests.isEmpty)
        state.requestActivation(saved, reauthenticate: true)
        XCTAssertEqual(requests, [true])
        state.remove(saved)
        XCTAssertTrue(state.profiles.contains { $0.id == saved.id })
        XCTAssertTrue(state.isError)

        // A matching login under a non-official configuration is not an
        // active official profile, but must not produce a duplicate row.
        state.current.provider = "custom"
        XCTAssertTrue(state.matchesCurrentLogin(saved))
        XCTAssertTrue(state.currentHasProfile)
        XCTAssertFalse(state.isCurrent(saved))
        XCTAssertNil(state.currentLoginWithoutProfile(for: .chatgpt))
        state.requestActivation(saved)
        XCTAssertEqual(requests, [true, false])
    }

    @MainActor
    func testCurrentAliasDoesNotRequireSavingCredential() throws {
        let state = AppState(demo: true)
        state.current.account = "current@example.invalid"
        state.current.credentialFingerprint = "current-identity"
        state.current.accountDisplayName = "官方名称"
        state.beginEditingCurrentAlias()
        XCTAssertNotNil(state.editingCurrent)
        state.saveCurrentAlias("我的别名")
        let profile = try XCTUnwrap(state.profiles.first { $0.accountID == "current-identity" })
        XCTAssertFalse(profile.hasSecret)
        XCTAssertTrue(state.currentHasProfile)
        XCTAssertTrue(state.isCurrent(profile))
        XCTAssertEqual(state.profileDisplayName(profile), "我的别名")
        XCTAssertNil(state.currentLoginWithoutProfile(for: .chatgpt))
        state.current.credentialFingerprint = "another-identity"
        XCTAssertFalse(state.shouldDisplayProfile(profile))
        state.current.credentialFingerprint = "current-identity"
        XCTAssertTrue(state.shouldDisplayProfile(profile))

        state.current.accountType = "apiKey"
        state.current.credentialFingerprint = "current-key"
        state.beginEditingCurrentAlias()
        state.saveCurrentAlias("我的密钥")
        let keyProfile = try XCTUnwrap(state.profiles.first { $0.secretFingerprint == "current-key" })
        XCTAssertFalse(keyProfile.hasSecret)
        XCTAssertTrue(state.isCurrent(keyProfile))
        XCTAssertTrue(state.update(keyProfile, name: "密钥别名", model: "", baseURL: "", secret: ""))
        XCTAssertEqual(state.profiles.first { $0.id == keyProfile.id }?.name, "密钥别名")
        XCTAssertFalse(try XCTUnwrap(state.profiles.first { $0.id == keyProfile.id }).hasSecret)
    }

    @MainActor
    func testNamesRejectDuplicatesWhenAddingOrEditing() throws {
        let state = AppState(demo: true)
        var first = try XCTUnwrap(state.profiles.first)
        first.name = "Team"
        first.hasCustomName = true
        state.profiles[0] = first
        let second = state.profiles[1]
        let original = state.profiles

        XCTAssertFalse(state.add(name: " ＴＥＡＭ ", kind: .openai, model: "", baseURL: "", secret: "sk-test"))
        XCTAssertTrue(state.isError)
        XCTAssertEqual(state.message, ProfileValidationError.duplicateName.localizedDescription)
        XCTAssertEqual(state.profiles, original)
        XCTAssertFalse(state.update(second, name: " team ", model: "", baseURL: "", secret: ""))
        XCTAssertEqual(state.profiles, original)

        // Editing the same profile without changing its name remains valid.
        XCTAssertTrue(state.update(first, name: " Team ", model: "", baseURL: "", secret: ""))
        XCTAssertEqual(state.profiles[0].name, "Team")

        var official = state.profiles[1]
        official.name = "work@example.invalid"
        official.accountDisplayName = "官方名称"
        official.hasCustomName = false
        state.profiles[1] = official
        XCTAssertFalse(state.update(state.profiles[0], name: "官方名称", model: "", baseURL: "", secret: ""))
        XCTAssertEqual(state.message, ProfileValidationError.duplicateName.localizedDescription)
    }

    @MainActor
    func testNamesIncludeCurrentUnsavedLoginAndAllowItsOwnName() throws {
        let state = AppState(demo: true)
        state.current.account = "current@example.invalid"
        state.current.credentialFingerprint = "current-identity"
        state.current.accountDisplayName = "当前官方名称"
        let existing = state.profiles[1]
        XCTAssertFalse(state.update(existing, name: "当前官方名称", model: "", baseURL: "", secret: ""))
        XCTAssertFalse(state.add(name: "当前官方名称", kind: .openai, model: "", baseURL: "", secret: "sk-test"))

        state.beginEditingCurrentAlias()
        state.saveCurrentAlias("工作账号")
        XCTAssertTrue(state.isError)
        XCTAssertEqual(state.message, ProfileValidationError.duplicateName.localizedDescription)
        XCTAssertNotNil(state.editingCurrent)
        XCTAssertFalse(state.profiles.contains { $0.accountID == "current-identity" })

        state.saveCurrentAlias("当前官方名称")
        let profile = try XCTUnwrap(state.profiles.first { $0.accountID == "current-identity" })
        XCTAssertEqual(profile.name, "当前官方名称")
        XCTAssertFalse(state.isError)
    }

    @MainActor
    func testPanelShortcutsRespectCurrentPageAndBusyState() {
        let state = AppState(demo: true)
        let panel = PanelSplitViewController(state: state)

        XCTAssertTrue(panel.handleShortcut("3"))
        XCTAssertTrue(panel.handleShortcut("n"))
        XCTAssertTrue(state.page == .add)
        XCTAssertFalse(panel.handleShortcut("n"))

        state.page = .manage
        XCTAssertTrue(panel.handleShortcut(","))
        XCTAssertFalse(panel.handleShortcut("n"))
        XCTAssertFalse(panel.handleShortcut("f"))
        XCTAssertTrue(panel.handleShortcut("["))
        XCTAssertTrue(panel.handleShortcut("f"))

        state.busy = true
        XCTAssertFalse(panel.handleShortcut("n"))
        XCTAssertFalse(panel.handleShortcut("x"))
    }

    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "py"))
    }

    private func prepareCodexPath(_ environment: inout [String: String], executable: URL) {
        let additions = [executable.deletingLastPathComponent().path,
                         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
                         "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let inherited = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        environment["PATH"] = (inherited + additions).joined(separator: ":")
    }

    func testValidationRejectsUnsafeProviderAddressAndMissingKey() throws {
        XCTAssertThrowsError(try ProfileValidator.validated(name: "x", kind: .provider, model: "m", baseURL: "http://remote.example/v1", secret: ""))
        XCTAssertThrowsError(try ProfileValidator.validated(name: "x", kind: .provider, model: "m", baseURL: "https://user:secret@example.com/v1", secret: ""))
        XCTAssertThrowsError(try ProfileValidator.validated(name: "x", kind: .provider, model: "m", baseURL: "https://example.com/v1?key=secret", secret: ""))
        XCTAssertThrowsError(try ProfileValidator.validated(name: "x", kind: .openai, model: "", baseURL: "", secret: ""))
        XCTAssertThrowsError(try ProfileValidator.validated(name: "x", kind: .openai, model: "", baseURL: "", secret: " \n "))
        XCTAssertThrowsError(try ProfileValidator.validated(name: "x", kind: .openai, model: "", baseURL: "", secret: "sk-test\nextra"))
        XCTAssertEqual(try ProfileValidator.validated(name: "x", kind: .openai, model: "", baseURL: "", secret: " \n sk-test \n ").3, "sk-test")
        let result = try ProfileValidator.validated(name: " local ", kind: .provider, model: "local/model", baseURL: "http://127.0.0.1:1234/v1/", secret: "")
        XCTAssertEqual(result.0, "local"); XCTAssertEqual(result.2, "http://127.0.0.1:1234/v1")
    }

    func testProfileMetadataContainsNoCredential() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(directory: directory)
        let profile = CodexProfile(id: UUID(), name: "sample", kind: .openai, model: nil, baseURL: nil, hasSecret: true)
        try store.save([profile])
        XCTAssertEqual(try store.load(), [profile])
        let bytes = try String(contentsOf: store.file, encoding: .utf8)
        XCTAssertFalse(bytes.contains("sk-test"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testSavedCredentialsUsePrivateCodexFormatFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cam-file-store-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SavedCredentialFiles(root: root)
        let accountID = UUID(), apiID = UUID()
        let auth = try chatGPTAuth(email: "person@example.invalid", subject: "person", workspace: "personal", refresh: "fake-refresh")
        let apiKey = "sk-fake-local-key"
        try store.save(String(decoding: auth, as: UTF8.self), id: accountID)
        try store.save(apiKey, id: apiID)

        let accountFile = store.directory.appendingPathComponent(accountID.uuidString.lowercased() + ".json")
        let apiFile = store.directory.appendingPathComponent(apiID.uuidString.lowercased() + ".json")
        XCTAssertEqual(try Data(contentsOf: accountFile), auth)
        let apiData = try Data(contentsOf: apiFile)
        let apiObject = try XCTUnwrap(JSONSerialization.jsonObject(with: apiData) as? [String: String])
        XCTAssertEqual(apiObject, ["OPENAI_API_KEY": apiKey])
        XCTAssertEqual(try store.load(id: accountID), String(decoding: auth, as: UTF8.self))
        XCTAssertEqual(try store.load(id: apiID), apiKey)
        XCTAssertEqual(try store.loadAPIKey(id: apiID), apiKey)
        XCTAssertThrowsError(try store.loadAPIKey(id: accountID)) {
            guard case StoreError.invalidSecret = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: store.directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        for file in [accountFile, apiFile] {
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
        try store.save("sk-fake-replacement", id: apiID)
        XCTAssertEqual(try store.load(id: apiID), "sk-fake-replacement")
        try store.delete(id: accountID)
        XCTAssertThrowsError(try store.load(id: accountID)) { guard case StoreError.missingSecret = $0 else { return XCTFail("Unexpected error: \($0)") } }
        XCTAssertEqual(try store.load(id: apiID), "sk-fake-replacement")
    }

    @MainActor
    func testSavedAPIKeyCanBeViewedAndChangedInDemoWithoutReadingRealCredentials() throws {
        let state = AppState(demo: true)
        let original = try XCTUnwrap(state.profiles.first { $0.kind == .openai })
        XCTAssertEqual(try state.savedAPIKey(for: original.id), "sk-demo-only-not-real")
        XCTAssertThrowsError(try state.savedAPIKey(for: state.profiles[0].id))

        XCTAssertTrue(state.update(original, name: "新的密钥名称", model: "", baseURL: "", secret: ""))
        let renamed = try XCTUnwrap(state.profiles.first { $0.id == original.id })
        XCTAssertEqual(try state.savedAPIKey(for: renamed.id), "sk-demo-only-not-real")
        XCTAssertTrue(state.update(renamed, name: renamed.name, model: "", baseURL: "", secret: "sk-demo-replacement"))
        let updated = try XCTUnwrap(state.profiles.first { $0.id == original.id })
        XCTAssertEqual(try state.savedAPIKey(for: updated.id), "sk-demo-replacement")

        state.current.accountType = "apiKey"
        state.current.credentialFingerprint = updated.secretFingerprint
        XCTAssertEqual(try state.currentAPIKey(for: state.current), "sk-demo-replacement")
        state.current.credentialFingerprint = "different-key"
        XCTAssertThrowsError(try state.currentAPIKey(for: state.current))
        state.remove(updated)
        XCTAssertThrowsError(try state.savedAPIKey(for: updated.id))
    }

    @MainActor
    func testSavedAPIKeyReadUsesTheMatchingCredentialFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cam-saved-key-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "local.cam.saved-key-test." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(root.path, forKey: "codexHome")
        preferences.set(try fixture("mock_codex").path, forKey: "codexPath")
        preferences.set(false, forKey: "diagnosticEnabled")
        let store = ProfileStore(directory: root.appendingPathComponent("metadata"))
        let key = "sk-fake-saved-only"
        let profile = CodexProfile(id: UUID(), name: "saved", kind: .openai, model: nil, baseURL: nil, hasSecret: true,
                                   secretFingerprint: CredentialSnapshot.fingerprint("api\0" + key))
        try store.save([profile])
        let files = SavedCredentialFiles(root: store.directory)
        try files.save(key, id: profile.id)
        let state = AppState(demo: false, storage: store, preferences: preferences, environment: ["CODEX_HOME": root.path])
        XCTAssertEqual(try state.savedAPIKey(for: profile.id), key)
        XCTAssertTrue(state.update(profile, name: "renamed", model: "", baseURL: "", secret: ""))
        XCTAssertEqual(try files.loadAPIKey(id: profile.id), key)
        try files.save("sk-fake-other", id: profile.id)
        XCTAssertThrowsError(try state.savedAPIKey(for: profile.id)) {
            guard case StoreError.invalidSecret = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
    }

    func testCurrentAPIKeyReadChecksIdentityAndEnvironment() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cam-current-key-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let key = "sk-fake-current-only"
        let data = try JSONSerialization.data(withJSONObject: ["OPENAI_API_KEY": key])
        try data.write(to: home.appendingPathComponent("auth.json"))
        let fingerprint = CredentialSnapshot.fingerprint("api\0" + key)
        let service = CodexService(environment: ["CODEX_HOME": home.path])
        XCTAssertEqual(try service.currentFileAPIKey(matching: fingerprint), key)
        XCTAssertThrowsError(try service.currentFileAPIKey(matching: "wrong")) {
            guard case CodexError.changedExternally = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        let managed = CodexService(environment: ["CODEX_HOME": home.path, "OPENAI_API_KEY": "managed"])
        XCTAssertThrowsError(try managed.currentFileAPIKey(matching: fingerprint)) {
            guard case CodexError.environmentOverride = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
    }

    func testCredentialFilesRejectSymlinksWithoutTouchingTheirTargets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cam-file-links-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let victim = root.appendingPathComponent("victim.json")
        let original = Data("do not change".utf8)
        try original.write(to: victim)
        let store = SavedCredentialFiles(root: root.appendingPathComponent("app")), id = UUID()
        try store.save("sk-fake", id: id)
        let file = store.directory.appendingPathComponent(id.uuidString.lowercased() + ".json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: victim)
        XCTAssertThrowsError(try store.load(id: id))
        XCTAssertThrowsError(try store.save("sk-fake-new", id: id))
        XCTAssertThrowsError(try store.delete(id: id))
        XCTAssertEqual(try Data(contentsOf: victim), original)

        let otherRoot = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: otherRoot.appendingPathComponent("credentials"), withDestinationURL: store.directory)
        XCTAssertThrowsError(try SavedCredentialFiles(root: otherRoot).save("sk-fake-new", id: UUID()))
        XCTAssertEqual(try Data(contentsOf: victim), original)
    }

    func testManagedIdentityStopsSwitchBeforeWriting() {
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_ACCESS_TOKEN"] = "fake-managed-token"
        let service = CodexService(environment: environment)
        let profile = CodexProfile(id: UUID(), name: "sample", kind: .openai, model: nil, baseURL: nil, hasSecret: true)
        XCTAssertThrowsError(try service.activate(profile, secret: "fake-key") { _ in true }) { error in
            guard case CodexError.environmentOverride = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testCodexReadsAndSwitchesTheSharedDefaultHome() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cam-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config.toml")
        try "cli_auth_credentials_store = \"file\"\nmodel = \"original-model\"\n".write(to: config, atomically: true, encoding: .utf8)
        var env = ProcessInfo.processInfo.environment
        for key in ["CODEX_SQLITE_HOME", "CODEX_API_KEY", "OPENAI_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_FEDERATION_RULE_ID", "OPENAI_IDENTITY_TOKEN_FILE"] { env.removeValue(forKey: key) }
        env["CODEX_HOME"] = root.path
        guard (try? CodexExecutable.find(environment: env)) != nil else { throw XCTSkip("Codex CLI unavailable") }
        // Finder-launched apps often have a minimal PATH; the Node-based Codex
        // launcher still needs to find its runtime in a standard install path.
        env["PATH"] = "/usr/bin:/bin"
        var service = CodexService(environment: env)
        service.helperPath = "/private/tmp/cam-fake-helper"
        XCTAssertEqual(try service.readCurrent().model, "original-model")
        let provider = CodexProfile(id: UUID(), name: "sample", kind: .provider, model: "test-model", baseURL: "https://api.example.invalid/v1", hasSecret: true)
        try service.removeProvider(provider) // A new profile may never have been activated.
        try service.activate(provider, secret: nil) { _ in XCTFail("Provider should not open login"); return false }
        let switched = try service.readCurrent()
        XCTAssertEqual(switched.provider, provider.providerID)
        XCTAssertEqual(switched.model, "test-model")
        XCTAssertEqual(switched.providerHost, "api.example.invalid")
        XCTAssertThrowsError(try service.removeProvider(provider))
        let text = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(text.contains("cli_auth_credentials_store"))
        XCTAssertFalse(text.contains("sk-test-local-only"))
        let api = CodexProfile(id: UUID(), name: "api", kind: .openai, model: nil, baseURL: nil, hasSecret: true)
        try service.activate(api, secret: "sk-test-local-only") { _ in XCTFail("API key should not open login"); return false }
        let restored = try service.readCurrent()
        XCTAssertEqual(restored.provider, "openai")
        XCTAssertEqual(restored.model, "test-model") // Account switches preserve the user's chosen model.
        XCTAssertEqual(restored.accountType, "apiKey")
        try service.removeProvider(provider)
        XCTAssertFalse((try String(contentsOf: config, encoding: .utf8)).contains(provider.providerID))
        XCTAssertFalse((try String(contentsOf: config, encoding: .utf8)).contains("sk-test-local-only"))
    }

    func testProviderCredentialHelperReachesCodexRequests() throws {
        let python = "/usr/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: python) else { throw XCTSkip("Python is needed only for the loopback test fixture") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cam-http-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let portFile = root.appendingPathComponent("port")
        let marker = root.appendingPathComponent("received")
        let fixture = try fixture("mock_responses")
        let mock = Process(); mock.executableURL = URL(fileURLWithPath: python)
        mock.arguments = [fixture.path, portFile.path, marker.path]
        mock.standardOutput = FileHandle.nullDevice; mock.standardError = FileHandle.nullDevice
        try mock.run()
        defer { if mock.isRunning { mock.terminate(); mock.waitUntilExit() } }
        let deadline = Date().addingTimeInterval(8)
        while !FileManager.default.fileExists(atPath: portFile.path), mock.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        guard let port = try? String(contentsOf: portFile, encoding: .utf8), mock.isRunning else { throw XCTSkip("Loopback server unavailable in this environment") }
        let helper = root.appendingPathComponent("fake-helper")
        try "#!/bin/sh\nprintf '%s\\n' 'fake-cam-test-key'\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        try "cli_auth_credentials_store = \"file\"\n".write(to: root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        var env = ProcessInfo.processInfo.environment
        for key in ["CODEX_SQLITE_HOME", "CODEX_API_KEY", "OPENAI_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_FEDERATION_RULE_ID", "OPENAI_IDENTITY_TOKEN_FILE"] { env.removeValue(forKey: key) }
        env["CODEX_HOME"] = root.path; env["NO_PROXY"] = "127.0.0.1,localhost"
        guard let executable = try? CodexExecutable.find(environment: env) else { throw XCTSkip("Codex CLI unavailable") }
        prepareCodexPath(&env, executable: executable)
        var service = CodexService(environment: env); service.helperPath = helper.path
        let profile = CodexProfile(id: UUID(), name: "local", kind: .provider, model: "test-model", baseURL: "http://127.0.0.1:\(port)/v1", hasSecret: true)
        try service.activate(profile, secret: nil) { _ in XCTFail("Unexpected browser login"); return false }
        let codex = Process(); codex.executableURL = executable
        codex.arguments = ["exec", "--skip-git-repo-check", "--color", "never", "Say hello"]
        codex.environment = env; codex.currentDirectoryURL = root
        codex.standardOutput = FileHandle.nullDevice; codex.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0); codex.terminationHandler = { _ in finished.signal() }
        try codex.run()
        guard finished.wait(timeout: .now() + 35) == .success else { codex.terminate(); codex.waitUntilExit(); XCTFail("Codex request timed out"); return }
        XCTAssertEqual(codex.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "matched")
        XCTAssertFalse((try String(contentsOf: root.appendingPathComponent("config.toml"), encoding: .utf8)).contains("fake-cam-test-key"))
    }

    private func chatGPTAuth(email: String, subject: String, workspace: String, refresh: String,
                             plan: String? = nil, tokenWorkspace: String? = nil, displayName: String? = nil) throws -> Data {
        var claims: [String: Any] = ["email": email, "sub": subject]
        if let displayName { claims["name"] = displayName }
        if let plan {
            claims["https://api.openai.com/auth"] = ["chatgpt_account_id": tokenWorkspace ?? workspace, "chatgpt_plan_type": plan]
        }
        let bytes = try JSONSerialization.data(withJSONObject: claims)
        let part = bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return try JSONSerialization.data(withJSONObject: ["OPENAI_API_KEY": NSNull(), "tokens": [
            "id_token": "header.\(part).signature", "access_token": "fake-access", "refresh_token": refresh, "account_id": workspace
        ]])
    }

    private func realisticFakeChatGPTAuth(email: String, subject: String, workspace: String) throws -> Data {
        func part(_ value: [String: Any]) throws -> String {
            try JSONSerialization.data(withJSONObject: value).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let header = try part(["alg": "none", "typ": "JWT"])
        let claims = try part(["sub": subject, "email": email, "exp": Int(Date().timeIntervalSince1970) + 3600,
                               "https://api.openai.com/auth": ["chatgpt_user_id": subject, "chatgpt_account_id": workspace, "chatgpt_plan_type": "plus"]])
        let token = header + "." + claims + ".fake"
        return try JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt", "OPENAI_API_KEY": NSNull(),
            "last_refresh": ISO8601DateFormatter().string(from: Date()), "tokens": [
                "id_token": token, "access_token": token, "refresh_token": "fake-refresh", "account_id": workspace
            ]])
    }

    @MainActor
    func testAddingOfficialAccountRequiresAuthorization() {
        let state = AppState(demo: true)
        let original = state.profiles
        XCTAssertFalse(state.add(name: "placeholder", kind: .chatgpt, model: "", baseURL: "", secret: ""))
        XCTAssertEqual(state.profiles, original)
        XCTAssertTrue(state.isError)
    }

    func testAdditionalAccountLoginUsesIsolatedCodexHomeForBothMethods() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cam-add-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let live = root.appendingPathComponent("live")
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        let oldAuth = try chatGPTAuth(email: "current@example.invalid", subject: "current", workspace: "current-workspace", refresh: "fake-current", plan: "plus")
        try oldAuth.write(to: live.appendingPathComponent("auth.json"))
        let newAuth = try chatGPTAuth(email: "new@example.invalid", subject: "new", workspace: "new-workspace", refresh: "fake-new", plan: "pro")
        let source = root.appendingPathComponent("new-auth.json")
        try newAuth.write(to: source)
        let marker = root.appendingPathComponent("login-home.json")
        var env = ProcessInfo.processInfo.environment
        for key in ["CODEX_API_KEY", "OPENAI_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_FEDERATION_RULE_ID", "OPENAI_IDENTITY_TOKEN_FILE", "OPENAI_WORKLOAD_IDENTITY_CONTEXT", "CHATGPT_BASE_URL", "CODEX_CHATGPT_BASE_URL"] { env.removeValue(forKey: key) }
        env["CODEX_HOME"] = live.path
        env["MOCK_LOGIN_AUTH_PATH"] = source.path
        env["MOCK_LOGIN_HOME_MARKER"] = marker.path
        env["MOCK_QUOTA"] = #"{"accountId":"new-workspace","rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300}}}"#
        let service = CodexService(environment: env, executableOverride: try fixture("mock_codex"))

        for method in ChatGPTLoginMethod.allCases {
            var shown: ChatGPTLoginInstructions?
            let result = try service.authorizeAdditionalChatGPT(method: method, cancellation: LoginCancellation()) { instructions in
                shown = instructions
                return true
            }
            XCTAssertEqual(shown?.method, method)
            XCTAssertEqual(shown?.url.host, "auth.openai.com")
            XCTAssertEqual(shown?.userCode, method == .deviceCode ? "ABCD-1234" : nil)
            XCTAssertEqual(result.current.account, "new@example.invalid")
            XCTAssertEqual(result.credentials.bytes, newAuth)
            XCTAssertEqual(result.quota?.buckets.first?.windows.first?.remainingPercent, 75)
            XCTAssertEqual(result.previousChatGPTFingerprint, try CredentialSnapshot(bytes: oldAuth).fingerprint)
            XCTAssertEqual(try Data(contentsOf: live.appendingPathComponent("auth.json")), oldAuth)
            let details = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any])
            let temporary = try XCTUnwrap(details["home"] as? String)
            XCTAssertNotEqual(temporary, live.path)
            XCTAssertEqual(details["mode"] as? Int, 0o700)
            XCTAssertEqual(details["config"] as? String, "cli_auth_credentials_store = \"file\"\n")
            XCTAssertFalse(FileManager.default.fileExists(atPath: temporary))
        }
    }

    func testAddingAccountRejectsCurrentAndSavedIdentityButAllowsDifferentWorkspace() throws {
        let savedAuth = try chatGPTAuth(email: "person@example.invalid", subject: "person", workspace: "one", refresh: "fake")
        let savedCredentials = try CredentialSnapshot(bytes: savedAuth)
        let current = CurrentCodex(account: "person@example.invalid", accountType: "chatgpt", provider: "openai", model: nil,
                                   configVersion: nil, configAvailable: true, accountAvailable: true, credentialStore: "file",
                                   credentialFingerprint: savedCredentials.fingerprint)
        var login = AuthorizedChatGPTAccount(current: current, credentials: savedCredentials, quota: nil,
                                             previousChatGPTFingerprint: savedCredentials.fingerprint)
        let profile = CodexProfile(id: UUID(), name: "已有账号", kind: .chatgpt, model: nil, baseURL: nil, hasSecret: true,
                                   accountEmail: "person@example.invalid", accountID: savedCredentials.fingerprint)
        XCTAssertThrowsError(try ensureNewChatGPTAccount(login, profiles: [profile])) { error in
            guard case NewChatGPTAccountError.alreadySaved = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertThrowsError(try ensureNewChatGPTAccount(login, profiles: [])) { error in
            guard case NewChatGPTAccountError.alreadyCurrent = error else { return XCTFail("Unexpected error: \(error)") }
        }

        let otherAuth = try chatGPTAuth(email: "person@example.invalid", subject: "person", workspace: "two", refresh: "fake-other")
        let otherCredentials = try CredentialSnapshot(bytes: otherAuth)
        var otherCurrent = current
        otherCurrent.credentialFingerprint = otherCredentials.fingerprint
        login = AuthorizedChatGPTAccount(current: otherCurrent, credentials: otherCredentials, quota: nil,
                                         previousChatGPTFingerprint: savedCredentials.fingerprint)
        XCTAssertNoThrow(try ensureNewChatGPTAccount(login, profiles: [profile]))
    }

    func testAdditionalAccountCancellationAndUnsafeURLKeepCurrentLogin() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cam-cancel-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let live = root.appendingPathComponent("live")
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        let oldAuth = try chatGPTAuth(email: "current@example.invalid", subject: "current", workspace: "current-workspace", refresh: "fake-current")
        try oldAuth.write(to: live.appendingPathComponent("auth.json"))
        let marker = root.appendingPathComponent("home.json"), cancelled = root.appendingPathComponent("cancelled")
        var env = ProcessInfo.processInfo.environment
        for key in ["CODEX_API_KEY", "OPENAI_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_FEDERATION_RULE_ID", "OPENAI_IDENTITY_TOKEN_FILE", "OPENAI_WORKLOAD_IDENTITY_CONTEXT", "CHATGPT_BASE_URL", "CODEX_CHATGPT_BASE_URL"] { env.removeValue(forKey: key) }
        env["CODEX_HOME"] = live.path
        env["MOCK_LOGIN_HOME_MARKER"] = marker.path
        env["MOCK_LOGIN_CANCEL_MARKER"] = cancelled.path
        env["MOCK_LOGIN_PENDING"] = "1"
        var service = CodexService(environment: env, executableOverride: try fixture("mock_codex"))
        let cancellation = LoginCancellation()
        XCTAssertThrowsError(try service.authorizeAdditionalChatGPT(method: .deviceCode, cancellation: cancellation) { _ in
            cancellation.cancel()
            return true
        }) { error in guard case CodexError.loginCancelled = error else { return XCTFail("Unexpected error: \(error)") } }
        XCTAssertTrue(FileManager.default.fileExists(atPath: cancelled.path))
        var details = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any])
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(details["home"] as? String)))

        env["MOCK_UNSAFE_LOGIN_URL"] = "1"
        service.environment = env
        XCTAssertThrowsError(try service.authorizeAdditionalChatGPT(method: .browser, cancellation: LoginCancellation()) { _ in
            XCTFail("An untrusted authorization URL must never be opened")
            return true
        }) { error in guard case CodexError.invalidAuthURL = error else { return XCTFail("Unexpected error: \(error)") } }
        details = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any])
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(details["home"] as? String)))

        env.removeValue(forKey: "MOCK_UNSAFE_LOGIN_URL")
        env.removeValue(forKey: "MOCK_LOGIN_PENDING")
        service.environment = env
        XCTAssertThrowsError(try service.authorizeAdditionalChatGPT(method: .browser, cancellation: LoginCancellation()) { _ in true }) { error in
            guard case CodexError.authenticationFailed = error else { return XCTFail("Unexpected error: \(error)") }
        }
        env["MOCK_DEVICE_UNAVAILABLE"] = "1"
        service.environment = env
        XCTAssertThrowsError(try service.authorizeAdditionalChatGPT(method: .deviceCode, cancellation: LoginCancellation()) { _ in
            XCTFail("Unavailable device login must not open a browser")
            return true
        }) { error in guard case CodexError.deviceLoginUnavailable = error else { return XCTFail("Unexpected error: \(error)") } }
        XCTAssertEqual(try Data(contentsOf: live.appendingPathComponent("auth.json")), oldAuth)
    }

    func testAuthorizedAccountDeduplicatesByWorkspaceAndRollsBackOnSaveFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cam-save-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(directory: root.appendingPathComponent("profiles"))
        let keys = MemoryCredentials()
        let auth = try chatGPTAuth(email: "person@example.invalid", subject: "person", workspace: "one", refresh: "fake-new", plan: "plus")
        let credentials = try CredentialSnapshot(bytes: auth)
        let current = CurrentCodex(account: "person@example.invalid", accountType: "chatgpt", provider: "openai", model: nil,
                                   configVersion: nil, configAvailable: true, accountAvailable: true, credentialStore: "file",
                                   credentialFingerprint: credentials.fingerprint, accountPlanType: "plus")
        let quota = try XCTUnwrap(AccountQuota.parse(["rateLimits": ["primary": ["usedPercent": 20]]]))
        let account = AuthorizedChatGPTAccount(current: current, credentials: credentials, quota: quota)
        let id = UUID()
        var profiles = [CodexProfile(id: id, name: "已有名称", kind: .chatgpt, model: nil, baseURL: nil, hasSecret: true,
                                     accountEmail: "person@example.invalid", accountID: credentials.fingerprint)]
        keys.values[id] = "previous-secret"
        XCTAssertTrue(try saveAuthorizedChatGPTAccount(account, profiles: &profiles, keys: keys, storage: store))
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].name, "已有名称")
        XCTAssertEqual(profiles[0].lastQuota, quota)
        XCTAssertEqual(keys.values[id], String(decoding: auth, as: UTF8.self))

        let otherAuth = try chatGPTAuth(email: "person@example.invalid", subject: "person", workspace: "two", refresh: "fake-other")
        let otherCredentials = try CredentialSnapshot(bytes: otherAuth)
        var otherCurrent = current
        otherCurrent.credentialFingerprint = otherCredentials.fingerprint
        let other = AuthorizedChatGPTAccount(current: otherCurrent, credentials: otherCredentials, quota: nil)
        XCTAssertFalse(try saveAuthorizedChatGPTAccount(other, profiles: &profiles, keys: keys, storage: store))
        XCTAssertEqual(profiles.count, 2)
        XCTAssertEqual(try store.load(), profiles)

        let blocker = root.appendingPathComponent("not-a-directory")
        try Data().write(to: blocker)
        let before = profiles, oldSecret = keys.values[id]
        XCTAssertThrowsError(try saveAuthorizedChatGPTAccount(account, profiles: &profiles, keys: keys, storage: ProfileStore(directory: blocker)))
        XCTAssertEqual(profiles, before)
        XCTAssertEqual(keys.values[id], oldSecret)
    }

    func testOfficialDisplayNameRequiresMatchingSavedIdentity() throws {
        let auth = try chatGPTAuth(email: "person@example.invalid", subject: "person", workspace: "one", refresh: "fake",
                                   displayName: "  官方名称  ")
        let snapshot = try CredentialSnapshot(bytes: auth)
        XCTAssertEqual(snapshot.displayName, "官方名称")
        let invalid = try chatGPTAuth(email: "person@example.invalid", subject: "person", workspace: "one", refresh: "fake",
                                      displayName: "bad\nname")
        XCTAssertNil(try CredentialSnapshot(bytes: invalid).displayName)
        let tooLong = try chatGPTAuth(email: "person@example.invalid", subject: "person", workspace: "one", refresh: "fake",
                                      displayName: String(repeating: "a", count: 121))
        XCTAssertNil(try CredentialSnapshot(bytes: tooLong).displayName)

        let first = CodexProfile(id: UUID(), name: "person@example.invalid", kind: .chatgpt, model: nil, baseURL: nil,
                                 hasSecret: true, accountEmail: "person@example.invalid", accountID: snapshot.fingerprint)
        let second = CodexProfile(id: UUID(), name: "person@example.invalid", kind: .chatgpt, model: nil, baseURL: nil,
                                  hasSecret: true, accountEmail: "person@example.invalid", accountID: "different-workspace")
        let recovered = recoverAccountDisplayNames([first, second]) { _ in String(decoding: auth, as: UTF8.self) }
        XCTAssertEqual(recovered, [first.id: "官方名称"])
    }

    @MainActor
    func testAccountNamePrefersOfficialNameThenRespectsEditedAlias() throws {
        let state = AppState(demo: true)
        var profile = try XCTUnwrap(state.profiles.first)
        profile.name = "person@example.invalid"
        profile.accountEmail = "person@example.invalid"
        profile.accountDisplayName = "已保存的官方名称"
        profile.hasCustomName = nil
        state.profiles = [profile]
        state.current.credentialFingerprint = profile.accountID
        state.current.accountDisplayName = "最新官方名称"
        XCTAssertEqual(state.profileDisplayName(profile), "最新官方名称")
        state.current.accountDisplayName = nil
        XCTAssertEqual(state.profileDisplayName(profile), "已保存的官方名称")
        profile.accountDisplayName = nil
        state.profiles = [profile]
        XCTAssertEqual(state.profileDisplayName(profile), "person@example.invalid")

        state.current.accountDisplayName = "官方名称"
        XCTAssertTrue(state.update(profile, name: "我的别名", model: "", baseURL: "", secret: ""))
        let updated = try XCTUnwrap(state.profiles.first)
        XCTAssertEqual(updated.hasCustomName, true)
        XCTAssertEqual(state.profileDisplayName(updated), "我的别名")
        XCTAssertEqual(try JSONDecoder().decode(CodexProfile.self, from: JSONEncoder().encode(updated)), updated)
        state.current.accountDisplayName = "变更后的官方名称"
        XCTAssertEqual(state.profileDisplayName(updated), "我的别名")

        // A manually selected alias remains authoritative even if it equals the email.
        XCTAssertTrue(state.update(updated, name: "person@example.invalid", model: "", baseURL: "", secret: ""))
        XCTAssertEqual(state.profileDisplayName(try XCTUnwrap(state.profiles.first)), "person@example.invalid")
    }

    func testCurrentAccountNameComesFromItsOwnCredential() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cam-name-current-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let auth = try chatGPTAuth(email: "person@example.invalid", subject: "person", workspace: "one", refresh: "fake",
                                   displayName: "官方名称")
        try FileCredentials(home: home).replace(expected: nil, with: auth)
        var env = ProcessInfo.processInfo.environment
        for key in ["CODEX_API_KEY", "OPENAI_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_FEDERATION_RULE_ID", "OPENAI_IDENTITY_TOKEN_FILE", "OPENAI_WORKLOAD_IDENTITY_CONTEXT"] { env.removeValue(forKey: key) }
        env["CODEX_HOME"] = home.path
        var service = CodexService(environment: env, executableOverride: try fixture("mock_codex"))
        let current = try service.readCurrent()
        XCTAssertEqual(current.accountDisplayName, "官方名称")
        XCTAssertEqual(current.currentLoginItem?.name, "官方名称")
        XCTAssertEqual(current.currentLoginItem?.accountEmail, "person@example.invalid")
        env["MOCK_EMAIL"] = "other@example.invalid"
        service.environment = env
        let mismatched = try service.readCurrent()
        XCTAssertNil(mismatched.accountDisplayName)
        XCTAssertEqual(mismatched.currentLoginItem?.name, "other@example.invalid")
        XCTAssertNil(mismatched.currentLoginItem?.accountEmail)
        var profiles: [CodexProfile] = []
        _ = try preserveCurrentAccount(service: service, profiles: &profiles, keys: MemoryCredentials(),
                                       storage: ProfileStore(directory: home.appendingPathComponent("metadata")))
        XCTAssertNil(profiles.first?.accountDisplayName)
        XCTAssertEqual(profiles.first?.name, "other@example.invalid")
    }

    func testMembershipTypesRecoverOnlyFromMatchingSavedWorkspaces() throws {
        XCTAssertEqual(ChatGPTPlan.title("free"), "Free")
        XCTAssertEqual(ChatGPTPlan.title("plus"), "Plus")
        XCTAssertEqual(ChatGPTPlan.title("PRO"), "Pro")
        XCTAssertEqual(ChatGPTPlan.title("prolite"), "Pro")
        XCTAssertEqual(ChatGPTPlan.title("promax"), "Pro")
        XCTAssertEqual(ChatGPTPlan.title("team"), "Team")
        XCTAssertEqual(ChatGPTPlan.title("self_serve_business_usage_based"), "Team")
        XCTAssertEqual(ChatGPTPlan.title("self_serve_business_prolite"), "Team")
        XCTAssertEqual(ChatGPTPlan.title("go"), "Unknown")
        XCTAssertEqual(ChatGPTPlan.title("business"), "Unknown")
        XCTAssertEqual(ChatGPTPlan.title("edu_plus"), "Unknown")
        XCTAssertEqual(ChatGPTPlan.title("edu_pro"), "Unknown")
        XCTAssertEqual(ChatGPTPlan.title("future_plan"), "Unknown")
        XCTAssertEqual(ChatGPTPlan.title("unknown"), "Unknown")
        XCTAssertEqual(ChatGPTPlan.title("unexpected untrusted text"), "Unknown")

        let auth = try chatGPTAuth(email: "person@example.invalid", subject: "person", workspace: "work", refresh: "fake", plan: "plus")
        let snapshot = try CredentialSnapshot(bytes: auth)
        XCTAssertEqual(snapshot.accountPlanType, "plus")
        let wrongWorkspace = try chatGPTAuth(email: "person@example.invalid", subject: "person", workspace: "work", refresh: "fake", plan: "pro", tokenWorkspace: "other")
        XCTAssertNil(try CredentialSnapshot(bytes: wrongWorkspace).accountPlanType)
        let unknown = try chatGPTAuth(email: "person@example.invalid", subject: "person", workspace: "work", refresh: "fake", plan: "unknown")
        XCTAssertNil(try CredentialSnapshot(bytes: unknown).accountPlanType)

        let saved = CodexProfile(id: UUID(), name: "saved", kind: .chatgpt, model: nil, baseURL: nil, hasSecret: true,
                                 accountEmail: "person@example.invalid", accountID: snapshot.fingerprint)
        let different = CodexProfile(id: UUID(), name: "different", kind: .chatgpt, model: nil, baseURL: nil, hasSecret: true,
                                     accountEmail: "person@example.invalid", accountID: "different-workspace")
        let noSecret = CodexProfile(id: UUID(), name: "new", kind: .chatgpt, model: nil, baseURL: nil, hasSecret: false)
        let values = [saved.id: String(decoding: auth, as: UTF8.self), different.id: String(decoding: auth, as: UTF8.self)]
        let recovered = recoverAccountPlanTypes([saved, different, noSecret]) { id in
            guard let value = values[id] else { throw StoreError.missingSecret }
            return value
        }
        XCTAssertEqual(recovered, [saved.id: "plus"])

        // Profiles written before the membership field was introduced still decode.
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        old.removeValue(forKey: "accountPlanType")
        let decoded = try JSONDecoder().decode(CodexProfile.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(decoded.accountPlanType)
        old["lastQuota"] = ["unrecognized_cache_format": true]
        let withBadCache = try JSONDecoder().decode(CodexProfile.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertEqual(withBadCache.id, saved.id)
        XCTAssertNil(withBadCache.lastQuota)
    }

    @MainActor
    func testMembershipDisplayUsesCurrentPlanAndKeepsMetadataWhenEdited() throws {
        let state = AppState(demo: true)
        let profile = try XCTUnwrap(state.profiles.first)
        XCTAssertEqual(state.accountPlanType(for: profile), "plus")
        state.current.accountPlanType = "pro"
        XCTAssertEqual(state.accountPlanType(for: profile), "pro")
        state.current.accountPlanType = "unknown"
        XCTAssertEqual(ChatGPTPlan.title(state.accountPlanType(for: profile)), "Unknown")
        state.current.credentialFingerprint = "different-workspace"
        XCTAssertEqual(state.accountPlanType(for: profile), "plus")
        XCTAssertTrue(state.update(profile, name: "renamed", model: "", baseURL: "", secret: ""))
        XCTAssertEqual(state.profiles.first?.accountPlanType, "plus")
        XCTAssertNil(state.accountPlanType(for: try XCTUnwrap(state.profiles.first { $0.kind == .openai })))
    }

    func testMembershipReadFromCodexAndSavedWithTheAccount() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("codex-plan-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let auth = try chatGPTAuth(email: "person@example.invalid", subject: "person", workspace: "work", refresh: "fake", plan: "plus")
        let credentials = FileCredentials(home: home)
        try credentials.replace(expected: nil, with: auth)
        var env = ProcessInfo.processInfo.environment
        for key in ["CODEX_API_KEY", "OPENAI_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_FEDERATION_RULE_ID", "OPENAI_IDENTITY_TOKEN_FILE", "OPENAI_WORKLOAD_IDENTITY_CONTEXT"] { env.removeValue(forKey: key) }
        env["CODEX_HOME"] = home.path
        env["MOCK_PLAN_TYPE"] = "pro"
        let fixture = try fixture("mock_codex")
        let service = CodexService(environment: env, executableOverride: fixture)
        XCTAssertEqual(try service.readCurrent().accountPlanType, "pro")
        let store = ProfileStore(directory: home.appendingPathComponent("metadata"))
        let vault = MemoryCredentials()
        var profiles: [CodexProfile] = []
        _ = try preserveCurrentAccount(service: service, profiles: &profiles, keys: vault, storage: store)
        XCTAssertEqual(profiles.first?.accountPlanType, "pro")
        XCTAssertEqual(try store.load().first?.accountPlanType, "pro")
        XCTAssertFalse(try String(contentsOf: store.file, encoding: .utf8).contains("fake"))

        env["MOCK_STORE"] = "keyring"
        XCTAssertEqual(try CodexService(environment: env, executableOverride: fixture).readCurrent().accountPlanType, "pro")
        let api = try JSONSerialization.data(withJSONObject: ["OPENAI_API_KEY": "sk-test-fake"])
        try credentials.replace(expected: auth, with: api)
        env["MOCK_STORE"] = "file"
        XCTAssertNil(try CodexService(environment: env, executableOverride: fixture).readCurrent().accountPlanType)
    }

    func testQuotaParsingKeepsAllReportedWindowsAndDoesNotInventMissingValues() throws {
        let payload: [String: Any] = [
            "rateLimits": ["primary": ["usedPercent": 99]],
            "rateLimitsByLimitId": [
                "codex": ["primary": ["usedPercent": 25, "windowDurationMins": 300, "resetsAt": 1_800_000_000],
                          "secondary": ["usedPercent": 50, "windowDurationMins": 10_080, "resetsAt": 1_800_100_000],
                          "credits": ["hasCredits": true, "unlimited": false, "balance": "12.5"],
                          "individualLimit": ["used": "10", "limit": "100", "remainingPercent": 90, "resetsAt": 1_800_100_000]],
                "codex_other": ["limitName": "其他模型", "primary": ["usedPercent": 110], "rateLimitReachedType": "rate_limit_reached"]
            ],
            "rateLimitResetCredits": ["availableCount": 2]
        ]
        // Match the NSNumber types delivered by JSONSerialization in the app server client.
        let json = try JSONSerialization.data(withJSONObject: payload)
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let quota = try XCTUnwrap(AccountQuota.parse(response, updatedAt: time))
        XCTAssertEqual(quota.updatedAt, time)
        XCTAssertEqual(quota.buckets.count, 2)
        XCTAssertEqual(quota.buckets[0].title, "Codex")
        XCTAssertEqual(quota.buckets[0].windows.map(\.title), ["5 小时", "7 天"])
        XCTAssertEqual(quota.buckets[0].windows.map(\.remainingPercent), [75, 50])
        XCTAssertEqual(quota.buckets[0].windows.first?.resetsAt, time)
        XCTAssertEqual(quota.buckets[0].credits, "积分：12.5")
        XCTAssertTrue(quota.buckets[0].individualLimit?.description.contains("个人已用 10 / 100 · 剩余 90%") == true)
        XCTAssertEqual(quota.buckets[1].title, "其他模型")
        XCTAssertEqual(quota.buckets[1].windows.first?.remainingPercent, 0)
        XCTAssertEqual(quota.buckets[1].reached, "已达到使用额度")
        XCTAssertEqual(quota.resetCredits, 2)
        XCTAssertEqual(try JSONDecoder().decode(AccountQuota.self, from: JSONEncoder().encode(quota)), quota)
        XCTAssertNil(AccountQuota.parse(["rateLimits": ["primary": ["windowDurationMins": 300]]]))
        XCTAssertNil(AccountQuota.parse(["rateLimits": ["primary": ["usedPercent": -1]]]))
        let malformedJSON = try JSONSerialization.data(withJSONObject: ["rateLimits": ["primary": ["usedPercent": true]]])
        XCTAssertNil(AccountQuota.parse(try XCTUnwrap(JSONSerialization.jsonObject(with: malformedJSON) as? [String: Any])))
        let fallback = try XCTUnwrap(AccountQuota.parse(["rateLimits": ["primary": ["usedPercent": 0]]]))
        XCTAssertEqual(fallback.buckets.first?.windows.first?.remainingPercent, 100)
        XCTAssertEqual(fallback.buckets.first?.windows.first?.title, "主要额度")
    }

    @MainActor
    func testQuotaPresentationKeepsCachedAccountsSeparate() throws {
        let state = AppState(demo: true)
        let active = try XCTUnwrap(state.profiles.first { $0.accountID == "demo-account" })
        let other = try XCTUnwrap(state.profiles.first { $0.accountID == "demo-work" })
        XCTAssertEqual(state.quotaPresentation(for: active).value?.buckets.first?.windows.first?.remainingPercent, 78)
        XCTAssertFalse(state.quotaPresentation(for: active).isCached)
        XCTAssertEqual(state.quotaPresentation(for: other).value?.buckets.first?.windows.first?.remainingPercent, 65)
        XCTAssertTrue(state.quotaPresentation(for: other).isCached)
        state.remove(other)
        XCTAssertNil(state.quotaByAccount["demo-work"])
        let savedQuota = try XCTUnwrap(state.currentQuota)
        state.profiles[0].lastQuota = savedQuota
        XCTAssertTrue(state.update(active, name: "renamed", model: "", baseURL: "", secret: ""))
        XCTAssertEqual(state.profiles.first?.lastQuota, savedQuota)
        let neverLoaded = CodexProfile(id: UUID(), name: "new", kind: .chatgpt, model: nil, baseURL: nil, hasSecret: true, accountID: "not-queried")
        XCTAssertNil(state.quotaPresentation(for: neverLoaded).value)
    }

    func testCurrentQuotaUsesOfficialEndpointAndRejectsChangedAccounts() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("codex-quota-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let first = try chatGPTAuth(email: "one@example.invalid", subject: "one", workspace: "team-one", refresh: "fake-one", plan: "plus")
        let second = try chatGPTAuth(email: "one@example.invalid", subject: "one", workspace: "team-two", refresh: "fake-two", plan: "plus")
        let file = FileCredentials(home: home)
        try file.replace(expected: nil, with: first)
        let marker = home.appendingPathComponent("quota-requests")
        var env = ProcessInfo.processInfo.environment
        for key in ["CODEX_API_KEY", "OPENAI_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_FEDERATION_RULE_ID", "OPENAI_IDENTITY_TOKEN_FILE", "OPENAI_WORKLOAD_IDENTITY_CONTEXT", "CHATGPT_BASE_URL", "CODEX_CHATGPT_BASE_URL"] { env.removeValue(forKey: key) }
        env["CODEX_HOME"] = home.path
        env["MOCK_QUOTA_MARKER"] = marker.path
        env["MOCK_QUOTA"] = #"{"accountId":"team-one","rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300}}}"#
        let fixture = try fixture("mock_codex")
        let service = CodexService(environment: env, executableOverride: fixture)
        let expected = try service.readCurrent()
        let quota = try XCTUnwrap(service.readCurrentQuota(expected: expected))
        XCTAssertEqual(quota.buckets.first?.windows.first?.remainingPercent, 75)
        XCTAssertEqual(try file.raw(), first)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "read\n")

        var wrong = expected; wrong.credentialFingerprint = "different"
        XCTAssertThrowsError(try service.readCurrentQuota(expected: wrong))
        wrong.credentialFingerprint = nil
        XCTAssertThrowsError(try service.readCurrentQuota(expected: wrong))
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "read\n")
        env["MOCK_CHATGPT_ENDPOINT"] = "https://example.invalid/backend-api/"
        XCTAssertThrowsError(try CodexService(environment: env, executableOverride: fixture).readCurrentQuota(expected: expected))
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "read\n")
        env.removeValue(forKey: "MOCK_CHATGPT_ENDPOINT")
        env["MOCK_QUOTA"] = #"{"accountId":"different","rateLimits":{"primary":{"usedPercent":25}}}"#
        XCTAssertThrowsError(try CodexService(environment: env, executableOverride: fixture).readCurrentQuota(expected: expected))
        env["MOCK_QUOTA"] = #"{"accountId":"team-one","rateLimits":{"primary":{"usedPercent":25}}}"#
        let replacement = home.appendingPathComponent("replacement-auth")
        try second.write(to: replacement)
        env["MOCK_SWAP_AUTH_PATH"] = replacement.path
        XCTAssertThrowsError(try CodexService(environment: env, executableOverride: fixture).readCurrentQuota(expected: expected))
        XCTAssertEqual(try file.raw(), second)
    }

    @MainActor
    func testQuotaRefreshButtonFlowFetchesAgainAndPersistsTheLastSnapshot() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("codex-quota-ui-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let auth = try chatGPTAuth(email: "person@example.invalid", subject: "person", workspace: "team", refresh: "fake", plan: "plus")
        let file = FileCredentials(home: home)
        try file.replace(expected: nil, with: auth)
        let identity = try CredentialSnapshot(bytes: auth).fingerprint
        let store = ProfileStore(directory: home.appendingPathComponent("metadata"))
        let profile = CodexProfile(id: UUID(), name: "saved", kind: .chatgpt, model: nil, baseURL: nil, hasSecret: true,
                                   accountEmail: "person@example.invalid", accountID: identity, accountPlanType: "plus")
        try store.save([profile])
        let quotaFile = home.appendingPathComponent("mock_quota.json")
        let marker = home.appendingPathComponent("mock_quota_counter")
        try "".write(to: marker, atomically: true, encoding: .utf8)
        try #"{"accountId":"team","rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":300}}}"#.write(to: quotaFile, atomically: true, encoding: .utf8)
        let suite = "local.cam.quota-test." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(home.path, forKey: "codexHome")
        preferences.set(try fixture("mock_codex").path, forKey: "codexPath")
        preferences.set(false, forKey: "diagnosticEnabled")
        let state = AppState(demo: false, storage: store, preferences: preferences)
        func waitForRemaining(_ value: Int) async throws {
            let deadline = Date().addingTimeInterval(12)
            while state.currentQuota?.buckets.first?.windows.first?.remainingPercent != value && Date() < deadline {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertEqual(state.currentQuota?.buckets.first?.windows.first?.remainingPercent, value)
        }
        try await waitForRemaining(80)
        XCTAssertEqual(try store.load().first?.lastQuota?.buckets.first?.windows.first?.remainingPercent, 80)
        try #"{"accountId":"team","rateLimits":{"primary":{"usedPercent":70,"windowDurationMins":300}}}"#.write(to: quotaFile, atomically: true, encoding: .utf8)
        state.refresh(retryMissingPlanTypes: true)
        XCTAssertTrue(state.currentStatusLoading)
        XCTAssertTrue(state.quotaRefreshInProgress)
        try await waitForRemaining(30)
        XCTAssertFalse(state.quotaRefreshInProgress)
        XCTAssertEqual(try store.load().first?.lastQuota?.buckets.first?.windows.first?.remainingPercent, 30)
        XCTAssertGreaterThanOrEqual(try String(contentsOf: marker, encoding: .utf8).components(separatedBy: "read\n").count - 1, 2)
        XCTAssertEqual(try file.raw(), auth)
        let failureFlag = home.appendingPathComponent("mock_quota_error")
        try "".write(to: failureFlag, atomically: true, encoding: .utf8)
        state.refresh(retryMissingPlanTypes: true)
        XCTAssertTrue(state.quotaRefreshInProgress)
        let failureDeadline = Date().addingTimeInterval(12)
        while !state.currentQuotaFailed && Date() < failureDeadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(state.currentQuotaFailed)
        XCTAssertFalse(state.quotaRefreshInProgress)
        XCTAssertEqual(state.currentQuota?.buckets.first?.windows.first?.remainingPercent, 30)
        XCTAssertEqual(try store.load().first?.lastQuota?.buckets.first?.windows.first?.remainingPercent, 30)
        try FileManager.default.removeItem(at: failureFlag)
        let restored = AppState(demo: false, storage: store, preferences: preferences)
        XCTAssertEqual(restored.quotaByAccount[identity]?.buckets.first?.windows.first?.remainingPercent, 30)
        let deadline = Date().addingTimeInterval(12)
        while (restored.current.accountType != "chatgpt" || restored.currentQuotaLoading || restored.currentQuota == nil) && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(restored.currentQuotaLoading)
        XCTAssertEqual(restored.currentQuota?.buckets.first?.windows.first?.remainingPercent, 30)
    }

    func testFileCredentialIdentityAndAtomicReplacement() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cam-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let first = try chatGPTAuth(email: "one@example.invalid", subject: "user-one", workspace: "team", refresh: "refresh-one")
        let rotated = try chatGPTAuth(email: "one@example.invalid", subject: "user-one", workspace: "team", refresh: "refresh-two")
        let second = try chatGPTAuth(email: "two@example.invalid", subject: "user-two", workspace: "team", refresh: "refresh-three")
        let firstIdentity = try CredentialSnapshot(bytes: first).fingerprint
        XCTAssertEqual(firstIdentity, try CredentialSnapshot(bytes: rotated).fingerprint)
        XCTAssertNotEqual(firstIdentity, try CredentialSnapshot(bytes: second).fingerprint)
        let credentials = FileCredentials(home: home)
        try credentials.replace(expected: nil, with: first)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: credentials.file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try credentials.replace(expected: first, with: rotated)
        XCTAssertThrowsError(try credentials.replace(expected: first, with: second))
        XCTAssertEqual(try credentials.raw(), rotated)
        try credentials.replace(expected: rotated, with: second)
        XCTAssertEqual(try credentials.read()?.fingerprint, try CredentialSnapshot(bytes: second).fingerprint)
        XCTAssertThrowsError(try CredentialSnapshot(bytes: Data("{}".utf8)))
    }

    func testSavedChatGPTSwitchUsesSharedHomeAndRejectsWrongIdentity() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cam-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let first = try chatGPTAuth(email: "one@example.invalid", subject: "one", workspace: "personal-one", refresh: "fake-one")
        let second = try chatGPTAuth(email: "two@example.invalid", subject: "two", workspace: "personal-two", refresh: "fake-two")
        let file = FileCredentials(home: home)
        try file.replace(expected: nil, with: first)
        var env = ProcessInfo.processInfo.environment
        for key in ["CODEX_API_KEY", "OPENAI_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_FEDERATION_RULE_ID", "OPENAI_IDENTITY_TOKEN_FILE", "OPENAI_WORKLOAD_IDENTITY_CONTEXT"] { env.removeValue(forKey: key) }
        env["CODEX_HOME"] = home.path
        let fixture = try fixture("mock_codex")
        let service = CodexService(environment: env, executableOverride: fixture)
        let identity = try CredentialSnapshot(bytes: second).fingerprint
        let profile = CodexProfile(id: UUID(), name: "第二个账号", kind: .chatgpt, model: nil, baseURL: nil, hasSecret: true, accountID: identity)
        XCTAssertEqual(try service.readCurrent().account, "one@example.invalid")
        XCTAssertThrowsError(try service.activateSavedChatGPT(profile, credential: String(decoding: second, as: UTF8.self), expectedPrevious: second))
        XCTAssertEqual(try file.raw(), first)
        try service.activateSavedChatGPT(profile, credential: String(decoding: second, as: UTF8.self), expectedPrevious: first)
        XCTAssertEqual(try service.readCurrent().account, "two@example.invalid")
        XCTAssertEqual(try service.readCurrent().credentialFingerprint, identity)
        XCTAssertThrowsError(try service.activateSavedChatGPT(profile, credential: String(decoding: first, as: UTF8.self), expectedPrevious: second))
        XCTAssertEqual(try file.raw(), second)

        env["MOCK_STORE"] = "keyring"
        let keyring = CodexService(environment: env, executableOverride: fixture)
        XCTAssertThrowsError(try keyring.activateSavedChatGPT(profile, credential: String(decoding: second, as: UTF8.self), expectedPrevious: second))
        XCTAssertEqual(try file.raw(), second)
        env["MOCK_STORE"] = "file"; env["MOCK_CUSTOM_ENDPOINT"] = "https://example.invalid/v1"
        let custom = CodexService(environment: env, executableOverride: fixture)
        XCTAssertThrowsError(try custom.activateSavedChatGPT(profile, credential: String(decoding: second, as: UTF8.self), expectedPrevious: second))
        XCTAssertEqual(try file.raw(), second)
    }

    func testReauthenticationChecksWorkspaceBeforeSavingOrSwitching() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cam-reauth-test-" + UUID().uuidString)
        let home = root.appendingPathComponent("live")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let live = try chatGPTAuth(email: "current@example.invalid", subject: "current", workspace: "live", refresh: "fake-live")
        let old = try chatGPTAuth(email: "person@example.invalid", subject: "person", workspace: "selected", refresh: "fake-old")
        let updated = try chatGPTAuth(email: "person@example.invalid", subject: "person", workspace: "selected", refresh: "fake-new")
        let wrongWorkspace = try chatGPTAuth(email: "person@example.invalid", subject: "person", workspace: "other", refresh: "fake-other")
        let source = root.appendingPathComponent("login.json")
        try live.write(to: home.appendingPathComponent("auth.json"))
        try wrongWorkspace.write(to: source)
        let fingerprint = try CredentialSnapshot(bytes: old).fingerprint
        let profile = CodexProfile(id: UUID(), name: "所选账号", kind: .chatgpt, model: nil, baseURL: nil, hasSecret: true, accountID: fingerprint)
        var profiles = [profile]
        let keys = MemoryCredentials()
        keys.values[profile.id] = String(decoding: old, as: UTF8.self)
        let store = ProfileStore(directory: root.appendingPathComponent("profiles"))
        try store.save(profiles)
        var env = ProcessInfo.processInfo.environment
        for key in ["CODEX_API_KEY", "OPENAI_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_FEDERATION_RULE_ID", "OPENAI_IDENTITY_TOKEN_FILE", "OPENAI_WORKLOAD_IDENTITY_CONTEXT", "CHATGPT_BASE_URL", "CODEX_CHATGPT_BASE_URL"] { env.removeValue(forKey: key) }
        env["CODEX_HOME"] = home.path
        env["MOCK_LOGIN_AUTH_PATH"] = source.path
        var service = CodexService(environment: env, executableOverride: try fixture("mock_codex"))

        XCTAssertThrowsError(try reauthorizeChatGPTAccount(service: service, profileID: profile.id, expectedPrevious: live,
                              profiles: &profiles, keys: keys, storage: store, cancellation: LoginCancellation(), onInstructions: { _ in true })) {
            guard case CodexError.differentAccount = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertEqual(try service.fileCredentials().raw(), live)
        XCTAssertEqual(keys.values[profile.id], String(decoding: old, as: UTF8.self))
        XCTAssertEqual(try store.load(), [profile])

        try updated.write(to: source)
        let cancellation = LoginCancellation()
        XCTAssertThrowsError(try reauthorizeChatGPTAccount(service: service, profileID: profile.id, expectedPrevious: live,
                              profiles: &profiles, keys: keys, storage: store, cancellation: cancellation, onInstructions: { _ in
            cancellation.cancel(); return true
        })) { guard case CodexError.loginCancelled = $0 else { return XCTFail("Unexpected error: \($0)") } }
        XCTAssertEqual(try service.fileCredentials().raw(), live)
        XCTAssertEqual(keys.values[profile.id], String(decoding: old, as: UTF8.self))

        env["MOCK_UNSAFE_LOGIN_URL"] = "1"
        service.environment = env
        XCTAssertThrowsError(try reauthorizeChatGPTAccount(service: service, profileID: profile.id, expectedPrevious: live,
                              profiles: &profiles, keys: keys, storage: store, cancellation: LoginCancellation(), onInstructions: { _ in
            XCTFail("Untrusted URL must not be opened"); return true
        })) { guard case CodexError.invalidAuthURL = $0 else { return XCTFail("Unexpected error: \($0)") } }
        env.removeValue(forKey: "MOCK_UNSAFE_LOGIN_URL")
        service.environment = env

        let blocker = root.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        XCTAssertThrowsError(try reauthorizeChatGPTAccount(service: service, profileID: profile.id, expectedPrevious: live,
                              profiles: &profiles, keys: keys, storage: ProfileStore(directory: blocker), cancellation: LoginCancellation(), onInstructions: { _ in true }))
        XCTAssertEqual(try service.fileCredentials().raw(), live)
        XCTAssertEqual(keys.values[profile.id], String(decoding: old, as: UTF8.self))
        XCTAssertEqual(profiles, [profile])

        // Reauthentication must also repair a profile whose saved credential was removed.
        keys.values.removeValue(forKey: profile.id)
        _ = try reauthorizeChatGPTAccount(service: service, profileID: profile.id, expectedPrevious: live,
                                          profiles: &profiles, keys: keys, storage: store, cancellation: LoginCancellation(), onInstructions: { _ in true })
        XCTAssertEqual(try service.fileCredentials().raw(), updated)
        XCTAssertEqual(keys.values[profile.id], String(decoding: updated, as: UTF8.self))
        XCTAssertEqual(profiles[0].name, "所选账号")
        XCTAssertEqual(profiles[0].accountID, fingerprint)
        XCTAssertEqual(try store.load(), profiles)
    }

    func testSwitchRestoresPreviousCredentialOrReportsUncertainState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cam-rollback-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try chatGPTAuth(email: "one@example.invalid", subject: "one", workspace: "one", refresh: "fake-one")
        let second = try chatGPTAuth(email: "two@example.invalid", subject: "two", workspace: "two", refresh: "fake-two")
        let external = try chatGPTAuth(email: "other@example.invalid", subject: "other", workspace: "other", refresh: "fake-other")
        let externalFile = root.appendingPathComponent("external.json")
        try external.write(to: externalFile)
        let home = root.appendingPathComponent("live")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let file = FileCredentials(home: home)
        try file.replace(expected: nil, with: first)
        var env = ProcessInfo.processInfo.environment
        for key in ["CODEX_API_KEY", "OPENAI_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_FEDERATION_RULE_ID", "OPENAI_IDENTITY_TOKEN_FILE", "OPENAI_WORKLOAD_IDENTITY_CONTEXT"] { env.removeValue(forKey: key) }
        env["CODEX_HOME"] = home.path
        env["MOCK_CONFIG_WRITE_FAIL"] = "1"
        var service = CodexService(environment: env, executableOverride: try fixture("mock_codex"))
        let profile = CodexProfile(id: UUID(), name: "账号", kind: .chatgpt, model: nil, baseURL: nil, hasSecret: true,
                                   accountID: try CredentialSnapshot(bytes: second).fingerprint)
        XCTAssertThrowsError(try service.activateSavedChatGPT(profile, credential: String(decoding: second, as: UTF8.self), expectedPrevious: first)) {
            guard case CodexError.loginRestored = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertEqual(try file.raw(), first)

        env.removeValue(forKey: "MOCK_CONFIG_WRITE_FAIL")
        env["MOCK_VERIFY_FAILURE"] = "1"
        service.environment = env
        XCTAssertThrowsError(try service.activateSavedChatGPT(profile, credential: String(decoding: second, as: UTF8.self), expectedPrevious: first)) {
            guard case CodexError.loginRestored = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertEqual(try file.raw(), first)

        env.removeValue(forKey: "MOCK_VERIFY_FAILURE")
        env["MOCK_CONFIG_WRITE_FAIL"] = "1"
        env["MOCK_CONFIG_WRITE_SWAP_AUTH_PATH"] = externalFile.path
        service.environment = env
        XCTAssertThrowsError(try service.activateSavedChatGPT(profile, credential: String(decoding: second, as: UTF8.self), expectedPrevious: first)) {
            guard case CodexError.partialLogin = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertEqual(try file.raw(), external)

        let emptyHome = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: emptyHome, withIntermediateDirectories: true)
        env["CODEX_HOME"] = emptyHome.path
        env.removeValue(forKey: "MOCK_CONFIG_WRITE_SWAP_AUTH_PATH")
        service.environment = env
        XCTAssertThrowsError(try service.activateSavedChatGPT(profile, credential: String(decoding: second, as: UTF8.self), expectedPrevious: nil)) {
            guard case CodexError.partialLogin = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertEqual(try service.fileCredentials().raw(), second)
    }

    func testAPIKeyLoginIsIsolatedAndRollbackDoesNotOverwriteExternalChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cam-api-stage-test-" + UUID().uuidString)
        let home = root.appendingPathComponent("live")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try chatGPTAuth(email: "one@example.invalid", subject: "one", workspace: "one", refresh: "fake-one")
        let external = try chatGPTAuth(email: "other@example.invalid", subject: "other", workspace: "other", refresh: "fake-other")
        let externalFile = root.appendingPathComponent("external.json"), marker = root.appendingPathComponent("home.json")
        try external.write(to: externalFile)
        let file = FileCredentials(home: home)
        try file.replace(expected: nil, with: first)
        var env = ProcessInfo.processInfo.environment
        for key in ["CODEX_API_KEY", "OPENAI_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_FEDERATION_RULE_ID", "OPENAI_IDENTITY_TOKEN_FILE", "OPENAI_WORKLOAD_IDENTITY_CONTEXT"] { env.removeValue(forKey: key) }
        env["CODEX_HOME"] = home.path
        env["MOCK_API_HOME_MARKER"] = marker.path
        env["MOCK_API_LOGIN_FAIL"] = "1"
        var service = CodexService(environment: env, executableOverride: try fixture("mock_codex"))
        let profile = CodexProfile(id: UUID(), name: "API", kind: .openai, model: nil, baseURL: nil, hasSecret: true)
        XCTAssertThrowsError(try service.activateAPIKey(profile, secret: "fake-api-key", expectedPrevious: first))
        XCTAssertEqual(try file.raw(), first)

        env.removeValue(forKey: "MOCK_API_LOGIN_FAIL")
        env["MOCK_CONFIG_WRITE_FAIL"] = "1"
        service.environment = env
        XCTAssertThrowsError(try service.activateAPIKey(profile, secret: "fake-api-key", expectedPrevious: first)) {
            guard case CodexError.loginRestored = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertEqual(try file.raw(), first)
        let details = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any])
        let temporary = try XCTUnwrap(details["home"] as? String)
        XCTAssertNotEqual(temporary, home.path)
        XCTAssertEqual(details["mode"] as? Int, 0o700)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary))

        env["MOCK_CONFIG_WRITE_SWAP_AUTH_PATH"] = externalFile.path
        service.environment = env
        XCTAssertThrowsError(try service.activateAPIKey(profile, secret: "fake-api-key", expectedPrevious: first)) {
            guard case CodexError.partialLogin = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertEqual(try file.raw(), external)
        env.removeValue(forKey: "MOCK_CONFIG_WRITE_FAIL")
        env.removeValue(forKey: "MOCK_CONFIG_WRITE_SWAP_AUTH_PATH")
        service.environment = env
        XCTAssertThrowsError(try service.activateAPIKey(profile, secret: "fake-api-key", expectedPrevious: first)) {
            guard case CodexError.changedExternally = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertEqual(try file.raw(), external)
        try service.activateAPIKey(profile, secret: "fake-api-key", expectedPrevious: external)
        XCTAssertEqual(try service.readCurrent().accountType, "apiKey")
        XCTAssertEqual(try file.read()?.fingerprint, CredentialSnapshot.fingerprint("api\0fake-api-key"))
    }

    func testPreservesCurrentLoginAndRefreshesSavedTokensBeforeSwitch() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cam-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let first = try chatGPTAuth(email: "one@example.invalid", subject: "one", workspace: "team", refresh: "fake-refresh-one")
        let rotated = try chatGPTAuth(email: "one@example.invalid", subject: "one", workspace: "team", refresh: "fake-refresh-two")
        let file = FileCredentials(home: home)
        try file.replace(expected: nil, with: first)
        var env = ProcessInfo.processInfo.environment
        for key in ["CODEX_API_KEY", "OPENAI_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_FEDERATION_RULE_ID", "OPENAI_IDENTITY_TOKEN_FILE", "OPENAI_WORKLOAD_IDENTITY_CONTEXT"] { env.removeValue(forKey: key) }
        env["CODEX_HOME"] = home.path
        let fixture = try fixture("mock_codex")
        let service = CodexService(environment: env, executableOverride: fixture)
        let store = ProfileStore(directory: home.appendingPathComponent("metadata"))
        let vault = MemoryCredentials()
        var profiles: [CodexProfile] = []
        vault.shouldFail = true
        XCTAssertThrowsError(try preserveCurrentAccount(service: service, profiles: &profiles, keys: vault, storage: store))
        XCTAssertTrue(profiles.isEmpty)
        XCTAssertEqual(try file.raw(), first)
        vault.shouldFail = false
        let identity = try CredentialSnapshot(bytes: first).fingerprint
        let quota = try XCTUnwrap(AccountQuota.parse(["rateLimits": ["primary": ["usedPercent": 25]]]))
        _ = try preserveCurrentAccount(service: service, profiles: &profiles, keys: vault, storage: store, cachedQuotas: [identity: quota])
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].accountEmail, "one@example.invalid")
        XCTAssertEqual(try store.load().first?.lastQuota, quota)
        XCTAssertEqual(vault.values[profiles[0].id], String(decoding: first, as: UTF8.self))
        try file.replace(expected: first, with: rotated)
        _ = try preserveCurrentAccount(service: service, profiles: &profiles, keys: vault, storage: store)
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].lastQuota, quota)
        XCTAssertEqual(vault.values[profiles[0].id], String(decoding: rotated, as: UTF8.self))
        let metadata = try String(contentsOf: store.file, encoding: .utf8)
        XCTAssertFalse(metadata.contains("fake-refresh"))
        let api = try JSONSerialization.data(withJSONObject: ["OPENAI_API_KEY": "sk-test-fake", "auth_mode": "apikey"])
        try file.replace(expected: rotated, with: api)
        _ = try preserveCurrentAccount(service: service, profiles: &profiles, keys: vault, storage: store)
        XCTAssertEqual(profiles.count, 2)
        let apiProfile = try XCTUnwrap(profiles.first { $0.kind == .openai })
        XCTAssertEqual(vault.values[apiProfile.id], "sk-test-fake")
        XCTAssertFalse(try String(contentsOf: store.file, encoding: .utf8).contains("sk-test-fake"))
    }

    func testSwitchBacksUpCurrentAuthFileBeforeReplacingIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cam-file-switch-test-" + UUID().uuidString)
        let home = root.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let current = try chatGPTAuth(email: "one@example.invalid", subject: "one", workspace: "one", refresh: "fake-one")
        let selected = try chatGPTAuth(email: "two@example.invalid", subject: "two", workspace: "two", refresh: "fake-two")
        let live = FileCredentials(home: home)
        try live.replace(expected: nil, with: current)
        let storage = ProfileStore(directory: root.appendingPathComponent("app"))
        let keys = SavedCredentialFiles(root: storage.directory)
        let target = CodexProfile(id: UUID(), name: "target", kind: .chatgpt, model: nil, baseURL: nil, hasSecret: true,
                                  accountID: try CredentialSnapshot(bytes: selected).fingerprint)
        try keys.save(String(decoding: selected, as: UTF8.self), id: target.id)
        var profiles = [target]
        try storage.save(profiles)
        var env = ProcessInfo.processInfo.environment
        for key in ["CODEX_API_KEY", "OPENAI_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_FEDERATION_RULE_ID", "OPENAI_IDENTITY_TOKEN_FILE", "OPENAI_WORKLOAD_IDENTITY_CONTEXT"] { env.removeValue(forKey: key) }
        env["CODEX_HOME"] = home.path
        let service = CodexService(environment: env, executableOverride: try fixture("mock_codex"))
        let previous = try preserveCurrentAccount(service: service, profiles: &profiles, keys: keys, storage: storage)
        let backup = try XCTUnwrap(profiles.first(where: { $0.id != target.id }))
        let backupFile = keys.directory.appendingPathComponent(backup.id.uuidString.lowercased() + ".json")
        XCTAssertEqual(try Data(contentsOf: backupFile), current)
        try service.activateSavedChatGPT(target, credential: keys.load(id: target.id), expectedPrevious: previous)
        XCTAssertEqual(try live.raw(), selected)
        XCTAssertEqual(try Data(contentsOf: backupFile), current)
    }

    func testCurrentAliasStoresOnlyMetadataUntilSwitchBackup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cam-current-alias-" + UUID().uuidString)
        let home = root.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = try chatGPTAuth(email: "one@example.invalid", subject: "one", workspace: "one", refresh: "fake-one")
        let live = FileCredentials(home: home)
        try live.replace(expected: nil, with: auth)
        var env = ProcessInfo.processInfo.environment
        for key in ["CODEX_API_KEY", "OPENAI_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_FEDERATION_RULE_ID", "OPENAI_IDENTITY_TOKEN_FILE", "OPENAI_WORKLOAD_IDENTITY_CONTEXT"] { env.removeValue(forKey: key) }
        env["CODEX_HOME"] = home.path
        let service = CodexService(environment: env, executableOverride: try fixture("mock_codex"))
        let current = try service.readCurrent()
        let store = ProfileStore(directory: root.appendingPathComponent("metadata"))
        let keys = SavedCredentialFiles(root: store.directory)
        var profiles = try profilesWithCurrentAlias("我的别名", current: current, profiles: [])
        try store.save(profiles)
        let id = try XCTUnwrap(profiles.first?.id)
        XCTAssertFalse(try XCTUnwrap(profiles.first).hasSecret)
        XCTAssertThrowsError(try keys.load(id: id)) { guard case StoreError.missingSecret = $0 else { return XCTFail("Unexpected error: \($0)") } }
        XCTAssertEqual(try live.raw(), auth)

        _ = try preserveCurrentAccount(service: service, profiles: &profiles, keys: keys, storage: store)
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.id, id)
        XCTAssertEqual(profiles.first?.name, "我的别名")
        XCTAssertTrue(try XCTUnwrap(profiles.first).hasSecret)
        XCTAssertEqual(try keys.load(id: id), String(decoding: auth, as: UTF8.self))
        XCTAssertEqual(try live.raw(), auth)
    }

    func testAddingAccountCanReuseAnInactiveAliasOnlyProfile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cam-alias-readd-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = try chatGPTAuth(email: "one@example.invalid", subject: "one", workspace: "one", refresh: "fake-one")
        let credentials = try CredentialSnapshot(bytes: auth)
        let current = CurrentCodex(account: "one@example.invalid", accountType: "chatgpt", provider: "openai", model: nil,
                                   configVersion: nil, configAvailable: true, accountAvailable: true, credentialStore: "file",
                                   credentialFingerprint: credentials.fingerprint)
        let account = AuthorizedChatGPTAccount(current: current, credentials: credentials, quota: nil,
                                               previousChatGPTFingerprint: "different-active-account")
        var profiles = try profilesWithCurrentAlias("我的别名", current: current, profiles: [])
        let id = try XCTUnwrap(profiles.first?.id)
        XCTAssertNoThrow(try ensureNewChatGPTAccount(account, profiles: profiles))
        let keys = SavedCredentialFiles(root: root.appendingPathComponent("metadata"))
        _ = try saveAuthorizedChatGPTAccount(account, profiles: &profiles, keys: keys,
                                             storage: ProfileStore(directory: root.appendingPathComponent("metadata")))
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.id, id)
        XCTAssertEqual(profiles.first?.name, "我的别名")
        XCTAssertEqual(profiles.first?.hasCustomName, true)
        XCTAssertTrue(try XCTUnwrap(profiles.first).hasSecret)
        XCTAssertEqual(try keys.load(id: id), String(decoding: auth, as: UTF8.self))
    }

    func testOfficialSwitchesKeepExistingSharedCodexSessions() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("codex-shared-history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent("config.toml")
        try """
        cli_auth_credentials_store = "file"
        model_provider = "custom"
        [model_providers.custom]
        name = "OpenAI"
        requires_openai_auth = true
        supports_websockets = true
        wire_api = "responses"
        """.write(to: config, atomically: true, encoding: .utf8)
        let threadID = UUID().uuidString.lowercased()
        let folder = home.appendingPathComponent("sessions/2026/10/30", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let thread = folder.appendingPathComponent("rollout-2026-10-30T12-00-00-\(threadID).jsonl")
        let time = "2026-10-30T12:00:00Z"
        let events: [[String: Any]] = [
            ["timestamp": time, "type": "session_meta", "payload": ["id": threadID, "timestamp": time, "cwd": home.path, "originator": "codex_cli_rs", "cli_version": "0.153.4", "source": "cli", "model_provider": "custom"]],
            ["timestamp": time, "type": "event_msg", "payload": ["type": "user_message", "message": "sample", "images": [], "local_images": []]],
            ["timestamp": time, "type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "sample"]]]]
        ]
        var original = Data()
        for event in events { original.append(try JSONSerialization.data(withJSONObject: event)); original.append(10) }
        try original.write(to: thread)
        var env = ProcessInfo.processInfo.environment
        for key in ["CODEX_SQLITE_HOME", "CODEX_API_KEY", "OPENAI_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_FEDERATION_RULE_ID", "OPENAI_IDENTITY_TOKEN_FILE", "OPENAI_WORKLOAD_IDENTITY_CONTEXT"] { env.removeValue(forKey: key) }
        env["CODEX_HOME"] = home.path
        guard let executable = try? CodexExecutable.find(environment: env) else { throw XCTSkip("Codex CLI unavailable") }
        prepareCodexPath(&env, executable: executable)
        let service = CodexService(environment: env)
        XCTAssertTrue(try service.readCurrent().usesSharedOfficialProvider)
        let api = CodexProfile(id: UUID(), name: "API", kind: .openai, model: nil, baseURL: nil, hasSecret: true)
        for key in ["sk-fake-first", "sk-fake-second"] {
            try service.activate(api, secret: key) { _ in XCTFail("Unexpected browser login"); return false }
            XCTAssertEqual(try service.readCurrent().provider, "custom")
            let client = try AppServerClient(executable: executable, environment: env)
            defer { client.close() }
            let list = try client.request("thread/list", ["modelProviders": ["custom"], "sourceKinds": ["cli"], "limit": 20])
            let threads = try XCTUnwrap(list["data"] as? [[String: Any]])
            XCTAssertTrue(threads.contains { $0["id"] as? String == threadID })
            XCTAssertNotNil(try client.request("thread/read", ["threadId": threadID, "includeTurns": false])["thread"])
            XCTAssertEqual(try Data(contentsOf: thread), original)
            if key == "sk-fake-second" {
                let resumed = try client.request("thread/resume", ["threadId": threadID], timeout: 20)
                XCTAssertNotNil(resumed["thread"])
            }
        }
        var disabled = service; disabled.preserveSharedHistory = false
        try disabled.activate(api, secret: "sk-fake-third") { _ in XCTFail("Unexpected browser login"); return false }
        XCTAssertEqual(try disabled.readCurrent().provider, "openai")
        XCTAssertTrue(try disabled.readCurrent().hasSharedOfficialProvider)
        var restored = service; restored.preferAvailableSharedHistory = true
        try restored.activate(api, secret: "sk-fake-fourth") { _ in XCTFail("Unexpected browser login"); return false }
        XCTAssertEqual(try restored.readCurrent().provider, "custom")
    }

    func testUntrustedCustomProviderIsNotTreatedAsOfficial() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("codex-unsafe-provider-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try """
        cli_auth_credentials_store = "file"
        model_provider = "custom"
        [model_providers.custom]
        name = "OpenAI"
        base_url = "https://example.invalid/v1"
        requires_openai_auth = true
        supports_websockets = true
        wire_api = "responses"
        """.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        var env = ProcessInfo.processInfo.environment
        for key in ["CODEX_SQLITE_HOME", "CODEX_API_KEY", "OPENAI_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_FEDERATION_RULE_ID", "OPENAI_IDENTITY_TOKEN_FILE", "OPENAI_WORKLOAD_IDENTITY_CONTEXT"] { env.removeValue(forKey: key) }
        env["CODEX_HOME"] = home.path
        guard (try? CodexExecutable.find(environment: env)) != nil else { throw XCTSkip("Codex CLI unavailable") }
        var service = CodexService(environment: env)
        service.preferAvailableSharedHistory = true
        XCTAssertFalse(try service.readCurrent().usesSharedOfficialProvider)
        let api = CodexProfile(id: UUID(), name: "API", kind: .openai, model: nil, baseURL: nil, hasSecret: true)
        try service.activate(api, secret: "sk-fake-only") { _ in XCTFail("Unexpected browser login"); return false }
        XCTAssertEqual(try service.readCurrent().provider, "openai")
    }

    func testRealCodexSwitchesFromFakeChatGPTToAPIKey() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cam-real-api-switch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try "cli_auth_credentials_store = \"file\"\n".write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let original = try realisticFakeChatGPTAuth(email: "account@example.invalid", subject: "fake-user", workspace: "fake-workspace")
        let files = FileCredentials(home: home)
        try files.replace(expected: nil, with: original)

        var env = ProcessInfo.processInfo.environment
        for key in ["CODEX_SQLITE_HOME", "CODEX_API_KEY", "OPENAI_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_FEDERATION_RULE_ID", "OPENAI_IDENTITY_TOKEN_FILE", "OPENAI_WORKLOAD_IDENTITY_CONTEXT"] { env.removeValue(forKey: key) }
        env["CODEX_HOME"] = home.path
        guard let executable = try? CodexExecutable.find(environment: env) else { throw XCTSkip("Codex CLI unavailable") }
        prepareCodexPath(&env, executable: executable)
        let service = CodexService(environment: env)
        XCTAssertEqual(try service.readCurrent().accountType, "chatgpt")
        let profile = CodexProfile(id: UUID(), name: "API", kind: .openai, model: nil, baseURL: nil, hasSecret: true)
        try service.activateAPIKey(profile, secret: "sk-test-only-not-a-real-key", expectedPrevious: original)
        XCTAssertEqual(try service.readCurrent().accountType, "apiKey")
        XCTAssertEqual(try files.read()?.fingerprint, CredentialSnapshot.fingerprint("api\0sk-test-only-not-a-real-key"))
    }

    func testRealCodexCanResumeSharedLocalThreadAfterFakeChatGPTSwitch() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("codex-shared-chatgpt-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try """
        cli_auth_credentials_store = "file"
        model_provider = "custom"
        [model_providers.custom]
        name = "OpenAI"
        requires_openai_auth = true
        supports_websockets = true
        wire_api = "responses"
        """.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let first = try realisticFakeChatGPTAuth(email: "first@example.invalid", subject: "fake-user-one", workspace: "fake-workspace-one")
        let second = try realisticFakeChatGPTAuth(email: "second@example.invalid", subject: "fake-user-two", workspace: "fake-workspace-two")
        let files = FileCredentials(home: home)
        try files.replace(expected: nil, with: first)
        let threadID = UUID().uuidString.lowercased(), time = "2026-10-30T12:00:00Z"
        let folder = home.appendingPathComponent("sessions/2026/10/30", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let thread = folder.appendingPathComponent("rollout-2026-10-30T12-00-00-\(threadID).jsonl")
        let events: [[String: Any]] = [
            ["timestamp": time, "type": "session_meta", "payload": ["id": threadID, "timestamp": time, "cwd": home.path, "originator": "codex_cli_rs", "cli_version": "0.153.4", "source": "cli", "model_provider": "custom", "creator_user_id": "fake-user-one", "creator_account_id": "fake-workspace-one"]],
            ["timestamp": time, "type": "event_msg", "payload": ["type": "user_message", "message": "sample", "images": [], "local_images": []]],
            ["timestamp": time, "type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "sample"]]]]
        ]
        var original = Data()
        for event in events { original.append(try JSONSerialization.data(withJSONObject: event)); original.append(10) }
        try original.write(to: thread)
        var env = ProcessInfo.processInfo.environment
        for key in ["CODEX_SQLITE_HOME", "CODEX_API_KEY", "OPENAI_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_FEDERATION_RULE_ID", "OPENAI_IDENTITY_TOKEN_FILE", "OPENAI_WORKLOAD_IDENTITY_CONTEXT"] { env.removeValue(forKey: key) }
        env["CODEX_HOME"] = home.path
        guard let executable = try? CodexExecutable.find(environment: env) else { throw XCTSkip("Codex CLI unavailable") }
        prepareCodexPath(&env, executable: executable)
        let service = CodexService(environment: env)
        XCTAssertEqual(try service.readCurrent().account, "first@example.invalid")
        let profile = CodexProfile(id: UUID(), name: "second", kind: .chatgpt, model: nil, baseURL: nil, hasSecret: true,
                                   accountID: try CredentialSnapshot(bytes: second).fingerprint)
        try service.activateSavedChatGPT(profile, credential: String(decoding: second, as: UTF8.self), expectedPrevious: first)
        XCTAssertEqual(try service.readCurrent().account, "second@example.invalid")
        XCTAssertEqual(try service.readCurrent().provider, "custom")
        XCTAssertEqual(try Data(contentsOf: thread), original)
        let client = try AppServerClient(executable: executable, environment: env); defer { client.close() }
        let list = try client.request("thread/list", ["modelProviders": ["custom"], "sourceKinds": ["cli"], "limit": 20])
        let threads = try XCTUnwrap(list["data"] as? [[String: Any]])
        XCTAssertTrue(threads.contains { $0["id"] as? String == threadID })
        XCTAssertNotNil(try client.request("thread/resume", ["threadId": threadID], timeout: 20)["thread"])
    }

    func testChangingProfileDirectoryDoesNotOverwriteExistingData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-profile-directory-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = ProfileStore(directory: root.appendingPathComponent("source"))
        let first = CodexProfile(id: UUID(), name: "example", kind: .chatgpt, model: nil, baseURL: nil, hasSecret: false)
        try source.save([first])
        let destination = root.appendingPathComponent("destination")
        let copied = try source.copyProfiles(to: destination, profiles: [first])
        XCTAssertEqual(try source.load(), [first])
        XCTAssertEqual(try copied.load(), [first])
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: copied.file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try source.copyProfiles(to: destination, profiles: [first]).directory.path, copied.directory.path)
        let other = CodexProfile(id: UUID(), name: "other", kind: .openai, model: nil, baseURL: nil, hasSecret: false)
        try copied.save([other])
        XCTAssertThrowsError(try source.copyProfiles(to: destination, profiles: [first]))
        XCTAssertEqual(try copied.load(), [other])
        XCTAssertEqual(try source.load(), [first])
    }

    func testChangingProfileDirectoryCopiesCredentialsWithoutOverwritingConflicts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cam-file-copy-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = ProfileStore(directory: root.appendingPathComponent("source"))
        let targetDirectory = root.appendingPathComponent("target")
        let account = CodexProfile(id: UUID(), name: "account", kind: .chatgpt, model: nil, baseURL: nil, hasSecret: true)
        let api = CodexProfile(id: UUID(), name: "api", kind: .openai, model: nil, baseURL: nil, hasSecret: true)
        let profiles = [account, api]
        let auth = try chatGPTAuth(email: "one@example.invalid", subject: "one", workspace: "one", refresh: "fake-one")
        let sourceFiles = SavedCredentialFiles(root: source.directory)
        try sourceFiles.save(String(decoding: auth, as: UTF8.self), id: account.id)
        try sourceFiles.save("sk-fake-old", id: api.id)
        try source.save(profiles)
        let copied = try source.copyProfiles(to: targetDirectory, profiles: profiles)
        let copiedFiles = SavedCredentialFiles(root: copied.directory)
        XCTAssertEqual(try copied.load(), profiles)
        XCTAssertEqual(try copiedFiles.load(id: account.id), String(decoding: auth, as: UTF8.self))
        XCTAssertEqual(try copiedFiles.load(id: api.id), "sk-fake-old")
        XCTAssertEqual(try sourceFiles.load(id: api.id), "sk-fake-old")

        try copiedFiles.save("sk-fake-different", id: api.id)
        XCTAssertThrowsError(try source.copyProfiles(to: targetDirectory, profiles: profiles)) {
            guard case StoreError.destinationHasCredentials = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertEqual(try copiedFiles.load(id: api.id), "sk-fake-different")
        XCTAssertEqual(try sourceFiles.load(id: api.id), "sk-fake-old")
        XCTAssertEqual(try copied.load(), profiles)
    }

    @MainActor
    func testCodexHomeUsesLaunchEnvironmentAndDefault() throws {
        let userHome = URL(fileURLWithPath: "/private/tmp/cam-home-fixture", isDirectory: true)
        XCTAssertEqual(CodexHome.resolve(environment: [:], userHome: userHome).path, userHome.appendingPathComponent(".codex").path)
        XCTAssertEqual(CodexHome.resolve(environment: ["CODEX_HOME": "   "], userHome: userHome).path, userHome.appendingPathComponent(".codex").path)
        let custom = userHome.appendingPathComponent("custom-codex", isDirectory: true)
        let environment = ["CODEX_HOME": "  \(custom.path)  "]
        XCTAssertEqual(CodexHome.resolve(environment: environment, userHome: userHome).path, custom.path)
        XCTAssertEqual(CodexService(environment: environment).fileCredentials().home.path, custom.path)

        let suite = "local.cam.home-test." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let state = AppState(demo: true, preferences: preferences, environment: environment)
        XCTAssertEqual(state.detectedCodexHome, custom.path)
        XCTAssertEqual(state.profileDirectory, "~/.cam")
        XCTAssertEqual(ProfileStore.standard().directory.lastPathComponent, ".cam")
    }

    func testCodexProcessAndCredentialReaderUseSameDetectedHome() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cam-detected-home-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(#"{"OPENAI_API_KEY":"sk-test-fixture"}"#.utf8).write(to: home.appendingPathComponent("auth.json"))
        var environment = ProcessInfo.processInfo.environment
        for key in ["CODEX_API_KEY", "OPENAI_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_FEDERATION_RULE_ID", "OPENAI_IDENTITY_TOKEN_FILE", "OPENAI_WORKLOAD_IDENTITY_CONTEXT"] { environment.removeValue(forKey: key) }
        environment["CODEX_HOME"] = "  \(home.path)  "
        let service = CodexService(environment: environment, executableOverride: try fixture("mock_codex"))
        let current = try service.readCurrent()
        XCTAssertEqual(current.accountType, "apiKey")
        XCTAssertNotNil(current.credentialFingerprint)
    }

    func testCodexProcessExitWaitKeepsIndependentSessionsProtected() throws {
        var elapsed: TimeInterval = 0
        var checks = 0
        try waitForCodexCLIToExit(maximumWait: 1, now: { elapsed }, sleep: { elapsed += $0 }) {
            checks += 1
            return checks < 3
        }
        XCTAssertEqual(checks, 3)
        XCTAssertEqual(elapsed, 0.5, accuracy: 0.001)

        checks = 0
        elapsed = 0
        XCTAssertThrowsError(try waitForCodexCLIToExit(maximumWait: 0, now: { elapsed }, sleep: { elapsed += $0 }) {
            checks += 1
            return true
        }) { error in
            guard case CodexError.codexStillRunning = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(checks, 1)
        XCTAssertEqual(elapsed, 0)

        checks = 0
        XCTAssertThrowsError(try waitForCodexCLIToExit(maximumWait: 0.5, now: { elapsed }, sleep: { elapsed += $0 }) {
            checks += 1
            return true
        }) { error in
            guard case CodexError.codexStillRunning = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(checks, 3)
        XCTAssertEqual(elapsed, 0.5, accuracy: 0.001)
        XCTAssertThrowsError(try waitForCodexCLIToExit(maximumWait: 1) { throw CodexError.processCheckFailed }) { error in
            guard case CodexError.processCheckFailed = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testDiagnosticLogHonorsLevelAndDisable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-diagnostics-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = DiagnosticLog(directory: root, enabled: true, level: .warning)
        log.record(.switchStarted)
        log.record(.switchFailed, level: .error)
        let file = try log.fileForOpening()
        let first = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(first.contains("切换登录失败"))
        XCTAssertFalse(first.contains("开始切换登录"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        log.configure(directory: root, enabled: true, level: .info)
        log.record(.switchAccountStarted)
        log.record(.switchAPIKeyStarted)
        let withTargets = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(withTargets.contains("开始切换账号登录"))
        XCTAssertTrue(withTargets.contains("开始切换 API Key 登录"))
        log.configure(directory: root, enabled: false, level: .trace)
        log.record(.started)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), withTargets)
    }
}
