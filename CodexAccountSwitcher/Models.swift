import Foundation
import CoreFoundation

enum ProfileKind: String, Codable, CaseIterable, Identifiable {
    case chatgpt, openai, provider
    var id: String { rawValue }
    // Keep decoding older third-party profiles, but do not offer them in the app.
    static let supported: [ProfileKind] = [.chatgpt, .openai]
    var title: String {
        switch self {
        case .chatgpt: return "ChatGPT 账号"
        case .openai: return "OpenAI API Key"
        case .provider: return "第三方 API"
        }
    }
    var icon: String {
        switch self {
        case .chatgpt: return "person.crop.circle"
        case .openai: return "key.horizontal"
        case .provider: return "network"
        }
    }
}

struct CodexProfile: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var kind: ProfileKind
    var model: String?
    var baseURL: String?
    var hasSecret: Bool
    // Optional so configurations created by previous versions remain readable.
    var accountEmail: String? = nil
    var accountID: String? = nil
    var secretFingerprint: String? = nil
    var accountPlanType: String? = nil
    var lastQuota: AccountQuota? = nil
    var accountDisplayName: String? = nil
    var hasCustomName: Bool? = nil

    var providerID: String { "codex_switcher_" + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased() }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, model, baseURL, hasSecret, accountEmail, accountID, secretFingerprint, accountPlanType, lastQuota, accountDisplayName, hasCustomName
    }
}

extension CodexProfile {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        kind = try values.decode(ProfileKind.self, forKey: .kind)
        model = try values.decodeIfPresent(String.self, forKey: .model)
        baseURL = try values.decodeIfPresent(String.self, forKey: .baseURL)
        hasSecret = try values.decode(Bool.self, forKey: .hasSecret)
        accountEmail = try values.decodeIfPresent(String.self, forKey: .accountEmail)
        accountID = try values.decodeIfPresent(String.self, forKey: .accountID)
        secretFingerprint = try values.decodeIfPresent(String.self, forKey: .secretFingerprint)
        accountPlanType = try values.decodeIfPresent(String.self, forKey: .accountPlanType)
        // A damaged or newer cache must not make saved login profiles unreadable.
        lastQuota = try? values.decode(AccountQuota.self, forKey: .lastQuota)
        accountDisplayName = try values.decodeIfPresent(String.self, forKey: .accountDisplayName)
        hasCustomName = try values.decodeIfPresent(Bool.self, forKey: .hasCustomName)
    }
}

enum ChatGPTPlan {
    static let unknownTitle = "Unknown"

    /// Collapse known account plans into the four requested display groups.
    /// Do not assign a different plan to a group without a clear match.
    static func title(_ value: String?) -> String {
        switch knownValue(value)?.lowercased() {
        case "free": return "Free"
        case "plus": return "Plus"
        case "prolite", "pro", "promax": return "Pro"
        case "team", "self_serve_business_usage_based", "self_serve_business_prolite": return "Team"
        default: return unknownTitle
        }
    }

    static func knownValue(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.utf8.count <= 64, value.lowercased() != "unknown",
              value.range(of: "^[A-Za-z][A-Za-z0-9_]*$", options: .regularExpression) != nil else { return nil }
        return value
    }
}

struct QuotaWindow: Codable, Identifiable, Equatable {
    let id: String
    let usedPercent: Int
    let durationMinutes: Int?
    let resetsAt: Date?

    var remainingPercent: Int { 100 - min(max(usedPercent, 0), 100) }
    var title: String {
        guard let minutes = durationMinutes, minutes > 0 else { return id == "secondary" ? "次要额度" : "主要额度" }
        if minutes.isMultiple(of: 1440) { return "\(minutes / 1440) 天" }
        if minutes.isMultiple(of: 60) { return "\(minutes / 60) 小时" }
        return "\(minutes) 分钟"
    }
}

struct QuotaIndividualLimit: Codable, Equatable {
    let used: String
    let limit: String
    let remainingPercent: Int
    let resetsAt: Date?

    var description: String {
        let summary = "个人已用 \(used) / \(limit) · 剩余 \(remainingPercent)%"
        return resetsAt.map { summary + " · \(QuotaTime.format($0)) 重置" } ?? summary
    }
}

struct QuotaBucket: Codable, Identifiable, Equatable {
    let id: String
    let title: String?
    let windows: [QuotaWindow]
    let credits: String?
    let individualLimit: QuotaIndividualLimit?
    let reached: String?
}

struct AccountQuota: Codable, Equatable {
    let buckets: [QuotaBucket]
    let resetCredits: Int?
    let updatedAt: Date

    /// Decode only displayable fields; missing limits are never treated as zero.
    static func parse(_ result: [String: Any], updatedAt: Date = Date()) -> AccountQuota? {
        func safeText(_ value: Any?, limit: Int = 80) -> String? {
            guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, text.count <= limit,
                  !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
            return text
        }
        func integer(_ value: Any?) -> Int? {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue >= -1_000_000_000, number.doubleValue <= 1_000_000_000,
                  number.doubleValue.rounded() == number.doubleValue else { return nil }
            return number.intValue
        }
        func date(_ value: Any?) -> Date? {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let seconds = number.doubleValue
            guard seconds.isFinite, seconds > 0, seconds < 4_102_444_800 else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
        func window(_ value: Any?, id: String) -> QuotaWindow? {
            guard let object = value as? [String: Any], let used = integer(object["usedPercent"]), used >= 0, used <= 1_000_000 else { return nil }
            let rawDuration = integer(object["windowDurationMins"])
            let duration = rawDuration.flatMap { $0 > 0 && $0 <= 525_600_000 ? $0 : nil }
            return QuotaWindow(id: id, usedPercent: used, durationMinutes: duration, resetsAt: date(object["resetsAt"]))
        }
        func bucket(_ object: [String: Any], id: String, multiple: Bool) -> QuotaBucket? {
            let windows = [window(object["primary"], id: "primary"), window(object["secondary"], id: "secondary")].compactMap { $0 }
            let name = safeText(object["limitName"]) ?? (id == "codex" ? "Codex" : safeText(id))
            let title = multiple || id != "codex" ? name : nil
            var credits: String?
            if let info = object["credits"] as? [String: Any], let unlimited = info["unlimited"] as? Bool, let hasCredits = info["hasCredits"] as? Bool {
                if unlimited { credits = "积分：不限" }
                else if let balance = safeText(info["balance"], limit: 40) { credits = "积分：\(balance)" }
                else { credits = hasCredits ? "积分可用" : "无可用积分" }
            }
            var individual: QuotaIndividualLimit?
            if let info = object["individualLimit"] as? [String: Any],
               let used = safeText(info["used"], limit: 40), let limit = safeText(info["limit"], limit: 40),
               let remaining = integer(info["remainingPercent"]), (0...100).contains(remaining) {
                individual = QuotaIndividualLimit(used: used, limit: limit, remainingPercent: remaining, resetsAt: date(info["resetsAt"]))
            }
            let reached: String?
            switch object["rateLimitReachedType"] as? String {
            case "rate_limit_reached": reached = "已达到使用额度"
            case "workspace_owner_credits_depleted": reached = "工作区积分不足"
            case "workspace_member_credits_depleted": reached = "个人积分不足"
            case "workspace_owner_usage_limit_reached": reached = "工作区已达到使用额度"
            case "workspace_member_usage_limit_reached": reached = "个人已达到使用额度"
            default: reached = nil
            }
            guard !windows.isEmpty || credits != nil || individual != nil || reached != nil else { return nil }
            return QuotaBucket(id: id, title: title, windows: windows, credits: credits, individualLimit: individual, reached: reached)
        }

        let grouped = result["rateLimitsByLimitId"] as? [String: [String: Any]] ?? [:]
        let keys = grouped.keys.sorted { ($0 == "codex" ? "" : $0) < ($1 == "codex" ? "" : $1) }
        var buckets = keys.compactMap { key -> QuotaBucket? in
            guard let value = grouped[key] else { return nil }
            return bucket(value, id: key, multiple: keys.count > 1)
        }
        if buckets.isEmpty, let fallback = result["rateLimits"] as? [String: Any],
           let value = bucket(fallback, id: safeText(fallback["limitId"]) ?? "codex", multiple: false) { buckets = [value] }
        let reset = integer((result["rateLimitResetCredits"] as? [String: Any])?["availableCount"])
        let resetCredits = reset.flatMap { (0...1_000_000).contains($0) ? $0 : nil }
        guard !buckets.isEmpty || resetCredits != nil else { return nil }
        return AccountQuota(buckets: buckets, resetCredits: resetCredits, updatedAt: updatedAt)
    }
}

enum QuotaTime {
    static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { formatter.dateFormat = "HH:mm" }
        else if calendar.isDate(date, equalTo: Date(), toGranularity: .year) { formatter.dateFormat = "M月d日 HH:mm" }
        else { formatter.dateFormat = "yyyy年M月d日 HH:mm" }
        return formatter.string(from: date)
    }
}

struct QuotaPresentation {
    let value: AccountQuota?
    let isLoading: Bool
    let failed: Bool
    let isCached: Bool
}

struct CurrentLoginItem: Equatable {
    let kind: ProfileKind
    let name: String
    var accountPlanType: String? = nil
    var accountEmail: String? = nil
}

struct CurrentCodex: Equatable {
    var account: String?
    var accountType: String?
    var provider: String
    var providerHost: String? = nil
    var model: String?
    var configVersion: String?
    var configAvailable: Bool
    var accountAvailable: Bool
    var credentialStore: String = "unknown"
    var credentialFingerprint: String? = nil
    var customOpenAIEndpoint: Bool = false
    var authRestricted: Bool = false
    var usesSharedOfficialProvider: Bool = false
    var hasSharedOfficialProvider: Bool = false
    var accountPlanType: String? = nil
    var quotaEndpointIsOfficial: Bool = true
    var accountDisplayName: String? = nil

    var isOfficialProvider: Bool { !customOpenAIEndpoint && (provider == "openai" || usesSharedOfficialProvider) }
    var providerLabel: String { usesSharedOfficialProvider ? "OpenAI（共享会话）" : provider }

    var currentLoginItem: CurrentLoginItem? {
        guard configAvailable, accountAvailable else { return nil }
        switch accountType {
        case "chatgpt":
            let rawEmail = account?.trimmingCharacters(in: .whitespacesAndNewlines)
            let email = rawEmail.flatMap { $0.isEmpty ? nil : $0 }
            let name = accountDisplayName ?? email ?? "当前官方账号"
            let secondaryEmail = email.flatMap { $0.caseInsensitiveCompare(name) == .orderedSame ? nil : $0 }
            return CurrentLoginItem(kind: .chatgpt, name: name,
                                    accountPlanType: accountPlanType, accountEmail: secondaryEmail)
        case "apiKey":
            return CurrentLoginItem(kind: .openai, name: "当前 API Key")
        default:
            return nil
        }
    }

    static let unavailable = CurrentCodex(account: nil, accountType: nil, provider: "openai", model: nil, configVersion: nil, configAvailable: false, accountAvailable: false)
}

enum ProfileValidationError: LocalizedError {
    case invalidName, invalidModel, invalidURL, missingKey
    var errorDescription: String? {
        switch self {
        case .invalidName: return "请输入 1–64 个字符的配置名称。"
        case .invalidModel: return "第三方 API 需要有效的模型名称。"
        case .invalidURL: return "请输入不含凭据、查询参数或片段的 HTTPS 地址；本机服务可使用 HTTP。"
        case .missingKey: return "请输入 API Key。"
        }
    }
}

enum ProfileValidator {
    static func validated(name: String, kind: ProfileKind, model: String, baseURL: String, secret: String) throws -> (String, String?, String?, String?) {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 64, title.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { throw ProfileValidationError.invalidName }
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelPattern = "^[A-Za-z0-9][A-Za-z0-9_./:@+\\-]{0,199}$"
        guard model.isEmpty || model.range(of: modelPattern, options: .regularExpression) != nil else { throw ProfileValidationError.invalidModel }
        if kind == .provider && model.isEmpty { throw ProfileValidationError.invalidModel }
        var address: String?
        if kind == .provider {
            let value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parts = URLComponents(string: value), let host = parts.host?.lowercased(), !host.isEmpty,
                  parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
                  parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)),
                  !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) })
            else { throw ProfileValidationError.invalidURL }
            address = value.hasSuffix("/") ? String(value.dropLast()) : value
        }
        // Copying a key from a browser often includes surrounding whitespace.
        let key = kind == .chatgpt ? "" : secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.contains("\n"), !key.contains("\r"), !key.contains("\0"), key.utf8.count <= 16_384 else { throw ProfileValidationError.missingKey }
        if kind == .openai && key.isEmpty { throw ProfileValidationError.missingKey }
        return (title, model.isEmpty ? nil : model, address, key.isEmpty ? nil : key)
    }
}
