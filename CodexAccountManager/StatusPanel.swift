import SwiftUI

private enum StatusPanelTab: String, CaseIterable {
    case configuration = "配置"
    case quota = "额度"
}

struct StatusPanelView: View {
    @ObservedObject var state: AppState
    let close: () -> Void
    let openMain: () -> Void
    let openSettings: () -> Void
    let quit: () -> Void

    @State private var tab: StatusPanelTab = .configuration
    @State private var selectedKind: ProfileKind?
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                if let selectedKind {
                    profiles(for: selectedKind)
                } else {
                    VStack(spacing: 0) {
                        tabs
                        if tab == .configuration { configuration }
                        else { quota }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            notice
            footer
        }
        .frame(width: 320, height: 270)
        .foregroundStyle(PanelColors.text)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let selectedKind {
                Button {
                    self.selectedKind = nil
                    query = ""
                } label: {
                    Label(title(for: selectedKind), systemImage: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                }.buttonStyle(.plain).help("返回")
            } else {
                Text("CAM").font(.system(size: 16, weight: .semibold))
            }
            Spacer()
            Button { close(); openSettings() } label: {
                Image(systemName: "gearshape").font(.system(size: 15))
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(PanelColors.secondary).help("设置").accessibilityLabel("设置")
        }.padding(.horizontal, 16).frame(height: 48)
    }

    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(StatusPanelTab.allCases, id: \.self) { item in
                Button { tab = item } label: {
                    Text(item.rawValue).font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity).frame(height: 28)
                        .foregroundStyle(tab == item ? PanelColors.text : PanelColors.secondary)
                        .background(tab == item ? Color.primary.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).accessibilityLabel(item.rawValue)
            }
        }.padding(3).background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9)).padding(.horizontal, 12)
    }

    private var configuration: some View {
        VStack(spacing: 4) {
            groupRow(.chatgpt)
            groupRow(.openai)
        }.padding(.horizontal, 12).padding(.top, 10).frame(maxHeight: .infinity, alignment: .top)
    }

    private func groupRow(_ kind: ProfileKind) -> some View {
        Button {
            query = ""
            selectedKind = kind
        } label: {
            HStack(spacing: 10) {
                Image(systemName: kind.icon).font(.system(size: 16))
                    .foregroundStyle(PanelColors.secondary).frame(width: 36, height: 36)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title(for: kind)).font(.system(size: 13, weight: .semibold))
                    Text(summary(for: kind)).font(.system(size: 11)).foregroundStyle(PanelColors.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(PanelColors.muted)
            }.frame(maxWidth: .infinity, minHeight: 58, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(StatusPanelRowStyle()).accessibilityLabel(title(for: kind))
    }

    private func profiles(for kind: ProfileKind) -> some View {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = state.profiles.filter { profile in
            profile.kind == kind && state.shouldDisplayProfile(profile) &&
            (term.isEmpty || state.profileDisplayName(profile).localizedCaseInsensitiveContains(term) ||
             (profile.accountEmail?.localizedCaseInsensitiveContains(term) ?? false))
        }
        let ordered = saved.filter { state.isCurrent($0) } + saved.filter { !state.isCurrent($0) }
        let current = state.currentLoginWithoutProfile(for: kind).flatMap { item in
            term.isEmpty || item.name.localizedCaseInsensitiveContains(term) ||
            (item.accountEmail?.localizedCaseInsensitiveContains(term) ?? false) ? item : nil
        }
        return VStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(PanelColors.muted)
                TextField("搜索账号或配置", text: $query).textFieldStyle(.plain)
            }.font(.system(size: 12)).padding(.horizontal, 10).frame(height: 32)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.10), lineWidth: 1).allowsHitTesting(false))
            ScrollView {
                VStack(spacing: 3) {
                    if let current {
                        profileLabel(name: current.name, email: current.accountEmail,
                                     plan: current.kind == .chatgpt ? ChatGPTPlan.title(current.accountPlanType) : nil,
                                     status: state.current.isOfficialProvider ? "使用中" : "当前登录")
                    }
                    ForEach(ordered) { profile in
                        if state.isCurrent(profile) {
                            profileLabel(name: state.profileDisplayName(profile), email: profile.accountEmail,
                                         plan: profile.kind == .chatgpt ? ChatGPTPlan.title(state.accountPlanType(for: profile)) : nil,
                                         status: "使用中")
                        } else {
                            Button {
                                close()
                                state.requestActivation(profile)
                            } label: {
                                profileLabel(name: state.profileDisplayName(profile), email: profile.accountEmail,
                                             plan: profile.kind == .chatgpt ? ChatGPTPlan.title(state.accountPlanType(for: profile)) : nil,
                                             status: state.matchesCurrentLogin(profile) ? "当前登录" : nil)
                            }.buttonStyle(StatusPanelRowStyle()).disabled(state.busy)
                        }
                    }
                    if current == nil && ordered.isEmpty {
                        Text(term.isEmpty ? "暂无配置" : "没有匹配的配置")
                            .font(.system(size: 12)).foregroundStyle(PanelColors.muted)
                            .frame(maxWidth: .infinity, minHeight: 64)
                    }
                }
            }.frame(maxHeight: .infinity)
        }.padding(.horizontal, 12).padding(.bottom, 8)
    }

    private func profileLabel(name: String, email: String?, plan: String?, status: String?) -> some View {
        let secondary = email.flatMap { $0.caseInsensitiveCompare(name) == .orderedSame ? nil : $0 }
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    if let plan { Text(plan).font(.system(size: 10)).foregroundStyle(PanelColors.accent) }
                }
                if let secondary {
                    Text(secondary).font(.system(size: 10)).foregroundStyle(PanelColors.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            if let status { Text(status).font(.system(size: 10, weight: .medium)).foregroundStyle(PanelColors.accent) }
            else { Image(systemName: "arrow.left.arrow.right").font(.system(size: 11)).foregroundStyle(PanelColors.muted) }
        }.frame(maxWidth: .infinity, minHeight: 42, alignment: .leading).padding(.horizontal, 8).contentShape(Rectangle())
    }

    private var quota: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("当前额度").font(.system(size: 12, weight: .semibold))
                if state.current.accountType == "chatgpt" {
                    Text(currentName).font(.system(size: 11)).foregroundStyle(PanelColors.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button { state.refresh(retryMissingPlanTypes: true) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(PanelColors.secondary)
                    .disabled(state.busy || state.currentQuotaLoading).help("刷新额度").accessibilityLabel("刷新额度")
            }
            if state.current.accountType == "chatgpt" {
                quotaContent
            } else {
                Text(state.current.accountType == "apiKey" ? "当前使用 API Key" : "当前没有官方账号登录")
                    .font(.system(size: 11)).foregroundStyle(PanelColors.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }.padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8).frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var quotaContent: some View {
        let presentation = state.currentQuotaPresentation
        if let quota = presentation.value {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(quota.buckets) { bucket in
                        if let title = bucket.title { Text(title).font(.system(size: 11, weight: .medium)) }
                        ForEach(bucket.windows) { window in quotaWindow(window) }
                        if let credits = bucket.credits { Text(credits).font(.system(size: 10)).foregroundStyle(PanelColors.secondary) }
                        if let value = bucket.individualLimit { Text(value.description).font(.system(size: 10)).foregroundStyle(PanelColors.secondary) }
                        if let reached = bucket.reached { Text(reached).font(.system(size: 10)).foregroundStyle(PanelColors.accent) }
                    }
                    if let count = quota.resetCredits { Text("可用重置次数：\(count)").font(.system(size: 10)).foregroundStyle(PanelColors.secondary) }
                    Text(presentation.isLoading ? "正在刷新额度…" :
                         (presentation.failed ? "刷新失败 · 上次查询 \(QuotaTime.format(quota.updatedAt))" : "更新于 \(QuotaTime.format(quota.updatedAt))"))
                        .font(.system(size: 10)).foregroundStyle(PanelColors.muted)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            HStack(spacing: 6) {
                if presentation.isLoading { ProgressView().controlSize(.small) }
                Text(presentation.isLoading ? "正在读取额度…" : (presentation.failed ? "额度暂不可用" : "额度尚未查询"))
                    .font(.system(size: 11)).foregroundStyle(PanelColors.muted)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func quotaWindow(_ window: QuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.title)
                Spacer()
                Text("剩余 \(window.remainingPercent)%").monospacedDigit()
            }
            GeometryReader { geometry in
                ZStack(alignment: .trailing) {
                    Capsule().fill(PanelColors.border)
                    Capsule().fill(PanelColors.accent).frame(width: geometry.size.width * CGFloat(window.remainingPercent) / 100)
                }
            }.frame(height: 4)
            if let reset = window.resetsAt { Text("\(QuotaTime.format(reset)) 重置").foregroundStyle(PanelColors.muted) }
        }.font(.system(size: 10)).foregroundStyle(PanelColors.secondary).accessibilityElement(children: .combine)
    }

    @ViewBuilder private var notice: some View {
        if state.busy {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(state.message.isEmpty ? "正在切换…" : state.message).lineLimit(2)
            }.font(.system(size: 10)).foregroundStyle(PanelColors.secondary).padding(.horizontal, 16).padding(.bottom, 8)
        } else if let pendingID = state.pendingProfileID, let profile = state.profiles.first(where: { $0.id == pendingID }) {
            HStack {
                Text("待切换：\(state.profileDisplayName(profile))").lineLimit(1)
                Spacer()
                Button("取消") { state.cancelPending(); state.setMessage("") }.buttonStyle(.plain)
            }.font(.system(size: 10)).foregroundStyle(PanelColors.secondary).padding(.horizontal, 16).padding(.bottom, 8)
        } else if state.isError && !state.message.isEmpty {
            Text(state.message).font(.system(size: 10)).foregroundStyle(Color.red).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 8)
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 1)
            HStack {
                Button { close(); openMain() } label: { Label("打开主面板", systemImage: "arrow.up.left.and.arrow.down.right") }
                Spacer()
                Button { close(); quit() } label: { Label("退出", systemImage: "power") }
            }.font(.system(size: 12)).buttonStyle(.plain).padding(.horizontal, 16).frame(height: 46)
        }
    }

    private func title(for kind: ProfileKind) -> String { kind == .chatgpt ? "官方账号" : "官方 API Key" }

    private func summary(for kind: ProfileKind) -> String {
        if let profile = state.profiles.first(where: { $0.kind == kind && state.isCurrent($0) }) {
            return state.profileDisplayName(profile)
        }
        if let current = state.currentLoginWithoutProfile(for: kind) { return current.name }
        let count = state.profiles.filter { $0.kind == kind && state.shouldDisplayProfile($0) }.count
        return count == 0 ? "暂无配置" : "\(count) 个已保存"
    }

    private var currentName: String {
        if let profile = state.profiles.first(where: { $0.kind == .chatgpt && state.matchesCurrentLogin($0) }) {
            return state.profileDisplayName(profile)
        }
        return state.current.currentLoginItem?.name ?? "当前账号"
    }
}

private struct StatusPanelRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { StatusPanelRow(configuration: configuration) }
}

private struct StatusPanelRow: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false

    var body: some View {
        configuration.label
            .background(hovering || configuration.isPressed ? Color.primary.opacity(0.08) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 9))
            .onHover { hovering = $0 }
    }
}
