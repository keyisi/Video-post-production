import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 主题
enum Theme {
    static let accent = Color(hex: 0x5B6CFF)      // 靛蓝
    static let accentDeep = Color(hex: 0x8B5CF6)  // 紫
    static let ok = Color(hex: 0x34C759)
    static let warn = Color(hex: 0xFF9F0A)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let page = Color(nsColor: .windowBackgroundColor)
    static let consoleBg = Color(hex: 0x1B1D24)
}

extension Color {
    init(hex: UInt) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

@main
struct FrameToolApp: App {
    init() {
        // 自检: 直接运行二进制加 --selftest，输出 ffmpeg 定位结果（打包分享验证用）
        if CommandLine.arguments.contains("--selftest") {
            print("FFMPEG=\(ffmpegBin())")
            print("FFPROBE=\(ffprobeBin())")
            exit(0)
        }
    }
    var body: some Scene {
        WindowGroup("Video Post-Production") {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1080, height: 700)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("检查更新…") {
                    NotificationCenter.default.post(name: .fxtCheckUpdate, object: nil)
                }
                .keyboardShortcut("u", modifiers: .command)
                Button("打开 GitHub 发布页") {
                    if let url = URL(string: UpdateCheck.fallbackURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}

// MARK: - 根视图

extension Notification.Name {
    /// 菜单里的「检查更新」触发
    static let fxtCheckUpdate = Notification.Name("fxtCheckUpdate")
}

/// App 内更新的阶段
enum UpdatePhase {
    case idle, downloading, installing
}

/// 更新检查中心：顶栏徽章与「关于与更新」板块共用同一份状态
final class UpdateCenter: ObservableObject {
    @Published private(set) var isChecking = false
    @Published private(set) var found: ReleaseInfo?
    @Published private(set) var noticeTitle = ""
    @Published private(set) var noticeText = ""
    @Published private(set) var lastCheckedAt: Double = 0
    /// 本次更新信息走的是哪条通道（界面上展示，便于排查代理/TLS 问题）
    @Published private(set) var lastSource = ""
    @Published var showNotice = false
    @Published var showUpdateAlert = false
    /// 通知弹窗里是否提供「打开 GitHub 发布页」（网络失败时有）
    @Published private(set) var noticeCanOpenWeb = false

    // MARK: App 内更新（下载 → 替换 → 重启）
    @Published private(set) var phase: UpdatePhase = .idle
    @Published private(set) var downloadFraction: Double = 0
    @Published private(set) var downloadText = ""
    private var downloader: UpdateDownloader?

    private let ud = UserDefaults.standard

    init() {
        lastCheckedAt = ud.double(forKey: "fxt_lastUpdateCheck")
        restoreSavedUpdate()
    }

    var skippedVersion: String { ud.string(forKey: "fxt_skipVersion") ?? "" }

    var lastCheckedText: String {
        guard lastCheckedAt > 0 else { return "尚未检查" }
        let d = Date(timeIntervalSince1970: lastCheckedAt)
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return "上次检查 \(f.string(from: d))"
    }

    var statusText: String {
        if isChecking { return "正在检查…" }
        if let info = found { return "发现新版本 \(info.version)" }
        return "已是最新版本 \(displayVersion(currentAppVersion()))"
    }

    var updateAlertMessage: String {
        guard let info = found else { return "" }
        var msg = "当前版本 \(displayVersion(currentAppVersion()))，最新版本 \(displayVersion(info.version))。"
        if let name = info.assetName {
            var size = ""
            if let bytes = info.assetSize { size = "（\(prettySize(bytes))）" }
            msg += "\n安装包：\(name)\(size)"
        }
        let notes = UpdateCheck.briefNotes(info.notes)
        if !notes.isEmpty { msg += "\n\n" + notes }
        return msg
    }

    /// 启动时自动检查：距上次检查超过 6 小时才联网
    func startupCheck() {
        let now = Date().timeIntervalSince1970
        if now - lastCheckedAt < 6 * 3600 { return }
        check(manual: false)
    }

    /// 上次发现过的新版本（跨重启仍显示提示）
    private func restoreSavedUpdate() {
        let v = ud.string(forKey: "fxt_newVersion") ?? ""
        let url = ud.string(forKey: "fxt_newURL") ?? ""
        guard !v.isEmpty, v != skippedVersion,
              compareVersion(v, currentAppVersion()) > 0 else {
            if !v.isEmpty && compareVersion(v, currentAppVersion()) <= 0 { clearSaved() }
            return
        }
        var info = ReleaseInfo()
        info.version = v
        info.tag = v
        info.htmlURL = url.isEmpty ? UpdateCheck.fallbackURL : url
        found = info
    }

    func check(manual: Bool) {
        guard !isChecking else { return }
        isChecking = true
        UpdateCheck.fetchLatest { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isChecking = false
                self.lastCheckedAt = Date().timeIntervalSince1970
                self.ud.set(self.lastCheckedAt, forKey: "fxt_lastUpdateCheck")
                switch result {
                case .failure(let err):
                    self.lastSource = "全部通道均失败"
                    if manual {
                        self.notify("检查更新失败", err.localizedDescription, canOpenWeb: true)
                    }
                case .success(let info):
                    guard let info = info else {
                        if manual { self.notify("暂无更新", "仓库还没有发布任何 Release。") }
                        return
                    }
                    self.lastSource = info.source
                    let current = currentAppVersion()
                    if compareVersion(info.version, current) > 0 {
                        if info.version == self.skippedVersion {
                            self.clearSaved()
                            if manual {
                                self.notify("已是最新可安装版本",
                                            "\(displayVersion(info.version)) 已跳过，当前 \(displayVersion(current))。")
                            }
                            return
                        }
                        self.found = info
                        self.ud.set(info.version, forKey: "fxt_newVersion")
                        self.ud.set(info.htmlURL, forKey: "fxt_newURL")
                        self.showUpdateAlert = true
                    } else {
                        self.found = nil
                        self.clearSaved()
                        if manual {
                            self.notify("已是最新版本",
                                        "当前 v\(current)，与 GitHub 上的最新版本一致。")
                        }
                    }
                }
            }
        }
    }

    func skipCurrent() {
        guard let info = found else { return }
        ud.set(info.version, forKey: "fxt_skipVersion")
        found = nil
        clearSaved()
    }

    /// 清除「跳过此版本」记录，让提示重新出现
    func resetPrompts() {
        ud.removeObject(forKey: "fxt_skipVersion")
        ud.removeObject(forKey: "fxt_lastUpdateCheck")
        lastCheckedAt = 0
    }

    private func clearSaved() {
        ud.removeObject(forKey: "fxt_newVersion")
        ud.removeObject(forKey: "fxt_newURL")
    }

    private func notify(_ title: String, _ text: String, canOpenWeb: Bool = false) {
        noticeTitle = title
        noticeText = text
        noticeCanOpenWeb = canOpenWeb
        showNotice = true
    }

    func openReleasesPage() {
        if let url = URL(string: UpdateCheck.fallbackURL) { NSWorkspace.shared.open(url) }
    }

    // MARK: App 内一键更新

    var isBusyUpdating: Bool { phase != .idle }

    /// 下载最新安装包 → 解压校验 → 生成脚本替换自身并重启
    /// - `quit` 由视图层传入（一般是 `NSApp.terminate(nil)`）
    func installUpdate(quit: @escaping () -> Void) {
        guard !isBusyUpdating else { return }
        guard let info = found, let url = info.assetURL, !url.isEmpty else {
            notify("无法自动更新",
                   "这次 Release 里没有找到 zip 安装包，请到 GitHub 发布页手动下载（dmg 也可以）。",
                   canOpenWeb: true)
            return
        }
        phase = .downloading
        downloadFraction = 0
        downloadText = "开始下载…"

        downloader = UpdateDownloader()
        // 下载优先走系统代理（本机实测直连只有 24KB/s、代理 6.9MB/s），失败/太慢会自动换直连
        downloader?.start(urlString: url, useProxy: true,
                          progress: { [weak self] f, got, total in
            guard let self = self else { return }
            self.downloadFraction = f
            self.downloadText = "\(prettySize(got)) / \(prettySize(total))"
        }, done: { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let err):
                self.phase = .idle
                self.notify("下载失败", err.localizedDescription, canOpenWeb: true)
            case .success(let zip):
                self.phase = .installing
                self.downloadText = "解压并校验安装包…"
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let newApp = try UpdateInstall.unzip(zip)
                        try UpdateInstall.validate(newApp: newApp,
                                                   currentVersion: currentAppVersion())
                        try UpdateInstall.installAndRelaunch(newApp: newApp,
                                                             targetApp: Bundle.main.bundleURL,
                                                             quit: quit)
                    } catch {
                        DispatchQueue.main.async {
                            self.phase = .idle
                            self.notify("更新失败", error.localizedDescription, canOpenWeb: true)
                        }
                    }
                }
            }
        })
    }
}

struct ContentView: View {
    @AppStorage("fxt_section") private var section = 0
    @StateObject private var updates = UpdateCenter()

    var body: some View {
        HStack(spacing: 0) {
            // 左侧导航栏
            sidebar

            // 四个板块常驻视图树（不销毁）：切换回来时已选文件/日志/预览全部保留
            ZStack {
                sectionLayer(0) { ExtractView() }
                sectionLayer(1) { ComposeView() }
                sectionLayer(2) { OrganizerView() }
                sectionLayer(3) { AboutView() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 2)
            .environmentObject(updates)
        }
        .frame(minWidth: 960, maxWidth: .infinity, minHeight: 620, maxHeight: .infinity)
        .background(Theme.page)
        .preferredColorScheme(nil)
        // 板块由 5 个减为 4 个：老用户存的 tag 3/4 会指向空白页，先映射一次
        .onAppear { section = remapSection(section) }
        .task { updates.startupCheck() }
        .onReceive(NotificationCenter.default.publisher(for: .fxtCheckUpdate)) { _ in
            updates.check(manual: true)
        }
        .alert("发现新版本 \(updates.found?.version ?? "")", isPresented: $updates.showUpdateAlert) {
            Button("下载并安装") {
                updates.installUpdate { NSApp.terminate(nil) }
            }
            Button("去网页下载") {
                if let info = updates.found { openURL(info.htmlURL) }
            }
            Button("跳过此版本") { updates.skipCurrent() }
            Button("稍后提醒", role: .cancel) {}
        } message: {
            Text(updates.updateAlertMessage)
        }
    }

    // MARK: 侧边导航

    private let navItems: [(title: String, icon: String, tag: Int)] = [
        ("视频抽帧", "photo.on.rectangle.angled", 0),
        ("封面与结尾", "flag.checkered", 1),
        ("整理归档", "archivebox", 2),
        ("关于与更新", "info.circle", 3),
    ]

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(navItems, id: \.tag) { item in
                navButton(item.title, icon: item.icon, tag: item.tag)
            }
            .padding(.top, 16)

            Spacer()

            updateBadge
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
                .alert(updates.noticeTitle, isPresented: $updates.showNotice) {
                    if updates.noticeCanOpenWeb {
                        Button("打开 GitHub 发布页") { updates.openReleasesPage() }
                        Button("好", role: .cancel) {}
                    } else {
                        Button("好") {}
                    }
                } message: {
                    Text(updates.noticeText)
                }
        }
        .frame(width: 176)
        .frame(maxHeight: .infinity)
        .background(Theme.card)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(width: 1)
        }
    }

    private func navButton(_ title: String, icon: String, tag: Int) -> some View {
        let active = section == tag
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { section = tag }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: active ? .semibold : .regular))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12.5, weight: active ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(active ? Color.white : Color.primary.opacity(0.72))
            .background {
                if active {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(LinearGradient(colors: [Theme.accent, Theme.accentDeep],
                                             startPoint: .leading, endPoint: .trailing))
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }

    /// 侧边栏底部：版本号 / 检查中 / 新版本提示
    @ViewBuilder
    private var updateBadge: some View {
        if updates.isChecking {
            HStack(spacing: 5) {
                ProgressView().controlSize(.small).scaleEffect(0.65)
                Text("检查更新…").font(.system(size: 11))
            }
            .foregroundStyle(.secondary)
        } else if let info = updates.found {
            Button {
                updates.showUpdateAlert = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 11, weight: .semibold))
                    Text("新版本 \(info.version)").font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Theme.accent))
            }
            .buttonStyle(.plain)
            .help("查看更新内容并前往 GitHub 下载")
        } else {
            Button {
                updates.check(manual: true)
            } label: {
                Text(displayVersion(currentAppVersion()))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("当前版本，点击检查更新")
        }
    }

    private func openURL(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    /// 板块图层：非当前板块只隐藏、不销毁，保证 @State（列表/日志/预览）不丢
    @ViewBuilder
    private func sectionLayer<Content: View>(_ tag: Int,
                                             @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(section == tag ? 1 : 0)
            // 移出可视区：只靠 allowsHitTesting 不够，隐藏层仍会抢占拖放落点
            .offset(x: section == tag ? 0 : 20000)
            .allowsHitTesting(section == tag)
    }

}

// MARK: - 通用小组件

// 卡片容器
struct Card<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06)))
            .shadow(color: .black.opacity(0.05), radius: 4, y: 1)
    }
}

// 区块标题
struct FieldLabel: View {
    let icon: String
    let text: String
    init(_ icon: String, _ text: String) { self.icon = icon; self.text = text }
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(text).font(.system(size: 12, weight: .semibold))
        }
    }
}

// 输入框（统一样式）
struct NiceField: View {
    var placeholder: String
    @Binding var text: String
    var width: CGFloat? = nil
    var disabled = false

    init(_ placeholder: String, text: Binding<String>, width: CGFloat? = nil, disabled: Bool = false) {
        self.placeholder = placeholder
        self._text = text
        self.width = width
        self.disabled = disabled
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .disabled(disabled)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.12)))
            .frame(width: width)
    }
}

// 拖放区 + 已选文件列表
struct DropZone: View {
    let icon: String
    let title: String
    let hint: String
    let files: [String]
    let running: Bool
    let onPick: () -> Void
    let onClear: () -> Void
    let onDrop: ([NSItemProvider]) -> Bool

    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if files.isEmpty {
                // 空状态: 大拖放区
                VStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(targeted ? Theme.accent : Color.primary.opacity(0.35))
                    Text(title).font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(targeted ? Theme.accent : Color.primary.opacity(0.6))
                    Text(hint).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 26)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(targeted ? Theme.accent.opacity(0.07) : Color(nsColor: .controlBackgroundColor).opacity(0.6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        .foregroundStyle(targeted ? Theme.accent : Color.primary.opacity(0.18))
                )
                .contentShape(RoundedRectangle(cornerRadius: 12))
                .onTapGesture { if !running { onPick() } }
                .onDrop(of: [.fileURL], isTargeted: $targeted) { onDrop($0) }
            } else {
                // 已选: 文件列表
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Label("\(files.count) 个已选", systemImage: icon)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !running {
                            Button {
                                onPick()
                            } label: {
                                Image(systemName: "plus")
                            }
                            .buttonStyle(.plain)
                            .padding(4)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(Circle())
                            .help("继续添加（重新选择会替换）")
                            Button {
                                onClear()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .padding(4)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(Circle())
                            .help("清空")
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)

                    Divider().opacity(0.4)

                    // 完整列表，可滚动
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(files.indices, id: \.self) { i in
                                HStack(spacing: 7) {
                                    Image(systemName: fileIcon(files[i]))
                                        .font(.system(size: 10))
                                        .foregroundStyle(Theme.accent)
                                        .frame(width: 14)
                                    Text("\(i + 1). \(URL(fileURLWithPath: files[i]).lastPathComponent)")
                                        .font(.system(size: 11.5))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                            }
                        }
                    }
                    .frame(maxHeight: files.count > 8 ? 300 : .infinity)
                }
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
                .onDrop(of: [.fileURL], isTargeted: $targeted) { onDrop($0) }
            }
        }
    }

    func fileIcon(_ path: String) -> String {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            return "folder.fill"
        }
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "heic", "webp", "tiff", "bmp"].contains(ext) ? "photo.fill" : "film.fill"
    }
}

// 控制台日志
struct LogPanel: View {
    let logs: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Circle().fill(Color(hex: 0xFF5F57)).frame(width: 7, height: 7)
                Circle().fill(Color(hex: 0xFFBD2E)).frame(width: 7, height: 7)
                Circle().fill(Color(hex: 0x28C840)).frame(width: 7, height: 7)
                Text("处理日志").font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(logs.enumerated().reversed()), id: \.offset) { i, line in
                        Text(line)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(i == 0 ? Color(hex: 0x8BE28B) : Color.white.opacity(0.72))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.consoleBg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - 时间线（「封面与结尾」板块）

/// 两行时间线：行 1 总览（只读），行 2 尾部放大窗口（可拖）
struct TimelineBar: View {
    let model: TimelineModel
    let width: CGFloat
    /// 外部指定的冻结窗口（拖拽期间由内部状态覆盖）
    var frozenWindow: Double? = nil
    /// 拖拽中：(被拖的段, 新时长)
    var onDragChanged: ((SegmentID, Double) -> Void)? = nil
    /// 拖拽结束
    var onDragEnded: (() -> Void)? = nil

    /// 拖拽期间冻结的窗口总时长（按下瞬间写入，松手清空）
    @State private var dragFrozen: Double? = nil
    /// 按下瞬间该段的时长，拖拽全程以它为基准累加
    @State private var dragOrigin: Double = 0
    /// 非 nil 表示对应段被拖到了钳制上限
    @State private var hitLimit: SegmentID? = nil

    private var effectiveFrozen: Double? { dragFrozen ?? frozenWindow }

    private var overview: [LaidOutSegment] { model.overview(width: Double(width)) }
    private var tail: [LaidOutSegment] { model.layout(width: Double(width), frozenWindow: effectiveFrozen) }

    /// 秒/像素：拖拽换算与布局必须用同一个，否则边界会漂
    private var secPerPx: Double {
        let usable = max(Double(width) - 24, 1)
        return max(effectiveFrozen ?? model.windowDuration, 0.001) / usable
    }

    /// 段当前的时长
    private func current(_ id: SegmentID) -> Double {
        switch id {
        case .fadeOut: return model.fadeOut
        case .whiteHold: return model.whiteHold
        case .fadeIn: return model.fadeIn
        case .freeze: return model.freeze
        default: return 0
        }
    }

    /// 可拖手柄：(段, 手柄所在 x)
    private var handleSpecs: [(SegmentID, Double)] {
        tail.compactMap { seg in
            switch seg.id {
            case .fadeOut: return (.fadeOut, seg.x)                 // 拖左缘
            case .whiteHold: return (.whiteHold, seg.x + seg.width) // 拖右缘
            case .fadeIn: return (.fadeIn, seg.x + seg.width)
            case .freeze: return (.freeze, seg.x + seg.width)
            default: return nil
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 行 1 · 总览
            HStack(spacing: 5) {
                Image(systemName: "film")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("总览")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            trackRow(overview, height: 30)

            // 行 2 · 尾部放大窗口
            HStack(spacing: 5) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("结尾时间轴")
                    .font(.system(size: 12, weight: .semibold))
                Text("（正片已折叠，只放大末尾）")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("窗口 \(String(format: "%.2f", model.windowDuration)) 秒")
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            trackRow(tail, height: 44, handles: true)

            if let lim = hitLimit {
                Text(limitHint(for: lim))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.warn)
            } else {
                Text("拖动色块之间的小竖条可改时长；渐白叠在正片最后 \(String(format: "%.2f", model.fadeOut)) 秒上")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06)))
    }

    @ViewBuilder
    private func trackRow(_ segs: [LaidOutSegment], height: CGFloat,
                          handles: Bool = false) -> some View {
        ZStack(alignment: .leading) {
            ForEach(Array(segs.enumerated()), id: \.offset) { _, seg in
                Group {
                    if seg.width >= 1 {
                        segmentView(seg)
                    } else {
                        zeroWidthMarker(seg)
                    }
                }
                .frame(width: max(CGFloat(seg.width), 2), height: height)
                .offset(x: CGFloat(seg.x))
            }
            if handles {
                ForEach(Array(handleSpecs.enumerated()), id: \.offset) { _, h in
                    handleView(id: h.0, x: h.1, height: height)
                }
            }
        }
        .frame(width: width, height: height, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// 一个可拖的边界手柄：视觉是 5px 竖条，命中区放宽到 14px
    private func handleView(id: SegmentID, x: Double, height: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2)
                .fill(hitLimit == id ? Theme.warn : Color.primary.opacity(0.7))
                .frame(width: 5, height: height + 8)
        }
        .frame(width: 14, height: height + 8)
        .contentShape(Rectangle())
        .offset(x: CGFloat(x) - 7)
        .gesture(dragGesture(for: id))
        .help("拖动调整「\(title(of: id))」时长")
    }

    private func dragGesture(for id: SegmentID) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                if dragFrozen == nil {
                    dragFrozen = model.windowDuration
                    dragOrigin = current(id)
                }
                let delta = Double(v.translation.width) * secPerPx
                // 渐白拖的是左缘：往左拖 = 变长
                let wanted = id == .fadeOut ? dragOrigin - delta : dragOrigin + delta
                let clamped = model.clamp(wanted, for: id)
                hitLimit = abs(clamped - wanted) > 1e-6 ? id : nil
                onDragChanged?(id, clamped)
            }
            .onEnded { _ in
                let stepped = (current(id) / 0.05).rounded() * 0.05
                onDragChanged?(id, model.clamp(stepped, for: id))
                dragFrozen = nil
                hitLimit = nil
                onDragEnded?()
            }
    }

    private func title(of id: SegmentID) -> String {
        switch id {
        case .fadeOut: return "渐白"
        case .whiteHold: return "全白"
        case .fadeIn: return "渐显"
        case .freeze: return "定格"
        default: return ""
        }
    }

    private func limitHint(for id: SegmentID) -> String {
        switch id {
        case .fadeOut:
            let upper = model.sourceDuration > 0
                ? max(0.05, model.sourceDuration - 0.1) : 10
            return "渐白最长 \(String(format: "%.2f", upper)) 秒（正片 \(String(format: "%.1f", model.sourceDuration)) 秒）"
        case .whiteHold: return "全白保持范围 0 – 10 秒"
        case .fadeIn: return "渐显范围 0.05 – 10 秒"
        case .freeze: return "定格范围 0.1 – 30 秒"
        default: return ""
        }
    }

    @ViewBuilder
    private func segmentView(_ seg: LaidOutSegment) -> some View {
        let fill = color(for: seg.id)
            .opacity(seg.isOverlay ? 0.62 : 1)
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(fill)
            if seg.isOverlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 2]))
                    .foregroundStyle(color(for: seg.id))
            }
            VStack(spacing: 1) {
                if seg.width >= 24 {
                    Text(seg.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                }
                if seg.width >= 46 {
                    Text(String(format: "%.2fs", seg.duration))
                        .font(.system(size: 10, design: .rounded))
                        .monospacedDigit()
                }
            }
            .foregroundStyle(textColor(for: seg.id))
        }
    }

    /// 时长为 0 的段（全白）：画一条虚线缝，避免整段消失
    @ViewBuilder
    private func zeroWidthMarker(_ seg: LaidOutSegment) -> some View {
        if seg.id == .whiteHold {
            VStack(spacing: 1) {
                Text("全白 0s")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.warn)
                    .fixedSize()
                    .offset(y: -14)
                Rectangle()
                    .fill(Theme.warn)
                    .frame(width: 1.5)
            }
        } else {
            EmptyView()
        }
    }

    private func color(for id: SegmentID) -> Color {
        switch id {
        case .cover: return Color.primary.opacity(0.34)
        case .source: return Color.primary.opacity(0.16)
        case .fadeOut: return Theme.accent
        case .whiteHold: return Theme.warn
        case .fadeIn: return Theme.accentDeep
        case .freeze: return Theme.ok
        case .ending: return Theme.accent
        }
    }

    private func textColor(for id: SegmentID) -> Color {
        switch id {
        case .cover, .source: return .primary
        default: return .white
        }
    }
}

// 进度条（带百分比）
struct NiceProgress: View {
    let value: Double
    var label: String? = nil
    var body: some View {
        HStack(spacing: 10) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(LinearGradient(colors: [Theme.accent, Theme.accentDeep],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(6, geo.size.width * min(value, 1)))
                        .animation(.easeOut(duration: 0.2), value: value)
                }
            }
            .frame(height: 7)
            Text("\(Int(min(value, 1) * 100))%")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.accent)
                .frame(width: 36, alignment: .trailing)
            if let label {
                Text(label)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}

// MARK: - 板块 1: 视频抽帧
struct ExtractView: View {
    @AppStorage("fxt_namePrefix") private var namePrefix = ""
    @AppStorage("fxt_suffix") private var suffix = "_cover"
    @AppStorage("fxt_step") private var stepText = "1"
    @AppStorage("fxt_jpg") private var jpg = false
    @AppStorage("fxt_quality") private var qualityText = "0.9"

    @State private var videos: [String] = []
    @State private var outputDir = ""
    @State private var running = false
    @State private var progressValue: Double = 0
    @State private var logs: [String] = []
    @State private var summary = ""

    private var prefixValid: Bool {
        !namePrefix.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 1. 视频
            DropZone(icon: "film.stack", title: "拖入视频，或点击选择",
                     hint: "支持多选 · 每隔 N 秒截一帧，跨视频连续编号",
                     files: videos, running: running,
                     onPick: pickVideos, onClear: { videos = [] }, onDrop: handleDrop)

            // 2. 命名设置
            Card {
                FieldLabel("textformat", "命名规则")
                HStack(spacing: 8) {
                    NiceField("第一个图的名字，例如 Stranger Things EP02", text: $namePrefix, disabled: running)
                    Text("+").font(.system(size: 11, weight: .bold)).foregroundStyle(.tertiary)
                    NiceField("_cover", text: $suffix, width: 90, disabled: running)
                }
                if prefixValid {
                    Text("输出: \(namePrefix.trimmingCharacters(in: .whitespaces))\(suffix) 起，每帧依次 +1，跨视频连续编号")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }

            // 3. 参数
            Card {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel("timer", "间隔（秒）")
                        NiceField("1", text: $stepText, width: 70, disabled: running)
                    }
                    Divider().frame(height: 34)
                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel("photo", "图片格式")
                        Picker("", selection: $jpg) {
                            Text("PNG").tag(false)
                            Text("JPG").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 130)
                        .disabled(running)
                    }
                    if jpg {
                        Divider().frame(height: 34)
                        VStack(alignment: .leading, spacing: 6) {
                            FieldLabel("gauge", "JPG 质量")
                            NiceField("0.9", text: $qualityText, width: 60, disabled: running)
                        }
                        .transition(.opacity)
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        FieldLabel("folder", "输出目录")
                        NiceField("默认: 视频旁的 <起始名称>_covers", text: $outputDir, width: 190, disabled: running)
                        Button {
                            pickOutDir()
                        } label: {
                            Image(systemName: "folder.badge.plus").font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .padding(7)
                        .background(Theme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.1)))
                        .disabled(running)
                        .help("选择输出文件夹")
                    }
                }
            }

            // 4. 动作区
            HStack(spacing: 12) {
                Button {
                    start()
                } label: {
                    HStack(spacing: 7) {
                        if running {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "play.fill").font(.system(size: 11, weight: .bold))
                        }
                        Text(running ? "正在处理…" : "开始抽帧")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 9)
                    .foregroundStyle(.white)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(LinearGradient(colors: [Theme.accent, Theme.accentDeep],
                                                 startPoint: .leading, endPoint: .trailing))
                            .opacity(canStart ? 1 : 0.35)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!canStart)

                if !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.ok)
                        .lineLimit(1)
                }
                Spacer()
                if !running && !videos.isEmpty {
                    Button {
                        openOutput()
                    } label: {
                        Label("输出文件夹", systemImage: "folder")
                            .font(.system(size: 11.5))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Theme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1)))
                    .disabled(defaultOutDir() == nil)
                }
            }

            if running || progressValue > 0 {
                NiceProgress(value: progressValue)
            }

            LogPanel(logs: logs)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    var canStart: Bool { !running && !videos.isEmpty && prefixValid }

    func defaultOutDir() -> String? {
        if !outputDir.isEmpty { return outputDir }
        let p = namePrefix.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, let first = videos.first else { return nil }
        return URL(fileURLWithPath: first).deletingLastPathComponent()
            .appendingPathComponent("\(p)_covers").path
    }

    func openOutput() {
        if let od = defaultOutDir(), FileManager.default.fileExists(atPath: od) {
            NSWorkspace.shared.open(URL(fileURLWithPath: od))
        }
    }

    func pickVideos() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .video, .avi]
        if panel.runModal() == .OK {
            videos = panel.urls.map { $0.path }
        }
    }

    func pickOutDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择输出文件夹"
        if panel.runModal() == .OK, let url = panel.url {
            outputDir = url.path
        }
    }

    func collectURLs(_ providers: [NSItemProvider]) -> [URL] {
        var urls: [URL] = []
        let group = DispatchGroup()
        let q = DispatchQueue(label: "drop")
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { q.async { urls.append(url); group.leave() } } else { group.leave() }
            }
        }
        group.wait()
        return urls
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let urls = collectURLs(providers)
        DispatchQueue.main.async {
            videos = urls.map { $0.path }
        }
        return !urls.isEmpty
    }

    func start() {
        let prefix = namePrefix.trimmingCharacters(in: .whitespaces)
        guard !prefix.isEmpty else {
            summary = "请填写起始名称"; return
        }
        // 兼容全角数字 / 中文逗号小数点
        let normalized = stepText.replacingOccurrences(of: "，", with: ".")
            .replacingOccurrences(of: ",", with: ".")
        let half = normalized.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? normalized
        guard let step = Double(half), step > 0 else {
            summary = "间隔必须是大于 0 的数字"; return
        }
        var quality = 0.9
        if jpg { quality = Double(qualityText) ?? 0.9 }
        let out = outputDir.isEmpty ? (defaultOutDir() ?? NSHomeDirectory()) : outputDir

        let job = UnifiedJob(videos: videos, outputDir: out, step: step, jpg: jpg,
                             quality: quality, startName: prefix, suffix: suffix)
        running = true
        summary = ""
        progressValue = 0
        logs = ["开始处理 \(videos.count) 个视频，输出到 \(out)"]

        DispatchQueue.global(qos: .userInitiated).async {
            let r = runUnifiedJob(job) { done, total, log in
                DispatchQueue.main.async {
                    progressValue = Double(done) / Double(max(total, 1))
                    logs.append(log)
                    if logs.count > 300 { logs.removeFirst(logs.count - 300) }
                }
            }
            DispatchQueue.main.async {
                running = false
                summary = "完成: 保存 \(r.saved) 张, 跳过 \(r.skipped) 张"
                logs.append(summary)
            }
        }
    }
}

// MARK: - 板块: 封面与结尾（时间线）

struct ComposeView: View {
    // 文件列表用新 key（旧 key 在 onAppear 迁移一次）
    @AppStorage("fxt_compVideos") private var videosRaw = ""
    @AppStorage("fxt_compCovers") private var coversRaw = ""
    @AppStorage("fxt_compEndingOn") private var endingOn = true
    // 时间参数复用原有 key：语义没变，老用户升级后不用重设
    @AppStorage("fxt_endFadeOut") private var fadeOutText = "0.25"
    @AppStorage("fxt_endWhiteHold") private var whiteHoldText = "0"
    @AppStorage("fxt_endFadeIn") private var fadeInText = "0.25"
    @AppStorage("fxt_endFreeze") private var freezeText = "1"
    @AppStorage("fxt_endSfxOffset") private var sfxOffsetText = "0"
    @AppStorage("fxt_endSfx") private var sfxPath = ""
    @AppStorage("fxt_endSuffix") private var suffix = "定格白场"
    @AppStorage("fxt_endRename") private var rename = true
    @AppStorage("fxt_endOverwrite") private var overwrite = false
    @AppStorage("fxt_endOutDir") private var outDirCustom = ""
    @AppStorage("fxt_endAFade") private var audioFadeOn = false
    @AppStorage("fxt_endAFadeDur") private var audioFadeDurText = "0.5"
    @AppStorage("fxt_endSpeed") private var encSpeed = EncodeSpeed.fast.rawValue
    @AppStorage("fxt_sizeMode") private var sizeMode = SizeMode.match.rawValue
    // 迁移用的旧 key（只读一次）
    @AppStorage("fxt_endVideos") private var legacyEndVideos = ""
    @AppStorage("fxt_insVideos") private var legacyInsVideos = ""
    @AppStorage("fxt_insCovers") private var legacyInsCovers = ""

    @State private var running = false
    @State private var stopping = false
    @State private var progressValue: Double = 0
    @State private var currentIdx = 0
    @State private var logs: [String] = []
    @State private var summary = ""
    @State private var sourceDuration: Double = 0
    @State private var coverFrame: Double = 1.0 / 24
    @State private var probed = false

    private var currentSpeed: EncodeSpeed { EncodeSpeed(rawValue: encSpeed) ?? .fast }
    private var currentSize: SizeMode { SizeMode(rawValue: sizeMode) ?? .match }
    private var videos: [String] { videosRaw.isEmpty ? [] : videosRaw.components(separatedBy: "\n") }
    private var covers: [String] { coversRaw.isEmpty ? [] : coversRaw.components(separatedBy: "\n") }
    private var sfxExists: Bool { !sfxPath.isEmpty && FileManager.default.fileExists(atPath: sfxPath) }
    private var matchedCount: Int {
        videos.filter { findCover(forVideo: $0, covers: covers) != nil }.count
    }

    private var timeline: TimelineModel {
        var m = TimelineModel()
        m.sourceDuration = sourceDuration
        m.coverFrame = coverFrame
        m.fadeOut = parseNum(fadeOutText, fallback: 0.25)
        m.whiteHold = parseNum(whiteHoldText, fallback: 0)
        m.fadeIn = parseNum(fadeInText, fallback: 0.25)
        m.freeze = parseNum(freezeText, fallback: 1)
        m.endingEnabled = endingOn
        return m
    }

    /// 解析数字输入：兼容全角数字 / 中文逗号小数点
    func parseNum(_ text: String, fallback: Double) -> Double {
        let normalized = text.replacingOccurrences(of: "，", with: ".")
            .replacingOccurrences(of: ",", with: ".")
        let half = normalized.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? normalized
        return Double(half) ?? fallback
    }

    var settings: JobSettings {
        var s = timeline.toJobSettings()
        s.sfxOffset = parseNum(sfxOffsetText, fallback: 0)
        s.suffix = rename ? (suffix.isEmpty ? "定格白场" : suffix) : ""
        s.overwrite = overwrite
        let custom = outDirCustom.trimmingCharacters(in: .whitespaces)
        s.outputDir = custom.isEmpty ? nil : custom
        s.sfxPath = sfxExists ? sfxPath : nil
        s.audioFade = audioFadeOn ? max(0.05, parseNum(audioFadeDurText, fallback: 0.5)) : 0
        s.speed = currentSpeed
        s.sizeMode = currentSize
        return s
    }

    var canStart: Bool { !running && !videos.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // 1. 视频
                DropZone(icon: "film.stack", title: "拖入视频，或点击选择",
                         hint: "支持多选 · 封面按集数自动匹配对应视频",
                         files: videos, running: running,
                         onPick: pickVideos, onClear: { videosRaw = "" }, onDrop: handleDropVideos)

                // 2. 封面
                DropZone(icon: "photo.stack", title: "拖入封面图，或点击选择",
                         hint: "支持多选 · 文件名需含集数，如 Stranger Things EP02_cover.jpg",
                         files: covers, running: running,
                         onPick: pickCovers, onClear: { coversRaw = "" }, onDrop: handleDropCovers)

                if !videos.isEmpty && !covers.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: matchedCount == videos.count
                              ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(matchedCount == videos.count ? Theme.ok : Theme.warn)
                        Text("\(matchedCount)/\(videos.count) 个视频已按集数配对封面")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(matchedCount == videos.count ? Theme.ok : Theme.warn)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Theme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
                }

                // 3. 时间线
                GeometryReader { geo in
                    TimelineBar(model: timeline, width: max(geo.size.width, 240),
                                onDragChanged: applyDrag, onDragEnded: {})
                }
                .frame(height: 220)

                // 4. 结尾开关 + 时间轴参数
                Card {
                    HStack(spacing: 8) {
                        Toggle("处理结尾", isOn: $endingOn)
                            .toggleStyle(.switch)
                            .font(.system(size: 12, weight: .semibold))
                            .disabled(running)
                        Text(endingOn
                             ? "封面 + 结尾一次编码完成（少一遍转码）"
                             : "只把封面插入视频开头，不动结尾")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    if endingOn {
                        Divider().opacity(0.4)
                        FieldLabel("timer", "时间轴参数（秒）")
                        HStack(spacing: 10) {
                            endField("渐白", $fadeOutText)
                            endField("全白保持", $whiteHoldText)
                            endField("渐显", $fadeInText)
                            endField("定格", $freezeText)
                            endField("音效偏移", $sfxOffsetText)
                            Spacer()
                        }
                        HStack(spacing: 8) {
                            Toggle("原视频音频淡出", isOn: $audioFadeOn).toggleStyle(.checkbox)
                                .font(.system(size: 11))
                                .disabled(running)
                            NiceField("0.5", text: $audioFadeDurText, width: 60, disabled: running || !audioFadeOn)
                            Text("秒 · 正片音频在结尾渐弱到无声")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                                .opacity(audioFadeOn ? 1 : 0.5)
                            Spacer()
                        }
                    }
                }

                // 5. 音效
                if endingOn {
                    Card {
                        FieldLabel("speaker.wave.2", "音效")
                        HStack(spacing: 8) {
                            Image(systemName: sfxExists ? "checkmark.circle.fill" : "exclamationmark.circle")
                                .font(.system(size: 11))
                                .foregroundStyle(sfxExists ? Theme.ok : Color.primary.opacity(0.35))
                            NiceField("音效文件路径（留空则不加音效）", text: $sfxPath, disabled: running)
                            Button { pickSFX() } label: {
                                Image(systemName: "folder.badge.plus").font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .padding(7)
                            .background(Theme.card)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.1)))
                            .disabled(running)
                            .help("选择音效文件")
                        }
                    }
                }

                // 6. 输出
                Card {
                    FieldLabel("folder", "输出")
                    HStack(spacing: 8) {
                        NiceField(endingOn ? "默认: 每个视频旁的「加结尾」文件夹"
                                          : "默认: 每个视频旁的「加封面」文件夹",
                                  text: $outDirCustom, disabled: running)
                        Button { pickOutDir() } label: {
                            Image(systemName: "folder.badge.plus").font(.system(size: 11))
                        }
                        .buttonStyle(.plain).padding(7).background(Theme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.1)))
                        .disabled(running)
                        Button { openOutput() } label: {
                            Label("打开", systemImage: "folder").font(.system(size: 11.5))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Theme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.1)))
                        .disabled(running || videos.isEmpty)
                    }
                    if endingOn {
                        HStack(spacing: 10) {
                            FieldLabel("slider.horizontal.3", "输出体积")
                            Picker("", selection: $sizeMode) {
                                ForEach(SizeMode.allCases, id: \.rawValue) { m in
                                    Text(m.label).tag(m.rawValue)
                                }
                            }
                            .pickerStyle(.segmented).labelsHidden().frame(width: 160)
                            .disabled(running)
                            Text(currentSize.hint).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                            Spacer()
                        }
                        HStack(spacing: 10) {
                            FieldLabel("gauge", "编码速度")
                            Picker("", selection: $encSpeed) {
                                ForEach(EncodeSpeed.allCases, id: \.rawValue) { s in
                                    Text(s.label).tag(s.rawValue)
                                }
                            }
                            .pickerStyle(.segmented).labelsHidden().frame(width: 160)
                            .disabled(running)
                            Text(currentSpeed.hint).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                            Spacer()
                        }
                        HStack(spacing: 8) {
                            Toggle("文件名加后缀", isOn: $rename).toggleStyle(.checkbox)
                                .font(.system(size: 11)).disabled(running)
                            NiceField("定格白场", text: $suffix, width: 120, disabled: running || !rename)
                            Toggle("覆盖已存在", isOn: $overwrite).toggleStyle(.checkbox)
                                .font(.system(size: 11)).disabled(running)
                            Spacer()
                        }
                    }
                }

                // 7. 日志
                LogPanel(logs: logs).frame(minHeight: 120)

                // 8. 动作区
                HStack(spacing: 12) {
                    Button { start() } label: {
                        HStack(spacing: 7) {
                            if running {
                                ProgressView().controlSize(.small).tint(.white)
                            } else {
                                Image(systemName: endingOn ? "sparkles" : "photo.badge.plus")
                                    .font(.system(size: 11, weight: .bold))
                            }
                            Text(running ? "正在处理…"
                                 : (endingOn ? "封面 + 结尾一次编码" : "把封面插入视频开头"))
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .padding(.horizontal, 22).padding(.vertical, 9)
                        .foregroundStyle(.white)
                        .background(
                            RoundedRectangle(cornerRadius: 9)
                                .fill(LinearGradient(colors: [Theme.accent, Theme.accentDeep],
                                                     startPoint: .leading, endPoint: .trailing))
                                .opacity(canStart ? 1 : 0.35))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canStart)

                    if running {
                        Button { stop() } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "stop.fill").font(.system(size: 10.5, weight: .bold))
                                Text(stopping ? "正在停止…" : "停止处理")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .padding(.horizontal, 18).padding(.vertical, 9)
                            .foregroundStyle(.white)
                            .background(RoundedRectangle(cornerRadius: 9)
                                .fill(Theme.warn.opacity(stopping ? 0.45 : 0.95)))
                        }
                        .buttonStyle(.plain)
                        .disabled(stopping)
                    }

                    if !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(summary.hasPrefix("已停止") ? Theme.warn : Theme.ok)
                            .lineLimit(1)
                    }
                    Spacer()
                }

                if running || progressValue > 0 {
                    NiceProgress(value: progressValue,
                                 label: running ? "\(min(currentIdx + 1, max(videos.count, 1)))/\(videos.count)" : nil)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .onAppear {
            migrateLegacyFiles()
            if sfxPath.isEmpty { sfxPath = EndingEngine.defaultSFX }
            refreshProbe()
        }
        .onChange(of: videosRaw) { _ in refreshProbe() }
    }

    // MARK: 迁移与探测

    /// 旧板块的文件列表搬过来一次
    private func migrateLegacyFiles() {
        guard videosRaw.isEmpty else { return }
        if !legacyEndVideos.isEmpty { videosRaw = legacyEndVideos }
        else if !legacyInsVideos.isEmpty { videosRaw = legacyInsVideos }
        if coversRaw.isEmpty, !legacyInsCovers.isEmpty { coversRaw = legacyInsCovers }
    }

    /// 只 probe 第一个视频：时长与 fps（封面时长 = 1 帧）
    private func refreshProbe() {
        guard let first = videos.first else {
            sourceDuration = 0; coverFrame = 1.0 / 24; probed = false; return
        }
        DispatchQueue.global(qos: .utility).async {
            let dur = probeDuration(first) ?? 0
            let fps = probeVideoInfo(first)?.2 ?? 24
            DispatchQueue.main.async {
                sourceDuration = dur
                coverFrame = fps > 0 ? 1.0 / fps : 1.0 / 24
                probed = dur > 0
            }
        }
    }

    // MARK: 时间线交互

    private func applyDrag(_ id: SegmentID, _ value: Double) {
        let text = String(format: "%.2f", value)
        switch id {
        case .fadeOut: fadeOutText = text
        case .whiteHold: whiteHoldText = text
        case .fadeIn: fadeInText = text
        case .freeze: freezeText = text
        default: break
        }
    }

    private func endField(_ label: String, _ binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary)
            NiceField("", text: binding, width: 78, disabled: running)
        }
    }

    // MARK: 输出目录

    private func currentOutDir(for video: String) -> String {
        let custom = outDirCustom.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty { return custom }
        let folder = endingOn ? "加结尾" : "加封面"
        return URL(fileURLWithPath: video).deletingLastPathComponent()
            .appendingPathComponent(folder).path
    }

    private var effectiveOutDir: String? {
        let custom = outDirCustom.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty { return custom }
        guard let first = videos.first else { return nil }
        return URL(fileURLWithPath: first).deletingLastPathComponent()
            .appendingPathComponent(endingOn ? "加结尾" : "加封面").path
    }

    private func openOutput() {
        if let od = effectiveOutDir, FileManager.default.fileExists(atPath: od) {
            NSWorkspace.shared.open(URL(fileURLWithPath: od))
        }
    }

    // MARK: 文件选择

    func pickVideos() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .video, .avi]
        if panel.runModal() == .OK { videosRaw = panel.urls.map { $0.path }.joined(separator: "\n") }
    }

    func pickCovers() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK { coversRaw = panel.urls.map { $0.path }.joined(separator: "\n") }
    }

    func pickSFX() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        if panel.runModal() == .OK, let u = panel.url { sfxPath = u.path }
    }

    func pickOutDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let u = panel.url { outDirCustom = u.path }
    }

    func collectURLs(_ providers: [NSItemProvider]) -> [URL] {
        var urls: [URL] = []
        let group = DispatchGroup()
        let q = DispatchQueue(label: "dropc")
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { q.async { urls.append(url); group.leave() } } else { group.leave() }
            }
        }
        group.wait()
        return urls
    }

    func handleDropVideos(_ providers: [NSItemProvider]) -> Bool {
        if running { return false }
        let urls = collectURLs(providers)
        DispatchQueue.main.async { videosRaw = urls.map { $0.path }.joined(separator: "\n") }
        return !urls.isEmpty
    }

    func handleDropCovers(_ providers: [NSItemProvider]) -> Bool {
        if running { return false }
        let urls = collectURLs(providers)
        DispatchQueue.main.async { coversRaw = urls.map { $0.path }.joined(separator: "\n") }
        return !urls.isEmpty
    }

    // MARK: 执行

    func start() {
        let list = videos
        let coverList = covers
        let s = settings
        let withEnding = endingOn
        running = true
        stopping = false
        summary = ""
        progressValue = 0
        currentIdx = 0
        RunControl.shared.begin()
        let customDir = outDirCustom.trimmingCharacters(in: .whitespaces)
        let folder = withEnding ? "加结尾" : "加封面"
        if customDir.isEmpty {
            for d in Set(list.map {
                URL(fileURLWithPath: $0).deletingLastPathComponent()
                    .appendingPathComponent(folder).path }) {
                try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
            }
        } else {
            try? FileManager.default.createDirectory(atPath: customDir, withIntermediateDirectories: true)
        }

        let modeText: String
        if !withEnding { modeText = "只插封面" }
        else if coverList.isEmpty { modeText = "结尾处理" }
        else { modeText = "封面+结尾（一次编码）" }
        var head = "开始\(modeText) \(list.count) 个视频"
        if withEnding {
            head += "：渐白 \(s.fadeOut)秒 / 全白保持 \(s.whiteHold)秒 / 渐显 \(s.fadeIn)秒 / 定格 \(s.freeze)秒"
                + "，音效：\(s.sfxPath ?? "无")"
                + (s.audioFade > 0 ? "，原视频音频淡出 \(s.audioFade)秒" : "")
                + "，编码 \(s.speed.label)，体积 \(s.sizeMode.label)"
        } else {
            head += "：\(coverList.count) 张封面按集数匹配，体积 \(s.sizeMode.label)"
        }
        head += customDir.isEmpty ? "，输出到每个视频旁的「\(folder)」文件夹" : "，输出到 \(customDir)"
        logs = [head]

        let size = currentSize
        DispatchQueue.global(qos: .userInitiated).async {
            var okCount = 0, failCount = 0
            var stopped = false
            let batchStart = Date()
            for (vi, video) in list.enumerated() {
                if RunControl.shared.isCancelled { stopped = true; break }
                let vName = URL(fileURLWithPath: video).lastPathComponent
                let outDir = customDir.isEmpty
                    ? URL(fileURLWithPath: video).deletingLastPathComponent()
                        .appendingPathComponent(folder).path
                    : customDir

                if !withEnding {
                    // 路径 A：只插封面 → 文件名不变
                    guard let cover = findCover(forVideo: video, covers: coverList) else {
                        failCount += 1
                        DispatchQueue.main.async {
                            logs.append("[\(vi+1)/\(list.count)] \(vName) 跳过: 没有匹配集数的封面图")
                            progressValue = Double(vi + 1) / Double(list.count); currentIdx = vi + 1
                        }
                        continue
                    }
                    let cName = URL(fileURLWithPath: cover).lastPathComponent
                    let t0 = Date()
                    let ok = insertCoverToVideo(video, coverPath: cover, outputDir: outDir,
                                                sizeMode: size) { msg in
                        DispatchQueue.main.async { logs.append("[\(vi+1)/\(list.count)] \(msg)") }
                    }
                    if RunControl.shared.isCancelled { stopped = true; break }
                    if ok { okCount += 1 } else { failCount += 1 }
                    let used = Date().timeIntervalSince(t0)
                    DispatchQueue.main.async {
                        logs.append("[\(vi+1)/\(list.count)] \(vName) ← \(cName) \(ok ? "✓" : "✗")（用时 \(humanDuration(used))）")
                        progressValue = Double(vi + 1) / Double(list.count); currentIdx = vi + 1
                    }
                    continue
                }

                // 路径 B：结尾（有封面就一次编码）
                var sv = s
                sv.outputDir = outDir
                let prog: (Double) -> Void = { frac in
                    let base = Double(vi) / Double(list.count)
                    let span = 1.0 / Double(list.count)
                    DispatchQueue.main.async {
                        progressValue = min(base + span * max(0, min(frac, 1)), 1)
                    }
                }
                DispatchQueue.main.async { currentIdx = vi + 1 }
                let res: EndingResult
                if let cover = findCover(forVideo: video, covers: coverList) {
                    res = EndingEngine.runCombined(input: video, cover: cover, settings: sv, onProgress: prog)
                } else {
                    res = EndingEngine.run(input: video, settings: sv, onProgress: prog)
                    if !coverList.isEmpty {
                        DispatchQueue.main.async {
                            logs.append("[\(vi+1)/\(list.count)] \(vName) 未匹配到封面，只做结尾处理")
                        }
                    }
                }
                if res.cancelled {
                    stopped = true
                    DispatchQueue.main.async { logs.append("[\(vi+1)/\(list.count)] \(vName) ⊘ 已停止") }
                    break
                }
                if res.success { okCount += 1 } else { failCount += 1 }
                let line = "[\(vi+1)/\(list.count)] \(vName) \(res.success ? "✓" : "✗") \(res.message)"
                DispatchQueue.main.async {
                    logs.append(line)
                    if logs.count > 300 { logs.removeFirst(logs.count - 300) }
                    progressValue = Double(vi + 1) / Double(list.count)
                }
            }
            let wall = Date().timeIntervalSince(batchStart)
            let summaryText: String
            if stopped {
                let rest = max(list.count - okCount - failCount, 0)
                summaryText = "已停止: 完成 \(okCount) 个，剩余 \(rest) 个未处理 · 已用时 \(humanDuration(wall))"
            } else {
                summaryText = "处理完成: 成功 \(okCount) 个, 失败 \(failCount) 个 · 总用时 \(humanDuration(wall))"
            }
            DispatchQueue.main.async {
                running = false
                stopping = false
                RunControl.shared.reset()
                summary = summaryText
                logs.append(summaryText)
            }
        }
    }

    func stop() {
        guard running, !stopping else { return }
        stopping = true
        logs.append("正在停止…（等待当前视频的编码进程退出，已完成的不受影响）")
        RunControl.shared.cancel()
    }
}

// MARK: - 板块 4: 整理归档（短剧整理助手：命名模板 + 分类夹归档 + 撤销 + CSV）
struct OrganizerView: View {
    @State private var folderURL: URL?
    @State private var title: String = ""
    // 整理为分类夹：默认开启（原开关已按需求移除）
    private let organize = true

    // 命名模板
    @State private var template: String = AppSettings.fallback.template
    @State private var presets: [String] = AppSettings.fallback.templates
    @State private var showTemplateHelp = false

    // 分类夹固定默认名（原自定义 UI 已按需求移除）
    private let currentCats = CategoryNames(sub: "字幕", clean: "纯净", main: "成片")
    private let currentOutput: URL? = nil

    @State private var plan: [PlanItem] = []
    @State private var notes: [String] = []
    @State private var errors: [String] = []
    @State private var logs: [String] = []
    @State private var emptyFolders: [URL] = []
    @State private var showPicker = false
    @State private var busy = false
    @State private var executed = false
    @State private var canUndo = false
    @State private var showUndoConfirm = false
    @State private var scanWork: DispatchWorkItem?

    var conflictCount: Int { plan.filter(\.conflict).count }
    var duplicateCount: Int { plan.filter(\.duplicate).count }
    var blocked: Bool { duplicateCount > 0 || !errors.isEmpty }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            // 1. 素材文件夹
            DropZone(icon: "folder.badge.gearshape",
                     title: "拖入素材文件夹，或点击选择",
                     hint: "文件夹内的视频/字幕将按模板整理，可分类归档",
                     files: folderURL == nil ? [] : [folderURL!.path],
                     running: busy,
                     onPick: { showPicker = true },
                     onClear: clearFolder,
                     onDrop: handleFolderDrop)

            // 2. 命名参数
            Card {
                FieldLabel("textformat", "剧名与命名模板")
                HStack(spacing: 8) {
                    Text("剧名").font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .leading)
                    NiceField("输入剧名，用于 {剧名} 占位", text: $title, disabled: busy)
                        .onSubmit { runScan() }
                    Spacer()
                }
                HStack(spacing: 8) {
                    Text("模板").font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .leading)
                    NiceField("命名模板：{剧名} EP{序号}", text: $template, width: 240, disabled: busy)
                        .onSubmit { runScan() }
                    Menu {
                        ForEach(presets, id: \.self) { p in
                            Button(p) { template = p }
                        }
                        Divider()
                        Button("把当前模板存为预设") {
                            let t = template.trimmingCharacters(in: .whitespaces)
                            if !t.isEmpty, !presets.contains(t) {
                                presets.append(t); persistSettings()
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "bookmark").font(.system(size: 10))
                            Text("预设").font(.system(size: 11))
                        }
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.12)))
                    }
                    .fixedSize()
                    Button { showTemplateHelp = true } label: {
                        Image(systemName: "questionmark.circle").font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .help("查看可用占位符")
                    Spacer()
                }
            }

            // 4. 执行与状态
            HStack(spacing: 10) {
                Button { runExecute() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 11, weight: .bold))
                        Text("执行整理").font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(LinearGradient(colors: [Theme.accent, Theme.accentDeep],
                                                 startPoint: .leading, endPoint: .trailing))
                    )
                }
                .buttonStyle(.plain)
                .disabled(plan.isEmpty || blocked || busy)
                .opacity(plan.isEmpty || blocked || busy ? 0.35 : 1)

                miniBtn("导出对照表…", icon: "doc.text", disabled: plan.isEmpty || busy) { exportCSV() }
                if executed {
                    miniBtn("打开文件夹", icon: "folder", disabled: false) {
                        if let u = folderURL { NSWorkspace.shared.open(u) }
                    }
                }
                Spacer()
                if duplicateCount > 0 {
                    Label("重复命名 \(duplicateCount) 项，已阻止执行", systemImage: "xmark.octagon.fill")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color(hex: 0xFF5F57))
                } else if !plan.isEmpty {
                    Label("共 \(plan.count) 项" + (conflictCount > 0 ? "，冲突 \(conflictCount) 项" : ""),
                          systemImage: conflictCount > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(conflictCount > 0 ? Theme.warn : Theme.ok)
                }
                miniBtn("撤销上次执行", icon: "arrow.uturn.backward", disabled: !canUndo || busy) { showUndoConfirm = true }
                    .help("把最近一次执行的所有文件移回原位")
                if busy { ProgressView().controlSize(.small) }
            }

            // 5. 预览表
            if !plan.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("整理预览").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Text("原文件 → 目标").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    Divider().opacity(0.4)
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(plan) { it in
                                HStack(spacing: 8) {
                                    Text(it.kind.rawValue)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(kindColor(it.kind))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(kindColor(it.kind).opacity(0.12)))
                                        .frame(width: 48, alignment: .leading)
                                    Text(it.source.lastPathComponent)
                                        .font(.system(size: 11.5, weight: it.duplicate ? .semibold : .regular))
                                        .foregroundStyle(it.duplicate ? Color(hex: 0xFF5F57) : Color.primary.opacity(0.85))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Image(systemName: "arrow.right")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                    Text(targetText(it))
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(it.conflict ? Theme.warn : Color.primary.opacity(0.6))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    if it.duplicate {
                                        Image(systemName: "xmark.octagon.fill")
                                            .font(.system(size: 11))
                                            .foregroundStyle(Color(hex: 0xFF5F57))
                                            .help("与计划内其他目标重名")
                                    } else if it.conflict {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .font(.system(size: 11))
                                            .foregroundStyle(Theme.warn)
                                            .help("目标已存在")
                                    }
                                    Text(prettySize(it.size))
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 60, alignment: .trailing)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                Divider().opacity(0.15)
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
            }

            // 6. 处理日志
            LogPanel(logs: consoleLines)
                .frame(height: 130)

            // 7. 空文件夹清理
            if executed && !emptyFolders.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.warn)
                    Text("另有 \(emptyFolders.count) 个空文件夹").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    miniBtn("清掉（进废纸篓）", icon: "trash.slash", disabled: false) { runTrashEmpty() }
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { selectFolder(url) }
        }
        .onAppear { loadSavedSettings() }
        .confirmationDialog("撤销最近一次执行？所有文件会被移回原位。", isPresented: $showUndoConfirm, titleVisibility: .visible) {
            Button("撤销", role: .destructive) { runUndo() }
            Button("取消", role: .cancel) {}
        }
        .popover(isPresented: $showTemplateHelp) {
            VStack(alignment: .leading, spacing: 6) {
                Text("可用占位符").font(.system(size: 12, weight: .semibold))
                ForEach(templatePlaceholders, id: \.token) { p in
                    HStack(spacing: 10) {
                        Text(p.token).font(.system(size: 11.5, design: .monospaced)).frame(width: 90, alignment: .leading)
                        Text(p.desc).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
                Divider()
                Text("示例：{剧名} EP{序号} → 剧名 EP41.mp4").font(.system(size: 10.5)).foregroundStyle(.secondary)
                Text("示例：{剧名}_{序号}_{日期}.{扩展名} → 剧名_41_2026-09-27.mp4").font(.system(size: 10.5)).foregroundStyle(.secondary)
                Text("非法字符 / \\ : ? % * | \" < > 会被拦截并提示；重名目标会标红并阻止执行。")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(width: 420)
        }
    }

    // MARK: 样式辅助

    private var consoleLines: [String] {
        errors.map { "✗ \($0)" } + notes.map { "· \($0)" } + logs
    }

    private func targetText(_ it: PlanItem) -> String {
        let dir = it.target.deletingLastPathComponent()
        let folderPath = folderURL?.resolvingSymlinksInPath().path
        let base = (dir.path == folderPath) ? "" : dir.lastPathComponent + "/"
        return base + it.target.lastPathComponent
    }

    @ViewBuilder
    private func miniBtn(_ title: String, icon: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10.5, weight: .semibold))
                Text(title).font(.system(size: 11.5, weight: .medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }

    func collectURLs(_ providers: [NSItemProvider]) -> [URL] {
        var urls: [URL] = []
        let group = DispatchGroup()
        let q = DispatchQueue(label: "orgdrop")
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { q.async { urls.append(url); group.leave() } } else { group.leave() }
            }
        }
        group.wait()
        return urls
    }

    func handleFolderDrop(_ providers: [NSItemProvider]) -> Bool {
        if busy { return false }
        let urls = collectURLs(providers)
        guard let u = urls.first, u.hasDirectoryPath else { return false }
        DispatchQueue.main.async { selectFolder(u) }
        return true
    }

    func clearFolder() {
        folderURL = nil
        plan = []; notes = []; errors = []; logs = []; executed = false; emptyFolders = []
    }

    private func kindColor(_ k: ItemKind) -> Color {
        switch k {
        case .main: return Theme.accent
        case .clean: return Theme.ok
        case .sub: return Theme.warn
        case .rename: return Color.secondary
        }
    }

    private func loadSavedSettings() {
        let s = loadSettings()
        template = s.template
        presets = s.templates
        canUndo = !loadHistory().isEmpty
    }

    private func persistSettings() {
        var s = AppSettings.fallback
        s.template = template
        s.templates = presets
        saveSettings(s)
    }

    private func selectFolder(_ url: URL) {
        folderURL = url
        plan = []; notes = []; errors = []; logs = []; executed = false; emptyFolders = []
        scheduleScan()
    }

    // 参数变化后防抖自动扫描
    private func scheduleScan() {
        guard folderURL != nil, !busy else { return }
        scanWork?.cancel()
        let w = DispatchWorkItem { runScan() }
        scanWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    private func runScan() {
        guard let folder = folderURL else { return }
        busy = true; logs = []; executed = false
        persistSettings()
        let org = organize
        let t = title
        let tpl = template
        let cats = currentCats
        let out = currentOutput
        DispatchQueue.global(qos: .userInitiated).async {
            let r = buildPlan(folder: folder, title: t, organize: org, srtEPName: false,
                              template: tpl, cats: cats, outputFolder: out)
            DispatchQueue.main.async {
                plan = r.items
                notes = r.notes
                errors = r.errors
                busy = false
            }
        }
    }

    private func runExecute() {
        guard !plan.isEmpty, !blocked, let folder = folderURL else { return }
        busy = true
        let snapshot = plan
        let org = organize
        let t = title
        let tpl = template
        let cats = currentCats
        let out = currentOutput
        DispatchQueue.global(qos: .userInitiated).async {
            let result = executePlan(snapshot, overwrite: false)
            recordBatch(folder: folder, title: t, moves: result.moves)
            var empties: [URL] = []
            if org { empties = findEmptyFolders(in: folder, cats: cats) }
            DispatchQueue.main.async {
                logs.append(contentsOf: result.logs)
                emptyFolders = empties
                executed = true
                canUndo = !result.moves.isEmpty
                // 重新扫描一次，反映最新状态
                let r = buildPlan(folder: folder, title: t, organize: org, srtEPName: false,
                                  template: tpl, cats: cats, outputFolder: out)
                plan = r.items
                notes = r.notes
                errors = r.errors
                busy = false
            }
        }
    }

    private func runUndo() {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = undoLastBatch()
            DispatchQueue.main.async {
                logs.append(contentsOf: result)
                canUndo = !loadHistory().isEmpty
                plan = []; notes = []; errors = []; executed = false; emptyFolders = []
                busy = false
            }
        }
    }

    private func runTrashEmpty() {
        let targets = emptyFolders
        DispatchQueue.global(qos: .userInitiated).async {
            let result = trashItems(targets)
            DispatchQueue.main.async {
                logs.append(contentsOf: result)
                emptyFolders = []
            }
        }
    }

    private func exportCSV() {
        guard let folder = folderURL, !plan.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "改名对照表.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            let csv = planCSV(plan, folderPath: folder.path)
            try? csv.write(to: url, atomically: true, encoding: .utf8)
            logs.append("📄 对照表已导出：\(url.path)")
        }
    }
}

// MARK: - 板块 5：关于与更新

struct AboutView: View {
    @EnvironmentObject private var updates: UpdateCenter

    @State private var ffmpegVer = "检测中…"
    @State private var ffprobeVer = "检测中…"
    @State private var notes = ""
    @State private var notesVersion = ""
    @State private var loadingNotes = false

    private var appIcon: NSImage {
        NSApp.applicationIconImage
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                headerCard
                updateCard
                notesCard
                envCard
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { probeTools() }
    }

    // MARK: 应用信息

    private var headerCard: some View {
        Card {
            HStack(spacing: 14) {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Video Post-Production")
                        .font(.system(size: 17, weight: .bold))
                    Text("版本 \(displayVersion(currentAppVersion())) · macOS 13.0+ · Apple Silicon")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("视频抽帧 / 插入封面 / 结尾处理 / 整理归档，内置 ffmpeg，开箱即用")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Link(destination: URL(string: UpdateCheck.fallbackURL)!) {
                        Label("GitHub 发布页", systemImage: "arrow.up.right.square")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    Link(destination: URL(string: "https://github.com/\(UpdateCheck.repoOwner)/\(UpdateCheck.repoName)")!) {
                        Label("项目仓库", systemImage: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                }
            }
        }
    }

    // MARK: 更新

    private var updateCard: some View {
        Card {
            FieldLabel("arrow.triangle.2.circlepath", "更新")
            HStack(spacing: 10) {
                Circle()
                    .fill(updates.found == nil ? Theme.ok : Theme.accent)
                    .frame(width: 7, height: 7)
                Text(updates.statusText)
                    .font(.system(size: 12.5, weight: .medium))
                Text("·")
                    .foregroundStyle(.secondary)
                Text(updates.lastCheckedText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                if !updates.lastSource.isEmpty {
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(updates.lastSource)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .help("本次更新信息走通的通道，用于排查代理/TLS 问题")
                }
                Spacer()
            }
            HStack(spacing: 10) {
                Button {
                    updates.check(manual: true)
                } label: {
                    HStack(spacing: 6) {
                        if updates.isChecking {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .bold))
                        }
                        Text(updates.isChecking ? "检查中…" : "检查更新")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .foregroundStyle(.white)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(LinearGradient(colors: [Theme.accent, Theme.accentDeep],
                                                 startPoint: .leading, endPoint: .trailing))
                            .opacity(updates.isChecking ? 0.4 : 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(updates.isChecking)

                if let info = updates.found {
                    // 一键更新：下载 → 替换 → 自动重启
                    Button {
                        updates.installUpdate { NSApp.terminate(nil) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 11, weight: .bold))
                            Text(updates.phase == .downloading ? "下载中…"
                                 : updates.phase == .installing ? "安装中…"
                                 : "安装更新 \(info.version)")
                                .font(.system(size: 12.5, weight: .semibold))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .foregroundStyle(.white)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Theme.ok)
                                .opacity(updates.isBusyUpdating ? 0.5 : 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(updates.isBusyUpdating)
                    .help("下载安装包并自动替换当前 App，完成后会自动重新打开")

                    Button {
                        if let url = URL(string: info.htmlURL) { NSWorkspace.shared.open(url) }
                    } label: {
                        Label("打开发布页", systemImage: "safari")
                            .font(.system(size: 12))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Theme.card)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.primary.opacity(0.12)))
                    }
                    .buttonStyle(.plain)

                    Button("跳过此版本") { updates.skipCurrent() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .disabled(updates.isBusyUpdating)
                }

                if !updates.skippedVersion.isEmpty {
                    Button("恢复更新提示（已跳过 \(updates.skippedVersion)）") {
                        updates.resetPrompts()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if updates.phase == .downloading {
                HStack(spacing: 8) {
                    ProgressView(value: max(0, min(1, updates.downloadFraction)))
                        .progressViewStyle(.linear)
                        .frame(width: 220)
                    Text("\(Int(updates.downloadFraction * 100))%")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(updates.downloadText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else if updates.phase == .installing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在安装，App 会自动退出并重新打开…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            Text("启动时自动检查一次（6 小时内不重复联网），也可以在菜单栏用 ⌘U 手动检查；发现新版本后可一键下载安装并自动重启。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 最新版本说明

    private var notesCard: some View {
        Card {
            HStack {
                FieldLabel("doc.text", "最新版本说明")
                Spacer()
                Button {
                    loadNotes()
                } label: {
                    HStack(spacing: 5) {
                        if loadingNotes { ProgressView().controlSize(.small) }
                        Image(systemName: "arrow.clockwise").font(.system(size: 10.5))
                        Text(loadingNotes ? "加载中…" : "拉取")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .disabled(loadingNotes)
            }
            if notes.isEmpty {
                Text(notesVersion.isEmpty ? "点「拉取」查看 GitHub 上最新版本的更新说明。"
                                          : "（无说明）")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    Text(notes)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 150)
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: 运行环境

    private var envCard: some View {
        Card {
            FieldLabel("wrench.and.screwdriver", "运行环境")
            envRow("ffmpeg", ffmpegBin(), ffmpegVer)
            envRow("ffprobe", ffprobeBin(), ffprobeVer)
            Text("两个工具都内置在 App 包内，不依赖系统安装的 ffmpeg。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func envRow(_ name: String, _ path: String, _ version: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                Text(version)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(path)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func loadNotes() {
        guard !loadingNotes else { return }
        loadingNotes = true
        UpdateCheck.fetchLatest { result in
            DispatchQueue.main.async {
                loadingNotes = false
                if case .success(let info) = result, let info = info {
                    notesVersion = info.version
                    notes = info.notes.trimmingCharacters(in: .whitespacesAndNewlines)
                    if notes.isEmpty { notes = "" }
                } else {
                    notesVersion = ""
                    notes = ""
                }
            }
        }
    }

    private func probeTools() {
        DispatchQueue.global(qos: .utility).async {
            let fv = firstLine(of: runTool(ffmpegBin(), ["-version"]).out)
            let pv = firstLine(of: runTool(ffprobeBin(), ["-version"]).out)
            DispatchQueue.main.async {
                ffmpegVer = fv.isEmpty ? "未找到" : fv
                ffprobeVer = pv.isEmpty ? "未找到" : pv
            }
        }
    }

    private func firstLine(of s: String) -> String {
        s.split(separator: "\n").first.map(String.init) ?? ""
    }
}
