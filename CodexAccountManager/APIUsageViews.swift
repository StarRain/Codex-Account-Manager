import SwiftUI

struct APIUsageCard: View {
    @ObservedObject var state: AppState
    let profile: CodexProfile

    var body: some View {
        let presentation = state.apiUsagePresentation(for: profile.id)
        CardDetailsSection(title: L("API 用量"), id: profile.id.uuidString) {
            overview(presentation)
        } details: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Button(L("配置查询")) { state.editingAPIUsage = profile }
                        .disabled(state.busy)
                    Spacer()
                    if profile.apiUsageSettings != nil {
                        Button { state.refreshAPIUsage(for: profile.id, force: true) } label: {
                            Group {
                                if presentation.isLoading { ProgressView().controlSize(.mini) }
                                else { Image(systemName: "arrow.clockwise") }
                            }.frame(width: 24, height: 24).contentShape(Rectangle())
                        }.disabled(state.busy || presentation.isLoading)
                            .help(L("刷新 API 用量")).accessibilityLabel(L("刷新 API 用量"))
                    }
                }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(PanelColors.accent)
                if let settings = profile.apiUsageSettings {
                    APIUsageSummary(settings: settings, presentation: presentation)
                } else {
                    Text(L("配置 Admin API Key 后，可查看本月费用、Token 用量与请求数。"))
                        .font(.system(size: 11)).foregroundStyle(PanelColors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }.onAppear { state.refreshAPIUsage(for: profile.id) }
    }

    private func overview(_ presentation: APIUsagePresentation) -> some View {
        HStack(spacing: 8) {
            if presentation.isLoading { ProgressView().controlSize(.mini) }
            if let settings = profile.apiUsageSettings {
                Text(overviewText(settings, presentation)).lineLimit(1).truncationMode(.tail).monospacedDigit()
                    .help(settings.scopeTitle + " · " + overviewText(settings, presentation))
                if !presentation.errors.isEmpty {
                    Label(L("查询失败"), systemImage: "exclamationmark.circle").foregroundStyle(.orange).fixedSize()
                }
            } else {
                Text(L("未配置用量查询")).foregroundStyle(PanelColors.muted)
            }
        }.font(.system(size: 11)).foregroundStyle(PanelColors.secondary)
    }

    private func overviewText(_ settings: APIUsageSettings, _ presentation: APIUsagePresentation) -> String {
        let scope = settings.apiKeyID != nil ? L("指定 Key") : settings.projectID != nil ? L("项目") : L("整个组织")
        var values = [scope]
        if let cost = presentation.snapshot?.cost?.value { values.append("\(L("本月费用")) \(cost.formatted)") }
        if let usage = presentation.snapshot?.usage?.value { values.append("\(L("生成请求数")) \(APIUsageFormat.count(usage.requests))") }
        if values.count == 1 {
            values.append(presentation.isLoading ? L("正在查询 API 用量…") : L("API 用量尚未查询"))
        } else if !presentation.errors.isEmpty {
            values.append(L("上次结果"))
        }
        return values.joined(separator: "  ·  ")
    }
}

struct APIUsageSummary: View {
    let settings: APIUsageSettings
    let presentation: APIUsagePresentation
    var compact = false
    @State private var modelFilter = ""

    var body: some View {
        let snapshot = presentation.snapshot
        VStack(alignment: .leading, spacing: compact ? 7 : 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(settings.scopeTitle).font(.system(size: compact ? 10 : 11, weight: .medium))
                    .lineLimit(compact ? 1 : 2).truncationMode(.middle).help(settings.scopeTitle)
                if settings.apiKeyID != nil, let project = settings.projectID {
                    Text(L("项目 · \(project)")).font(.system(size: 10)).lineLimit(1).truncationMode(.middle)
                }
                Text(APIUsageFormat.month(snapshot?.monthStart ?? APIUsageFormat.monthStart(at: Date())))
                    .font(.system(size: 10)).foregroundStyle(PanelColors.muted)
            }.foregroundStyle(PanelColors.secondary)
            LazyVGrid(columns: compact ? [GridItem(.flexible()), GridItem(.flexible())] : [GridItem(.adaptive(minimum: 130))], alignment: .leading, spacing: 10) {
                metric(L("本月费用"), snapshot?.cost?.value.formatted)
                metric(L("输入 Token"), snapshot?.usage.map { APIUsageFormat.count($0.value.inputTokens) })
                metric(L("输出 Token"), snapshot?.usage.map { APIUsageFormat.count($0.value.outputTokens) })
                metric(L("生成请求数"), snapshot?.usage.map { APIUsageFormat.count($0.value.requests) })
            }
            if let cached = snapshot?.usage?.value.cachedInputTokens {
                Text(L("输入中含缓存 Token：\(APIUsageFormat.count(cached))"))
                    .font(.system(size: 10)).foregroundStyle(PanelColors.secondary)
            }
            ForEach(APIUsageSection.allCases) { section in
                if let error = presentation.errors[section] {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(section.title)：\(error.localizedDescription)")
                        if let date = cachedDate(for: section) {
                            Text(L("保留上次结果 · \(QuotaTime.format(date))"))
                        }
                    }.font(.system(size: 10)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 6) {
                if presentation.isLoading { ProgressView().controlSize(.mini) }
                Text(presentation.isLoading ? L("正在查询 API 用量…") :
                        snapshot?.latestUpdate.map { L("更新于 \(QuotaTime.format($0))") } ?? L("API 用量尚未查询"))
            }.font(.system(size: 10)).foregroundStyle(PanelColors.muted)
            if !compact {
                rateLimits
                Text(L("费用包含所选范围内的 API 消费；Token 和请求数为生成用量。数据可能延迟。"))
                    .font(.system(size: 10)).foregroundStyle(PanelColors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metric(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10)).foregroundStyle(PanelColors.secondary)
            Text(value ?? "—").font(.system(size: compact ? 12 : 15, weight: .semibold)).monospacedDigit()
                .foregroundStyle(PanelColors.text).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cachedDate(for section: APIUsageSection) -> Date? {
        switch section {
        case .cost: return presentation.snapshot?.cost?.updatedAt
        case .usage: return presentation.snapshot?.usage?.updatedAt
        case .rateLimits: return presentation.snapshot?.rateLimits?.updatedAt
        }
    }

    @ViewBuilder private var rateLimits: some View {
        if let limits = presentation.snapshot?.rateLimits?.value {
            DisclosureGroup(L("项目速率上限 · \(limits.count) 个模型")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("RPM：请求/分钟 · TPM：Token/分钟；显示配置上限，不代表剩余次数。"))
                        .font(.system(size: 10)).foregroundStyle(PanelColors.muted)
                    if limits.isEmpty {
                        Text(L("项目未返回模型速率上限。")).foregroundStyle(PanelColors.secondary)
                    } else {
                        TextField(L("筛选模型"), text: $modelFilter).textFieldStyle(.roundedBorder)
                        let visible = limits.filter { modelFilter.isEmpty || $0.model.localizedCaseInsensitiveContains(modelFilter) }
                        if visible.isEmpty { Text(L("没有匹配的模型")).foregroundStyle(PanelColors.secondary) }
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(visible) { limit in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(limit.model).fontWeight(.medium).textSelection(.enabled)
                                        Text(limit.summary).foregroundStyle(PanelColors.secondary).textSelection(.enabled)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(height: min(CGFloat(visible.count) * 48, 190))
                    }
                }.padding(.top, 7).font(.system(size: 11))
            }.font(.system(size: 11)).foregroundStyle(PanelColors.secondary)
        } else if settings.projectID == nil {
            Text(L("填写项目 ID 可同时查看模型速率上限。"))
                .font(.system(size: 10)).foregroundStyle(PanelColors.muted)
        }
    }
}

struct APIUsageSettingsView: View {
    @ObservedObject var state: AppState
    let profile: CodexProfile
    @Environment(\.dismiss) private var dismiss
    @State private var adminKey = ""
    @State private var loadedAdminKey: String?
    @State private var projectID = ""
    @State private var apiKeyID = ""
    @State private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(L("API 用量查询")).font(.system(size: 19, weight: .semibold))
                Text(state.profileDisplayName(profile)).font(.system(size: 12)).foregroundStyle(PanelColors.secondary)
            }
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Admin API Key").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Link(L("创建管理员密钥"), destination: OpenAIUsageClient.adminKeysURL).font(.system(size: 11))
                }
                KeyInputField(title: "Admin API Key", text: $adminKey,
                              prompt: profile.apiUsageSettings == nil ? "sk-admin-…" : L("留空保留现有管理员密钥"))
                Text(L("管理员密钥单独保存在本机，用于查询费用、用量和项目限额。"))
                    .font(.system(size: 11)).foregroundStyle(PanelColors.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 9) {
                Text(L("统计范围")).font(.system(size: 12, weight: .medium))
                Text(L("留空显示管理员密钥所属组织的总用量；填写 ID 可缩小统计范围。"))
                    .font(.system(size: 11)).foregroundStyle(PanelColors.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("项目 ID（可选）")).font(.system(size: 11))
                    TextField("proj_…", text: $projectID).textFieldStyle(.roundedBorder).accessibilityLabel(L("项目 ID（可选）"))
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("API Key ID（可选）")).font(.system(size: 11))
                    KeyInputField(title: "API Key ID", text: $apiKeyID, prompt: "key_…")
                    Text(L("填写平台显示的 Key ID，不是 sk- 开头的调用密钥。"))
                        .font(.system(size: 10)).foregroundStyle(PanelColors.muted)
                }
            }
            if !error.isEmpty {
                Text(error).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                if profile.apiUsageSettings != nil {
                    Button(L("移除查询配置"), role: .destructive) {
                        do { try state.removeAPIUsageConfiguration(for: profile.id); adminKey = ""; dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.disabled(state.busy)
                }
                Spacer()
                Button(L("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("保存并查询")) {
                    do {
                        let replacement = loadedAdminKey != nil && adminKey == loadedAdminKey ? "" : adminKey
                        try state.configureAPIUsage(for: profile.id, adminKey: replacement, projectID: projectID, apiKeyID: apiKeyID)
                        adminKey = ""; dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(state.busy)
            }
        }.padding(24).frame(width: 520).background(PanelColors.background).foregroundStyle(PanelColors.text)
            .onAppear {
                projectID = profile.apiUsageSettings?.projectID ?? ""
                apiKeyID = profile.apiUsageSettings?.apiKeyID ?? ""
                if profile.apiUsageSettings != nil {
                    do {
                        adminKey = try state.savedAdminKey(for: profile.id)
                        loadedAdminKey = adminKey
                    } catch { self.error = error.localizedDescription }
                }
            }
            .onDisappear { adminKey = ""; loadedAdminKey = nil }
    }
}
