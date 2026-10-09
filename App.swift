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

/// 更新检查中心：顶栏徽章与「关于与更新」板块共用同一份状态
final class UpdateCenter: ObservableObject {
    @Published private(set) var isChecking = false
    @Published private(set) var found: ReleaseInfo?
    @Published private(set) var noticeTitle = ""
    @Published private(set) var noticeText = ""
    @Published private(set) var lastCheckedAt: Double = 0
    @Published var showNotice = false
    @Published var showUpdateAlert = false

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
        return "已是最新版本 v\(currentAppVersion())"
    }

    var updateAlertMessage: String {
        guard let info = found else { return "" }
        var msg = "当前版本 v\(currentAppVersion())，最新版本 v\(info.version)。"
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
                    if manual { self.notify("检查更新失败", err.localizedDescription) }
                case .success(let info):
                    guard let info = info else {
                        if manual { self.notify("暂无更新", "仓库还没有发布任何 Release。") }
                        return
                    }
                    let current = currentAppVersion()
                    if compareVersion(info.version, current) > 0 {
                        if info.version == self.skippedVersion {
                            self.clearSaved()
                            if manual {
                                self.notify("已是最新可安装版本",
                                            "v\(info.version) 已跳过，当前 v\(current)。")
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

    private func notify(_ title: String, _ text: String) {
        noticeTitle = title
        noticeText = text
        showNotice = true
    }
}

struct ContentView: View {
    @AppStorage("fxt_section") private var section = 0
    @StateObject private var updates = UpdateCenter()

    var body: some View {
        HStack(spacing: 0) {
            // 左侧导航栏
            sidebar

            // 五个板块常驻视图树（不销毁）：切换回来时已选文件/日志/预览全部保留
            ZStack {
                sectionLayer(0) { ExtractView() }
                sectionLayer(1) { InsertCoverView() }
                sectionLayer(2) { EndingView() }
                sectionLayer(3) { OrganizerView() }
                sectionLayer(4) { AboutView() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 2)
            .environmentObject(updates)
        }
        .frame(minWidth: 960, maxWidth: .infinity, minHeight: 620, maxHeight: .infinity)
        .background(Theme.page)
        .preferredColorScheme(nil)
        .task { updates.startupCheck() }
        .onReceive(NotificationCenter.default.publisher(for: .fxtCheckUpdate)) { _ in
            updates.check(manual: true)
        }
        .alert("发现新版本 \(updates.found?.version ?? "")", isPresented: $updates.showUpdateAlert) {
            Button("去 GitHub 下载") {
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
        ("插入封面", "photo.badge.plus", 1),
        ("结尾处理", "flag.checkered", 2),
        ("整理归档", "archivebox", 3),
        ("关于与更新", "info.circle", 4),
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
                    Button("好") {}
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
                Text("v\(currentAppVersion())")
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

// MARK: - 板块 2: 插入封面
struct InsertCoverView: View {
    // 持久化: 重开 App 保留上次导入的视频/封面
    @AppStorage("fxt_insVideos") private var videosRaw = ""
    @AppStorage("fxt_insCovers") private var coversRaw = ""
    @AppStorage("fxt_insOutDir") private var outDirCustom = ""
    // 跨板块流转: 继续到结尾处理
    @AppStorage("fxt_section") private var section = 0
    @AppStorage("fxt_endVideos") private var endVideosRaw = ""
    @AppStorage("fxt_endCovers") private var endCoversRaw = ""
    @AppStorage("fxt_endLocked") private var endLocked = false
    // 输出体积档位（与结尾处理共享同一设置）
    @AppStorage("fxt_sizeMode") private var sizeMode = SizeMode.match.rawValue
    private var currentSize: SizeMode { SizeMode(rawValue: sizeMode) ?? .match }
    private var videos: [String] { videosRaw.isEmpty ? [] : videosRaw.components(separatedBy: "\n") }
    private var covers: [String] { coversRaw.isEmpty ? [] : coversRaw.components(separatedBy: "\n") }
    @State private var running = false
    @State private var stopping = false
    @State private var progressValue: Double = 0
    @State private var currentIdx = 0
    @State private var logs: [String] = []
    @State private var summary = ""

    var body: some View {
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

            // 2.5 输出目录（可选）
            HStack(spacing: 8) {
                FieldLabel("folder", "输出目录")
                NiceField("默认: 每个视频旁边的「加封面」文件夹", text: $outDirCustom, disabled: running)
                Button {
                    pickOutDir()
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .padding(7)
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.1)))
                .disabled(running)
                .help("选择输出文件夹")
                Button {
                    let dir = videos.first.map { currentOutDir(for: $0) }
                    if let dir, FileManager.default.fileExists(atPath: dir) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: dir))
                    }
                } label: {
                    Label("输出文件夹", systemImage: "folder")
                        .font(.system(size: 11.5))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.1)))
                .disabled(running || videos.isEmpty)
                .help("打开输出文件夹")
            }

            // 2.6 输出体积
            HStack(spacing: 10) {
                FieldLabel("slider.horizontal.3", "输出体积")
                Picker("", selection: $sizeMode) {
                    ForEach(SizeMode.allCases, id: \.rawValue) { m in
                        Text(m.label).tag(m.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
                .disabled(running)
                Text(currentSize.hint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            // 3. 匹配预览 / 日志
            if !videos.isEmpty || !covers.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Label("匹配预览", systemImage: "arrow.left.arrow.right.circle")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        let okN = matchPairs.filter { $0.cover != nil }.count
                        Text("\(okN)/\(matchPairs.count) 已配对")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(okN == matchPairs.count && !matchPairs.isEmpty ? Theme.ok : Theme.warn)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background((okN == matchPairs.count && !matchPairs.isEmpty ? Theme.ok : Theme.warn).opacity(0.12))
                            .clipShape(Capsule())
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)

                    Divider().opacity(0.4)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(matchPairs, id: \.video) { p in
                                HStack(spacing: 8) {
                                    Image(systemName: p.cover == nil ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                                        .foregroundStyle(p.cover == nil ? Theme.warn : Theme.ok)
                                        .font(.system(size: 11))
                                    Text(p.video)
                                        .font(.system(size: 11.5, weight: .medium))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Image(systemName: "arrow.left")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                    if let c = p.cover {
                                        Text(c)
                                            .font(.system(size: 11.5))
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                            .foregroundStyle(Theme.ok)
                                    } else {
                                        Text("没有匹配集数的封面")
                                            .font(.system(size: 11.5))
                                            .foregroundStyle(Theme.warn)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                            }
                            if !unusedCovers.isEmpty {
                                Divider().opacity(0.4)
                                HStack(spacing: 6) {
                                    Image(systemName: "photo.slash")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                    Text("未使用: \(unusedCovers.joined(separator: "、"))")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(2)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
            } else {
                LogPanel(logs: logs)
            }

            // 4. 动作区
            HStack(spacing: 12) {
                Button {
                    insertCovers()
                } label: {
                    HStack(spacing: 7) {
                        if running {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "photo.badge.plus").font(.system(size: 11, weight: .bold))
                        }
                        Text(running ? "正在插入…" : "把封面插入视频开头")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 9)
                    .foregroundStyle(.white)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(LinearGradient(colors: [Theme.accent, Theme.accentDeep],
                                                 startPoint: .leading, endPoint: .trailing))
                            .opacity(canInsert ? 1 : 0.35)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!canInsert)

                if running {
                    Button {
                        stopInsert()
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "stop.fill").font(.system(size: 10.5, weight: .bold))
                            Text(stopping ? "正在停止…" : "停止处理")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .foregroundStyle(.white)
                        .background(
                            RoundedRectangle(cornerRadius: 9)
                                .fill(Theme.warn.opacity(stopping ? 0.45 : 0.95))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(stopping)
                    .help("立即停止：已完成的视频保留，未处理的跳过，半成品自动清理")
                }

                if !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(summary.hasPrefix("已停止") ? Theme.warn : Theme.ok)
                        .lineLimit(1)
                }
                Spacer()

                Button {
                    continueToEnding()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.right.circle.fill").font(.system(size: 12, weight: .semibold))
                        Text("继续到结尾处理").font(.system(size: 12.5, weight: .semibold))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .foregroundStyle(.white)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(LinearGradient(colors: [Theme.accentDeep, Theme.accent],
                                                 startPoint: .leading, endPoint: .trailing))
                    )
                }
                .buttonStyle(.plain)
                .disabled(running || videos.isEmpty)
                .help("把这些视频带入「结尾处理」继续加工（文件选择将锁定）")
            }

            if running || progressValue > 0 {
                NiceProgress(value: progressValue,
                             label: running ? "\(min(currentIdx + 1, videos.count))/\(videos.count)" : nil)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    // 把当前视频列表带入「结尾处理」板块并锁定其文件选择
    func continueToEnding() {
        endVideosRaw = videosRaw
        endCoversRaw = coversRaw
        endLocked = true
        section = 2
    }

    var canInsert: Bool { !running && !videos.isEmpty && !covers.isEmpty }

    // 输出目录: 自定义优先，否则视频旁边的「加封面」
    func currentOutDir(for video: String) -> String {
        let custom = outDirCustom.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty { return custom }
        return URL(fileURLWithPath: video).deletingLastPathComponent()
            .appendingPathComponent("加封面").path
    }

    func pickOutDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            outDirCustom = url.path
        }
    }

    // 每个视频对应的封面（实时计算）
    var matchPairs: [(video: String, cover: String?)] {
        videos.map { v in
            let cover = findCover(forVideo: v, covers: covers)
            return (URL(fileURLWithPath: v).lastPathComponent,
                    cover.map { URL(fileURLWithPath: $0).lastPathComponent })
        }
    }

    // 没被任何视频用到的封面
    var unusedCovers: [String] {
        let used = Set(videos.compactMap { findCover(forVideo: $0, covers: covers) })
        return covers.filter { !used.contains($0) }
            .map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    func pickVideos() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .video, .avi]
        if panel.runModal() == .OK {
            videosRaw = panel.urls.map { $0.path }.joined(separator: "\n")
        }
    }

    func pickCovers() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK {
            coversRaw = panel.urls.map { $0.path }.joined(separator: "\n")
        }
    }

    func collectURLs(_ providers: [NSItemProvider]) -> [URL] {
        var urls: [URL] = []
        let group = DispatchGroup()
        let q = DispatchQueue(label: "dropi")
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
        let urls = collectURLs(providers)
        DispatchQueue.main.async { videosRaw = urls.map { $0.path }.joined(separator: "\n") }
        return !urls.isEmpty
    }

    func handleDropCovers(_ providers: [NSItemProvider]) -> Bool {
        let urls = collectURLs(providers)
        DispatchQueue.main.async { coversRaw = urls.map { $0.path }.joined(separator: "\n") }
        return !urls.isEmpty
    }

    func insertCovers() {
        let list = videos
        let coverList = covers
        let size = currentSize
        running = true
        stopping = false
        summary = ""
        progressValue = 0
        currentIdx = 0
        RunControl.shared.begin()
        let customDir = outDirCustom.trimmingCharacters(in: .whitespaces)
        if !customDir.isEmpty {
            try? FileManager.default.createDirectory(atPath: customDir, withIntermediateDirectories: true)
        }
        logs = ["开始插入封面: \(list.count) 个视频, \(coverList.count) 张封面图" +
                "，体积 \(size.label)" +
                (customDir.isEmpty ? "" : "，输出到 \(customDir)")]

        DispatchQueue.global(qos: .userInitiated).async {
            var okCount = 0
            var failCount = 0
            var totalElapsed: Double = 0
            var stopped = false
            let batchStart = Date()
            for (vi, video) in list.enumerated() {
                // 用户点了「停止处理」→ 跳出剩余任务
                if RunControl.shared.isCancelled { stopped = true; break }
                let vName = URL(fileURLWithPath: video).lastPathComponent
                guard let cover = findCover(forVideo: video, covers: coverList) else {
                    failCount += 1
                    DispatchQueue.main.async {
                        logs.append("[\(vi+1)/\(list.count)] \(vName) 跳过: 没有匹配集数的封面图")
                        progressValue = Double(vi + 1) / Double(list.count)
                        currentIdx = vi + 1
                    }
                    continue
                }
                let outDir = currentOutDir(for: video)
                let cName = URL(fileURLWithPath: cover).lastPathComponent
                let t0 = Date()
                let ok = insertCoverToVideo(video, coverPath: cover, outputDir: outDir,
                                            sizeMode: size) { msg in
                    DispatchQueue.main.async { logs.append("[\(vi+1)/\(list.count)] \(msg)") }
                }
                let used = Date().timeIntervalSince(t0)
                // 被停止：函数内已记录日志，这里不再计成功/失败，直接跳出
                if RunControl.shared.isCancelled { stopped = true; break }
                if ok { okCount += 1 } else { failCount += 1 }
                totalElapsed += used
                let line = ok
                    ? "[\(vi+1)/\(list.count)] \(vName) ← \(cName) 完成（用时 \(humanDuration(used))）"
                    : "[\(vi+1)/\(list.count)] \(vName) ✗ 插入失败（用时 \(humanDuration(used))）"
                DispatchQueue.main.async {
                    logs.append(line)
                    progressValue = Double(vi + 1) / Double(list.count)
                    currentIdx = vi + 1
                }
            }
            let wall = Date().timeIntervalSince(batchStart)
            let done = okCount, failed = failCount, totalUsed = totalElapsed
            let wasStopped = stopped
            let summaryText: String
            if wasStopped {
                let rest = max(list.count - done - failed, 0)
                summaryText = "已停止: 完成 \(done) 个，剩余 \(rest) 个未处理 · 已用时 \(humanDuration(wall))"
            } else {
                summaryText = "插入完成: 成功 \(done) 个, 失败 \(failed) 个 · 总用时 \(humanDuration(wall))"
                    + (done > 0 ? "（平均每个 \(humanDuration(totalUsed / Double(done)))）" : "")
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

    /// 停止插入：终止当前编码进程，剩余视频不再处理（已完成的输出保留）
    func stopInsert() {
        guard running, !stopping else { return }
        stopping = true
        logs.append("正在停止…（等待当前视频的编码进程退出，已完成的不受影响）")
        RunControl.shared.cancel()
    }
}

// MARK: - 板块 3: 结尾处理（渐白 → 全白 → 定格渐显 → 定格保持 + 音效）
struct EndingView: View {
    // 持久化: 重开 App 保留上次设置
    @AppStorage("fxt_endVideos") private var videosRaw = ""
    @AppStorage("fxt_endCovers") private var coversRaw = ""
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
    @AppStorage("fxt_endLocked") private var locked = false
    @AppStorage("fxt_endAFade") private var audioFadeOn = false
    @AppStorage("fxt_endAFadeDur") private var audioFadeDurText = "0.5"
    @AppStorage("fxt_endSpeed") private var encSpeed = EncodeSpeed.fast.rawValue
    @AppStorage("fxt_sizeMode") private var sizeMode = SizeMode.match.rawValue

    private var currentSpeed: EncodeSpeed { EncodeSpeed(rawValue: encSpeed) ?? .fast }
    private var currentSize: SizeMode { SizeMode(rawValue: sizeMode) ?? .match }

    private var videos: [String] { videosRaw.isEmpty ? [] : videosRaw.components(separatedBy: "\n") }
    private var covers: [String] { coversRaw.isEmpty ? [] : coversRaw.components(separatedBy: "\n") }
    // 已匹配到封面的视频数
    private var matchedCount: Int {
        videos.filter { findCover(forVideo: $0, covers: covers) != nil }.count
    }
    @State private var running = false
    @State private var stopping = false
    @State private var progressValue: Double = 0
    @State private var currentIdx = 0
    @State private var batchStartAt: Date? = nil
    @State private var elapsedText = ""
    @State private var logs: [String] = []
    @State private var summary = ""

    // 处理中每 0.5 秒刷新一次已用时
    private let ticker = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var progressLabel: String? {
        guard running else { return nil }
        var parts: [String] = []
        if !videos.isEmpty { parts.append("第 \(max(currentIdx, 1))/\(videos.count) 个") }
        if !elapsedText.isEmpty { parts.append("已用时 \(elapsedText)") }
        if stopping { parts.append("正在停止…") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var sfxExists: Bool { !sfxPath.isEmpty && FileManager.default.fileExists(atPath: sfxPath) }

    // 解析数字输入：兼容全角数字 / 中文逗号小数点
    func parseNum(_ text: String, fallback: Double) -> Double {
        let normalized = text.replacingOccurrences(of: "，", with: ".")
            .replacingOccurrences(of: ",", with: ".")
        let half = normalized.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? normalized
        return Double(half) ?? fallback
    }

    var settings: JobSettings {
        var s = JobSettings()
        s.fadeOut = max(0.05, parseNum(fadeOutText, fallback: 0.25))
        s.whiteHold = max(0, parseNum(whiteHoldText, fallback: 0))
        s.fadeIn = max(0.05, parseNum(fadeInText, fallback: 0.25))
        s.freeze = max(0.1, parseNum(freezeText, fallback: 1))
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

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            // 锁定提示: 从「插入封面」继续带入的文件不可再选
            if locked {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.accent)
                    Text("已从「插入封面」继续带入 \(videos.count) 个视频，文件选择已锁定")
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    Button {
                        locked = false
                    } label: {
                        Label("解锁重新选择", systemImage: "lock.open")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.1)))
                    .disabled(running)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.accent.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accent.opacity(0.25)))
            }

            // 1. 视频
            DropZone(icon: "film.stack",
                     title: locked ? "已从「插入封面」带入，文件已锁定" : "拖入视频，或点击选择",
                     hint: locked ? "如需更换视频，点击上方「解锁重新选择」" : "支持多选 · 结尾自动叠加：渐白 → 全白保持 → 定格渐显 → 定格保持",
                     files: videos, running: running || locked,
                     onPick: pickVideos, onClear: { videosRaw = "" }, onDrop: handleDrop)

            // 1.5 带入的封面（只读，来自「插入封面」的继续操作）
            if !covers.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: matchedCount == videos.count
                          ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(matchedCount == videos.count ? Theme.ok : Theme.warn)
                    Text("已带入 \(covers.count) 张封面，\(matchedCount)/\(videos.count) 个视频已按集数配对，将与结尾一次编码完成（少一遍转码）")
                        .font(.system(size: 10.5))
                        .foregroundStyle(matchedCount == videos.count ? Theme.ok : Theme.warn)
                    if !locked {
                        Button {
                            coversRaw = ""
                        } label: {
                            Image(systemName: "trash").font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .padding(4)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(Circle())
                        .disabled(running)
                        .help("清掉带入的封面（只做结尾处理）")
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
            }

            // 2. 结尾参数
            Card {
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
                    Text("秒 · 正片音频在结尾渐弱到无声（定格/白场段本身无声）")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .opacity(audioFadeOn ? 1 : 0.5)
                    Spacer()
                }
                Text("时间轴：渐白与正片结尾重叠 → 全白保持 → 定格渐显 → 定格保持；音效从 渐白起点+偏移 播到结束")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            // 3. 音效
            Card {
                FieldLabel("speaker.wave.2", "音效")
                HStack(spacing: 8) {
                    Image(systemName: sfxExists ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(sfxExists ? Theme.ok : Color.primary.opacity(0.35))
                    NiceField("音效文件路径（留空则不加音效）", text: $sfxPath, disabled: running)
                    Button {
                        pickSFX()
                    } label: {
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

            // 3.5 编码
            Card {
                FieldLabel("slider.horizontal.3", "编码设置")
                HStack(spacing: 10) {
                    Text("速度")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .leading)
                    Picker("", selection: $encSpeed) {
                        ForEach(EncodeSpeed.allCases, id: \.rawValue) { sp in
                            Text(sp.label).tag(sp.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 120)
                    .disabled(running)
                    Text(currentSpeed.hint)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                HStack(spacing: 10) {
                    Text("体积")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .leading)
                    Picker("", selection: $sizeMode) {
                        ForEach(SizeMode.allCases, id: \.rawValue) { m in
                            Text(m.label).tag(m.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 160)
                    .disabled(running)
                    Text(currentSize.hint)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }

            // 4. 输出
            Card {
                FieldLabel("folder", "输出")
                HStack(spacing: 8) {
                    Toggle("加后缀命名", isOn: $rename).toggleStyle(.checkbox)
                        .font(.system(size: 11))
                        .disabled(running)
                    NiceField("后缀", text: $suffix, width: 90, disabled: running || !rename)
                    Text(rename
                         ? "→ 原名\((suffix.isEmpty ? "定格白场" : suffix)).mp4"
                         : "→ 保持原文件名（默认输出到「加结尾」文件夹）")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Toggle("覆盖已有输出", isOn: $overwrite).toggleStyle(.checkbox)
                        .font(.system(size: 11))
                        .disabled(running)
                }
                HStack(spacing: 8) {
                    FieldLabel("folder", "输出目录")
                    NiceField("默认: 每个视频旁边的「加结尾」文件夹", text: $outDirCustom, disabled: running)
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

            // 4. 动作区
            HStack(spacing: 12) {
                Button {
                    start()
                } label: {
                    HStack(spacing: 7) {
                        if running {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "flag.checkered").font(.system(size: 11, weight: .bold))
                        }
                        Text(running ? "正在处理…" : "开始处理")
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

                if running {
                    Button {
                        stop()
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "stop.fill").font(.system(size: 10.5, weight: .bold))
                            Text(stopping ? "正在停止…" : "停止处理")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .foregroundStyle(.white)
                        .background(
                            RoundedRectangle(cornerRadius: 9)
                                .fill(Theme.warn.opacity(stopping ? 0.45 : 0.95))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(stopping)
                    .help("立即停止：已完成的视频保留，未处理的跳过，半成品自动清理")
                }

                if !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(summary.hasPrefix("已停止") ? Theme.warn : Theme.ok)
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
                }
            }

            if running || progressValue > 0 {
                NiceProgress(value: progressValue, label: progressLabel)
            }

            LogPanel(logs: logs)
                .frame(height: 150)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        }
        .onAppear {
            if sfxPath.isEmpty { sfxPath = EndingEngine.defaultSFX }
        }
        .onReceive(ticker) { _ in
            guard running, let t0 = batchStartAt else { return }
            elapsedText = humanDuration(Date().timeIntervalSince(t0))
        }
    }

    var canStart: Bool { !running && !videos.isEmpty }

    func endField(_ label: String, _ binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary)
            NiceField("", text: binding, width: 78, disabled: running)
        }
    }

    var effectiveOutDir: String? {
        let custom = outDirCustom.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty { return custom }
        guard let first = videos.first else { return nil }
        return URL(fileURLWithPath: first).deletingLastPathComponent().path
    }

    func openOutput() {
        if let od = effectiveOutDir, FileManager.default.fileExists(atPath: od) {
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
            videosRaw = panel.urls.map { $0.path }.joined(separator: "\n")
        }
    }

    func pickSFX() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        if panel.runModal() == .OK, let u = panel.url {
            sfxPath = u.path
        }
    }

    func pickOutDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            outDirCustom = url.path
        }
    }

    func collectURLs(_ providers: [NSItemProvider]) -> [URL] {
        var urls: [URL] = []
        let group = DispatchGroup()
        let q = DispatchQueue(label: "drope")
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
        if locked || running { return false }
        let urls = collectURLs(providers)
        DispatchQueue.main.async { videosRaw = urls.map { $0.path }.joined(separator: "\n") }
        return !urls.isEmpty
    }

    func start() {
        let list = videos
        let coverList = covers
        let s = settings
        running = true
        stopping = false
        summary = ""
        progressValue = 0
        currentIdx = 0
        batchStartAt = Date()
        elapsedText = "0.0 秒"
        RunControl.shared.begin()
        // 输出目录: 自定义优先，否则每个视频旁边的「加结尾」文件夹（与「插入封面」一致）
        let customDir = outDirCustom.trimmingCharacters(in: .whitespaces)
        if !s.overwrite {
            let dirs = customDir.isEmpty
                ? Set(list.map { URL(fileURLWithPath: $0).deletingLastPathComponent().appendingPathComponent("加结尾").path })
                : [customDir]
            for d in dirs {
                try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
            }
        }
        let modeText = coverList.isEmpty ? "结尾处理" : "封面+结尾（一次编码）"
        logs = ["开始\(modeText) \(list.count) 个视频：渐白 \(s.fadeOut)秒 / 全白保持 \(s.whiteHold)秒 / 渐显 \(s.fadeIn)秒 / 定格 \(s.freeze)秒，音效：\(s.sfxPath ?? "无")" +
                (s.audioFade > 0 ? "，原视频音频淡出 \(s.audioFade)秒" : "") +
                (coverList.isEmpty ? "" : "，封面 \(coverList.count) 张按集数匹配") +
                "，编码 \(s.speed.label)" +
                "，体积 \(s.sizeMode.label)" +
                (customDir.isEmpty ? "，输出到每个视频旁的「加结尾」文件夹" : "，输出到 \(customDir)")]

        DispatchQueue.global(qos: .userInitiated).async {
            var okCount = 0
            var failCount = 0
            var totalElapsed: Double = 0
            var stopped = false
            let batchStart = Date()
            for (vi, video) in list.enumerated() {
                // 用户点了「停止处理」→ 跳出剩余任务
                if RunControl.shared.isCancelled { stopped = true; break }
                let vName = URL(fileURLWithPath: video).lastPathComponent
                // 每个视频的输出目录: 自定义优先，否则视频旁边的「加结尾」文件夹
                var sv = s
                if customDir.isEmpty {
                    sv.outputDir = URL(fileURLWithPath: video).deletingLastPathComponent()
                        .appendingPathComponent("加结尾").path
                }
                // 实时进度: 整体 = 已完成视频数 + 当前视频内进度
                let base = Double(vi) / Double(list.count)
                let span = 1.0 / Double(list.count)
                let prog: (Double) -> Void = { frac in
                    DispatchQueue.main.async {
                        progressValue = min(base + span * max(0, min(frac, 1)), 1)
                    }
                }
                DispatchQueue.main.async { currentIdx = vi + 1 }
                let res: EndingResult
                if coverList.isEmpty {
                    res = EndingEngine.run(input: video, settings: sv, onProgress: prog)
                } else if let cover = findCover(forVideo: video, covers: coverList) {
                    res = EndingEngine.runCombined(input: video, cover: cover, settings: sv, onProgress: prog)
                } else {
                    res = EndingEngine.run(input: video, settings: sv, onProgress: prog)
                    DispatchQueue.main.async {
                        logs.append("[\(vi+1)/\(list.count)] \(vName) 未匹配到封面，只做结尾处理")
                    }
                }
                if res.cancelled {
                    stopped = true
                    DispatchQueue.main.async {
                        logs.append("[\(vi+1)/\(list.count)] \(vName) ⊘ 已停止")
                    }
                    break
                }
                let ok = res.success
                let msg = res.message
                if ok { okCount += 1 } else { failCount += 1 }
                totalElapsed += res.elapsed
                let line = "[\(vi+1)/\(list.count)] \(vName) \(ok ? "✓" : "✗") \(msg)"
                DispatchQueue.main.async {
                    logs.append(line)
                    if logs.count > 300 { logs.removeFirst(logs.count - 300) }
                    progressValue = Double(vi + 1) / Double(list.count)
                }
            }
            let wall = Date().timeIntervalSince(batchStart)
            let done = okCount
            let failed = failCount
            let totalUsed = totalElapsed
            let wasStopped = stopped
            let summaryText: String
            if wasStopped {
                let rest = max(list.count - done - failed, 0)
                summaryText = "已停止: 完成 \(done) 个，剩余 \(rest) 个未处理 · 已用时 \(humanDuration(wall))"
            } else {
                summaryText = "处理完成: 成功 \(done) 个, 失败 \(failed) 个 · 总用时 \(humanDuration(wall))"
                    + (done > 0 ? "（平均每个 \(humanDuration(totalUsed / Double(done)))）" : "")
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

    /// 停止处理：终止当前编码进程，剩余视频不再处理（已完成的输出保留）
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
                    Text("版本 v\(currentAppVersion()) · macOS 13.0+ · Apple Silicon")
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
                    Button {
                        if let url = URL(string: info.htmlURL) { NSWorkspace.shared.open(url) }
                    } label: {
                        Label("下载 \(info.version)", systemImage: "arrow.down.circle")
                            .font(.system(size: 12.5, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Theme.ok.opacity(0.16))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)

                    Button("跳过此版本") { updates.skipCurrent() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
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
            Text("启动时自动检查一次（6 小时内不重复联网），也可以在菜单栏用 ⌘U 手动检查。")
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
