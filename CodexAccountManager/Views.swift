import AppKit
import SwiftUI

private enum PanelSection: CaseIterable, Hashable {
    case overview, chatgpt, openai

    var title: String {
        switch self {
        case .overview: return "全部"
        case .chatgpt: return "官方账号"
        case .openai: return "官方 API Key"
        }
    }
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .chatgpt: return "person.crop.circle"
        case .openai: return "key.horizontal"
        }
    }
    var subtitle: String {
        switch self {
        case .overview: return "管理账号与 API Key"
        case .chatgpt: return "管理已保存的官方账号"
        case .openai: return "管理已保存的 API Key"
        }
    }
    var kinds: [ProfileKind] {
        switch self {
        case .overview: return ProfileKind.supported
        case .chatgpt: return [.chatgpt]
        case .openai: return [.openai]
        }
    }
    var shortcut: String {
        switch self { case .overview: return "⌘1"; case .chatgpt: return "⌘2"; case .openai: return "⌘3" }
    }
}

private enum SettingsSection: CaseIterable, Hashable {
    case general, config, about
    var title: String {
        switch self { case .general: return "通用"; case .config: return "配置"; case .about: return "关于" }
    }
    var icon: String {
        switch self { case .general: return "slider.horizontal.3"; case .config: return "folder"; case .about: return "info.circle" }
    }
    var subtitle: String {
        switch self {
        case .general: return "个性化外观与启动方式"
        case .config: return "管理存储位置与诊断日志"
        case .about: return "应用信息与使用说明"
        }
    }
}

/// Shared colors for the light and dark appearances.
enum PanelColors {
    private static func adaptiveColor(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                           green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
        }
    }
    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color { Color(nsColor: adaptiveColor(light, dark)) }
    static let windowBackground = adaptiveColor(0xf7f9fc, 0x171b22)
    static let background = Color(nsColor: windowBackground)
    static let sidebar = background
    static let card = adaptive(0xffffff, 0x232a35)
    static let subtle = adaptive(0xecf1f7, 0x202731)
    static let selected = adaptive(0xdfeaf9, 0x283c54)
    static let border = adaptive(0xe0e6ee, 0x343e4c)
    static let borderStrong = adaptive(0xcbd5e2, 0x4b5869)
    static let text = adaptive(0x1b2635, 0xeaf0f8)
    static let secondary = adaptive(0x536276, 0xaeb9c9)
    static let muted = adaptive(0x617083, 0x96a5b8)
    static let action = adaptive(0x245fc6, 0x2e70d2)
    static let accent = adaptive(0x2359b4, 0x8bb8ff)
    static let accentBackground = adaptive(0xe8f1ff, 0x253b55)
    static let active = adaptive(0xecf4ff, 0x202f42)
    static let activeBorder = adaptive(0x9bbbed, 0x476b98)
}

enum PanelMenuPlacement {
    static func origin(anchor: CGRect, container: CGSize, menu: CGSize, inset: CGFloat = 8) -> CGPoint {
        let maximumX = max(inset, container.width - menu.width - inset)
        let x = min(max(anchor.maxX - menu.width, inset), maximumX)
        let below = anchor.maxY + 6
        let preferredY = below + menu.height <= container.height - inset ? below : anchor.minY - menu.height - 6
        let maximumY = max(inset, container.height - menu.height - inset)
        return CGPoint(x: x, y: min(max(preferredY, inset), maximumY))
    }
}

private enum PanelMenuTarget: Hashable {
    case add
    case profile(UUID)
}

private struct PanelMenuAnchorKey: PreferenceKey {
    static var defaultValue: [PanelMenuTarget: Anchor<CGRect>] = [:]
    static func reduce(value: inout [PanelMenuTarget: Anchor<CGRect>], nextValue: () -> [PanelMenuTarget: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct SystemMenuBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct NavItem: View {
    let title: String
    let symbol: String
    let selected: Bool
    var shortcut: String? = nil
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 15, weight: .medium)).frame(width: 20)
                    .foregroundStyle(selected ? PanelColors.accent : PanelColors.secondary)
                Text(title).font(.system(size: 13, weight: selected ? .medium : .regular))
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 34).padding(.horizontal, 10)
            .contentShape(Rectangle())
            .background(selected ? PanelColors.selected : (hovering ? PanelColors.subtle : Color.clear), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain).foregroundStyle(selected ? PanelColors.accent : PanelColors.text)
        .onHover { hovering = $0 }
        .help(shortcut.map { "\(title)（\($0)）" } ?? title).accessibilityLabel(title)
    }
}

private struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14).frame(height: 34)
            .foregroundStyle(.white)
            .background(PanelColors.action.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 8))
            .opacity(isEnabled ? 1 : 0.5)
    }
}

private struct OutlineButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12).frame(minHeight: 34)
            .foregroundStyle(PanelColors.text)
            .background(configuration.isPressed ? PanelColors.subtle : PanelColors.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(PanelColors.borderStrong, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.5)
    }
}

private struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverIconButton(configuration: configuration)
    }
}

private struct ActionIcon: View {
    let image: NSImage?
    let fallback: String
    let size: CGFloat

    var body: some View {
        Group {
            if let image { Image(nsImage: image).renderingMode(.template).resizable().aspectRatio(contentMode: .fit) }
            else { Image(systemName: fallback).resizable().aspectRatio(contentMode: .fit) }
        }.frame(width: size, height: size).foregroundColor(PanelColors.secondary)
    }
}

private struct HoverIconButton: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label.font(.system(size: 14))
            .frame(width: 32, height: 32).contentShape(Rectangle())
            .foregroundStyle(PanelColors.secondary)
            .background(configuration.isPressed || hovering ? PanelColors.subtle : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovering = $0 }
    }
}

private struct PanelMenuButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PanelMenuButton(configuration: configuration)
    }
}

private struct PanelMenuButton: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false

    var body: some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .frame(maxWidth: .infinity, alignment: .leading).frame(height: 34).padding(.horizontal, 10)
            .contentShape(Rectangle())
            .background(hovering || configuration.isPressed ? PanelColors.selected : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7))
            .onHover { hovering = $0 }
    }
}

private struct SwitchAccountButton: View {
    let name: String
    let disabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                ActionIcon(image: Branding.switchAccountIcon, fallback: "person.crop.circle.badge.arrow.right", size: 16)
                Text("切换到【\(name)】")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(PanelColors.text)
                    .lineLimit(1).truncationMode(.middle).padding(.leading, 7)
                    .frame(maxWidth: hovering ? 200 : 0, alignment: .leading)
                    .clipped().opacity(hovering ? 1 : 0).offset(x: hovering ? 0 : -5)
            }
            .padding(.horizontal, 8).frame(height: 32).contentShape(Rectangle())
            .background(hovering ? PanelColors.selected : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain).fixedSize()
        // Keep the card layout stable while the button expands to the left.
        .frame(width: 32, height: 32, alignment: .trailing)
        .onHover { inside in withAnimation(.easeInOut(duration: 0.2)) { hovering = inside && !disabled } }
        .onChange(of: disabled) { if $0 { hovering = false } }
        .disabled(disabled).opacity(disabled ? 0.45 : 1)
        .help("切换到 \(name)").accessibilityLabel("切换到 \(name)")
    }
}

private struct ReferenceSwitchStyle: ToggleStyle {
    let title: String
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule().fill(configuration.isOn ? PanelColors.action : PanelColors.borderStrong)
                .frame(width: 34, height: 20)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(.white).frame(width: 16, height: 16).padding(2)
                }
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityRepresentation { Toggle(title, isOn: configuration.$isOn).toggleStyle(.switch) }
    }
}

private struct PanelCard<Content: View>: View {
    var active = false
    @ViewBuilder let content: Content
    var body: some View {
        content.frame(maxWidth: .infinity, alignment: .leading)
            .background(active ? PanelColors.active : PanelColors.card, in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(active ? PanelColors.activeBorder : PanelColors.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.025), radius: 3, y: 1)
    }
}

private struct InputFrame: ViewModifier {
    var focused = false

    func body(content: Content) -> some View {
        content.font(.system(size: 13)).padding(.horizontal, 12).frame(height: 38)
            .background(PanelColors.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(focused ? PanelColors.accent : PanelColors.borderStrong, lineWidth: 1).allowsHitTesting(false))
    }
}

private struct PageHeading: View {
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 16, weight: .medium))
                .foregroundStyle(PanelColors.accent).frame(width: 36, height: 36)
                .background(PanelColors.accentBackground, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 17, weight: .semibold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(PanelColors.secondary)
            }
        }
    }
}

private final class PanelNavigation: ObservableObject {
    @Published var selection: PanelSection = .overview
    @Published var showingSettings = false
    @Published var settingsSelection: SettingsSection = .general
    @Published var newKind: ProfileKind = .chatgpt
    @Published var searchFocusRequest = 0
}

final class PanelSplitViewController: NSSplitViewController {
    private let state: AppState
    private let navigation: PanelNavigation

    init(state: AppState) {
        self.state = state
        navigation = PanelNavigation()
        super.init(nibName: nil, bundle: nil)
        let sidebar = NSHostingController(rootView: PanelSidebar(state: state, navigation: navigation))
        sidebar.sizingOptions = []
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 200
        addSplitViewItem(sidebarItem)

        let content = NSHostingController(rootView: PanelContent(state: state, navigation: navigation))
        content.sizingOptions = []
        addSplitViewItem(NSSplitViewItem(viewController: content))
        splitView.dividerStyle = .thin
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Handle panel-only shortcuts after the window has checked modifiers and sheets.
    func handleShortcut(_ key: String) -> Bool {
        switch key {
        case "1", "2", "3":
            navigation.selection = key == "1" ? .overview : (key == "2" ? .chatgpt : .openai)
            navigation.showingSettings = false
            if !state.busy { state.setMessage("") }
        case ",":
            navigation.settingsSelection = .general
            navigation.showingSettings = true
            if !state.busy { state.setMessage("") }
        case "[":
            guard navigation.showingSettings else { return false }
            navigation.showingSettings = false
            if !state.busy { state.setMessage("") }
        case "f":
            guard !navigation.showingSettings else { return false }
            navigation.searchFocusRequest += 1
        case "n":
            guard !navigation.showingSettings, !state.busy, state.page != .add else { return false }
            navigation.newKind = navigation.selection == .openai ? .openai : .chatgpt
            state.editing = nil; state.editingCurrent = nil; state.setMessage(""); state.page = .add
        case "r":
            guard !navigation.showingSettings else { return false }
            state.refresh(retryMissingPlanTypes: true)
        default:
            return false
        }
        return true
    }
}

private struct PanelSidebar: View {
    @ObservedObject var state: AppState
    @ObservedObject var navigation: PanelNavigation

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let icon = Branding.appIcon {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 30, height: 30)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(Branding.appName).font(.system(size: 14, weight: .semibold))
                    Text("账号管理").font(.system(size: 11)).foregroundStyle(PanelColors.muted)
                }
                Spacer(minLength: 0)
            }.frame(height: 58).padding(.horizontal, 16)
            if navigation.showingSettings {
                NavItem(title: "返回", symbol: "arrow.left", selected: false, shortcut: "⌘[") {
                    navigation.showingSettings = false
                    if !state.busy { state.setMessage("") }
                }.padding(.horizontal, 10)
                sidebarLabel("设置")
                VStack(spacing: 3) {
                    ForEach(SettingsSection.allCases, id: \.self) { section in
                        NavItem(title: section.title, symbol: section.icon, selected: section == navigation.settingsSelection) {
                            navigation.settingsSelection = section
                            if !state.busy { state.setMessage("") }
                        }
                    }
                }.padding(.horizontal, 10)
                Spacer()
                Text("\(Branding.fullName) v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.5.0")")
                    .font(.system(size: 10)).foregroundStyle(PanelColors.muted).lineLimit(1).minimumScaleFactor(0.9)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 16).padding(.bottom, 16)
            } else {
                sidebarLabel("账户")
                VStack(spacing: 3) {
                    ForEach(PanelSection.allCases, id: \.self) { section in
                        NavItem(title: section.title, symbol: section.icon, selected: navigation.selection == section, shortcut: section.shortcut) {
                            navigation.selection = section
                            if !state.busy { state.setMessage("") }
                        }
                    }
                }.padding(.horizontal, 10)
                Spacer()
                Rectangle().fill(PanelColors.border).frame(height: 1).padding(.horizontal, 14)
                NavItem(title: "设置", symbol: "gearshape", selected: false, shortcut: "⌘,") {
                    navigation.settingsSelection = .general; navigation.showingSettings = true
                    if !state.busy { state.setMessage("") }
                }.padding(.horizontal, 10).padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PanelColors.sidebar).foregroundStyle(PanelColors.text)
    }

    private func sidebarLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(PanelColors.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 20).padding(.top, 12).padding(.bottom, 7)
    }
}

private struct PanelContent: View {
    @ObservedObject var state: AppState
    @ObservedObject var navigation: PanelNavigation

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if navigation.showingSettings {
                    SettingsView(state: state, section: navigation.settingsSelection)
                } else {
                    ManageView(state: state, navigation: navigation, section: navigation.selection) { kind in
                        navigation.newKind = kind; state.editing = nil; state.editingCurrent = nil; state.setMessage(""); state.page = .add
                    }
                }
            }
            if let login = state.accountLogin, state.page != .add {
                HStack(spacing: 10) {
                    if let instructions = login.instructions {
                        Button("打开登录网页") { NSWorkspace.shared.open(instructions.url) }
                        Button("复制登录链接") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(instructions.url.absoluteString, forType: .string)
                        }
                    }
                    Spacer()
                    Button("取消登录") { state.cancelChatGPTLogin() }
                        .disabled(login.isCancelling || login.isSaving)
                }.padding(.horizontal, 24).padding(.vertical, 10)
                    .background(PanelColors.card)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PanelColors.background).foregroundStyle(PanelColors.text)
        .sheet(isPresented: Binding(get: { state.page == .add }, set: { visible in
            if !visible && state.page == .add { state.editing = nil; state.editingCurrent = nil; state.page = .manage; state.setMessage("") }
        })) { AddView(state: state, initialKind: navigation.newKind).interactiveDismissDisabled(state.accountLogin != nil || (state.editingCurrent != nil && state.busy)) }
    }
}

private struct StatusMessage: View {
    @ObservedObject var state: AppState
    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            if state.busy { ProgressView().controlSize(.small) }
            Text(state.message).font(.system(size: 12))
                .foregroundStyle(state.isError ? Color.red : PanelColors.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ManageView: View {
    @ObservedObject var state: AppState
    @ObservedObject var navigation: PanelNavigation
    let section: PanelSection
    let add: (ProfileKind) -> Void
    @State private var toDelete: CodexProfile?
    @State private var query = ""
    @State private var openMenu: PanelMenuTarget?
    @FocusState private var searchFocused: Bool
    @FocusState private var menuFocusedItem: Int?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                PageHeading(title: section.title, subtitle: section.subtitle, symbol: section.icon)
                Spacer()
                Button { state.refresh(retryMissingPlanTypes: true) } label: {
                    Label(section == .openai ? "刷新" : "刷新额度", systemImage: "arrow.clockwise")
                }.buttonStyle(OutlineButtonStyle()).disabled(state.busy || (section != .openai && state.currentQuotaLoading))
                    .help("刷新账号状态和额度（⌘R）")
                if section == .overview {
                    Button { openMenu = .add } label: {
                        Label("添加", systemImage: "plus").font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 6).frame(height: 34).contentShape(Rectangle())
                    }.buttonStyle(.plain).fixedSize().disabled(state.busy)
                        .help("添加账号或 API Key")
                        .anchorPreference(key: PanelMenuAnchorKey.self, value: .bounds) { [.add: $0] }
                } else {
                    Button { add(section == .openai ? .openai : .chatgpt) } label: {
                        Label(section == .openai ? "添加 API Key" : "登录新账号", systemImage: "plus")
                    }.buttonStyle(PrimaryButtonStyle()).disabled(state.busy).help("添加（⌘N）")
                }
            }.padding(.horizontal, 28).frame(height: 70)
            Rectangle().fill(PanelColors.border).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 9) {
                        Image(systemName: "magnifyingglass").foregroundStyle(PanelColors.muted)
                        TextField("搜索账号或配置", text: $query).textFieldStyle(.plain)
                            .focused($searchFocused).help("搜索账号或配置（⌘F）")
                    }.font(.system(size: 13)).padding(.horizontal, 12).frame(height: 38)
                        .background(PanelColors.card, in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(PanelColors.border, lineWidth: 1))
                    if state.demo { Label("演示模式 · 模拟数据", systemImage: "sparkles").font(.system(size: 11)).foregroundStyle(PanelColors.muted) }
                    currentStatusMessage
                    ForEach(section.kinds) { kind in group(kind) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(28)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let pending = state.profiles.first(where: { $0.id == state.pendingProfileID }) {
                HStack {
                    Label("待切换：\(state.profileDisplayName(pending))", systemImage: "clock").font(.system(size: 11)).foregroundStyle(PanelColors.secondary)
                    Spacer()
                    Button("重试") { state.requestActivation(pending, reauthenticate: state.pendingReauthentication) }.disabled(state.busy)
                    Button("取消") { state.cancelPending(); state.setMessage("") }.disabled(state.busy)
                }.padding(.horizontal, 24).padding(.bottom, 8)
            }
            if !state.message.isEmpty { StatusMessage(state: state).padding(.horizontal, 24).padding(.bottom, 12) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlayPreferenceValue(PanelMenuAnchorKey.self) { anchors in
            GeometryReader { geometry in
                if let menu = openMenu, let anchor = anchors[menu] {
                    let size = CGSize(width: min(190, max(0, geometry.size.width - 16)), height: 82)
                    let position = PanelMenuPlacement.origin(anchor: geometry[anchor], container: geometry.size, menu: size)
                    ZStack(alignment: .topLeading) {
                        Color.clear.contentShape(Rectangle()).onTapGesture { openMenu = nil }
                        Button("关闭菜单") { openMenu = nil }
                            .keyboardShortcut(.cancelAction)
                            .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
                        panelMenu(menu, size: size)
                            .position(x: position.x + size.width / 2, y: position.y + size.height / 2)
                    }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }
            }
        }
        .onChange(of: navigation.searchFocusRequest) { _ in
            openMenu = nil
            searchFocused = true
        }
        .onChange(of: openMenu) { if $0 == nil { menuFocusedItem = nil } }
        .onChange(of: section) { _ in openMenu = nil }
        .onChange(of: state.busy) { if $0 { openMenu = nil } }
        .confirmationDialog("删除已保存的配置？", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }), titleVisibility: .visible) {
            if let profile = toDelete { Button("删除 \(state.profileDisplayName(profile))", role: .destructive) { state.remove(profile); toDelete = nil } }
            Button("取消", role: .cancel) { toDelete = nil }
        }
    }

    private func panelMenu(_ target: PanelMenuTarget, size: CGSize) -> some View {
        VStack(spacing: 2) {
            switch target {
            case .add:
                panelMenuItem("登录新账号", symbol: "person.badge.plus", index: 0) { add(.chatgpt) }
                panelMenuItem("添加 API Key", symbol: "key.horizontal", index: 1) { add(.openai) }
            case .profile(let id):
                if let profile = state.profiles.first(where: { $0.id == id }) {
                    panelMenuItem("重新登录", symbol: "arrow.clockwise", index: 0) {
                        state.requestActivation(profile, reauthenticate: true)
                    }
                    panelMenuItem("删除", symbol: "trash", role: .destructive, index: 1) { toDelete = profile }
                }
            }
        }
        .padding(6).frame(width: size.width, height: size.height)
        .background(SystemMenuBackground().clipShape(RoundedRectangle(cornerRadius: 10)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(PanelColors.borderStrong, lineWidth: 1).allowsHitTesting(false))
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
        .onMoveCommand { direction in
            switch direction {
            case .up: menuFocusedItem = max(0, (menuFocusedItem ?? 0) - 1)
            case .down: menuFocusedItem = min(1, (menuFocusedItem ?? 0) + 1)
            default: break
            }
        }
        .onExitCommand { openMenu = nil }
    }

    private func panelMenuItem(_ title: String, symbol: String, role: ButtonRole? = nil, index: Int,
                               action: @escaping () -> Void) -> some View {
        Button(role: role) {
            openMenu = nil
            action()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol).frame(width: 16)
                Text(title).lineLimit(1)
            }.foregroundStyle(role == .destructive ? Color.red : PanelColors.text)
        }
        .buttonStyle(PanelMenuButtonStyle()).focused($menuFocusedItem, equals: index)
    }

    @ViewBuilder private var currentStatusMessage: some View {
        if state.current.configAvailable && !state.current.accountAvailable {
            Label("无法读取当前登录状态。", systemImage: "exclamationmark.triangle")
                .font(.system(size: 12)).foregroundStyle(PanelColors.secondary)
        } else if state.current.configAvailable && !state.current.isOfficialProvider {
            Label("当前 Codex 配置未识别为官方配置。", systemImage: "exclamationmark.triangle")
                .font(.system(size: 12)).foregroundStyle(PanelColors.secondary)
        } else if state.current.accountAvailable && state.current.accountType != nil && state.current.currentLoginItem == nil {
            Label("当前登录类型暂不支持。", systemImage: "exclamationmark.triangle")
                .font(.system(size: 12)).foregroundStyle(PanelColors.secondary)
        }
    }

    private func group(_ kind: ProfileKind) -> some View {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = state.profiles.filter { profile in
            profile.kind == kind && state.shouldDisplayProfile(profile) && (term.isEmpty || state.profileDisplayName(profile).localizedCaseInsensitiveContains(term) ||
                (profile.accountEmail?.localizedCaseInsensitiveContains(term) ?? false))
        }
        let entries = filtered.filter { state.isCurrent($0) } + filtered.filter { !state.isCurrent($0) }
        let current = state.currentLoginWithoutProfile(for: kind).flatMap { item in
            term.isEmpty || item.name.localizedCaseInsensitiveContains(term) || (item.accountEmail?.localizedCaseInsensitiveContains(term) ?? false) ? item : nil
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(kind == .chatgpt ? "官方账号" : "官方 API Key").font(.system(size: 14, weight: .semibold))
                Text("\(entries.count + (current == nil ? 0 : 1))").font(.system(size: 10, weight: .semibold)).foregroundStyle(PanelColors.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3).background(PanelColors.subtle, in: Capsule())
                Spacer()
                if section == .overview {
                    Button { add(kind) } label: {
                        Label(kind == .chatgpt ? "登录新账号" : "添加 API Key", systemImage: "plus")
                    }.buttonStyle(.plain).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(PanelColors.accent).disabled(state.busy)
                }
            }
            if entries.isEmpty && current == nil {
                PanelCard {
                    HStack {
                        Text(term.isEmpty ? "还没有\(kind == .chatgpt ? "账号" : "API Key")" : "没有匹配的配置")
                            .font(.system(size: 13)).foregroundStyle(PanelColors.secondary)
                        Spacer()
                    }.padding(16)
                }
            } else {
                if let current { currentLoginCard(current) }
                ForEach(entries) { profile in profileCard(profile) }
            }
        }
    }

    private func currentLoginCard(_ current: CurrentLoginItem) -> some View {
        let active = state.current.isOfficialProvider
        return PanelCard(active: active) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    if current.kind != .chatgpt { profileIcon(current.kind) }
                    accountIdentity(kind: current.kind, name: current.name, email: current.accountEmail,
                                    plan: current.accountPlanType,
                                    editDisabled: state.busy || state.current.credentialFingerprint == nil) {
                        state.beginEditingCurrentAlias()
                    }
                    Spacer(minLength: 6)
                    currentBadge(active ? "使用中" : "当前登录")
                }.padding(.horizontal, 16).padding(.vertical, 12).frame(minHeight: 68)
                if current.kind == .chatgpt {
                    quotaDetails(state.currentQuotaPresentation).padding(.horizontal, 16).padding(.bottom, 14)
                }
            }
        }
    }

    private func profileCard(_ profile: CodexProfile) -> some View {
        let active = state.isCurrent(profile)
        let name = state.profileDisplayName(profile)
        return PanelCard(active: active) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    if profile.kind != .chatgpt { profileIcon(profile.kind) }
                    accountIdentity(kind: profile.kind, name: name, email: profile.accountEmail,
                                    plan: state.accountPlanType(for: profile), editDisabled: state.busy) {
                        state.editingCurrent = nil; state.editing = profile; state.setMessage(""); state.page = .add
                    }
                    Spacer(minLength: 6)
                    if active {
                        currentBadge("使用中")
                    } else {
                        if state.matchesCurrentLogin(profile) { currentBadge("当前登录") }
                        SwitchAccountButton(name: name, disabled: state.busy) { state.requestActivation(profile) }
                    }
                    if !active && profile.kind == .chatgpt && profile.hasSecret {
                        Button { openMenu = .profile(profile.id) } label: { Image(systemName: "ellipsis") }
                            .buttonStyle(IconButtonStyle()).disabled(state.busy).help("更多操作")
                            .accessibilityLabel("更多操作")
                            .anchorPreference(key: PanelMenuAnchorKey.self, value: .bounds) { [.profile(profile.id): $0] }
                    } else if active && profile.kind == .chatgpt {
                        Button("重新登录") { state.requestActivation(profile, reauthenticate: true) }
                            .buttonStyle(OutlineButtonStyle()).fixedSize().disabled(state.busy)
                    } else if !active {
                        Button { toDelete = profile } label: { Image(systemName: "trash") }
                            .buttonStyle(IconButtonStyle()).help("删除 \(name)").accessibilityLabel("删除 \(name)").disabled(state.busy)
                    }
                }.padding(.horizontal, 16).padding(.vertical, 12).frame(minHeight: 68)
                if profile.kind == .chatgpt {
                    quotaDetails(state.quotaPresentation(for: profile)).padding(.horizontal, 16).padding(.bottom, 14)
                }
            }
        }
    }

    private func accountIdentity(kind: ProfileKind, name: String, email: String?, plan: String?,
                                 editDisabled: Bool, edit: @escaping () -> Void) -> some View {
        let secondaryEmail = email.flatMap { $0.caseInsensitiveCompare(name) == .orderedSame ? nil : $0 }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle).help(name)
                if kind == .chatgpt && secondaryEmail == nil { membershipBadge(plan) }
                Button(action: edit) {
                    ActionIcon(image: Branding.editIcon, fallback: "square.and.pencil", size: 14)
                }.buttonStyle(IconButtonStyle()).help("编辑 \(name)").accessibilityLabel("编辑 \(name)").disabled(editDisabled)
            }
            if kind == .chatgpt, let secondaryEmail {
                HStack(spacing: 7) {
                    Text(secondaryEmail).font(.system(size: 11)).foregroundStyle(PanelColors.secondary)
                        .lineLimit(1).truncationMode(.middle).help(secondaryEmail)
                    membershipBadge(plan)
                }
            } else if kind == .openai {
                Text("OpenAI API Key").font(.system(size: 11)).foregroundStyle(PanelColors.secondary)
            }
        }
    }

    @ViewBuilder private func quotaDetails(_ presentation: QuotaPresentation) -> some View {
        if let quota = presentation.value {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(quota.buckets) { bucket in
                    if let title = bucket.title { Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(PanelColors.secondary) }
                    if !bucket.windows.isEmpty {
                        HStack(alignment: .top, spacing: 24) {
                            ForEach(bucket.windows) { window in quotaWindow(window) }
                        }
                        .frame(maxWidth: bucket.windows.count == 1 ? 320 : 664, alignment: .leading)
                    }
                    if let value = bucket.individualLimit { Text(value.description).font(.system(size: 11)).foregroundStyle(PanelColors.secondary) }
                    if let value = bucket.reached { Text(value).font(.system(size: 11, weight: .medium)).foregroundStyle(PanelColors.accent) }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { quotaSummaryItems(quota, presentation) }
                        .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 6) { quotaSummaryItems(quota, presentation) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 6) {
                if presentation.isLoading { ProgressView().controlSize(.small) }
                Text(presentation.isLoading ? "正在读取额度…" :
                     (presentation.failed ? "额度暂不可用" : (presentation.isCached ? "切换后查看额度" : "额度尚未查询")))
                    .font(.system(size: 11)).foregroundStyle(PanelColors.muted)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func quotaWindow(_ window: QuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(window.title)
                Spacer(minLength: 4)
                Text("剩余 \(window.remainingPercent)%").monospacedDigit()
            }
            quotaProgressBar(window)
            if let reset = window.resetsAt {
                Text("\(QuotaTime.format(reset)) 重置").foregroundStyle(PanelColors.muted).lineLimit(1)
            }
        }
        .font(.system(size: 11)).foregroundStyle(PanelColors.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func quotaProgressBar(_ window: QuotaWindow) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .trailing) {
                Capsule().fill(PanelColors.border)
                Capsule().fill(PanelColors.accent).frame(width: geometry.size.width * CGFloat(window.remainingPercent) / 100)
            }
        }.frame(height: 4)
    }

    @ViewBuilder private func quotaSummaryItems(_ quota: AccountQuota, _ presentation: QuotaPresentation) -> some View {
        ForEach(quota.buckets) { bucket in
            if let value = bucket.credits {
                Text(quota.buckets.count > 1 ? bucket.title.map { "\($0) · \(value)" } ?? value : value)
                    .font(.system(size: 11)).foregroundStyle(PanelColors.secondary)
            }
        }
        if let count = quota.resetCredits {
            Text("可用重置次数：\(count)").font(.system(size: 11)).foregroundStyle(PanelColors.secondary)
        }
        Text(presentation.isLoading ? "正在刷新额度…" :
             (presentation.failed ? "刷新失败 · 上次查询 \(QuotaTime.format(quota.updatedAt))" :
              "\(presentation.isCached ? "上次查询" : "更新于") \(QuotaTime.format(quota.updatedAt))"))
            .font(.system(size: 10)).foregroundStyle(PanelColors.muted)
    }

    private func profileIcon(_ kind: ProfileKind) -> some View {
        Image(systemName: kind.icon).font(.system(size: 17, weight: .medium))
            .foregroundStyle(PanelColors.accent).frame(width: 40, height: 40)
            .background(PanelColors.accentBackground, in: RoundedRectangle(cornerRadius: 10))
    }

    private func currentBadge(_ title: String) -> some View {
        HStack(spacing: 5) { Circle().fill(PanelColors.accent).frame(width: 6, height: 6); Text(title) }
            .font(.system(size: 11, weight: .medium)).foregroundStyle(PanelColors.accent)
    }

    private func membershipBadge(_ plan: String?) -> some View {
        let title = ChatGPTPlan.title(plan)
        return Text(title).font(.system(size: 10, weight: .medium))
            .lineLimit(1).truncationMode(.middle)
            .foregroundStyle(title == ChatGPTPlan.unknownTitle ? PanelColors.secondary : PanelColors.accent)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(title == ChatGPTPlan.unknownTitle ? PanelColors.subtle : PanelColors.accentBackground, in: Capsule())
            .layoutPriority(1)
            .accessibilityLabel("会员类型：\(title)")
            .help(title == ChatGPTPlan.unknownTitle ? "该会员类型无法归入当前显示的分类。" : "会员类型来自 Codex，具体订阅以 ChatGPT 设置为准。")
    }
}

private struct AddView: View {
    @ObservedObject var state: AppState
    let initialKind: ProfileKind
    @State private var name = ""
    @State private var kind: ProfileKind = .chatgpt
    @State private var loginMethod: ChatGPTLoginMethod = .browser
    @State private var openBrowser = true
    @State private var showSecret = false
    @State private var model = ""
    @State private var secret = ""
    @FocusState private var focusedField: InputField?

    private enum InputField: Hashable { case name, secret }
    private var isEditingCurrent: Bool { state.editingCurrent != nil }
    private var isEditing: Bool { state.editing != nil || isEditingCurrent }
    private var isNewChatGPT: Bool { !isEditing && kind == .chatgpt }
    private var isCurrentAPIWithoutBackup: Bool {
        guard let profile = state.editing else { return false }
        return profile.kind == .openai && !profile.hasSecret && state.matchesCurrentLogin(profile)
    }
    private var title: String {
        if isEditing { return kind == .chatgpt ? "编辑账号" : "编辑 API Key" }
        return isNewChatGPT ? "登录新账号" : "添加 API Key"
    }
    private var subtitle: String {
        if isEditing { return isEditingCurrent ? "修改本地别名" : "修改本地配置" }
        return isNewChatGPT ? "使用 ChatGPT 账号完成官方授权" : "保存 OpenAI API Key 以便切换"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeading(title: title, subtitle: subtitle, symbol: isEditing ? "pencil" : (isNewChatGPT ? "person.badge.plus" : "key.horizontal"))
                .padding(24)
            Rectangle().fill(PanelColors.border).frame(height: 1)
            VStack(alignment: .leading, spacing: 18) {
                if isNewChatGPT {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("登录方式").font(.system(size: 12, weight: .medium))
                        HStack(spacing: 10) {
                            ForEach(ChatGPTLoginMethod.allCases) { method in loginOption(method) }
                        }.disabled(state.busy)
                    }
                    HStack {
                        Text("自动打开浏览器").font(.system(size: 12))
                        Spacer()
                        Toggle("自动打开浏览器", isOn: $openBrowser)
                            .toggleStyle(ReferenceSwitchStyle(title: "自动打开浏览器"))
                            .disabled(state.busy)
                    }
                    if let instructions = state.accountLogin?.instructions {
                        loginInstructions(instructions)
                    } else {
                        Text("在浏览器中登录要添加的账号，完成后不会自动切换当前 Codex 登录。")
                            .font(.system(size: 11)).foregroundStyle(PanelColors.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("名称").font(.system(size: 12, weight: .medium))
                        TextField("名称", text: $name, prompt: Text(kind == .openai ? "例如：工作 API Key" : "例如：个人账号"))
                            .textFieldStyle(.plain).focused($focusedField, equals: .name)
                            .modifier(InputFrame(focused: focusedField == .name))
                            .accessibilityLabel("名称")
                    }
                }
                if kind == .openai && !isEditingCurrent && !isCurrentAPIWithoutBackup {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("API Key").font(.system(size: 12, weight: .medium))
                        HStack(spacing: 8) {
                            Group {
                                if showSecret {
                                    TextField("API Key", text: $secret, prompt: Text(state.editing?.hasSecret == true ? "留空保留现有密钥" : "OpenAI API Key"))
                                        .textFieldStyle(.plain).focused($focusedField, equals: .secret).accessibilityLabel("API Key")
                                } else {
                                    SecureField("API Key", text: $secret, prompt: Text(state.editing?.hasSecret == true ? "留空保留现有密钥" : "OpenAI API Key"))
                                        .textFieldStyle(.plain).focused($focusedField, equals: .secret).accessibilityLabel("API Key")
                                }
                            }
                            Button {
                                showSecret.toggle()
                                DispatchQueue.main.async { focusedField = .secret }
                            } label: { Image(systemName: showSecret ? "eye.slash" : "eye") }
                                .buttonStyle(.plain).foregroundStyle(PanelColors.secondary)
                                .help(showSecret ? "隐藏 API Key" : "显示 API Key")
                                .accessibilityLabel(showSecret ? "隐藏 API Key" : "显示 API Key")
                        }.modifier(InputFrame(focused: focusedField == .secret))
                        Text("密钥保存在本地凭据文件中，保存时不会验证有效性。")
                            .font(.system(size: 11)).foregroundStyle(PanelColors.muted)
                    }
                }
                if !state.message.isEmpty { StatusMessage(state: state) }
                HStack(spacing: 10) {
                    Spacer()
                    Button(state.accountLogin == nil ? "取消" : "取消登录") {
                        if state.accountLogin != nil { state.cancelChatGPTLogin() }
                        else { state.editing = nil; state.editingCurrent = nil; state.page = .manage; state.setMessage("") }
                    }
                        .buttonStyle(OutlineButtonStyle()).keyboardShortcut(.cancelAction)
                        .disabled(state.accountLogin?.isCancelling == true || state.accountLogin?.isSaving == true || (isEditingCurrent && state.busy))
                    Button(isNewChatGPT ? "开始登录" : "保存") {
                        if isNewChatGPT { state.beginChatGPTLogin(loginMethod, openBrowser: openBrowser) }
                        else if isEditingCurrent { state.saveCurrentAlias(name) }
                        else {
                            let saved: Bool
                            if let profile = state.editing { saved = state.update(profile, name: name, model: model, baseURL: "", secret: secret) }
                            else { saved = state.add(name: name, kind: kind, model: model, baseURL: "", secret: secret) }
                            if saved { secret = "" }
                        }
                    }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction).disabled(state.busy)
                }
            }.padding(24)
        }.frame(width: 500).background(PanelColors.background).foregroundStyle(PanelColors.text)
            .onChange(of: loginMethod) { _ in if !state.busy { state.setMessage("") } }
            .onAppear {
                if let current = state.editingCurrent?.currentLoginItem { name = current.name; kind = current.kind }
                else if let profile = state.editing { name = state.profileDisplayName(profile); kind = profile.kind; model = profile.model ?? "" }
                else { kind = initialKind }
                focusedField = isNewChatGPT ? nil : .name
            }
    }

    private func loginOption(_ method: ChatGPTLoginMethod) -> some View {
        let selected = loginMethod == method
        return Button { loginMethod = method } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: method == .browser ? "globe" : "number.square")
                    .font(.system(size: 15)).foregroundStyle(selected ? PanelColors.accent : PanelColors.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(method.title).font(.system(size: 12, weight: .semibold))
                    Text(method == .browser ? "在浏览器中授权" : "输入一次性代码授权")
                        .font(.system(size: 10)).foregroundStyle(PanelColors.secondary)
                }
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(PanelColors.accent) }
            }.frame(maxWidth: .infinity, minHeight: 42, alignment: .topLeading).padding(12)
                .background(selected ? PanelColors.active : PanelColors.card, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? PanelColors.activeBorder : PanelColors.border, lineWidth: 1))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func loginInstructions(_ instructions: ChatGPTLoginInstructions) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let code = instructions.userCode {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("设备代码").font(.system(size: 11)).foregroundStyle(PanelColors.secondary)
                        Text(code).font(.system(size: 19, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                    }
                    Spacer()
                    Button("复制代码") { copy(code) }.buttonStyle(OutlineButtonStyle())
                }
            }
            HStack(spacing: 10) {
                Button("打开登录网页") { NSWorkspace.shared.open(instructions.url) }.buttonStyle(OutlineButtonStyle())
                Button("复制登录链接") { copy(instructions.url.absoluteString) }.buttonStyle(OutlineButtonStyle())
            }
            Text("如果浏览器已登录其他账号，可以复制链接到另一个浏览器或无痕窗口。")
                .font(.system(size: 11)).foregroundStyle(PanelColors.muted).fixedSize(horizontal: false, vertical: true)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(PanelColors.subtle, in: RoundedRectangle(cornerRadius: 9))
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private struct SettingsView: View {
    @ObservedObject var state: AppState
    let section: SettingsSection
    @State private var home = ""
    @State private var path = ""
    @State private var directory = ""

    private var defaultCodexHome: String {
        (state.detectedCodexHome as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                PageHeading(title: section.title, subtitle: section.subtitle, symbol: section.icon)
                Spacer()
            }.padding(.horizontal, 28).frame(height: 70)
            Rectangle().fill(PanelColors.border).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    switch section {
                    case .general: generalContent
                    case .config: configContent
                    case .about: aboutContent
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(28)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if !state.message.isEmpty { StatusMessage(state: state).padding(.horizontal, 28).padding(.bottom, 10) }
            if section == .config {
                Rectangle().fill(PanelColors.border).frame(height: 1)
                HStack {
                    Spacer()
                    Button("保存目录") {
                        let savedHome = NSString(string: home).expandingTildeInPath == state.detectedCodexHome ? "" : home
                        state.savePreferences(home: savedHome, path: path, directory: directory)
                    }
                        .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction).disabled(state.busy)
                }.padding(.horizontal, 28).padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            home = state.codexHome.isEmpty ? defaultCodexHome : state.codexHome
            path = state.codexPath
            directory = (state.profileDirectory as NSString).abbreviatingWithTildeInPath
        }
    }

    @ViewBuilder private var generalContent: some View {
        settingGroup("外观") {
            PanelCard {
                HStack {
                    Text("明暗")
                    Spacer()
                    HStack(spacing: 1) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Button { state.setAppearance(appearance) } label: {
                                Label(appearance.title, systemImage: appearance.symbol)
                                    .font(.system(size: 12, weight: state.appearance == appearance ? .medium : .regular))
                                    .padding(.horizontal, 9).frame(height: 30)
                                    .background(state.appearance == appearance ? PanelColors.card : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(state.appearance == appearance ? PanelColors.border : Color.clear, lineWidth: 1))
                            }.buttonStyle(.plain).foregroundStyle(state.appearance == appearance ? PanelColors.accent : PanelColors.secondary)
                        }
                    }.padding(3).background(PanelColors.subtle, in: RoundedRectangle(cornerRadius: 9))
                }.font(.system(size: 13)).padding(.horizontal, 16).frame(minHeight: 54)
            }
        }
        settingGroup("窗口与启动") {
            PanelCard {
                VStack(spacing: 0) {
                    switchRow("开机自启", description: "登录 macOS 时启动应用。", value: Binding(get: { state.launchAtLogin }, set: { state.setLaunchAtLogin($0) }))
                    settingDivider
                    switchRow("静默启动", description: "启动时仅显示菜单栏图标。", value: Binding(get: { state.silentLaunch }, set: { state.setSilentLaunch($0) }))
                    settingDivider
                    switchRow("关闭窗口后保留在菜单栏", description: "关闭后隐藏程序坞图标，仍可从菜单栏打开。", value: Binding(get: { state.closeToMenuBar }, set: { state.setCloseToMenuBar($0) }))
                }
            }
        }
    }

    @ViewBuilder private var configContent: some View {
        settingGroup("存储位置") {
            PanelCard {
                VStack(alignment: .leading, spacing: 10) {
                    directoryRow("应用配置目录", value: $directory, placeholder: "默认位置", defaultValue: (ProfileStore.standard().directory.path as NSString).abbreviatingWithTildeInPath,
                                 help: "保存账号配置、凭据文件和应用诊断日志。")
                }.padding(16)
            }
        }
        settingGroup("Codex", symbol: "terminal") {
            PanelCard {
                VStack(spacing: 0) {
                    HStack {
                        titleWithHelp("统一 Codex 会话历史", help: "切换时保留已识别的官方共享分组，不会改写旧会话。")
                        Spacer()
                        Toggle("统一 Codex 会话历史", isOn: Binding(get: { state.preserveSharedHistory }, set: { state.setPreserveSharedHistory($0) }))
                            .labelsHidden().toggleStyle(ReferenceSwitchStyle(title: "统一 Codex 会话历史")).disabled(state.busy || !state.current.configAvailable)
                    }.padding(.horizontal, 16).frame(minHeight: 55)
                    settingDivider
                    VStack(alignment: .leading, spacing: 10) {
                        directoryRow("配置目录", value: $home, placeholder: "默认 Codex 配置目录", defaultValue: defaultCodexHome,
                                     help: "自动读取启动环境中的 CODEX_HOME，未设置时使用 ~/.codex；也可以手动指定。")
                        if !state.preserveSharedHistory {
                            Text("关闭后，下次切换可能使旧共享分组的会话暂时不显示。")
                                .font(.system(size: 11)).foregroundStyle(PanelColors.secondary)
                        } else if state.current.usesSharedOfficialProvider {
                            Label("已识别现有的官方共享会话分组", systemImage: "checkmark.circle")
                                .font(.system(size: 11)).foregroundStyle(PanelColors.secondary)
                        }
                    }.padding(16)
                }.font(.system(size: 13))
            }
        }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("应用诊断日志")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button { state.openDiagnosticLog() } label: { Label("打开日志", systemImage: "folder") }.buttonStyle(OutlineButtonStyle())
            }
            PanelCard {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("启用应用诊断日志")
                            Text("只记录应用事件，不记录账号、密钥或会话内容。")
                                .font(.system(size: 11)).foregroundStyle(PanelColors.secondary)
                        }
                        Spacer()
                        Toggle("启用应用诊断日志", isOn: Binding(get: { state.loggingEnabled }, set: { state.setDiagnostics(enabled: $0, level: state.logLevel) }))
                            .labelsHidden().toggleStyle(ReferenceSwitchStyle(title: "启用应用诊断日志"))
                    }
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("日志级别")
                            Text("设置输出的最低日志级别").font(.system(size: 11)).foregroundStyle(PanelColors.secondary)
                        }
                        Spacer()
                        Picker("日志级别", selection: Binding(get: { state.logLevel }, set: { state.setDiagnostics(enabled: state.loggingEnabled, level: $0) })) {
                            ForEach(DiagnosticLevel.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden().frame(width: 125).disabled(!state.loggingEnabled)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("日志级别说明：").foregroundStyle(PanelColors.secondary).padding(.bottom, 2)
                        logDescription("error", "仅严重错误", color: .red)
                        logDescription("warn", "错误和警告信息", color: .yellow)
                        logDescription("info", "一般操作信息（默认）", color: PanelColors.text)
                        logDescription("debug", "详细状态事件", color: .green)
                        logDescription("trace", "全部诊断事件", color: PanelColors.muted)
                    }.font(.system(size: 11)).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(PanelColors.subtle, in: RoundedRectangle(cornerRadius: 9))
                }.font(.system(size: 13)).padding(18)
            }
        }
    }

    @ViewBuilder private var aboutContent: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 16) {
                    if let icon = Branding.appIcon { Image(nsImage: icon).resizable().interpolation(.high).frame(width: 56, height: 56) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Branding.fullName).font(.system(size: 16, weight: .semibold))
                        Text("版本 v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.5.0")")
                            .font(.system(size: 12)).foregroundStyle(PanelColors.secondary)
                    }
                    Spacer(minLength: 8)
                }.padding(22)
                settingDivider
                HStack(spacing: 8) {
                    Button { if let url = Bundle.main.url(forResource: "README", withExtension: "md") { NSWorkspace.shared.open(url) } } label: {
                        Label("使用说明", systemImage: "doc.text")
                    }.buttonStyle(OutlineButtonStyle())
                    Button { if let url = Bundle.main.url(forResource: "LICENSE", withExtension: nil) { NSWorkspace.shared.open(url) } } label: {
                        Label("许可证", systemImage: "doc.plaintext")
                    }.buttonStyle(OutlineButtonStyle())
                }.padding(16)
            }
        }
    }

    private var settingDivider: some View { Rectangle().fill(PanelColors.border).frame(height: 1) }

    private func settingGroup<Content: View>(_ title: String, symbol: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }.font(.system(size: 14, weight: .semibold))
            content()
        }
    }

    private func titleWithHelp(_ title: String, help: String) -> some View {
        HStack(spacing: 7) {
            Text(title)
            Image(systemName: "questionmark.circle").font(.system(size: 12)).foregroundStyle(PanelColors.muted).help(help)
        }
    }

    private func switchRow(_ title: String, description: String, value: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(description).font(.system(size: 11)).foregroundStyle(PanelColors.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            Toggle(title, isOn: value).labelsHidden().toggleStyle(ReferenceSwitchStyle(title: title))
        }.padding(.horizontal, 18).padding(.vertical, 14).frame(minHeight: 60)
    }

    private func logDescription(_ name: String, _ detail: String, color: Color) -> some View {
        HStack(spacing: 0) {
            Text(name).foregroundStyle(color).font(.system(size: 11, design: .monospaced))
            Text(" - \(detail)").foregroundStyle(PanelColors.secondary)
        }
    }

    private func directoryRow(_ title: String, value: Binding<String>, placeholder: String, defaultValue: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            titleWithHelp(title, help: help).font(.system(size: 13))
            HStack(spacing: 8) {
                TextField(placeholder, text: value).textFieldStyle(.plain).modifier(InputFrame())
                Button {
                    let picker = NSOpenPanel()
                    picker.canChooseFiles = false; picker.canChooseDirectories = true; picker.allowsMultipleSelection = false
                    if picker.runModal() == .OK, let url = picker.url { value.wrappedValue = url.path }
                } label: { Image(systemName: "folder") }.buttonStyle(OutlineButtonStyle()).help("选择目录").accessibilityLabel("选择\(title)")
                Button { value.wrappedValue = defaultValue } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(OutlineButtonStyle()).help("恢复默认目录").accessibilityLabel("恢复默认\(title)")
            }
        }
    }
}
