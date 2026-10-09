import Foundation
// Video Post-Production 逻辑层 —— ffmpeg 版（零 AVFoundation 依赖）
// 需要 ffmpeg + ffprobe（依次查找 ~/.local/bin、/opt/homebrew/bin、/usr/local/bin、/usr/bin）

// MARK: - 版本更新检查（GitHub Releases）

struct ReleaseInfo {
    var tag: String = ""
    var version: String = ""
    var htmlURL: String = ""
    var notes: String = ""
    var assetName: String?
    var assetURL: String?
    var assetSize: Int64?
    /// 这次信息是走哪条通道拿到的（界面上展示，便于排查网络问题）
    var source: String = ""
}

/// 当前 App 版本（Info.plist 的 CFBundleShortVersionString）
func currentAppVersion() -> String {
    (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
}

/// 统一成「v3.15.0」这种展示格式：版本号本身可能带也可能不带 v 前缀（GitHub tag 通常带）
func displayVersion(_ s: String) -> String {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.isEmpty { return t }
    return t.lowercased().hasPrefix("v") ? t : "v" + t
}

/// 逐段数字比较版本号：a > b 返回 1，相等返回 0，a < b 返回 -1
func compareVersion(_ a: String, _ b: String) -> Int {
    func parts(_ s: String) -> [Int] {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasPrefix("v") { t = String(t.dropFirst()) }
        return t.split(separator: ".").map { Int(String($0.filter { $0.isNumber })) ?? 0 }
    }
    let pa = parts(a), pb = parts(b)
    let n = max(pa.count, pb.count)
    for i in 0..<n {
        let x = i < pa.count ? pa[i] : 0
        let y = i < pb.count ? pb[i] : 0
        if x > y { return 1 }
        if x < y { return -1 }
    }
    return 0
}

enum UpdateCheck {
    static let repoOwner = "keyisi"
    static let repoName = "video-post-production"
    static let apiURL = "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"
    static let fallbackURL = "https://github.com/\(repoOwner)/\(repoName)/releases/latest"
    /// API 兜底通道：releases.atom 不占 API 限流额度
    static let atomURL = "https://github.com/\(repoOwner)/\(repoName)/releases.atom"

    /// 建一个更新检查用的 session
    /// - `useProxy = false` 时清空 connectionProxyDictionary → **绕过系统代理直连**。
    ///   必须这么做的两个理由：
    ///   1. Clash 这类 HTTPS 代理会 MITM，URLSession 校验不了它的根证书，
    ///      直接报「A TLS error caused the secure connection to fail」（-1206）；
    ///   2. 代理的共用出口 IP 很容易把 GitHub API 未认证的 60 次/小时配额打满（403）。
    static func session(useProxy: Bool, timeout: TimeInterval) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout + 5
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if !useProxy { cfg.connectionProxyDictionary = [:] }
        return URLSession(configuration: cfg)
    }

    /// 拉取 GitHub 最新 Release（只认 latest，草稿/预发布不算）
    /// 四级兜底链：API 直连 → API 走代理 → atom 直连 → atom 走代理
    /// - 成功但仓库还没有 Release → .success(nil)
    static func fetchLatest(timeout: TimeInterval = 10,
                            completion: @escaping (Result<ReleaseInfo?, Error>) -> Void) {
        let per = min(timeout, 8)
        var lastErr: Error?

        fetchFromAPI(timeout: per, useProxy: false) { r in
            if case .success(let info) = r { completion(.success(info)); return }
            if case .failure(let e) = r { lastErr = e }

            fetchFromAPI(timeout: per, useProxy: true) { r2 in
                if case .success(let info) = r2 { completion(.success(info)); return }
                if case .failure(let e) = r2 { lastErr = e }

                // API 限流是常态（未认证 60 次/小时，共用出口 IP 容易撞上），改走 atom
                fetchFromAtom(timeout: per, useProxy: false) { info3, e3 in
                    if let info3 = info3 { completion(.success(info3)); return }
                    if let e3 = e3 { lastErr = e3 }

                    fetchFromAtom(timeout: per, useProxy: true) { info4, e4 in
                        if let info4 = info4 { completion(.success(info4)); return }
                        if let e4 = e4 { lastErr = e4 }
                        completion(.failure(friendlyError(lastErr)))
                    }
                }
            }
        }
    }

    /// 把系统级的网络报错翻译成人话（弹窗直接显示 localizedDescription）
    private static func friendlyError(_ err: Error?) -> Error {
        guard let err = err else {
            return NSError(domain: "Update", code: -9,
                           userInfo: [NSLocalizedDescriptionKey: "暂时拿不到更新信息，请稍后再试。"])
        }
        let ns = err as NSError
        guard ns.domain == NSURLErrorDomain else { return err }
        if (-1210..<(-1199)).contains(ns.code) {
            return NSError(domain: "Update", code: ns.code,
                           userInfo: [NSLocalizedDescriptionKey:
                            "HTTPS 握手失败（错误 \(ns.code)），通常是代理/VPN 的中间证书没被信任。已尝试绕过系统代理重试仍未成功，可点「GitHub 发布页」手动查看。"])
        }
        if ns.code == NSURLErrorTimedOut {
            return NSError(domain: "Update", code: ns.code,
                           userInfo: [NSLocalizedDescriptionKey: "连接超时：网络到 GitHub 不通，或需要可用的代理。"])
        }
        if ns.code == NSURLErrorNotConnectedToInternet {
            return NSError(domain: "Update", code: ns.code,
                           userInfo: [NSLocalizedDescriptionKey: "当前没有网络连接。"])
        }
        return err
    }

    private static func fetchFromAPI(timeout: TimeInterval,
                                     useProxy: Bool,
                                     completion: @escaping (Result<ReleaseInfo?, Error>) -> Void) {
        guard let url = URL(string: apiURL) else {
            completion(.failure(NSError(domain: "Update", code: -2,
                                        userInfo: [NSLocalizedDescriptionKey: "更新地址无效"])))
            return
        }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "GET"
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Video-Post-Production", forHTTPHeaderField: "User-Agent")
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let sess = session(useProxy: useProxy, timeout: timeout)
        sess.dataTask(with: req) { data, response, error in
            defer { sess.finishTasksAndInvalidate() }
            if let error = error {
                completion(.failure(error)); return
            }
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data),
                  let dict = obj as? [String: Any] else {
                completion(.failure(NSError(domain: "Update", code: -1,
                                            userInfo: [NSLocalizedDescriptionKey: "无法解析 GitHub 返回的数据"])))
                return
            }
            let tag = (dict["tag_name"] as? String) ?? ""
            if tag.isEmpty {
                // GitHub 限流 / 报错时会返回 {"message": "..."}
                let msg = (dict["message"] as? String) ?? "仓库还没有发布任何 Release"
                completion(.failure(NSError(domain: "Update", code: -3,
                                            userInfo: [NSLocalizedDescriptionKey: msg])))
                return
            }
            var info = ReleaseInfo()
            info.tag = tag
            info.version = tag
            info.htmlURL = (dict["html_url"] as? String) ?? fallbackURL
            info.notes = (dict["body"] as? String) ?? ""
            info.source = useProxy ? "GitHub API · 系统代理" : "GitHub API · 直连"
            if let assets = dict["assets"] as? [[String: Any]] {
                let zipAsset = assets.first { (($0["name"] as? String) ?? "").lowercased().hasSuffix(".zip") }
                if let z = zipAsset {
                    info.assetName = z["name"] as? String
                    info.assetURL = z["browser_download_url"] as? String
                    info.assetSize = (z["size"] as? NSNumber)?.int64Value
                }
            }
            completion(.success(info))
        }.resume()
    }

    /// 兜底：解析 https://github.com/…/releases.atom 的第一条 entry
    private static func fetchFromAtom(timeout: TimeInterval,
                                      useProxy: Bool,
                                      completion: @escaping (ReleaseInfo?, Error?) -> Void) {
        guard let url = URL(string: atomURL) else { completion(nil, nil); return }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue("Video-Post-Production", forHTTPHeaderField: "User-Agent")
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let sess = session(useProxy: useProxy, timeout: timeout)
        sess.dataTask(with: req) { data, _, error in
            defer { sess.finishTasksAndInvalidate() }
            if let error = error { completion(nil, error); return }
            guard let data = data, let xml = String(data: data, encoding: .utf8) else {
                completion(nil, NSError(domain: "Update", code: -4,
                                        userInfo: [NSLocalizedDescriptionKey: "读取更新信息失败"]))
                return
            }
            let parts = xml.components(separatedBy: "<entry>")
            guard parts.count > 1 else { completion(nil, nil); return }
            let first = parts[1].components(separatedBy: "</entry>")[0]
            var title = textBetween(first, start: "<title>", end: "</title>")
            if title.isEmpty {
                // id 形如 tag:github.com,2008:Repository/123/v3.14.1
                let id = textBetween(first, start: "<id>", end: "</id>")
                title = id.components(separatedBy: "/").last ?? ""
            }
            if title.isEmpty { completion(nil, nil); return }
            // link 形如 <link type="text/html" href="https://github.com/…/releases/tag/v3.14.1"/>
            var html = ""
            for chunk in first.components(separatedBy: "<link") where chunk.contains("text/html") {
                html = textBetween(chunk, start: "href=\"", end: "\"")
                if !html.isEmpty { break }
            }
            var info = ReleaseInfo()
            info.tag = title
            info.version = title
            info.htmlURL = html.isEmpty ? fallbackURL : html
            info.notes = ""
            info.source = useProxy ? "releases.atom · 系统代理" : "releases.atom · 直连"
            completion(info, nil)
        }.resume()
    }

    /// 把安装包地址切成「直连 / 走代理」两种尝试顺序
    static func downloadAttempts(for urlString: String) -> [(String, Bool)] {
        guard !urlString.isEmpty else { return [] }
        return [(urlString, false), (urlString, true)]
    }
}

// MARK: - App 内更新：下载 → 解压校验 → 替换 → 重启

enum UpdateError: LocalizedError {
    case noAsset
    case notNewer(String)
    case unzipFailed(String)
    case appNotFound
    case notWritable(String)
    case scriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAsset: return "这次 Release 里没有找到可下载的安装包（zip）。"
        case .notNewer(let v): return "安装包里的版本（\(v)）不比当前新，已取消安装。"
        case .unzipFailed(let s): return "解压安装包失败：\(s)"
        case .appNotFound: return "安装包里没有找到 .app。"
        case .notWritable(let p): return "没有权限替换这个位置的 App：\(p)"
        case .scriptFailed(let s): return "写入更新脚本失败：\(s)"
        }
    }
}

/// 下载安装包（带进度 + 自动换通道）
///
/// 通道顺序和「查版本号」相反 —— **先走系统代理，失败或太慢再直连**：
/// 实测本机 GitHub Release 附件直连只有 ~24 KB/s（45MB 要半小时），走代理 6.9 MB/s（6.5 秒）；
/// 而查版本号用的是 API，代理共用出口 IP 容易撞限流，所以那里反过来先直连。
/// 另外加了「5 秒还没下到 1MB 就换通道」的看门狗，避免卡在慢通道上干等。
final class UpdateDownloader: NSObject, URLSessionDownloadDelegate {
    private var session: URLSession?
    private var dest: URL!
    private var onProgress: ((Double, Int64, Int64) -> Void)?
    private var onDone: ((Result<URL, Error>) -> Void)?
    private var urlString = ""
    private var modes: [Bool] = []      // true = 走系统代理，false = 直连
    private var useProxy = true
    private var finished = false
    private var switching = false
    private var received: Int64 = 0
    private var lastError: Error?

    func start(urlString: String,
               useProxy: Bool,
               progress: @escaping (Double, Int64, Int64) -> Void,
               done: @escaping (Result<URL, Error>) -> Void) {
        self.urlString = urlString
        self.onProgress = progress
        self.onDone = done
        self.finished = false
        self.received = 0
        self.lastError = nil
        // 优先用调用方给的模式，另一个作为兜底
        self.modes = useProxy ? [true, false] : [false, true]
        dest = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fxt_update_\(UUID().uuidString).zip")
        next()
    }

    private func next() {
        guard !modes.isEmpty else {
            finish(.failure(lastError ?? UpdateError.noAsset)); return
        }
        useProxy = modes.removeFirst()
        received = 0
        guard let url = URL(string: urlString) else { finish(.failure(UpdateError.noAsset)); return }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 3600
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if !useProxy { cfg.connectionProxyDictionary = [:] }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.setValue("Video-Post-Production", forHTTPHeaderField: "User-Agent")
        let sess = URLSession(configuration: cfg, delegate: self, delegateQueue: .main)
        self.session = sess
        sess.downloadTask(with: req).resume()

        // 看门狗：5 秒还不到 1MB（≈200KB/s）就判定这条通道太慢，换另一条
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self, !self.finished else { return }
            if self.received < 1_000_000 { self.switchChannel() }
        }
    }

    private func switchChannel() {
        guard !modes.isEmpty, !finished else { return }
        switching = true
        session?.invalidateAndCancel()
    }

    private func finish(_ r: Result<URL, Error>) {
        guard !finished else { return }
        finished = true
        session?.finishTasksAndInvalidate()
        DispatchQueue.main.async { self.onDone?(r) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        received = totalBytesWritten
        guard totalBytesExpectedToWrite > 0 else { return }
        DispatchQueue.main.async {
            self.onProgress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite),
                             totalBytesWritten, totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if switching {
            // 自己取消的（换通道），不算失败
            switching = false
            next()
            return
        }
        if let error = error {
            lastError = error
            if !modes.isEmpty { next(); return }
            finish(.failure(error))
            return
        }
        guard let d = dest, FileManager.default.fileExists(atPath: d.path) else {
            lastError = UpdateError.noAsset
            if !modes.isEmpty { next(); return }
            finish(.failure(UpdateError.noAsset))
            return
        }
        finish(.success(d))
    }
}

/// 解压 + 校验 + 生成自替换脚本（App 退出后由脚本完成替换并重新打开）
enum UpdateInstall {
    /// 解压 zip，返回里面的 .app 路径
    static func unzip(_ zip: URL) throws -> URL {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fxt_unzip_\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", "--sequesterRsrc", zip.path, dir.path]
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw UpdateError.unzipFailed(msg.isEmpty ? "ditto 退出码 \(p.terminationStatus)" : msg)
        }
        guard let app = findApp(in: dir) else { throw UpdateError.appNotFound }
        return app
    }

    static func findApp(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
        while let u = e.nextObject() as? URL {
            if u.pathExtension == "app" {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue { return u }
            }
        }
        return nil
    }

    /// 读某个 .app 的版本号
    static func version(ofApp app: URL) -> String {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let d = NSDictionary(contentsOf: plist),
              let v = d["CFBundleShortVersionString"] as? String else { return "" }
        return v
    }

    /// 新 App 必须：版本更新 + 内置 ffmpeg 还在（防止下到残缺包）
    static func validate(newApp: URL, currentVersion: String) throws {
        let v = version(ofApp: newApp)
        guard !v.isEmpty, compareVersion(v, currentVersion) > 0 else {
            throw UpdateError.notNewer(v.isEmpty ? "未知" : v)
        }
        let ff = newApp.appendingPathComponent("Contents/Resources/ffmpeg")
        guard FileManager.default.fileExists(atPath: ff.path) else {
            throw UpdateError.unzipFailed("安装包里缺少内置 ffmpeg，可能是残缺文件")
        }
    }

    /// 当前 App 所在目录是否可写（/Applications 这类 root 目录通常不可写 → 走管理员授权）
    static func parentWritable(_ app: URL) -> Bool {
        let parent = app.deletingLastPathComponent()
        return FileManager.default.isWritableFile(atPath: parent.path)
    }

    /// 生成替换脚本并**脱离 App 进程**启动：等 App 退出 → 备份旧版 → 换新 → 去隔离 → 重新打开
    /// - `quit` 由调用方（App 层）提供，脚本启动后才退出自身
    static func installAndRelaunch(newApp: URL,
                                   targetApp: URL,
                                   quit: @escaping () -> Void) throws {
        let fm = FileManager.default
        let pid = ProcessInfo.processInfo.processIdentifier
        let needAdmin = !parentWritable(targetApp)
        if needAdmin {
            // /Applications 等受保护目录：先看看能不能走管理员授权（用户取消则失败）
            if !fm.isWritableFile(atPath: targetApp.path) &&
               !fm.isWritableFile(atPath: targetApp.deletingLastPathComponent().path) {
                // 脚本里会用管理员权限执行，这里不直接判定失败
            }
        }
        let script = """
        #!/bin/sh
        NEW="\(newApp.path)"
        TARGET="\(targetApp.path)"
        PID=\(pid)
        BAK="$(dirname "$TARGET")/.VideoPostProduction.old.app"
        i=0
        while kill -0 "$PID" 2>/dev/null && [ $i -lt 300 ]; do
          sleep 0.2
          i=$((i+1))
        done
        sleep 1
        rm -rf "$BAK" 2>/dev/null
        if mv "$TARGET" "$BAK" 2>/dev/null; then
          :
        else
          rm -rf "$TARGET" 2>/dev/null
        fi
        if mv "$NEW" "$TARGET" 2>/dev/null; then
          xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null
          rm -rf "$BAK" 2>/dev/null
          open -a "$TARGET"
        else
          # 失败就回滚，别把用户原来的 App 弄没了
          if [ -d "$BAK" ]; then mv "$BAK" "$TARGET" 2>/dev/null; fi
          exit 1
        fi
        """
        let scriptURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fxt_update_\(pid).sh")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            throw UpdateError.scriptFailed(error.localizedDescription)
        }
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        if needAdmin {
            // 管理员授权：弹出系统密码框，App 退出后由它完成替换
            let osa = "do shell script \"/bin/sh '\(scriptURL.path)'\" with administrator privileges"
            launcher.arguments = ["-c", "nohup /usr/bin/osascript -e '\(osa)' >/tmp/fxt_update.log 2>&1 &"]
        } else {
            launcher.arguments = ["-c", "nohup /bin/sh '\(scriptURL.path)' >/tmp/fxt_update.log 2>&1 &"]
        }
        do {
            try launcher.run()
        } catch {
            throw UpdateError.scriptFailed(error.localizedDescription)
        }
        DispatchQueue.main.async { quit() }
    }
}

extension UpdateCheck {
    private static func textBetween(_ s: String, start: String, end: String) -> String {
        guard let a = s.range(of: start),
              let b = s.range(of: end, range: a.upperBound..<s.endIndex) else { return "" }
        return String(s[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 精简 Release 说明用于弹窗展示
    static func briefNotes(_ notes: String, limit: Int = 420) -> String {
        let body = notes
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#")
                      && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("---") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        if body.count <= limit { return body }
        return String(body.prefix(limit)) + "…"
    }
}

enum FrameResult {
    case ok(saved: Int, skipped: Int)
    case fail(String)
}

struct UnifiedJob {
    var videos: [String]
    var outputDir: String
    var step: Double
    var jpg: Bool
    var quality: Double
    var startName: String   // 第一张图的名字（不含后缀）
    var suffix: String      // 如 "_cover"
}

// ---------- 工具定位与执行 ----------

func toolPath(_ name: String) -> String {
    // 优先用 App 包内自带的（Contents/Resources），分享给别人免装 ffmpeg
    if let bundled = Bundle.main.path(forResource: name, ofType: nil),
       FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
    let home = NSHomeDirectory()
    let candidates = ["\(home)/.local/bin/\(name)",
                      "/opt/homebrew/bin/\(name)",
                      "/usr/local/bin/\(name)",
                      "/usr/bin/\(name)"]
    for c in candidates where FileManager.default.fileExists(atPath: c) { return c }
    return name // 交给 PATH
}

func ffmpegBin() -> String { toolPath("ffmpeg") }
func ffprobeBin() -> String { toolPath("ffprobe") }

// MARK: - 全局运行控制（支持用户中途「停止处理」）

/// 登记当前正在跑的 ffmpeg/ffprobe 进程，并携带一个取消标志。
/// 界面上点「停止」→ cancel() 终止当前进程，调用方的循环检测 isCancelled 后跳出。
final class RunControl {
    static let shared = RunControl()
    private let lock = NSLock()
    private var current: Process?
    private var _cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }

    /// 一批任务开始前调用：清掉上一次的取消状态
    func begin() {
        lock.lock(); _cancelled = false; current = nil; lock.unlock()
    }

    /// 登记正在运行的子进程
    func register(_ p: Process) {
        lock.lock()
        // 若在启动瞬间已被取消，立刻终止这个进程（避免漏杀）
        let killed = _cancelled
        current = p
        lock.unlock()
        if killed && p.isRunning { p.terminate() }
    }

    func finish(_ p: Process) {
        lock.lock()
        if current === p { current = nil }
        lock.unlock()
    }

    /// 请求停止：先温和 terminate，0.5 秒后仍存活则 SIGKILL 兜底（半成品由调用方清理）
    func cancel() {
        lock.lock()
        _cancelled = true
        let p = current
        lock.unlock()
        guard let proc = p, proc.isRunning else { return }
        proc.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
        }
    }

    /// 一批任务结束后复位
    func reset() {
        lock.lock(); _cancelled = false; current = nil; lock.unlock()
    }
}

@discardableResult
func runTool(_ path: String, _ args: [String]) -> (code: Int32, out: String, err: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let outP = Pipe(), errP = Pipe()
    var outData = Data(), errData = Data()
    outP.fileHandleForReading.readabilityHandler = { h in
        let d = h.availableData
        if !d.isEmpty { outData.append(d) }
    }
    errP.fileHandleForReading.readabilityHandler = { h in
        let d = h.availableData
        if !d.isEmpty { errData.append(d) }
    }
    p.standardOutput = outP
    p.standardError = errP
    // 关键: ffmpeg 会读终端 stdin，继承 pty 会触发进程监控被杀，必须指向 /dev/null
    p.standardInput = FileHandle.nullDevice
    do {
        try p.run()
    } catch {
        return (-1, "", error.localizedDescription)
    }
    RunControl.shared.register(p)
    p.waitUntilExit()
    RunControl.shared.finish(p)
    outP.fileHandleForReading.readabilityHandler = nil
    errP.fileHandleForReading.readabilityHandler = nil
    outData.append(outP.fileHandleForReading.readDataToEndOfFile())
    errData.append(errP.fileHandleForReading.readDataToEndOfFile())
    return (p.terminationStatus,
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? "")
}

// 带进度的执行: 从 ffmpeg -progress pipe:1 的 stdout 解析 out_time_us 换算百分比
@discardableResult
func runToolProgress(_ path: String, _ args: [String], totalSeconds: Double,
                     onProgress: @escaping (Double) -> Void) -> (code: Int32, out: String, err: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let outP = Pipe(), errP = Pipe()
    var errData = Data()
    let lock = NSLock()
    var lastEmit = Date.distantPast
    var lastFrac = 0.0
    outP.fileHandleForReading.readabilityHandler = { h in
        let d = h.availableData
        guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
        for raw in s.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq])
            // ffmpeg 的 out_time_us 与 out_time_ms 都是微秒
            guard key == "out_time_us" || key == "out_time_ms" else { continue }
            let valStr = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard let us = Double(valStr), us >= 0, totalSeconds > 0 else { continue }
            let frac = min(us / 1_000_000.0 / totalSeconds, 1.0)
            lock.lock()
            let now = Date()
            let due = frac - lastFrac >= 0.005 || now.timeIntervalSince(lastEmit) >= 0.25
            if due { lastFrac = frac; lastEmit = now }
            lock.unlock()
            if due { onProgress(frac) }
        }
    }
    errP.fileHandleForReading.readabilityHandler = { h in
        let d = h.availableData
        if !d.isEmpty { errData.append(d) }
    }
    p.standardOutput = outP
    p.standardError = errP
    // 同 runTool: stdin 必须指向 /dev/null，否则继承 pty 会被进程监控杀掉
    p.standardInput = FileHandle.nullDevice
    do {
        try p.run()
    } catch {
        return (-1, "", error.localizedDescription)
    }
    RunControl.shared.register(p)
    p.waitUntilExit()
    RunControl.shared.finish(p)
    outP.fileHandleForReading.readabilityHandler = nil
    errP.fileHandleForReading.readabilityHandler = nil
    _ = outP.fileHandleForReading.readDataToEndOfFile()
    errData.append(errP.fileHandleForReading.readDataToEndOfFile())
    return (p.terminationStatus, "", String(data: errData, encoding: .utf8) ?? "")
}

// 在输出路径前插入进度输出参数（-progress 需在输出文件之前）
func withProgressArgs(_ args: [String]) -> [String] {
    var a = args
    a.insert(contentsOf: ["-progress", "pipe:1", "-stats_period", "0.2", "-nostats"],
             at: max(0, a.count - 1))
    return a
}

func probeDuration(_ videoPath: String) -> Double? {
    let r = runTool(ffprobeBin(), ["-v", "error", "-show_entries", "format=duration",
                                   "-of", "default=nw=1:nk=1", videoPath])
    guard r.code == 0, let d = Double(r.out.trimmingCharacters(in: .whitespacesAndNewlines)), d > 0 else {
        return nil
    }
    return d
}

// (宽, 高, fps, 是否有音轨)
func probeVideoInfo(_ videoPath: String) -> (Int, Int, Double, Bool)? {
    let v = runTool(ffprobeBin(), ["-v", "error", "-select_streams", "v:0",
                                   "-show_entries", "stream=width,height,r_frame_rate",
                                   "-of", "csv=p=0", videoPath])
    guard v.code == 0 else { return nil }
    let parts = v.out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",")
    guard parts.count >= 3,
          let w = Int(parts[0]), let h = Int(parts[1]) else { return nil }
    var fps = 30.0
    let fr = parts[2].split(separator: "/")
    if fr.count == 2, let a = Double(fr[0]), let b = Double(fr[1]), b != 0 {
        fps = a / b
    } else if let f = Double(parts[2]) {
        fps = f
    }
    let a = runTool(ffprobeBin(), ["-v", "error", "-select_streams", "a",
                                   "-show_entries", "stream=index", "-of", "csv=p=0", videoPath])
    let hasAudio = a.code == 0 && !a.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    return (w, h, fps, hasAudio)
}

// ---------- 命名 ----------

// 集数自增: "BTUK EP21" -> "BTUK EP22"（保留前导零宽度）；不含集数则返回 nil
func incrementEpisode(_ prefix: String) -> String? {
    let patterns = ["(?i)(.*?ep)(\\d+)(.*)", "(.*第)(\\d+)(集.*)", "(.*?)(\\d+)\\s*$"]
    for p in patterns {
        guard let re = try? NSRegularExpression(pattern: p) else { continue }
        let ns = prefix as NSString
        if let m = re.firstMatch(in: prefix, range: NSRange(location: 0, length: ns.length)) {
            let numStr = ns.substring(with: m.range(at: 2))
            guard let num = Int(numStr) else { continue }
            let width = numStr.count
            let next = String(num + 1)
            let padded = next.count < width ? String(repeating: "0", count: width - next.count) + next : next
            var result = ns.substring(with: m.range(at: 1)) + padded
            if m.numberOfRanges > 3 && m.range(at: 3).location != NSNotFound {
                result += ns.substring(with: m.range(at: 3))
            }
            return result
        }
    }
    return nil
}

// 提取文件名里的所有数字（不含扩展名）: "adffEP32.mp4" -> {32}
func numbersIn(_ fileName: String) -> Set<Int> {
    let base = (fileName as NSString).deletingPathExtension
    let re = try! NSRegularExpression(pattern: "\\d+")
    let ns = base as NSString
    var s = Set<Int>()
    for m in re.matches(in: base, range: NSRange(location: 0, length: ns.length)) {
        if let v = Int(ns.substring(with: m.range)) { s.insert(v) }
    }
    return s
}

// 分辨率/码率等常见「非集数」数字：只有在文件名里没有 EP 标记时才用它们排除干扰
private let nonEpisodeNumbers: Set<Int> = [240, 360, 480, 720, 1080, 1440, 2160, 4320]

/// 取文件名里的集数（**只看文件名，不看上层目录**，否则「…31-45导出」这类文件夹名会把 45 也算进来）
/// 优先级：EP31 / 第31集 标记 → 去掉 "(1)" 副本标记后的最后一个数字（排除分辨率、年份）
func episodeNumber(in pathOrName: String) -> Int? {
    let file = URL(fileURLWithPath: pathOrName).lastPathComponent
    var base = (file as NSString).deletingPathExtension
    if let m = firstMatch("(?:ep|第)\\s*(\\d+)", base), let v = Int(m[1]) { return v }
    if let re = try? NSRegularExpression(pattern: "\\(\\s*\\d+\\s*\\)") {
        let ns = base as NSString
        base = re.stringByReplacingMatches(in: base, range: NSRange(location: 0, length: ns.length), withTemplate: " ")
    }
    guard let re = try? NSRegularExpression(pattern: "\\d+") else { return nil }
    let ns = base as NSString
    var nums: [Int] = []
    for m in re.matches(in: base, range: NSRange(location: 0, length: ns.length)) {
        if let v = Int(ns.substring(with: m.range)) { nums.append(v) }
    }
    // 排除分辨率与年份，剩下取最后一个（命名习惯上集数靠后）
    let filtered = nums.filter { !nonEpisodeNumbers.contains($0) && !(1900..<2100).contains($0) }
    return filtered.last ?? nums.last
}

// 在封面列表里找与视频集数匹配的封面：集数必须精确相等
func findCover(forVideo videoPath: String, covers: [String]) -> String? {
    guard let ep = episodeNumber(in: videoPath) else { return nil }
    let sorted = covers.sorted {
        URL(fileURLWithPath: $0).lastPathComponent < URL(fileURLWithPath: $1).lastPathComponent
    }
    for c in sorted where episodeNumber(in: c) == ep { return c }
    return nil
}

// ---------- 统一抽帧: 多视频，每隔 step 秒一帧，帧名从 startName 依次 +1 加 suffix ----------

func runUnifiedJob(_ job: UnifiedJob, progress: @escaping (Int, Int, String) -> Void)
    -> (saved: Int, skipped: Int, finalName: String) {
    let fm = FileManager.default
    var current = job.startName.trimmingCharacters(in: .whitespaces)
    var fallback = 1
    func nextName() {
        if let n = incrementEpisode(current) {
            current = n
        } else {
            // 名称里没有可递增的数字: 用 起始名+序号 兜底，避免重名覆盖
            fallback += 1
            current = job.startName.trimmingCharacters(in: .whitespaces) + String(fallback)
        }
    }

    do {
        try fm.createDirectory(atPath: job.outputDir, withIntermediateDirectories: true)
    } catch {
        progress(0, 1, "失败: 无法创建输出目录 \(error.localizedDescription)")
        return (0, 0, current)
    }

    let ext = job.jpg ? "jpg" : "png"
    var saved = 0, skipped = 0
    let total = job.videos.count

    for (vi, video) in job.videos.enumerated() {
        let vName = URL(fileURLWithPath: video).lastPathComponent
        guard fm.fileExists(atPath: video), probeDuration(video) != nil else {
            skipped += 1
            progress(vi + 1, total, "[\(vi+1)/\(total)] 跳过（无法读取）: \(vName)")
            continue
        }
        // 1. ffmpeg 按 fps=1/step 抽帧到临时目录
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fx_uni_\(UUID().uuidString)")
        try? fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        var args = ["-y", "-v", "error", "-i", video, "-vf", "fps=1/\(job.step)"]
        if job.jpg { args += ["-q:v", "2"] }
        args += ["-start_number", "0", tmpDir.appendingPathComponent("%05d.\(ext)").path]
        let r = runTool(ffmpegBin(), args)
        guard r.code == 0 else {
            skipped += 1
            try? fm.removeItem(at: tmpDir)
            progress(vi + 1, total, "[\(vi+1)/\(total)] \(vName) 失败: \(String(r.err.suffix(200)))")
            continue
        }
        // 2. 按顺序重命名为 目标名
        let files = (try? fm.contentsOfDirectory(atPath: tmpDir.path))?
            .filter { $0.hasSuffix(".\(ext)") }
            .sorted() ?? []
        for f in files {
            let name = current + job.suffix
            let dst = URL(fileURLWithPath: job.outputDir).appendingPathComponent("\(name).\(ext)")
            if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: dst) }
            do {
                try fm.moveItem(at: tmpDir.appendingPathComponent(f), to: dst)
                saved += 1
                progress(vi + 1, total, "[\(vi+1)/\(total)] \(vName) → \(name).\(ext)")
            } catch {
                skipped += 1
                progress(vi + 1, total, "[\(vi+1)/\(total)] \(vName) 移动失败: \(error.localizedDescription)")
            }
            nextName()
        }
        try? fm.removeItem(at: tmpDir)
    }
    return (saved, skipped, current)
}

// ---------- 封面提取: 取视频第一帧 ----------

func extractCover(_ videoPath: String, outputDir: String, outName: String,
                  jpg: Bool, quality: Double) -> FrameResult {
    let fm = FileManager.default
    guard fm.fileExists(atPath: videoPath) else { return .fail("找不到视频文件: \(videoPath)") }
    do {
        try fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
    } catch {
        return .fail("无法创建输出目录: \(error.localizedDescription)")
    }
    let ext = jpg ? "jpg" : "png"
    let outURL = URL(fileURLWithPath: outputDir).appendingPathComponent("\(outName).\(ext)")
    var args = ["-y", "-v", "error", "-ss", "0", "-i", videoPath, "-frames:v", "1"]
    if jpg { args += ["-q:v", "2"] }
    args.append(outURL.path)
    let r = runTool(ffmpegBin(), args)
    if r.code == 0 {
        return .ok(saved: 1, skipped: 0)
    }
    return .fail("取封面失败: \(String(r.err.suffix(200)))")
}

// ---------- 插入封面: 封面按集数匹配视频, 插到视频最开头占 1 帧 ----------

func insertCoverToVideo(_ videoPath: String, coverPath: String, outputDir: String,
                        sizeMode: SizeMode = .match,
                        log: @escaping (String) -> Void) -> Bool {
    let fm = FileManager.default
    guard fm.fileExists(atPath: videoPath) else {
        log("失败: 找不到视频 \(videoPath)"); return false
    }
    guard fm.fileExists(atPath: coverPath) else {
        log("失败: 找不到封面图 \(coverPath)"); return false
    }
    do {
        try fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
    } catch {
        log("失败: 无法创建输出目录 \(error.localizedDescription)"); return false
    }
    guard let (w, h, fps, hasAudio) = probeVideoInfo(videoPath), w > 0, h > 0, fps > 0 else {
        log("失败: 无法读取视频信息 \(videoPath)"); return false
    }
    let stillDur = 1.0 / fps
    let ms = max(Int(stillDur * 1000), 1)

    // 封面等比缩放居中 + 与原视频 concat（视频轨）；原音轨延迟 stillDur
    var filter = "[0:v]scale=\(w):\(h):force_original_aspect_ratio=decrease," +
        "pad=\(w):\(h):(ow-iw)/2:(oh-ih)/2:color=black,setsar=1,fps=\(fps)[s];" +
        "[s][1:v]concat=n=2:v=1:a=0[v]"
    if hasAudio {
        filter += ";[1:a]adelay=\(ms):all=1[a]"
    }

    let outName = URL(fileURLWithPath: videoPath).lastPathComponent
    let outURL = URL(fileURLWithPath: outputDir).appendingPathComponent(outName)
    if fm.fileExists(atPath: outURL.path) { try? fm.removeItem(at: outURL) }

    var args = ["-y", "-v", "error",
                "-loop", "1", "-framerate", "\(fps)", "-t", String(stillDur), "-i", coverPath,
                "-i", videoPath,
                "-filter_complex", filter,
                "-map", "[v]"]
    if hasAudio {
        args += ["-map", "[a]", "-c:a", "aac", "-b:a", "128k"]
    } else {
        args += ["-an"]
    }
    args += EncodeSpeed.fast.videoArgs(targetBitRate: targetVideoKbps(videoPath, sizeMode: sizeMode))
    args += ["-pix_fmt", "yuv420p", "-movflags", "+faststart", outURL.path]

    let r = runTool(ffmpegBin(), args)
    guard r.code == 0 else {
        if RunControl.shared.isCancelled {
            try? fm.removeItem(at: outURL)
            log("已停止（未完成，已清理半成品）")
        } else {
            log("失败: \(String(r.err.suffix(200)))")
        }
        return false
    }
    return true
}

// ---------- 结尾处理: 渐白 → 全白保持 → 定格渐显 → 定格保持 (+音效) ----------

// 编码速度档位: 决定 x264 预设（实测 1080p30 结尾管线下 veryfast 比 medium 快约 1.7 倍，画质基本一致）
enum EncodeSpeed: String, CaseIterable {
    case standard = "standard"   // 画质优先
    case fast = "fast"           // 速度优先（默认）

    var label: String {
        switch self {
        case .standard: return "标准"
        case .fast: return "快速"
        }
    }

    var hint: String {
        switch self {
        case .standard: return "x264 medium · 编码较慢"
        case .fast: return "x264 veryfast · 速度约快 1.7 倍"
        }
    }

    var preset: String {
        switch self {
        case .standard: return "medium"
        case .fast: return "veryfast"
        }
    }

    // 视频编码参数（插入到 -c:a 之前）
    // targetBitRate = nil → CRF 18（高画质）；否则单遍 ABR 打目标码率并限制峰值
    func videoArgs(targetBitRate kbps: Int? = nil) -> [String] {
        if let k = kbps, k > 0 {
            return ["-c:v", "libx264", "-preset", preset,
                    "-b:v", "\(k)k",
                    "-maxrate", "\(k * 16 / 10)k",
                    "-bufsize", "\(k * 24 / 10)k"]
        }
        return ["-c:v", "libx264", "-preset", preset, "-crf", "18"]
    }
}

// 输出体积档位
enum SizeMode: String, CaseIterable {
    case match = "match"   // 跟随原片（默认）：按源视频码率编码，输出体积≈源
    case high = "high"     // 高画质：x264 CRF 18，体积可能明显大于源

    var label: String {
        switch self {
        case .match: return "跟随原片"
        case .high: return "高画质"
        }
    }

    var hint: String {
        switch self {
        case .match: return "按原视频码率编码 · 体积与原片基本一致"
        case .high: return "CRF 18 画质优先 · 体积可能远大于原片"
        }
    }
}

/// 源视频的视频流码率（bps）：优先取流自身码率，缺失则用容器总码率减音频码率
func probeVideoBitRate(_ path: String) -> Double? {
    func num(_ r: (code: Int32, out: String, err: String)) -> Double? {
        guard r.code == 0 else { return nil }
        return Double(r.out.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    let rv = runTool(ffprobeBin(), ["-v", "error", "-select_streams", "v:0",
                                    "-show_entries", "stream=bit_rate",
                                    "-of", "default=nw=1:nk=1", path])
    if let v = num(rv), v > 50_000 { return v }

    let rt = runTool(ffprobeBin(), ["-v", "error", "-show_entries", "format=bit_rate",
                                    "-of", "default=nw=1:nk=1", path])
    guard let total = num(rt), total > 50_000 else { return nil }
    let ra = runTool(ffprobeBin(), ["-v", "error", "-select_streams", "a:0",
                                    "-show_entries", "stream=bit_rate",
                                    "-of", "default=nw=1:nk=1", path])
    let audio = num(ra) ?? 128_000
    return max(total - audio, 200_000)
}

/// 「跟随原片」时的目标视频码率（kbps）；返回 nil 表示走 CRF 高画质
func targetVideoKbps(_ input: String, sizeMode: SizeMode) -> Int? {
    guard sizeMode == .match else { return nil }
    let src = probeVideoBitRate(input) ?? 2_500_000
    // 夹在 900k ~ 20M 之间，避免异常源（超低/超高码率）编出离谱结果
    let clamped = min(max(src, 900_000), 20_000_000)
    return Int((clamped / 1000).rounded())
}

struct JobSettings {
    var fadeOut: Double = 0.25      // 正片结尾渐白时长
    var whiteHold: Double = 0.0     // 全白保持时长
    var fadeIn: Double = 0.25       // 定格画面渐显时长
    var freeze: Double = 1.0        // 定格保持时长
    var sfxOffset: Double = 0.0     // 音效相对渐白起点的偏移（负=提前）
    var suffix: String = "定格白场"
    var overwrite: Bool = false
    var outputDir: String? = nil
    var sfxPath: String? = nil
    var audioFade: Double = 0        // 原视频音频淡出时长（0=不淡化）
    var speed: EncodeSpeed = .fast   // 编码速度档位
    var sizeMode: SizeMode = .match  // 输出体积档位（默认跟随原片）
}

// 耗时格式化: 8.4 秒 / 1 分 23 秒 / 1 小时 02 分
func humanDuration(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "-" }
    if seconds < 60 { return String(format: "%.1f 秒", seconds) }
    let total = Int(seconds.rounded())
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    if h > 0 { return String(format: "%d 小时 %02d 分", h, m) }
    return String(format: "%d 分 %02d 秒", m, s)
}

struct EndingResult {
    var input: String
    var output: String? = nil
    var total: Double = 0
    var message: String = ""
    var success = false
    /// 实际处理耗时（秒），仅编码阶段
    var elapsed: Double = 0
    /// 是否被用户中途停止（不计入失败）
    var cancelled = false
}

enum EndingEngine {

    static let defaultSFXCandidates = [
        "/Users/apple/Movies/Videos/旋风.mp3",
        "/Users/apple/Movies/旋风.mp3"
    ]

    static var defaultSFX: String {
        defaultSFXCandidates.first { FileManager.default.fileExists(atPath: $0) } ?? ""
    }

    static func isVideo(_ path: String) -> Bool {
        ["mp4", "mov", "m4v"].contains((path as NSString).pathExtension.lowercased())
    }

    static func hasAudio(_ path: String) -> Bool {
        let r = runTool(ffprobeBin(), ["-v", "error", "-select_streams", "a",
                                       "-show_entries", "stream=index", "-of", "csv=p=0", path])
        return r.code == 0 && !r.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    struct Timeline {
        let source: Double
        let total: Double
        let fadeOutStart: Double
        let fadeInStart: Double
        let sfxStart: Double
    }

    static func timeline(_ s: JobSettings, sourceDuration dur: Double) -> Timeline {
        let foStart = dur - s.fadeOut
        let fiStart = dur + s.whiteHold
        let total = dur + s.whiteHold + s.fadeIn + s.freeze
        return Timeline(source: dur, total: total,
                        fadeOutStart: foStart, fadeInStart: fiStart,
                        sfxStart: max(0, foStart + s.sfxOffset))
    }

    static func outputURL(for input: String, settings s: JobSettings) -> URL {
        let src = URL(fileURLWithPath: input)
        let dir: URL
        if let od = s.outputDir, !od.isEmpty {
            dir = URL(fileURLWithPath: od, isDirectory: true)
        } else {
            dir = src.deletingLastPathComponent()
        }
        return dir.appendingPathComponent(
            src.deletingPathExtension().lastPathComponent + s.suffix + ".mp4")
    }

    static func buildFilter(_ dur: Double, settings s: JobSettings,
                            audio: Bool, useSFX: Bool) -> String {
        let t = timeline(s, sourceDuration: dur)
        var fc = ""
        fc += "[0:v]split=2[v1][v2];"
        fc += String(format: "[v1]fade=t=out:st=%.3f:d=%.3f:color=white[segA];",
                     t.fadeOutStart, s.fadeOut)
        let pad = s.whiteHold + s.fadeIn + s.freeze
        fc += String(format: "[v2]tpad=stop_mode=clone:stop_duration=%.3f,trim=start=%.3f,setpts=PTS-STARTPTS,fade=t=in:st=%.3f:d=%.3f:color=white[segB];",
                     pad, dur, s.whiteHold, s.fadeIn)
        fc += "[segA][segB]concat=n=2:v=1:a=0,format=yuv420p[v];"
        if audio {
            if s.audioFade > 0 {
                let f = min(s.audioFade, dur)
                fc += String(format: "[0:a]aresample=44100,afade=t=out:st=%.3f:d=%.3f,apad=whole_dur=%.3f[base];",
                             dur - f, f, t.total)
            } else {
                fc += String(format: "[0:a]aresample=44100,apad=whole_dur=%.3f[base];", t.total)
            }
        } else {
            fc += String(format: "anullsrc=r=44100:cl=stereo,atrim=0:%.3f[base];", t.total)
        }
        if useSFX {
            let ms = Int(t.sfxStart * 1000)
            fc += "[1:a]aresample=44100,adelay=\(ms)|\(ms)[sfx];"
            fc += String(format: "[base][sfx]amix=inputs=2:duration=longest:normalize=0,atrim=0:%.3f,asetpts=PTS-STARTPTS[a];", t.total)
        } else {
            fc += "[base]anull[a];"
        }
        return fc
    }

    static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // 导出 shell 命令（--print-cmd 调试用，避开沙箱孙进程限制）
    static func command(input: String, settings s: JobSettings) -> String? {
        guard isVideo(input), let dur = probeDuration(input), dur > s.fadeOut + 0.1 else { return nil }
        let sfx = s.sfxPath ?? ""
        let useSFX = !sfx.isEmpty && FileManager.default.fileExists(atPath: sfx)
        let fc = buildFilter(dur, settings: s,
                             audio: hasAudio(input), useSFX: useSFX)
        let out = outputURL(for: input, settings: s)
        guard out.path != input else { return nil }  // 防止顶掉源文件
        try? FileManager.default.createDirectory(
            at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        var parts = [shellQuoted(ffmpegBin()),
                     "-hide_banner", "-loglevel", "error", "-y",
                     "-i", shellQuoted(input)]
        if useSFX { parts += ["-i", shellQuoted(sfx)] }
        parts += ["-filter_complex", shellQuoted(fc),
                  "-map", "[v]", "-map", "[a]"]
        parts += s.speed.videoArgs(targetBitRate: targetVideoKbps(input, sizeMode: s.sizeMode))
        parts += ["-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart",
                  "-y", shellQuoted(out.path)]
        return parts.joined(separator: " ")
    }

    @discardableResult
    static func run(input: String, settings s: JobSettings,
                    onProgress: ((Double) -> Void)? = nil) -> EndingResult {
        var r = EndingResult(input: input)
        guard isVideo(input) else { r.message = "不支持的格式"; return r }
        if RunControl.shared.isCancelled {
            r.cancelled = true
            r.message = "已停止"
            return r
        }
        guard let dur = probeDuration(input), dur > s.fadeOut + 0.1 else {
            r.message = "读取视频时长失败"; return r
        }
        let t = timeline(s, sourceDuration: dur)
        r.total = t.total
        let out = outputURL(for: input, settings: s)
        r.output = out.path
        if out.path == input {
            r.message = "输出与源文件同名同目录，请勾选「加后缀命名」或设置输出目录"; return r
        }
        if !s.overwrite && FileManager.default.fileExists(atPath: out.path) {
            r.message = "输出已存在，跳过"; return r
        }
        let sfx = s.sfxPath ?? ""
        let useSFX = !sfx.isEmpty && FileManager.default.fileExists(atPath: sfx)
        let fc = buildFilter(dur, settings: s,
                             audio: hasAudio(input), useSFX: useSFX)
        try? FileManager.default.createDirectory(
            at: out.deletingLastPathComponent(), withIntermediateDirectories: true)

        var args = ["-hide_banner", "-loglevel", "error", "-y", "-i", input]
        if useSFX { args += ["-i", sfx] }
        args += ["-filter_complex", fc, "-map", "[v]", "-map", "[a]"]
        args += s.speed.videoArgs(targetBitRate: targetVideoKbps(input, sizeMode: s.sizeMode))
        args += ["-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart", out.path]

        let t0 = Date()
        let res = onProgress.map {
            runToolProgress(ffmpegBin(), withProgressArgs(args), totalSeconds: t.total, onProgress: $0)
        } ?? runTool(ffmpegBin(), args)
        r.elapsed = Date().timeIntervalSince(t0)
        if res.code == 0 {
            onProgress?(1.0)
            r.success = true
            r.message = String(format: "完成（总长 %.2fs，用时 %@）", t.total, humanDuration(r.elapsed))
        } else if RunControl.shared.isCancelled {
            r.cancelled = true
            r.message = "已停止（未完成，已清理半成品）"
            try? FileManager.default.removeItem(at: out)
        } else {
            r.message = "失败：" + String(res.err.suffix(300))
        }
        return r
    }

    // MARK: 封面 + 结尾 一次编码（封面帧插最前 + 渐白/全白/定格 + 音效）
    // 输入: 0=视频, 1=封面图(loop), 2=音效(可选)

    static func buildCombinedFilter(_ dur: Double, w: Int, h: Int, fps: Double,
                                    settings s: JobSettings, audio: Bool, useSFX: Bool) -> String {
        let t = timeline(s, sourceDuration: dur)
        let still = 1.0 / fps
        let ms = max(Int(still * 1000), 1)
        let grandTotal = t.total + still
        var fc = ""
        fc += "[0:v]split=2[v1][v2];"
        fc += "[1:v]scale=\(w):\(h):force_original_aspect_ratio=decrease," +
              "pad=\(w):\(h):(ow-iw)/2:(oh-ih)/2:color=black,setsar=1,fps=\(fps)[c];"
        fc += String(format: "[v1]fade=t=out:st=%.3f:d=%.3f:color=white[segA];",
                     t.fadeOutStart, s.fadeOut)
        let pad = s.whiteHold + s.fadeIn + s.freeze
        fc += String(format: "[v2]tpad=stop_mode=clone:stop_duration=%.3f,trim=start=%.3f,setpts=PTS-STARTPTS,fade=t=in:st=%.3f:d=%.3f:color=white[segB];",
                     pad, dur, s.whiteHold, s.fadeIn)
        fc += "[c][segA][segB]concat=n=3:v=1:a=0,format=yuv420p[v];"
        if audio {
            if s.audioFade > 0 {
                let f = min(s.audioFade, dur)
                fc += String(format: "[0:a]aresample=44100,afade=t=out:st=%.3f:d=%.3f,adelay=%d:all=1,apad=whole_dur=%.3f[base];",
                             dur - f, f, ms, grandTotal)
            } else {
                fc += String(format: "[0:a]aresample=44100,adelay=%d:all=1,apad=whole_dur=%.3f[base];",
                             ms, grandTotal)
            }
        } else {
            fc += String(format: "anullsrc=r=44100:cl=stereo,atrim=0:%.3f[base];", grandTotal)
        }
        if useSFX {
            let sfxMs = Int((still + t.sfxStart) * 1000)
            fc += "[2:a]aresample=44100,adelay=\(sfxMs)|\(sfxMs)[sfx];"
            fc += String(format: "[base][sfx]amix=inputs=2:duration=longest:normalize=0,atrim=0:%.3f,asetpts=PTS-STARTPTS[a];",
                         grandTotal)
        } else {
            fc += "[base]anull[a];"
        }
        return fc
    }

    static func combinedArgs(input: String, cover: String, fc: String,
                             settings s: JobSettings, out: URL) -> [String]? {
        guard let (_, _, fps, _) = probeVideoInfo(input),
              probeDuration(input) != nil else { return nil }
        let still = 1.0 / fps
        let sfx = s.sfxPath ?? ""
        let useSFX = !sfx.isEmpty && FileManager.default.fileExists(atPath: sfx)
        var args = ["-hide_banner", "-loglevel", "error", "-y", "-i", input,
                    "-loop", "1", "-framerate", "\(fps)", "-t", String(still), "-i", cover]
        if useSFX { args += ["-i", sfx] }
        args += ["-filter_complex", fc, "-map", "[v]", "-map", "[a]"]
        args += s.speed.videoArgs(targetBitRate: targetVideoKbps(input, sizeMode: s.sizeMode))
        args += ["-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart", out.path]
        return args
    }

    static func commandCombined(input: String, cover: String, settings s: JobSettings) -> String? {
        guard isVideo(input),
              let (w, h, fps, _) = probeVideoInfo(input), w > 0, h > 0, fps > 0,
              let dur = probeDuration(input), dur > s.fadeOut + 0.1 else { return nil }
        let sfx = s.sfxPath ?? ""
        let useSFX = !sfx.isEmpty && FileManager.default.fileExists(atPath: sfx)
        let fc = buildCombinedFilter(dur, w: w, h: h, fps: fps,
                                     settings: s, audio: hasAudio(input), useSFX: useSFX)
        let out = outputURL(for: input, settings: s)
        guard out.path != input else { return nil }  // 防止顶掉源文件
        try? FileManager.default.createDirectory(
            at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let rawArgs = combinedArgs(input: input, cover: cover, fc: fc,
                                         settings: s, out: out),
              rawArgs.count > 4 else { return nil }
        // 重新 shell-quote 导出（combinedArgs 里是裸参数，供 Process 用）
        // 规则: 纯 flag（-y / -loglevel 这类）不加引号，其余一律加，滤镜串含 ;()[] 元字符必须 quote
        var quoted: [String] = []
        for a in rawArgs {
            let isFlag = a.hasPrefix("-") && a.count > 1 &&
                a.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
            quoted.append(isFlag ? a : shellQuoted(a))
        }
        // combinedArgs 不含二进制路径（runTool 会补），导出 shell 命令需补在开头
        return shellQuoted(ffmpegBin()) + " " + quoted.joined(separator: " ")
    }

    @discardableResult
    static func runCombined(input: String, cover: String, settings s: JobSettings,
                            onProgress: ((Double) -> Void)? = nil) -> EndingResult {
        var r = EndingResult(input: input)
        guard isVideo(input) else { r.message = "不支持的格式"; return r }
        if RunControl.shared.isCancelled {
            r.cancelled = true
            r.message = "已停止"
            return r
        }
        guard FileManager.default.fileExists(atPath: cover) else {
            r.message = "找不到封面图"; return r
        }
        guard let (w, h, fps, _) = probeVideoInfo(input), w > 0, h > 0, fps > 0 else {
            r.message = "读取视频信息失败"; return r
        }
        guard let dur = probeDuration(input), dur > s.fadeOut + 0.1 else {
            r.message = "读取视频时长失败"; return r
        }
        let t = timeline(s, sourceDuration: dur)
        r.total = t.total + 1.0 / fps
        let out = outputURL(for: input, settings: s)
        r.output = out.path
        if out.path == input {
            r.message = "输出与源文件同名同目录，请勾选「加后缀命名」或设置输出目录"; return r
        }
        if !s.overwrite && FileManager.default.fileExists(atPath: out.path) {
            r.message = "输出已存在，跳过"; return r
        }
        let sfx = s.sfxPath ?? ""
        let useSFX = !sfx.isEmpty && FileManager.default.fileExists(atPath: sfx)
        let fc = buildCombinedFilter(dur, w: w, h: h, fps: fps,
                                     settings: s, audio: hasAudio(input), useSFX: useSFX)
        try? FileManager.default.createDirectory(
            at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let args = combinedArgs(input: input, cover: cover, fc: fc,
                                      settings: s, out: out),
              args.count > 4 else {
            r.message = "构建命令失败"; return r
        }
        let t0 = Date()
        let res = onProgress.map {
            runToolProgress(ffmpegBin(), withProgressArgs(args), totalSeconds: r.total, onProgress: $0)
        } ?? runTool(ffmpegBin(), args)
        r.elapsed = Date().timeIntervalSince(t0)
        if res.code == 0 {
            onProgress?(1.0)
            r.success = true
            r.message = String(format: "完成（封面+结尾，总长 %.2fs，用时 %@）", r.total, humanDuration(r.elapsed))
        } else if RunControl.shared.isCancelled {
            r.cancelled = true
            r.message = "已停止（未完成，已清理半成品）"
            try? FileManager.default.removeItem(at: out)
        } else {
            r.message = "失败：" + String(res.err.suffix(300))
        }
        return r
    }

    static func collectInputs(from urls: [URL]) -> [String] {
        var out: [String] = []
        let fm = FileManager.default
        for u in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let items = (try? fm.contentsOfDirectory(atPath: u.path))?.sorted() ?? []
                for it in items {
                    let full = u.appendingPathComponent(it).path
                    if isVideo(full) { out.append(full) }
                }
            } else if isVideo(u.path) {
                out.append(u.path)
            }
        }
        return out.sorted()
    }
}

// ---------- CLI 测试入口 ----------

func cliMain() {
    let args = Array(CommandLine.arguments.dropFirst())
    // 插封面: --insert <视频> <封面图> [-o 目录]
    if args.first == "--insert" {
        guard args.count >= 3 else {
            print("用法: VideoPostCLI --insert <视频> <封面图> [-o 目录]"); exit(1)
        }
        var outDir: String? = nil
        var i = 3
        while i < args.count {
            if args[i] == "-o" { i += 1; outDir = args[i] }
            i += 1
        }
        let video = args[1]
        let dir = outDir ?? URL(fileURLWithPath: video).deletingLastPathComponent()
            .appendingPathComponent("加封面").path
        let r = insertCoverToVideo(video, coverPath: args[2], outputDir: dir) { print($0) }
        print(r ? "OK: \(dir)" : "FAILED")
        exit(r ? 0 : 1)
    }
    // 统一模式: --uni <起始名> <后缀> <间隔秒> <视频...> [-o 目录] [--jpg]
    if args.first == "--uni" {
        guard args.count >= 5 else {
            print("用法: VideoPostCLI --uni <起始名> <后缀> <间隔秒> <视频...> [-o 目录] [--jpg]"); exit(1)
        }
        let startName = args[1], suf = args[2], step = Double(args[3]) ?? 1.0
        var vids: [String] = []
        var outDir: String? = nil
        var jpg = false
        var i = 4
        while i < args.count {
            switch args[i] {
            case "-o": i += 1; outDir = args[i]
            case "--jpg": jpg = true
            default: vids.append(args[i])
            }
            i += 1
        }
        let dir = outDir ?? URL(fileURLWithPath: vids[0]).deletingLastPathComponent()
            .appendingPathComponent("\(startName)_covers").path
        let job = UnifiedJob(videos: vids, outputDir: dir, step: step, jpg: jpg,
                             quality: 0.9, startName: startName, suffix: suf)
        let r = runUnifiedJob(job) { _, _, log in print(log) }
        print("完成: 保存 \(r.saved), 跳过 \(r.skipped), 最后名称: \(r.finalName)")
        exit(r.saved > 0 ? 0 : 1)
    }
    // 封面模式: --cover <输出名> <视频> [-o 目录] [--jpg]
    if args.first == "--cover" {
        guard args.count >= 3 else {
            print("用法: VideoPostCLI --cover <输出名> <视频> [-o 目录] [--jpg]"); exit(1)
        }
        let outName = args[1]
        let video = args[2]
        var outDir: String? = nil
        var jpg = false
        var i = 3
        while i < args.count {
            switch args[i] {
            case "-o": i += 1; outDir = args[i]
            case "--jpg": jpg = true
            default: break
            }
            i += 1
        }
        let dir = outDir ?? URL(fileURLWithPath: video).deletingLastPathComponent()
            .appendingPathComponent("\(outName)_covers").path
        switch extractCover(video, outputDir: dir, outName: outName, jpg: jpg, quality: 0.9) {
        case .ok: print("封面已保存到 \(dir)"); exit(0)
        case .fail(let msg): print("失败: \(msg)"); exit(1)
        }
    }
    // 结尾处理模式: --ending <视频或目录...> [--sfx 路径] [--fade-out 秒] [--hold 秒] [--fade-in 秒]
    //              [--freeze 秒] [--sfx-offset 秒] [--afade 秒] [--speed fast|standard] [--size match|high] [--suffix 后缀] [-o 目录] [--overwrite] [--print-cmd]
    if args.first == "--ending" {
        var paths: [String] = []
        var s = JobSettings()
        var outDir: String? = nil
        var printCmd = false
        var coverArg: String? = nil
        var i = 1
        while i < args.count {
            let a = args[i]
            func need() -> String {
                i += 1
                guard i < args.count else {
                    print("参数 \(a) 缺少值"); exit(2)
                }
                return args[i]
            }
            switch a {
            case "--sfx": s.sfxPath = need()
            case "--fade-out": s.fadeOut = Double(need()) ?? s.fadeOut
            case "--hold": s.whiteHold = Double(need()) ?? s.whiteHold
            case "--fade-in": s.fadeIn = Double(need()) ?? s.fadeIn
            case "--freeze": s.freeze = Double(need()) ?? s.freeze
            case "--sfx-offset": s.sfxOffset = Double(need()) ?? s.sfxOffset
            case "--afade": s.audioFade = Double(need()) ?? 0
            case "--suffix": s.suffix = need()
            case "--out": outDir = need()
            case "--overwrite": s.overwrite = true
            case "--speed": s.speed = EncodeSpeed(rawValue: need().lowercased()) ?? .fast
            case "--size": s.sizeMode = SizeMode(rawValue: need().lowercased()) ?? .match
            case "--print-cmd": printCmd = true
            case "--cover": coverArg = need()
            default: paths.append(a)
            }
            i += 1
        }
        s.outputDir = outDir
        if (s.sfxPath ?? "").isEmpty {
            let def = EndingEngine.defaultSFX
            if !def.isEmpty { s.sfxPath = def }
        }
        let inputs = EndingEngine.collectInputs(from: paths.map { URL(fileURLWithPath: $0) })
        guard !inputs.isEmpty else { print("没有找到可处理的视频（支持 mp4/mov/m4v）"); exit(1) }
        // 封面: 单文件用于全部视频；目录则按集数自动匹配
        var covers: [String] = []
        var coverIsSingle = false
        if let ca = coverArg, !ca.isEmpty {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: ca, isDirectory: &isDir), isDir.boolValue {
                let exts = ["jpg", "jpeg", "png", "heic", "webp", "tiff", "bmp"]
                covers = ((try? FileManager.default.contentsOfDirectory(atPath: ca))?.sorted() ?? [])
                    .filter { exts.contains(($0 as NSString).pathExtension.lowercased()) }
                    .map { URL(fileURLWithPath: ca).appendingPathComponent($0).path }
            } else {
                covers = [ca]
                coverIsSingle = true
            }
        }
        func matchedCover(for video: String) -> String? {
            if coverIsSingle { return covers.first }
            return findCover(forVideo: video, covers: covers)
        }
        if printCmd {
            // 摘要走 stderr，命令走 stdout（可重定向成 .sh 直接执行）
            var failed = 0
            for input in inputs {
                if covers.isEmpty {
                    if let cmd = EndingEngine.command(input: input, settings: s) {
                        print(cmd)
                    } else {
                        FileHandle.standardError.write("✗ 无法构建命令：\(input)\n".data(using: .utf8)!)
                        failed += 1
                    }
                } else if let cover = matchedCover(for: input) {
                    if let cmd = EndingEngine.commandCombined(input: input, cover: cover, settings: s) {
                        print(cmd)
                    } else {
                        FileHandle.standardError.write("✗ 无法构建命令：\(input)\n".data(using: .utf8)!)
                        failed += 1
                    }
                } else {
                    FileHandle.standardError.write("✗ 没有匹配集数的封面，跳过：\(input)\n".data(using: .utf8)!)
                    failed += 1
                }
            }
            exit(failed == 0 ? 0 : 1)
        }
        var failed = 0
        print("共 \(inputs.count) 个视频，音效：\(s.sfxPath ?? "无")\(covers.isEmpty ? "" : "，封面：\(coverArg ?? "")")")
        for input in inputs {
            print("▶ \((input as NSString).lastPathComponent)")
            let r: EndingResult
            if covers.isEmpty {
                r = EndingEngine.run(input: input, settings: s)
            } else if let cover = matchedCover(for: input) {
                r = EndingEngine.runCombined(input: input, cover: cover, settings: s)
            } else {
                r = EndingResult(input: input, message: "跳过: 没有匹配集数的封面")
            }
            if r.success {
                print("  ✓ \(r.message) → \(r.output ?? "")")
            } else {
                print("  ✗ \(r.message)")
                failed += 1
            }
        }
        exit(failed == 0 ? 0 : 1)
    }
    // 集数自增测试: --ep <名称>
    if args.count == 2 && args[0] == "--ep" {
        if let r = incrementEpisode(args[1]) { print(r); exit(0) }
        print("NO_MATCH"); exit(2)
    }
    print("用法: VideoPostCLI --uni <起始名> <后缀> <间隔秒> <视频...> | --insert <视频> <封面> [-o 目录] | --cover <输出名> <视频> | --ending <视频...> [结尾参数] | --ep <名称>")
    exit(1)
}
// 短剧整理助手 —— 逻辑层 v3
// 命名模板（{剧名}{序号}{日期}{时间}{原名}{扩展名}）+ 非法字符/重复命名校验
// 自定义分类夹名称、自定义输出位置、文件夹新建/重命名
// 保留：整理归档、补零、撤销历史、CSV 导出、文件夹改名、CLI

import Foundation

// MARK: - 数据模型

enum ItemKind: String {
    case rename = "改名"
    case main   = "成片"
    case clean  = "纯净"
    case sub    = "字幕"
}

struct PlanItem: Identifiable {
    let id = UUID()
    let source: URL
    let target: URL
    let kind: ItemKind
    let size: Int64
    var duplicate: Bool = false   // 与计划内其他目标重名
    var conflict: Bool { FileManager.default.fileExists(atPath: target.path) }
}

let videoExts = ["mp4", "mov", "mkv", "m4v", "ts"]

// MARK: - 命名模板

let templatePlaceholders: [(token: String, desc: String)] = [
    ("{剧名}",   "输入的剧名"),
    ("{序号}",   "分集编号（自动配合补零设置）"),
    ("{日期}",   "今天的日期，如 2026-09-27"),
    ("{时间}",   "当前时间，如 142530"),
    ("{原名}",   "原文件名（不含扩展名）"),
    ("{扩展名}", "文件扩展名，如 mp4"),
]

let knownTokens = Set(templatePlaceholders.map { $0.token })

// macOS 文件名非法字符
let illegalNameChars = CharacterSet(charactersIn: "/\\:?%*|\"<>")

func illegalChars(in s: String) -> [Character] {
    var out: [Character] = []
    for ch in s where ch.unicodeScalars.contains(where: { illegalNameChars.contains($0) }) {
        if !out.contains(ch) { out.append(ch) }
    }
    return out
}

func firstMatch(_ pattern: String, _ s: String) -> [String]? {
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
    let ns = s as NSString
    guard let m = re.firstMatch(in: s, options: [], range: NSRange(location: 0, length: ns.length)) else { return nil }
    var out: [String] = []
    for i in 0..<m.numberOfRanges {
        out.append(m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i)))
    }
    return out
}

struct EpisodeParse {
    let prefix: String
    let digits: String
    let ext: String
    let copy: String?   // "(1)" 这类副本标记
}

// "41.mp4" → ("" , "41", mp4)   "SOD 51.mp4" → ("SOD ", "51")   "20(1).mp4" → ("", "20", copy "1")
// "Title EP41.mp4" → ("Title EP", "41") —— 已归档文件也能解析，用于重新命名
func parseEpisodeFile(_ name: String) -> EpisodeParse? {
    if let m = firstMatch("^(.*?)\\s*(\\d+)\\s*\\((\\d+)\\)\\.(" + videoExts.joined(separator: "|") + "|srt)$", name) {
        return EpisodeParse(prefix: m[1], digits: m[2], ext: m[4].lowercased(), copy: m[3])
    }
    if let m = firstMatch("^(.*?)\\s*(\\d+)\\.(" + videoExts.joined(separator: "|") + "|srt)$", name) {
        return EpisodeParse(prefix: m[1], digits: m[2], ext: m[3].lowercased(), copy: nil)
    }
    return nil
}

// "TFTH 25" → ("TFTH ", "25")
func parseEpisodeFolder(_ name: String) -> (prefix: String, digits: String)? {
    if let m = firstMatch("^(.*?)\\s*(\\d+)$", name) {
        return (m[1], m[2])
    }
    return nil
}

func isVideoExt(_ ext: String) -> Bool { videoExts.contains(ext.lowercased()) }

// pad: 补零位数（0 = 不补零，保持原数字写法）
func paddedDigits(_ digits: String, pad: Int) -> String {
    guard pad > 0, digits.count < pad else { return digits }
    return String(repeating: "0", count: pad - digits.count) + digits
}

// 旧版默认命名（模板为空时兜底）
func epTargetName(_ title: String, _ digits: String, _ ext: String, pad: Int = 0) -> String {
    "\(title) EP\(paddedDigits(digits, pad: pad)).\(ext)"
}

func renderTemplate(_ tpl: String, title: String, digits: String, pad: Int,
                    originalName: String, ext: String, date: Date = Date()) -> String {
    let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
    let tf = DateFormatter(); tf.dateFormat = "HHmmss"
    var s = tpl
    s = s.replacingOccurrences(of: "{剧名}", with: title)
    s = s.replacingOccurrences(of: "{序号}", with: paddedDigits(digits, pad: pad))
    s = s.replacingOccurrences(of: "{日期}", with: df.string(from: date))
    s = s.replacingOccurrences(of: "{时间}", with: tf.string(from: date))
    s = s.replacingOccurrences(of: "{原名}", with: originalName)
    s = s.replacingOccurrences(of: "{扩展名}", with: ext)
    // 模板没写 {扩展名} 时自动补上后缀，避免输出文件丢失扩展名
    if !tpl.contains("{扩展名}") && !ext.isEmpty {
        s += "." + ext
    }
    return s
}

// 模板与剧名校验：返回错误列表（空 = 通过）
func validateTemplate(_ tpl: String, title: String) -> [String] {
    var errs: [String] = []
    let t = tpl.trimmingCharacters(in: .whitespaces)
    if t.isEmpty { errs.append("命名模板为空。") }
    if !tpl.contains("{序号}") {
        errs.append("模板缺少 {序号}：没有序号时所有文件会生成同名目标，执行将被阻止。")
    }
    // 未知占位符
    if let re = try? NSRegularExpression(pattern: "\\{([^{}]*)\\}") {
        let ns = tpl as NSString
        var unknown: [String] = []
        for m in re.matches(in: tpl, options: [], range: NSRange(location: 0, length: ns.length)) {
            let token = "{\(ns.substring(with: m.range(at: 1)))}"
            if !knownTokens.contains(token), !unknown.contains(token) { unknown.append(token) }
        }
        if !unknown.isEmpty {
            errs.append("模板含未知占位符：\(unknown.joined(separator: " "))。可用：\(templatePlaceholders.map { $0.token }.joined(separator: " "))")
        }
    }
    // 非法字符
    var bad = illegalChars(in: tpl)
    for ch in illegalChars(in: title) where !bad.contains(ch) { bad.append(ch) }
    if !bad.isEmpty {
        errs.append("包含非法字符 \(bad.map { String($0) }.joined(separator: " "))——文件名不能含 / \\ : ? % * | \" < >，请修改后再扫描。")
    }
    return errs
}

func prettySize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

// MARK: - 设置持久化

struct AppSettings: Codable {
    var templates: [String]
    var template: String
    var catSub: String
    var catClean: String
    var catMain: String
    var useOutputFolder: Bool
    var outputFolderPath: String

    static let fallback = AppSettings(
        templates: ["{剧名} EP{序号}", "{剧名} EP{序号} {日期}", "{日期} {剧名} EP{序号}", "{剧名}_{序号}.{扩展名}"],
        template: "{剧名} EP{序号}",
        catSub: "字幕", catClean: "纯净", catMain: "成片",
        useOutputFolder: false, outputFolderPath: "")

    init(templates: [String], template: String, catSub: String, catClean: String,
         catMain: String, useOutputFolder: Bool, outputFolderPath: String) {
        self.templates = templates
        self.template = template
        self.catSub = catSub
        self.catClean = catClean
        self.catMain = catMain
        self.useOutputFolder = useOutputFolder
        self.outputFolderPath = outputFolderPath
    }

    // 兼容旧配置文件：缺 key 用默认值
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        templates         = try c.decodeIfPresent([String].self, forKey: .templates) ?? Self.fallback.templates
        template          = try c.decodeIfPresent(String.self, forKey: .template) ?? Self.fallback.template
        catSub            = try c.decodeIfPresent(String.self, forKey: .catSub) ?? Self.fallback.catSub
        catClean          = try c.decodeIfPresent(String.self, forKey: .catClean) ?? Self.fallback.catClean
        catMain           = try c.decodeIfPresent(String.self, forKey: .catMain) ?? Self.fallback.catMain
        useOutputFolder   = try c.decodeIfPresent(Bool.self, forKey: .useOutputFolder) ?? false
        outputFolderPath  = try c.decodeIfPresent(String.self, forKey: .outputFolderPath) ?? ""
    }
}

var appSupportDir: URL {
    let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/DramaOrganizer", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

var settingsURL: URL { appSupportDir.appendingPathComponent("settings.json") }

func loadSettings() -> AppSettings {
    guard let data = try? Data(contentsOf: settingsURL),
          let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return .fallback }
    return s
}

func saveSettings(_ s: AppSettings) {
    if let data = try? JSONEncoder().encode(s) {
        try? data.write(to: settingsURL, options: .atomic)
    }
}

// MARK: - 扫描

struct PlanResult {
    var items: [PlanItem]
    var notes: [String]
    var errors: [String]   // 致命错误（模板非法等）：items 为空
}

struct CategoryNames {
    var sub: String
    var clean: String
    var main: String
    var all: [String] { [sub, clean, main] }
}

let defaultCats = CategoryNames(sub: "字幕", clean: "纯净", main: "成片")

func buildPlan(folder origFolder: URL, title: String, organize: Bool, srtEPName: Bool,
               pad: Int = 0, template: String = "", cats: CategoryNames = defaultCats,
               outputFolder: URL? = nil) -> PlanResult {
    let fm = FileManager.default
    let folder = origFolder.resolvingSymlinksInPath()
    var items: [PlanItem] = []
    var notes: [String] = []
    let trimmedTitle = title.trimmingCharacters(in: .whitespaces)

    // 模板校验（模板为空 = 旧版默认命名，不校验模板本身，只查剧名非法字符）
    let tpl = template.trimmingCharacters(in: .whitespaces)
    let errs = tpl.isEmpty ? validateTemplate("{剧名} EP{序号}", title: trimmedTitle) : validateTemplate(tpl, title: trimmedTitle)
    if !errs.isEmpty { return PlanResult(items: [], notes: [], errors: errs) }
    if trimmedTitle.isEmpty { return PlanResult(items: [], notes: [], errors: ["剧名不能为空"]) }

    // 输出位置：自定义输出文件夹（不存在则自动创建）或原地
    var dest = folder
    if var out = outputFolder?.resolvingSymlinksInPath(), out.path != folder.path {
        if !fm.fileExists(atPath: out.path) {
            do {
                try fm.createDirectory(at: out, withIntermediateDirectories: true)
                notes.append("已创建输出文件夹：\(out.path)")
            } catch {
                notes.append("⚠️ 无法创建输出文件夹（\(error.localizedDescription)），将在当前文件夹内处理。")
                out = folder
            }
        }
        dest = out
    } else if outputFolder != nil {
        notes.append("⚠️ 输出文件夹与素材文件夹相同，将在当前文件夹内处理。")
    }

    // 按模板生成目标名（含扩展名）
    func nameFor(digits: String, ext: String, original: String) -> String {
        if tpl.isEmpty {
            return epTargetName(trimmedTitle, digits, ext, pad: pad)
        }
        return renderTemplate(tpl, title: trimmedTitle, digits: digits, pad: pad,
                              originalName: original, ext: ext)
    }

    func size(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    func append(_ source: URL, _ target: URL, _ kind: ItemKind) {
        if source.path == target.path { return }
        items.append(PlanItem(source: source, target: target, kind: kind, size: size(of: source)))
    }

    guard let children = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: []) else {
        return PlanResult(items: [], notes: [], errors: ["无法读取目录：\(folder.path)"])
    }

    var subfolderCount = 0
    let catSet = Set(cats.all)

    for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let name = child.lastPathComponent
        if name.hasPrefix(".") { continue }

        let isDir = ((try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory) ?? false

        // 已归档的分类夹（支持自定义名称）：里面的文件原地改名（换剧名/换模板）
        if catSet.contains(name) {
            guard let inner = try? fm.contentsOfDirectory(at: child, includingPropertiesForKeys: [.fileSizeKey], options: []) else { continue }
            for f in inner.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let fname = f.lastPathComponent
                if fname.hasPrefix(".") { continue }
                guard let p = parseEpisodeFile(fname) else {
                    notes.append("跳过文件（无法识别集数）：\(name)/\(fname)")
                    continue
                }
                let base = (fname as NSString).deletingPathExtension
                let ext = isVideoExt(p.ext) || p.ext == "srt" ? p.ext : (fname as NSString).pathExtension
                append(f, child.appendingPathComponent(nameFor(digits: p.digits, ext: ext, original: base)), .rename)
            }
            continue
        }

        if isDir {
            subfolderCount += 1
            guard let (_, folderDigits) = parseEpisodeFolder(name) else {
                notes.append("跳过文件夹（无法识别集数）：\(name)")
                continue
            }
            guard let inner = try? fm.contentsOfDirectory(at: child, includingPropertiesForKeys: [.fileSizeKey], options: []) else {
                notes.append("跳过文件夹（无法读取内部）：\(name)")
                continue
            }
            for f in inner.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let fname = f.lastPathComponent
                if fname.hasPrefix(".") { continue }
                if let p = parseEpisodeFile(fname) {
                    let digits = p.digits.isEmpty ? folderDigits : p.digits
                    let base = (fname as NSString).deletingPathExtension
                    if isVideoExt(p.ext) {
                        append(f, dest.appendingPathComponent("\(cats.main)/\(nameFor(digits: digits, ext: p.ext, original: base))"), .main)
                    } else if p.ext == "srt" {
                        let targetName = srtEPName ? nameFor(digits: digits, ext: "srt", original: base) : fname
                        append(f, dest.appendingPathComponent("\(cats.sub)/\(targetName)"), .sub)
                    } else {
                        notes.append("跳过文件（未知类型）：\(name)/\(fname)")
                    }
                } else {
                    notes.append("跳过文件（无法识别集数）：\(name)/\(fname)")
                }
            }
        } else if let p = parseEpisodeFile(name) {
            let base = (name as NSString).deletingPathExtension
            if p.ext == "srt" {
                if organize {
                    let targetName = srtEPName ? nameFor(digits: p.digits, ext: "srt", original: base) : name
                    append(child, dest.appendingPathComponent("\(cats.sub)/\(targetName)"), .sub)
                } else {
                    append(child, dest.appendingPathComponent(nameFor(digits: p.digits, ext: "srt", original: base)), .rename)
                }
            } else if isVideoExt(p.ext) {
                if organize, p.copy != nil {
                    // 带 (N) 副本标记的 → 纯净；普通视频原地改名（不再生成「成片」文件夹）
                    append(child, dest.appendingPathComponent("\(cats.clean)/\(nameFor(digits: p.digits, ext: p.ext, original: base))"), .clean)
                } else {
                    append(child, dest.appendingPathComponent(nameFor(digits: p.digits, ext: p.ext, original: base)), .rename)
                }
            } else {
                notes.append("跳过文件（未知类型）：\(name)")
            }
        } else {
            notes.append("跳过文件（无法识别集数）：\(name)")
        }
    }

    // 重复命名检测：计划内两个及以上条目指向同一目标 → 标记并阻止执行
    var targetCounts: [String: Int] = [:]
    for it in items { targetCounts[it.target.path, default: 0] += 1 }
    let dupPaths = Set(targetCounts.filter { $0.value > 1 }.keys)
    for i in items.indices where dupPaths.contains(items[i].target.path) {
        items[i].duplicate = true
    }
    if !dupPaths.isEmpty {
        let examples = dupPaths.prefix(3).map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: "、")
        notes.append("❌ 存在重复命名（如 \(examples)），执行已被阻止。请检查模板是否包含 {序号} 或 {原名} 等能区分文件的占位符。")
    }

    if subfolderCount > 0 && organize == false && catSet.isDisjoint(with: Set(children.map { $0.lastPathComponent })) {
        notes.append("检测到 \(subfolderCount) 个子文件夹未处理；勾选「整理模式」可把里面的 mp4/srt 一并归位。")
    }
    if items.isEmpty && notes.isEmpty {
        notes.append("没有识别到可处理的分集文件。")
    }
    return PlanResult(items: items, notes: notes, errors: [])
}

// MARK: - 执行

struct MoveRecord: Codable {
    let from: String
    let to: String
}

struct ExecResult {
    var logs: [String]
    var moves: [MoveRecord]
}

func executePlan(_ items: [PlanItem], overwrite: Bool) -> ExecResult {
    var logs: [String] = []
    var moves: [MoveRecord] = []
    let fm = FileManager.default

    for parent in Set(items.map({ $0.target.deletingLastPathComponent() })) {
        try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    for it in items {
        if fm.fileExists(atPath: it.target.path) {
            if overwrite {
                do {
                    try fm.trashItem(at: it.target, resultingItemURL: nil)
                    logs.append("🗑 旧文件入废纸篓：\(it.target.lastPathComponent)")
                } catch {
                    logs.append("⚠️ 无法移除旧目标，跳过：\(it.target.lastPathComponent)（\(error.localizedDescription)）")
                    continue
                }
            } else {
                logs.append("⚠️ 目标已存在，跳过：\(it.target.lastPathComponent)")
                continue
            }
        }
        do {
            try fm.moveItem(at: it.source, to: it.target)
            moves.append(MoveRecord(from: it.source.path, to: it.target.path))
            logs.append("✅ \(it.source.lastPathComponent) → \(it.target.lastPathComponent)")
        } catch {
            logs.append("❌ \(it.source.lastPathComponent)（\(error.localizedDescription)）")
        }
    }
    return ExecResult(logs: logs, moves: moves)
}

// MARK: - 操作历史（撤销支持）

struct HistoryBatch: Codable {
    let date: Date
    let folder: String
    let title: String
    let ops: [MoveRecord]
    var renamedFrom: String?
    var renamedTo: String?
}

var historyURL: URL { appSupportDir.appendingPathComponent("history.json") }

func loadHistory() -> [HistoryBatch] {
    guard let data = try? Data(contentsOf: historyURL),
          let batches = try? JSONDecoder().decode([HistoryBatch].self, from: data) else { return [] }
    return batches
}

func saveHistory(_ batches: [HistoryBatch]) {
    if let data = try? JSONEncoder().encode(batches) {
        try? data.write(to: historyURL, options: .atomic)
    }
}

func recordBatch(folder: URL, title: String, moves: [MoveRecord], renamedFrom: String? = nil, renamedTo: String? = nil) {
    guard !moves.isEmpty || renamedFrom != nil else { return }
    var hist = loadHistory()
    hist.append(HistoryBatch(date: Date(), folder: folder.path, title: title, ops: moves,
                             renamedFrom: renamedFrom, renamedTo: renamedTo))
    if hist.count > 30 { hist = Array(hist.suffix(30)) }
    saveHistory(hist)
}

// 撤销最近一批：先还原文件夹名，再把所有文件移回原位（倒序执行）
func undoLastBatch() -> [String] {
    var hist = loadHistory()
    guard let last = hist.popLast() else { return ["没有可撤销的操作。"] }
    saveHistory(hist)
    let fm = FileManager.default
    var logs = ["↩️ 撤销 \(last.date) 对「\(last.title)」的操作："]

    if let rf = last.renamedFrom, let rt = last.renamedTo,
       fm.fileExists(atPath: rt), !fm.fileExists(atPath: rf) {
        do {
            try fm.moveItem(atPath: rt, toPath: rf)
            logs.append("📁 文件夹已还原：\(URL(fileURLWithPath: rt).lastPathComponent) → 原名")
        } catch {
            logs.append("⚠️ 文件夹还原失败（\(error.localizedDescription)），后续文件还原可能受影响")
        }
    }

    logs.append("共 \(last.ops.count) 项文件移动：")
    for op in last.ops.reversed() {
        let to = URL(fileURLWithPath: op.to)
        let from = URL(fileURLWithPath: op.from)
        if fm.fileExists(atPath: to.path) {
            if fm.fileExists(atPath: from.path) {
                logs.append("⚠️ 原位置已被占用，保留现文件：\(from.lastPathComponent)")
                continue
            }
            do {
                try? fm.createDirectory(at: from.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: to, to: from)
                logs.append("↩️ \(to.lastPathComponent) → 原位")
            } catch {
                logs.append("❌ \(to.lastPathComponent)（\(error.localizedDescription)）")
            }
        } else {
            logs.append("⚠️ 找不到，跳过：\(to.lastPathComponent)")
        }
    }
    logs.append("（整理时产生的空文件夹和进废纸篓的旧文件不在撤销范围内）")
    return logs
}

// MARK: - CSV 导出

func csvField(_ s: String) -> String {
    s.contains(",") || s.contains("\"") || s.contains("\n")
        ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        : s
}

func planCSV(_ items: [PlanItem], folderPath: String) -> String {
    var rows = ["类型,原文件,目标,大小(字节)"]
    for it in items {
        let rel = it.target.path.replacingOccurrences(of: folderPath + "/", with: "")
        rows.append([it.kind.rawValue, it.source.path, rel, String(it.size)].map(csvField).joined(separator: ","))
    }
    return "\u{FEFF}" + rows.joined(separator: "\n")
}

// MARK: - 文件夹改名 / 新建 / 管理

// 把素材文件夹改名为「剧名 41-45导出」（编号取自计划中的目标文件）
func renameFolderToExportName(_ folder: URL, title: String, items: [PlanItem]) -> (url: URL?, log: String) {
    let digits = items.compactMap { parseEpisodeFile($0.target.lastPathComponent)?.digits }.compactMap { Int($0) }
    guard let mn = digits.min(), let mx = digits.max() else {
        return (nil, "⚠️ 无法从目标名中确定集数范围，文件夹未改名")
    }
    let newName = "\(title) \(mn)-\(mx)导出"
    return renameFolder(folder, to: newName)
}

// 通用文件夹重命名（含名称合法性校验）
func renameFolder(_ folder: URL, to newName: String) -> (url: URL?, log: String) {
    let bad = illegalChars(in: newName)
    if !bad.isEmpty {
        return (nil, "❌ 名称含非法字符 \(bad.map { String($0) }.joined(separator: " "))：/ \\ : ? % * | \" < >")
    }
    let trimmed = newName.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return (nil, "❌ 名称不能为空") }
    if trimmed == folder.lastPathComponent { return (folder, "文件夹已是该名称：\(trimmed)") }
    let dest = folder.deletingLastPathComponent().appendingPathComponent(trimmed)
    if FileManager.default.fileExists(atPath: dest.path) {
        return (nil, "❌ 已存在同名文件夹：\(trimmed)")
    }
    do {
        try FileManager.default.moveItem(at: folder, to: dest)
        return (dest, "📁 \(folder.lastPathComponent) → \(trimmed)")
    } catch {
        return (nil, "⚠️ 文件夹改名失败（\(error.localizedDescription)）")
    }
}

// 在指定目录下新建文件夹
func createFolder(in parent: URL, name: String) -> (url: URL?, log: String) {
    let bad = illegalChars(in: name)
    if !bad.isEmpty {
        return (nil, "❌ 名称含非法字符 \(bad.map { String($0) }.joined(separator: " "))：/ \\ : ? % * | \" < >")
    }
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return (nil, "❌ 名称不能为空") }
    let dest = parent.appendingPathComponent(trimmed)
    if FileManager.default.fileExists(atPath: dest.path) {
        return (nil, "❌ 已存在同名文件夹：\(trimmed)")
    }
    do {
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
        return (dest, "📁 已新建文件夹：\(trimmed)")
    } catch {
        return (nil, "⚠️ 新建失败（\(error.localizedDescription)）")
    }
}

// MARK: - 空文件夹与废纸篓

// 整理后找空文件夹（排除分类夹本身）
func findEmptyFolders(in folder: URL, cats: CategoryNames = defaultCats) -> [URL] {
    let fm = FileManager.default
    guard let children = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return [] }
    var empties: [URL] = []
    let catSet = Set(cats.all)
    for c in children {
        let name = c.lastPathComponent
        if name.hasPrefix(".") || catSet.contains(name) { continue }
        let isDir = ((try? c.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory) ?? false
        if isDir {
            let inner = (try? fm.contentsOfDirectory(atPath: c.path)) ?? []
            if inner.isEmpty { empties.append(c) }
        }
    }
    return empties
}

func trashItems(_ urls: [URL]) -> [String] {
    var logs: [String] = []
    for u in urls {
        do {
            try FileManager.default.trashItem(at: u, resultingItemURL: nil)
            logs.append("🗑 \(u.lastPathComponent) → 废纸篓")
        } catch {
            logs.append("⚠️ \(u.lastPathComponent)（\(error.localizedDescription)）")
        }
    }
    return logs
}

// MARK: - CLI 模式

func organizerCLI() -> Never {
    let args = CommandLine.arguments
    func usage() {
        print("""
        用法: 短剧整理助手 --cli <文件夹> "<剧名>" [选项]
          --organize       字幕→字幕夹、带(N)副本→纯净夹；普通视频原地改名（不生成成片夹）
          --cats a,b,c     自定义三个分类夹名称（顺序：字幕,纯净,成片）
          --template T     命名模板，占位符：{剧名} {序号} {日期} {时间} {原名} {扩展名}
          --srt-ep         字幕也按模板/EPxx 命名（默认保留原名）
          --pad N          集数补零到 N 位（默认不补零）
          --out <文件夹>   输出到其他文件夹（默认原地处理）
          --overwrite      目标已存在时先把旧文件移入废纸篓
          --rename-folder  执行后把文件夹改名为「剧名 NN-NN导出」
          --csv <路径>     把改名对照表导出为 CSV
          --undo           撤销最近一次执行（忽略其他参数）
          --execute        真正执行（默认只预览）
        """)
    }
    if args.contains("--undo") {
        for line in undoLastBatch() { print(line) }
        exit(0)
    }
    guard args.count >= 4, args[1] == "--cli" else { usage(); exit(2) }
    let folder = URL(fileURLWithPath: args[2])
    let title = args[3]
    let organize = args.contains("--organize")
    let srtEPName = args.contains("--srt-ep")
    let overwrite = args.contains("--overwrite")
    let renameFolder = args.contains("--rename-folder")
    let execute = args.contains("--execute")
    var pad = 0
    if let i = args.firstIndex(of: "--pad"), i + 1 < args.count, let p = Int(args[i + 1]) { pad = p }
    var tpl = ""
    if let i = args.firstIndex(of: "--template"), i + 1 < args.count { tpl = args[i + 1] }
    var cats = defaultCats
    if let i = args.firstIndex(of: "--cats"), i + 1 < args.count {
        let parts = args[i + 1].components(separatedBy: ",")
        if parts.count == 3 { cats = CategoryNames(sub: parts[0], clean: parts[1], main: parts[2]) }
    }
    var outDir: URL? = nil
    if let i = args.firstIndex(of: "--out"), i + 1 < args.count { outDir = URL(fileURLWithPath: args[i + 1]) }
    var csvPath: String? = nil
    if let i = args.firstIndex(of: "--csv"), i + 1 < args.count { csvPath = args[i + 1] }

    let plan = buildPlan(folder: folder, title: title, organize: organize, srtEPName: srtEPName,
                         pad: pad, template: tpl, cats: cats, outputFolder: outDir)
    print("扫描：\(folder.path)")
    print("剧名：\(title)   整理模式：\(organize ? "开" : "关")   补零：\(pad > 0 ? "\(pad) 位" : "无")\(tpl.isEmpty ? "" : "   模板：\(tpl)")")
    print(String(repeating: "-", count: 60))
    if !plan.errors.isEmpty {
        for e in plan.errors { print("❌ \(e)") }
        exit(1)
    }
    for n in plan.notes { print("ℹ️  \(n)") }
    for it in plan.items {
        var mark = it.conflict ? " [目标已存在]" : ""
        if it.duplicate { mark += " [重复命名]" }
        print("\(it.kind.rawValue.padding(toLength: 2, withPad: "　", startingAt: 0))  \(it.source.lastPathComponent)  →  \(it.target.path.replacingOccurrences(of: folder.path + "/", with: ""))  (\(prettySize(it.size)))\(mark)")
    }
    print(String(repeating: "-", count: 60))
    print("共 \(plan.items.count) 项，冲突 \(plan.items.filter { $0.conflict }.count) 项，重复 \(plan.items.filter { $0.duplicate }.count) 项\(execute ? "" : "（预览模式，未改动任何文件）")")

    if let cp = csvPath {
        let csv = planCSV(plan.items, folderPath: folder.path)
        try? csv.write(toFile: cp, atomically: true, encoding: .utf8)
        print("📄 对照表已导出：\(cp)")
    }

    if execute {
        if plan.items.contains(where: { $0.duplicate }) {
            print("❌ 存在重复命名，已阻止执行。")
            exit(1)
        }
        print("\n执行：")
        let result = executePlan(plan.items, overwrite: overwrite)
        for line in result.logs { print(line) }
        var renamedFrom: String? = nil, renamedTo: String? = nil
        if organize {
            let empties = findEmptyFolders(in: folder, cats: cats)
            if !empties.isEmpty {
                print("\n空文件夹 \(empties.count) 个：")
                for line in trashItems(empties) { print(line) }
            }
        }
        if renameFolder {
            let (newURL, log) = renameFolderToExportName(folder, title: title, items: plan.items)
            print(log)
            if let newURL {
                renamedFrom = folder.path
                renamedTo = newURL.path
            }
        }
        recordBatch(folder: folder, title: title, moves: result.moves,
                    renamedFrom: renamedFrom, renamedTo: renamedTo)
        print("\n提示：执行已记录，可用 --undo 撤销。")
    }
    exit(0)
}
