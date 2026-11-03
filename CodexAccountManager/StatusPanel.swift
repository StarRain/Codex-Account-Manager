import SwiftUI

enum StatusPanelLayout {
    static let width: CGFloat = 320
    static let height: CGFloat = 284
}

private enum StatusPanelTab: CaseIterable {
    case currentLogin, quota
    var title: String { self == .currentLogin ? L("当前登录") : L("额度") }
}

struct StatusPanelView: View {
    @ObservedObject var state: AppState
    let close: () -> Void
    let openMain: () -> Void
    let openSettings: () -> Void
    let quit: () -> Void

    @State private var tab: StatusPanelTab = .currentLogin
    @State private var showingSwitcher = false
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                if showingSwitcher {
                    switcher
                } else {
                    VStack(spacing: 0) {
                        tabs
                        if tab == .currentLogin { currentLogin }
                        else { quota }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            notice
            footer
        }
        .frame(width: StatusPanelLayout.width, height: StatusPanelLayout.height)
        .foregroundStyle(PanelColors.text)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if showingSwitcher {
                Button {
                    showingSwitcher = false
                    query = ""
                } label: {
                    Label(L("切换登录"), systemImage: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                }.buttonStyle(.plain).help(L("返回"))
            } else {
                Text(Branding.fullName).font(.system(size: 16, weight: .semibold)).lineLimit(1)
            }
            Spacer()
            Button { close(); openSettings() } label: {
                Image(systemName: "gearshape").font(.system(size: 15))
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(PanelColors.secondary).help(L("设置")).accessibilityLabel(L("设置"))
        }.padding(.horizontal, 16).frame(height: 48)
    }

    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(StatusPanelTab.allCases, id: \.self) { item in
                Button { tab = item } label: {
                    Text(item.title).font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity).frame(height: 28)
                        .contentShape(Rectangle())
                        .foregroundStyle(tab == item ? PanelColors.text : PanelColors.secondary)
                        .background(tab == item ? Color.primary.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).accessibilityLabel(item.title)
            }
        }.padding(3).background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9)).padding(.horizontal, 12)
    }

    private var currentLogin: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: state.currentLoginDisplayItem?.kind.icon ?? "person.crop.circle.badge.questionmark")
                    .font(.system(size: 16)).foregroundStyle(PanelColors.secondary)
                    .frame(width: 36, height: 36)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                if let item = state.currentLoginDisplayItem {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(item.kind == .chatgpt ? L("账号登录") : L("API Key 登录"))
                                .font(.system(size: 12, weight: .semibold))
                            Spacer(minLength: 4)
                            Text(state.current.isOfficialProvider ? L("使用中") : L("当前登录"))
                                .font(.system(size: 10, weight: .medium)).foregroundStyle(PanelColors.accent)
                        }
                        HStack(spacing: 6) {
                            Text(item.name).font(.system(size: 12, weight: .medium))
                                .lineLimit(1).truncationMode(.middle)
                            if item.kind == .chatgpt, let plan = item.accountPlanType {
                                Text(ChatGPTPlan.title(plan)).font(.system(size: 10)).foregroundStyle(PanelColors.accent)
                            }
                        }
                        if let email = item.accountEmail {
                            Text(email).font(.system(size: 10)).foregroundStyle(PanelColors.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(currentLoginUnavailableTitle).font(.system(size: 12, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                }
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            Button {
                query = ""
                showingSwitcher = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.left.arrow.right").frame(width: 36)
                    Text(L("切换登录"))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                }.font(.system(size: 12, weight: .medium)).foregroundStyle(PanelColors.secondary)
                    .frame(maxWidth: .infinity, minHeight: 42).contentShape(Rectangle())
            }.buttonStyle(StatusPanelRowStyle())
        }.padding(.horizontal, 12).padding(.top, 10).frame(maxHeight: .infinity, alignment: .top)
    }

    private var currentLoginUnavailableTitle: String {
        guard state.current.configAvailable, state.current.accountAvailable else { return L("无法读取当前登录状态。") }
        return state.current.accountType == nil ? L("尚未登录") : L("当前登录类型暂不支持。")
    }

    private var switcher: some View {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasResults = ProfileKind.supported.contains { kind in
            !matchingProfiles(for: kind, term: term).isEmpty || matchingCurrent(for: kind, term: term) != nil
        }
        return VStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(PanelColors.muted)
                TextField(L("搜索账号或配置"), text: $query).textFieldStyle(.plain)
            }.font(.system(size: 12)).padding(.horizontal, 10).frame(height: 32)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.10), lineWidth: 1).allowsHitTesting(false))
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(ProfileKind.supported) { kind in
                        let profiles = matchingProfiles(for: kind, term: term)
                        let current = matchingCurrent(for: kind, term: term)
                        if current != nil || !profiles.isEmpty {
                            Text(title(for: kind)).font(.system(size: 10, weight: .medium))
                                .foregroundStyle(PanelColors.muted).padding(.horizontal, 8).padding(.top, 5)
                            if let current {
                                profileLabel(name: current.name, email: current.accountEmail,
                                             plan: kind == .chatgpt ? ChatGPTPlan.title(current.accountPlanType) : nil,
                                             status: state.current.isOfficialProvider ? L("使用中") : L("当前登录"))
                            }
                            ForEach(profiles) { profile in
                                if state.isCurrent(profile) {
                                    profileLabel(name: state.profileDisplayName(profile), email: profile.accountEmail,
                                                 plan: kind == .chatgpt ? ChatGPTPlan.title(state.accountPlanType(for: profile)) : nil,
                                                 status: L("使用中"))
                                } else {
                                    Button {
                                        showingSwitcher = false
                                        query = ""
                                        close()
                                        state.requestActivation(profile)
                                    } label: {
                                        profileLabel(name: state.profileDisplayName(profile), email: profile.accountEmail,
                                                     plan: kind == .chatgpt ? ChatGPTPlan.title(state.accountPlanType(for: profile)) : nil,
                                                     status: state.matchesCurrentLogin(profile) ? L("当前登录") : nil)
                                    }.buttonStyle(StatusPanelRowStyle()).disabled(state.busy)
                                }
                            }
                        }
                    }
                    if !hasResults {
                        Text(term.isEmpty ? L("暂无配置") : L("没有匹配的配置"))
                            .font(.system(size: 12)).foregroundStyle(PanelColors.muted)
                            .frame(maxWidth: .infinity, minHeight: 64)
                    }
                }
            }.frame(maxHeight: .infinity)
        }.padding(.horizontal, 12).padding(.bottom, 8)
    }

    private func matchingProfiles(for kind: ProfileKind, term: String) -> [CodexProfile] {
        let profiles = state.profiles.filter { profile in
            profile.kind == kind && state.shouldDisplayProfile(profile) &&
            (term.isEmpty || state.profileDisplayName(profile).localizedCaseInsensitiveContains(term) ||
             (profile.accountEmail?.localizedCaseInsensitiveContains(term) ?? false))
        }
        return profiles.filter { state.isCurrent($0) } + profiles.filter { !state.isCurrent($0) }
    }

    private func matchingCurrent(for kind: ProfileKind, term: String) -> CurrentLoginItem? {
        state.currentLoginWithoutProfile(for: kind).flatMap { item in
            term.isEmpty || item.name.localizedCaseInsensitiveContains(term) ||
            (item.accountEmail?.localizedCaseInsensitiveContains(term) ?? false) ? item : nil
        }
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
                Text(L("当前额度")).font(.system(size: 12, weight: .semibold))
                if state.current.accountType == "chatgpt" {
                    Text(currentName).font(.system(size: 11)).foregroundStyle(PanelColors.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button { state.refresh(retryMissingPlanTypes: true) } label: {
                    Group {
                        if state.quotaRefreshInProgress { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.clockwise") }
                    }.frame(width: 28, height: 28).contentShape(Rectangle())
                }
                    .buttonStyle(.plain).foregroundStyle(PanelColors.secondary)
                    .disabled(state.busy || state.quotaRefreshInProgress)
                    .help(L("刷新额度"))
                    .accessibilityLabel(state.quotaRefreshInProgress ? L("正在刷新额度…") : L("刷新额度"))
            }
            if state.current.accountType == "chatgpt" {
                quotaContent
            } else {
                Text(state.current.accountType == "apiKey" ? L("当前使用 API Key") : L("当前没有官方账号登录"))
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
                        if let credits = bucket.credits { Text(localizedQuotaCredits(credits)).font(.system(size: 10)).foregroundStyle(PanelColors.secondary) }
                        if let value = bucket.individualLimit { Text(value.description).font(.system(size: 10)).foregroundStyle(PanelColors.secondary) }
                        if let reached = bucket.reached { Text(Localization.text(reached)).font(.system(size: 10)).foregroundStyle(PanelColors.accent) }
                    }
                    if let count = quota.resetCredits { Text(L("可用重置次数：\(count)")).font(.system(size: 10)).foregroundStyle(PanelColors.secondary) }
                    Text(presentation.isLoading ? L("正在刷新额度…") :
                         (presentation.failed ? L("刷新失败 · 上次查询 \(QuotaTime.format(quota.updatedAt))") : L("更新于 \(QuotaTime.format(quota.updatedAt))")))
                        .font(.system(size: 10)).foregroundStyle(PanelColors.muted)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            HStack(spacing: 6) {
                Text(presentation.isLoading ? L("正在读取额度…") : (presentation.failed ? L("额度暂不可用") : L("额度尚未查询")))
                    .font(.system(size: 11)).foregroundStyle(PanelColors.muted)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func quotaWindow(_ window: QuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.title)
                Spacer()
                Text(L("剩余 \(window.remainingPercent)%")).monospacedDigit()
            }
            GeometryReader { geometry in
                ZStack(alignment: .trailing) {
                    Capsule().fill(PanelColors.border)
                    Capsule().fill(PanelColors.accent).frame(width: geometry.size.width * CGFloat(window.remainingPercent) / 100)
                }
            }.frame(height: 4)
            if let reset = window.resetsAt { Text(L("\(QuotaTime.format(reset)) 重置")).foregroundStyle(PanelColors.muted) }
        }.font(.system(size: 10)).foregroundStyle(PanelColors.secondary).accessibilityElement(children: .combine)
    }

    @ViewBuilder private var notice: some View {
        if state.busy {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(state.message.isEmpty ? L("正在切换…") : state.message).lineLimit(2)
            }.font(.system(size: 10)).foregroundStyle(PanelColors.secondary).padding(.horizontal, 16).padding(.bottom, 8)
        } else if let pendingID = state.pendingProfileID, let profile = state.profiles.first(where: { $0.id == pendingID }) {
            HStack {
                Text(L("待切换：\(state.profileDisplayName(profile))")).lineLimit(1)
                Spacer()
                Button(L("取消")) { state.cancelPending(); state.setMessage("") }.buttonStyle(.plain)
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
                Button { close(); openMain() } label: {
                    Label(L("打开主面板"), systemImage: "arrow.up.left.and.arrow.down.right")
                        .padding(.horizontal, 4).frame(height: 32).contentShape(Rectangle())
                }
                Spacer()
                Button { close(); quit() } label: {
                    Label(L("退出"), systemImage: "power").padding(.horizontal, 4).frame(height: 32).contentShape(Rectangle())
                }
            }.font(.system(size: 12)).buttonStyle(.plain).padding(.horizontal, 16).frame(height: 46)
        }
    }

    private func title(for kind: ProfileKind) -> String { kind == .chatgpt ? L("官方账号") : L("官方 API Key") }

    private var currentName: String {
        if let profile = state.profiles.first(where: { $0.kind == .chatgpt && state.matchesCurrentLogin($0) }) {
            return state.profileDisplayName(profile)
        }
        return state.current.currentLoginItem?.name ?? L("当前账号")
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
