import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .english: return "English"
        }
    }

    var locale: Locale {
        switch self {
        case .simplifiedChinese: return Locale(identifier: "zh_CN")
        case .traditionalChinese: return Locale(identifier: "zh_TW")
        case .english: return Locale(identifier: "en_US")
        }
    }
}

struct LocalizedTemplate: ExpressibleByStringInterpolation {
    let key: String
    let arguments: [String]

    init(stringLiteral value: String) { key = value; arguments = [] }
    init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key
        arguments = stringInterpolation.arguments
    }

    struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []

        init(literalCapacity: Int, interpolationCount: Int) {
            key.reserveCapacity(literalCapacity)
            arguments.reserveCapacity(interpolationCount)
        }
        mutating func appendLiteral(_ value: String) { key += value }
        mutating func appendInterpolation<T>(_ value: T) {
            key += "{\(arguments.count)}"
            arguments.append(String(describing: value))
        }
    }
}

enum Localization {
    private static let lock = NSLock()
    private static var selected: AppLanguage = .simplifiedChinese
    private static var traditionalCache: [String: String] = [:]
    private static let placeholderPattern = try! NSRegularExpression(pattern: #"\{([0-9]+)\}"#)

    static var language: AppLanguage {
        lock.lock(); defer { lock.unlock() }
        return selected
    }

    static func select(_ language: AppLanguage) {
        lock.lock(); defer { lock.unlock() }
        selected = language
    }

    static func text(_ key: String, arguments: [String] = [], language: AppLanguage? = nil) -> String {
        let selectedLanguage = language ?? self.language
        let template: String
        switch selectedLanguage {
        case .simplifiedChinese:
            template = key
        case .english:
            if arguments.first == "1", arguments.count == 1 {
                switch key {
                case "{0} 天": template = "{0} day"
                case "{0} 小时": template = "{0} hour"
                case "{0} 分钟": template = "{0} minute"
                default: template = english[key] ?? key
                }
            } else {
                template = english[key] ?? key
            }
        case .traditionalChinese:
            lock.lock()
            if let cached = traditionalCache[key] {
                template = cached
            } else {
                var value = key.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? key
                for (from, to) in traditionalTerms { value = value.replacingOccurrences(of: from, with: to) }
                traditionalCache[key] = value
                template = value
            }
            lock.unlock()
        }
        guard !arguments.isEmpty else { return template }
        let source = template as NSString
        let matches = placeholderPattern.matches(in: template, range: NSRange(location: 0, length: source.length))
        var result = "", position = 0
        for match in matches {
            result += source.substring(with: NSRange(location: position, length: match.range.location - position))
            let index = Int(source.substring(with: match.range(at: 1)))
            result += index.flatMap { arguments.indices.contains($0) ? arguments[$0] : nil } ?? source.substring(with: match.range)
            position = NSMaxRange(match.range)
        }
        result += source.substring(from: position)
        return result
    }

    private static let traditionalTerms: [(String, String)] = [
        ("賬號", "帳號"), ("賬戶", "帳戶"), ("設置", "設定"), ("啓", "啟"),
        ("密鑰", "金鑰"), ("數據", "資料"), ("信息", "資訊"), ("文件", "檔案"),
        ("默認", "預設"), ("設備", "裝置"), ("應用程序", "應用程式"), ("隱藏程序塢圖標", "隱藏 Dock 圖示"),
        ("程序塢", "Dock"), ("菜單欄", "選單列"), ("菜單", "選單"), ("圖標", "圖示"), ("登錄", "登入"),
        ("自啟", "自動啟動"), ("保存", "儲存"), ("窗口", "視窗"), ("進程", "程序"), ("鏈接", "連結"), ("界面", "介面")
    ]

    private static let english: [String: String] = [
        "展开详情": "Show details",
        "收起详情": "Hide details",
        "已展开": "Expanded",
        "已收起": "Collapsed",
        "账号额度": "Account usage limits",
        "刷新失败": "Refresh failed",
        "缓存": "Cached",
        "查询失败": "Query failed",
        "上次结果": "Previous result",
        "未配置用量查询": "Usage reporting not configured",
        "指定 Key": "Selected key",
        "项目": "Project",
        "API 用量": "API usage",
        "API 用量查询": "API usage reporting",
        "配置查询": "Configure",
        "刷新 API 用量": "Refresh API usage",
        "配置 Admin API Key 后，可查看本月费用、Token 用量与请求数。": "Add an Admin API key to view monthly costs, tokens, and requests.",
        "指定 Key · {0}": "Selected key · {0}",
        "项目 · {0}": "Project · {0}",
        "整个组织": "Entire organization",
        "本月费用": "Monthly cost",
        "输入 Token": "Input tokens",
        "输出 Token": "Output tokens",
        "生成请求数": "Generation requests",
        "输入中含缓存 Token：{0}": "Cached tokens included in input: {0}",
        "保留上次结果 · {0}": "Previous result retained · {0}",
        "正在查询 API 用量…": "Loading API usage…",
        "API 用量尚未查询": "API usage has not been retrieved",
        "费用包含所选范围内的 API 消费；Token 和请求数为生成用量。数据可能延迟。": "Costs cover API spend in the selected scope; tokens and requests cover generation. Data may be delayed.",
        "项目速率上限 · {0} 个模型": "Project rate limits · {0} models",
        "RPM：请求/分钟 · TPM：Token/分钟；显示配置上限，不代表剩余次数。": "RPM: requests/min · TPM: tokens/min. These are configured limits, not remaining capacity.",
        "项目未返回模型速率上限。": "No model rate limits were returned for this project.",
        "筛选模型": "Filter models",
        "没有匹配的模型": "No matching models",
        "填写项目 ID 可同时查看模型速率上限。": "Add a project ID to also view model rate limits.",
        "创建管理员密钥": "Create Admin API key",
        "留空保留现有管理员密钥": "Leave blank to keep the saved Admin API key",
        "管理员密钥单独保存在本机，用于查询费用、用量和项目限额。": "The Admin API key is stored separately on this Mac for cost, usage, and project limit queries.",
        "统计范围": "Reporting scope",
        "留空显示管理员密钥所属组织的总用量；填写 ID 可缩小统计范围。": "Leave IDs blank for totals across the Admin API key's organization, or enter IDs to narrow the scope.",
        "项目 ID（可选）": "Project ID (optional)",
        "API Key ID（可选）": "API key ID (optional)",
        "填写平台显示的 Key ID，不是 sk- 开头的调用密钥。": "Enter the key ID shown in the platform, not the secret starting with sk-.",
        "移除查询配置": "Remove reporting setup",
        "保存并查询": "Save and fetch",
        "保存当前配置后，可配置 API 用量查询。": "Save the current configuration to set up API usage reporting.",
        "保存当前配置": "Save current configuration",
        "在主面板配置 API 用量查询。": "Set up API usage reporting in the main panel.",
        "费用": "Costs",
        "生成用量": "Generation usage",
        "项目速率上限": "Project rate limits",
        "批处理 Token/天 {0}": "Batch tokens/day {0}",
        "请输入有效的 Admin API Key（sk-admin- 开头）。": "Enter a valid Admin API key starting with sk-admin-.",
        "未找到管理员密钥，请重新配置用量查询。": "Admin API key not found. Set up usage reporting again.",
        "项目 ID 应以 proj_ 开头，仅包含字母、数字、下划线或连字符。": "Project IDs must start with proj_ and contain only letters, numbers, underscores, or hyphens.",
        "Key ID 应以 key_ 开头；请填写 ID，而不是 sk- 开头的密钥。": "Enter a key ID starting with key_, not a secret starting with sk-.",
        "管理员密钥无效或已失效，请更新查询配置。": "The Admin API key is invalid or expired. Update your reporting setup.",
        "管理员密钥没有查询权限，请检查所属组织和权限。": "The Admin API key cannot access these statistics. Check its organization and permissions.",
        "查询范围不可用，请检查项目 ID 和 Key ID。": "The reporting scope is unavailable. Check the project ID and key ID.",
        "查询过于频繁，请稍后刷新。": "Too many requests. Refresh again later.",
        "无法连接 OpenAI，请稍后刷新。": "Unable to connect to OpenAI. Refresh again later.",
        "OpenAI 返回的数据不完整，请稍后刷新。": "OpenAI returned incomplete data. Refresh again later.",
        "全部": "All",
        "官方账号": "Official accounts",
        "官方 API Key": "Official API keys",
        "管理账号与 API Key": "Manage accounts and API keys",
        "管理已保存的官方账号": "Manage saved official accounts",
        "管理已保存的 API Key": "Manage saved API keys",
        "通用": "General",
        "配置": "Configuration",
        "关于": "About",
        "个性化外观与启动方式": "Customize appearance and startup",
        "管理存储位置与诊断日志": "Manage storage and diagnostic logs",
        "应用信息与使用说明": "App information and documentation",
        "切换到【{0}】": "Switch to “{0}”",
        "切换到 {0}": "Switch to {0}",
        "账号管理": "Account management",
        "返回": "Back",
        "设置": "Settings",
        "账户": "Accounts",
        "打开登录网页": "Open sign-in page",
        "复制登录链接": "Copy sign-in link",
        "已复制": "Copied",
        "取消登录": "Cancel sign-in",
        "刷新": "Refresh",
        "刷新额度": "Refresh usage limits",
        "刷新账号状态和额度（⌘R）": "Refresh account status and usage limits (⌘R)",
        "添加": "Add",
        "添加账号或 API Key": "Add an account or API key",
        "添加 API Key": "Add API key",
        "登录新账号": "Sign in to another account",
        "添加（⌘N）": "Add (⌘N)",
        "搜索账号或配置": "Search accounts or configurations",
        "搜索账号或配置（⌘F）": "Search accounts or configurations (⌘F)",
        "演示模式 · 模拟数据": "Demo mode · Sample data",
        "待切换：{0}": "Pending switch: {0}",
        "重试": "Retry",
        "取消": "Cancel",
        "关闭菜单": "Close menu",
        "删除已保存的配置？": "Delete this saved configuration?",
        "删除 {0}": "Delete {0}",
        "重新登录": "Sign in again",
        "删除": "Delete",
        "无法读取当前登录状态。": "Unable to read the current sign-in status.",
        "当前 Codex 配置未识别为官方配置。": "The current Codex configuration is not recognized as official.",
        "当前登录类型暂不支持。": "The current sign-in type is not supported.",
        "账号": "accounts",
        "还没有{0}": "No {0} yet",
        "没有匹配的配置": "No matching configurations",
        "使用中": "In use",
        "当前登录": "Currently signed in",
        "账号登录": "Account sign-in",
        "API Key 登录": "API key sign-in",
        "切换登录": "Switch sign-in",
        "尚未登录": "Not signed in",
        "更多操作": "More actions",
        "编辑 {0}": "Edit {0}",
        "正在读取额度…": "Loading usage limits…",
        "额度暂不可用": "Usage limits are unavailable",
        "切换后查看额度": "Switch to view usage limits",
        "额度尚未查询": "Usage limits have not been checked",
        "剩余 {0}%": "{0}% remaining",
        "{0} 重置": "Resets at {0}",
        "可用重置次数：{0}": "Available resets: {0}",
        "正在刷新额度…": "Refreshing usage limits…",
        "刷新失败 · 上次查询 {0}": "Refresh failed · Last checked {0}",
        "上次查询": "Last checked",
        "更新于": "Updated at",
        "会员类型：{0}": "Plan: {0}",
        "该会员类型无法归入当前显示的分类。": "This plan does not match the available categories.",
        "会员类型来自 Codex，具体订阅以 ChatGPT 设置为准。": "The plan comes from Codex. Check ChatGPT settings for subscription details.",
        "编辑账号": "Edit account",
        "编辑 API Key": "Edit API key",
        "修改本地别名": "Edit local alias",
        "修改本地配置": "Edit local configuration",
        "使用 ChatGPT 账号完成官方授权": "Complete official authorization with a ChatGPT account",
        "保存 OpenAI API Key 以便切换": "Save an OpenAI API key for switching",
        "登录方式": "Sign-in method",
        "自动打开浏览器": "Open browser automatically",
        "在浏览器中登录要添加的账号，完成后不会自动切换当前 Codex 登录。": "Sign in to the account in your browser. This will not change the current Codex login.",
        "名称": "Name",
        "例如：工作 API Key": "e.g. Work API key",
        "例如：个人账号": "e.g. Personal account",
        "留空保留现有密钥": "Leave blank to keep the existing key",
        "点击眼睛查看当前密钥": "Select the eye to view the current key",
        "当前使用的密钥由 Codex 管理，只能查看；更换请添加新的 API Key。": "The current key is managed by Codex and can only be viewed here. Add a new API key to replace it.",
        "隐藏 API Key": "Hide API key",
        "显示 API Key": "Show API key",
        "显示 {0}": "Show {0}",
        "密钥保存在本地凭据文件中，保存时不会验证有效性。": "Keys are stored in local credential files and are not validated when saved.",
        "开始登录": "Start sign-in",
        "保存": "Save",
        "在浏览器中授权": "Authorize in a browser",
        "输入一次性代码授权": "Authorize with a one-time code",
        "设备代码": "Device code",
        "复制代码": "Copy code",
        "如果浏览器已登录其他账号，可以复制链接到另一个浏览器或无痕窗口。": "If the browser is signed in to another account, copy the link to another browser or a private window.",
        "保存目录": "Save directories",
        "外观": "Appearance",
        "界面语言": "Interface language",
        "主题": "Theme",
        "窗口与启动": "Window and startup",
        "开机自启": "Launch at login",
        "登录 macOS 时启动应用。": "Start the app when you log in to macOS.",
        "静默启动": "Launch silently",
        "启动时仅显示菜单栏图标。": "Show only the menu bar icon at startup.",
        "关闭窗口后保留在菜单栏": "Keep in menu bar when window closes",
        "关闭后隐藏程序坞图标，仍可从菜单栏打开。": "Hide the Dock icon when closed; the app remains available from the menu bar.",
        "存储位置": "Storage",
        "应用配置目录": "App configuration directory",
        "默认位置": "Default location",
        "保存账号配置、凭据文件和应用诊断日志。": "Stores account configurations, credential files, and app diagnostics.",
        "统一 Codex 会话历史": "Unify Codex conversation history",
        "切换时保留已识别的官方共享分组，不会改写旧会话。": "Keep recognized official shared groups when switching, without rewriting old conversations.",
        "配置目录": "Configuration directory",
        "默认 Codex 配置目录": "Default Codex configuration directory",
        "自动读取启动环境中的 CODEX_HOME，未设置时使用 ~/.codex；也可以手动指定。": "Uses CODEX_HOME from the launch environment, or ~/.codex by default. You can also choose a directory.",
        "关闭后，下次切换可能使旧共享分组的会话暂时不显示。": "If disabled, old shared conversations may be temporarily hidden after the next switch.",
        "已识别现有的官方共享会话分组": "Existing official shared conversation group detected",
        "应用诊断日志": "App diagnostic log",
        "打开日志": "Open log",
        "启用应用诊断日志": "Enable app diagnostic log",
        "只记录应用事件，不记录账号、密钥或会话内容。": "Records app events only, not accounts, keys, or conversation contents.",
        "日志级别": "Log level",
        "设置输出的最低日志级别": "Set the minimum log level",
        "日志级别说明：": "Log levels:",
        "仅严重错误": "Critical errors only",
        "错误和警告信息": "Errors and warnings",
        "一般操作信息（默认）": "General activity (default)",
        "详细状态事件": "Detailed status events",
        "全部诊断事件": "All diagnostic events",
        "版本 v{0}": "Version v{0}",
        "使用说明": "Documentation",
        "检查更新": "Check for updates",
        "正在检查更新…": "Checking for updates…",
        "当前已是最新版本": "You have the latest version",
        "发现新版本 v{0}": "Version v{0} is available",
        "查看更新": "View update",
        "尚未找到正式发布版本": "No stable release is available yet",
        "检查更新失败，请检查网络后重试。": "Could not check for updates. Check your connection and try again.",
        "GitHub 请求受限，请稍后重试。": "GitHub rejected the request or rate limit was reached. Try again later.",
        "无法识别版本信息，请检查发布标签。": "Could not read the version. Check the release tag.",
        "许可证": "License",
        "选择目录": "Choose directory",
        "选择{0}": "Choose {0}",
        "恢复默认目录": "Restore default directory",
        "恢复默认{0}": "Restore default {0}",
        "额度": "Usage limits",
        "暂无配置": "No configurations",
        "当前额度": "Current usage limits",
        "当前使用 API Key": "Using an API key",
        "当前没有官方账号登录": "No official account is currently signed in",
        "更新于 {0}": "Updated at {0}",
        "正在切换…": "Switching…",
        "打开主面板": "Open main panel",
        "退出": "Quit",
        "{0} 个已保存": "{0} saved",
        "当前账号": "Current account",
        "编辑": "Edit",
        "撤销": "Undo",
        "重做": "Redo",
        "剪切": "Cut",
        "复制": "Copy",
        "粘贴": "Paste",
        "全选": "Select All",
        "切换未完成": "Switch incomplete",
        "好": "OK",
        "隐藏 {0}": "Hide {0}",
        "隐藏其他应用": "Hide Others",
        "显示全部": "Show All",
        "退出 {0}": "Quit {0}",
        "无法确定 Codex 应用的位置，请先手动退出后切换。": "Could not locate the Codex app. Quit it manually before switching.",
        "切换后需要重启 Codex": "Codex needs to restart after switching",
        "已选择“{0}”。立即重启时，应用会先退出 Codex，再完成切换并重新打开。选择稍后，将在 Codex 退出后完成切换。请先结束其他 Codex CLI 会话。": "“{0}” is selected. Restarting now will quit Codex, switch accounts, and reopen it. Choosing Later will switch after Codex quits. First close any other Codex CLI sessions.",
        "立即重启": "Restart now",
        "稍后": "Later",
        "ChatGPT 账号": "ChatGPT account",
        "第三方 API": "Third-party API",
        "次要额度": "Secondary limit",
        "主要额度": "Primary limit",
        "{0} 天": "{0} days",
        "{0} 小时": "{0} hours",
        "{0} 分钟": "{0} minutes",
        "个人已用 {0} / {1} · 剩余 {2}%": "Personal usage {0} / {1} · {2}% remaining",
        " · {0} 重置": " · Resets at {0}",
        "OpenAI（共享会话）": "OpenAI (shared conversations)",
        "当前官方账号": "Current official account",
        "当前 API Key": "Current API key",
        "请输入 1–64 个字符的配置名称。": "Enter a configuration name of 1–64 characters.",
        "名称已存在，请使用其他名称。": "This name is already in use. Choose another name.",
        "第三方 API 需要有效的模型名称。": "A third-party API requires a valid model name.",
        "请输入不含凭据、查询参数或片段的 HTTPS 地址；本机服务可使用 HTTP。": "Enter an HTTPS URL without credentials, query parameters, or fragments. HTTP is allowed for local services.",
        "请输入 API Key。": "Enter an API key.",
        "找不到 Codex CLI。请安装 Codex，并确保 codex 在常用路径中。": "Codex CLI was not found. Install Codex and make sure codex is on a standard path.",
        "无法启动 Codex 服务，请检查本机配置。": "Could not start the Codex service. Check the local configuration.",
        "Codex 响应超时，请重试。": "Codex timed out. Try again.",
        "Codex 未能完成操作，请检查配置和组织策略。": "Codex could not complete the operation. Check the configuration and organization policies.",
        "Codex 配置在操作期间发生变化，请刷新后重试。": "The Codex configuration changed during the operation. Refresh and try again.",
        "Codex 登录未完成，请重试。": "Codex sign-in was not completed. Try again.",
        "登录未完成或已取消。": "Sign-in was not completed or was cancelled.",
        "Codex 返回了无效的登录地址。": "Codex returned an invalid sign-in URL.",
        "无法打开浏览器，登录已取消。": "Could not open the browser. Sign-in was cancelled.",
        "无法启动设备代码登录。请确认 ChatGPT 安全设置中已启用设备代码登录，或改用浏览器登录。": "Could not start device-code sign-in. Enable it in ChatGPT security settings or use browser sign-in.",
        "配置已写入，但被更高优先级的设置覆盖。请检查组织或项目配置。": "The configuration was saved but overridden by a higher-priority setting. Check organization or project settings.",
        "切换未完成，当前登录或 Codex 配置可能已改变。请检查当前状态后重试。": "The switch was not completed. The current login or Codex configuration may have changed. Check the status and try again.",
        "切换未完成，已恢复原登录凭据。请检查 Codex 配置后重试。": "The switch was not completed; the previous credentials were restored. Check the Codex configuration and try again.",
        "找不到应用内的凭据读取程序。": "The app's credential helper could not be found.",
        "请先切换到其他配置，再删除当前使用的第三方服务。": "Switch to another configuration before deleting the current third-party service.",
        "当前环境通过变量或组织身份控制登录，无法可靠切换。请先检查 Codex 身份设置。": "Environment variables or organization identity settings control sign-in, so switching cannot be performed reliably. Check Codex identity settings.",
        "当前 Codex 凭据不是文件存储，暂不支持保存或切换官方账号。未更改登录状态。": "The current Codex credentials are not stored in a file. Saving or switching official accounts is not supported. The current login was not changed.",
        "无法安全识别 Codex 登录凭据，未更改登录状态。请检查或重新登录。": "Could not safely identify Codex credentials. The current login was not changed. Check credentials or sign in again.",
        "Codex 的 OpenAI 地址被自定义，无法确认是否为官方服务地址。请先检查 openai_base_url。": "The OpenAI endpoint in Codex is customized and cannot be verified as official. Check openai_base_url.",
        "登录的账号或工作区与所选账号不一致，CAM 未切换当前 Codex 登录。请重新选择账号。": "The signed-in account or workspace does not match the selected account. CAM did not change the current Codex login. Choose the account again.",
        "请先退出正在运行的 Codex 桌面版和 CLI，再从菜单切换。切换后重新打开。": "Quit the running Codex desktop app and CLI sessions before switching from the menu. Reopen them afterward.",
        "无法检查运行中的 Codex 进程，未更改登录状态。": "Could not check running Codex processes. The current login was not changed.",
        "无法退出 Codex 桌面版，未更改登录状态。请先手动退出后重试。": "Could not quit Codex desktop. The current login was not changed. Quit it manually and try again.",
        "Codex 登录方式或工作区受到限制，暂不支持切换；未更改登录状态。": "The Codex sign-in method or workspace is restricted, so switching is unavailable. The current login was not changed.",
        "账号资料保存未完成，无法确认已保存凭据是否恢复。CAM 未切换当前登录，请检查账号后重试。": "Account details could not be saved, and the saved credentials could not be confirmed as restored. CAM did not switch the Codex login. Check the account and try again.",
        "浏览器登录": "Browser sign-in",
        "设备代码登录": "Device-code sign-in",
        "未找到此配置的密钥，请重新保存。": "The key for this configuration was not found. Save it again.",
        "保存的密钥无法读取，请重新保存。": "The saved key could not be read. Save it again.",
        "请输入有效的绝对目录路径。": "Enter a valid absolute directory path.",
        "目标目录已有不同的配置，请选择空目录，避免覆盖。": "The destination already contains different configurations. Choose an empty directory to avoid overwriting them.",
        "目标目录已有不同的凭据文件，请选择其他目录，避免覆盖。": "The destination already contains different credential files. Choose another directory to avoid overwriting them.",
        "无法安全读写凭据文件，请检查应用配置目录的权限。": "Cannot safely read or write credential files. Check permissions on the app configuration directory.",
        "错误": "Error",
        "警告": "Warning",
        "信息": "Info",
        "调试": "Debug",
        "详细": "Trace",
        "跟随系统": "System",
        "浅色": "Light",
        "深色": "Dark",
        "无法读取已保存的配置，请检查本机文件。": "Could not read saved configurations. Check the local files.",
        "请在系统设置的登录项中允许此应用开机启动。": "Allow this app in Login Items in System Settings to launch it at login.",
        "无法更改开机自启，请检查系统设置中的登录项。": "Could not change launch at login. Check Login Items in System Settings.",
        "演示模式不会保存设置。": "Demo mode does not save settings.",
        "会话设置已保存，将在下次切换账号时生效。": "Conversation settings saved. They will take effect on the next switch.",
        "演示模式不会打开真实日志。": "Demo mode does not open real logs.",
        "无法打开诊断日志，请检查存储目录。": "Could not open the diagnostic log. Check the storage directory.",
        "已暂存 {0}。退出 Codex 后自动切换。": "{0} is queued. The switch will happen when Codex quits.",
        "正在保存别名…": "Saving alias…",
        "应用目录已保存，原配置文件保留。": "App directory saved. The original configuration files remain in place.",
        "目录设置已保存。": "Directory settings saved.",
        "请先完成官方账号登录。": "Complete official account sign-in first.",
        "已添加模拟配置。": "Demo configuration added.",
        "配置已保存。": "Configuration saved.",
        "演示模式不会添加真实账号。": "Demo mode cannot add real accounts.",
        "正在启动{0}…": "Starting {0}…",
        "登录成功，正在读取账号信息…": "Sign-in successful. Loading account information…",
        "请复制登录链接，在要使用的浏览器中打开并完成登录。": "Copy the sign-in link and open it in the browser you want to use.",
        "请在浏览器登录要添加的账号。": "Sign in to the account you want to add in the browser.",
        "请在授权网页登录要添加的账号并输入设备代码。": "Sign in to the account on the authorization page and enter the device code.",
        "未能自动打开浏览器，请打开或复制登录链接。": "Could not open the browser automatically. Open or copy the sign-in link.",
        "登录成功，正在保存账号…": "Sign-in successful. Saving account…",
        "账号已添加。": "Account added.",
        "已取消添加账号。": "Account addition cancelled.",
        "正在取消登录…": "Cancelling sign-in…",
        "当前使用中的配置不能删除，请先切换到其他配置。": "The configuration in use cannot be deleted. Switch to another configuration first.",
        "模拟配置已移除。": "Demo configuration removed.",
        "正在移除配置…": "Removing configuration…",
        "配置已移除。": "Configuration removed.",
        "未能完整移除配置：": "Could not fully remove the configuration: ",
        "演示模式不会修改 Codex 配置或登录状态。": "Demo mode does not change Codex configuration or login status.",
        "正在准备官方浏览器登录…": "Preparing official browser sign-in…",
        "正在切换默认配置…": "Switching default configuration…",
        "登录成功，正在核对账号…": "Sign-in successful. Verifying account…",
        "请在浏览器登录所选账号。": "Sign in to the selected account in your browser.",
        "未能自动打开浏览器，请复制登录链接。": "Could not open the browser automatically. Copy the sign-in link.",
        "账号已核对，正在保存并切换…": "Account verified. Saving and switching…",
        "无法自动重新打开 Codex，请从应用程序中手动打开。": "Could not reopen Codex automatically. Open it manually from Applications.",
        "已切换。重新打开 Codex 后生效。": "Switched. The change takes effect when Codex is reopened.",
        "已切换，正在重新打开 Codex。": "Switched. Reopening Codex…",
        "已取消重新登录。": "Reauthentication cancelled.",
        "该账号已添加。请登录其他账号；如需更新登录，请在账号菜单中选择“重新登录”。": "This account has already been added. Sign in with another account; to update its login, choose “Sign in again” from the account menu.",
        "这是当前正在使用的账号，请登录其他账号。": "This account is currently in use. Sign in with another account.",
        "积分：不限": "Credits: unlimited",
        "积分：{0}": "Credits: {0}",
        "积分：可用": "Credits: available",
        "积分：不可用": "Credits: unavailable",
        "积分可用": "Credits available",
        "无可用积分": "No credits available",
        "已达到使用额度": "Usage limit reached",
        "工作区积分不足": "Workspace credits depleted",
        "个人积分不足": "Personal credits depleted",
        "工作区已达到使用额度": "Workspace usage limit reached",
        "个人已达到使用额度": "Personal usage limit reached",
    ]
}

func L(_ value: LocalizedTemplate) -> String {
    Localization.text(value.key, arguments: value.arguments)
}

func localizedQuotaCredits(_ value: String) -> String {
    if value == "积分：不限" {
        return Localization.text(value)
    }
    if value == "积分可用" { return L("积分：可用") }
    if value == "无可用积分" { return L("积分：不可用") }
    if value.hasPrefix("积分：") {
        let balance = String(value.dropFirst(3))
        return L("积分：\(normalizedCreditBalance(balance))")
    }
    return value
}

private func normalizedCreditBalance(_ value: String) -> String {
    guard value.range(of: #"^[+-]?[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
          let dot = value.firstIndex(of: ".") else { return value }
    let integer = String(value[..<dot])
    var fraction = String(value[value.index(after: dot)...])
    while fraction.last == "0" { fraction.removeLast() }
    let result = fraction.isEmpty ? integer : integer + "." + fraction
    if result == "-0" || result == "+0" { return "0" }
    return result
}
