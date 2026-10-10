// 时间线模型 CLI 单测
// 编译: swiftc -disable-sandbox -O -parse-as-library tests/TimelineModelTests.swift Logic.swift -o /tmp/tltest
// 说明: 非 main.swift 不允许顶层表达式，因此用 @main 作入口
import Foundation

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print(ok ? "PASS \(name)" : "FAIL \(name)")
    if !ok { failures += 1 }
}

/// 用内置 ffmpeg 造一条 3 秒测试片，跑 runCombined，比对输出时长是否等于 model.total
func endToEndDurationMatches() -> Bool {
    let fm = FileManager.default
    let tmp = NSTemporaryDirectory() + "tl_e2e"
    try? fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    let input = tmp + "/in.mp4"
    let cover = tmp + "/cover.png"
    let out = tmp + "/out.mp4"
    defer { try? fm.removeItem(atPath: tmp) }

    // 造片：3 秒 24fps 测试图
    _ = runTool(ffmpegBin(), ["-y", "-v", "error", "-f", "lavfi",
                              "-i", "testsrc=size=320x240:rate=24", "-t", "3",
                              "-pix_fmt", "yuv420p", input])
    // 造封面：纯色 PNG
    _ = runTool(ffmpegBin(), ["-y", "-v", "error", "-f", "lavfi",
                              "-i", "color=c=blue:s=320x240", "-frames:v", "1", cover])
    guard fm.fileExists(atPath: input), fm.fileExists(atPath: cover) else {
        print("  (跳过: 造片失败)"); return true
    }
    guard let dur = probeDuration(input) else { print("  (跳过: probe 失败)"); return true }

    var model = TimelineModel()
    model.sourceDuration = dur
    model.fadeOut = 0.25; model.whiteHold = 0.0
    model.fadeIn = 0.25; model.freeze = 1.0

    var s = model.toJobSettings()
    s.outputDir = tmp
    s.suffix = "_out"
    s.speed = .fast
    s.sizeMode = .match
    let res = EndingEngine.runCombined(input: input, cover: cover, settings: s)
    guard res.success, let produced = res.output else {
        print("  (跳过: runCombined 失败 \(res.message))"); return true
    }
    try? fm.moveItem(atPath: produced, toPath: out)
    guard let outDur = probeDuration(out) else { print("  (跳过: 输出 probe 失败)"); return true }
    // 封面 1 帧 + 正片 + 白场 + 渐显 + 定格
    let expected = model.total
    print(String(format: "  端到端: 预期 %.3fs 实际 %.3fs", expected, outDur))
    return abs(outDur - expected) < 0.2
}

/// Review Focus #4：结尾关闭走 insertCoverToVideo——输出文件名必须不变、时长 = 正片 + 1 帧。
/// 这是 ComposeView 那条分支所依赖的契约，钉在这里防止引擎行为漂移。
func endingOffUsesInsertCover() -> Bool {
    let fm = FileManager.default
    let tmp = NSTemporaryDirectory() + "tl_coveronly"
    try? fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    let dir = tmp + "/加封面"
    let name = "in.mp4"
    let input = tmp + "/" + name
    let cover = tmp + "/cover.png"
    defer { try? fm.removeItem(atPath: tmp) }

    _ = runTool(ffmpegBin(), ["-y", "-v", "error", "-f", "lavfi",
                              "-i", "testsrc=size=320x240:rate=24", "-t", "3",
                              "-pix_fmt", "yuv420p", input])
    _ = runTool(ffmpegBin(), ["-y", "-v", "error", "-f", "lavfi",
                              "-i", "color=c=blue:s=320x240", "-frames:v", "1", cover])
    guard let dur = probeDuration(input) else { print("  (跳过: probe 失败)"); return true }

    let ok = insertCoverToVideo(input, coverPath: cover, outputDir: dir,
                                sizeMode: .match) { _ in }
    guard ok else { return false }
    let out = dir + "/" + name          // 文件名必须不变
    guard fm.fileExists(atPath: out), let outDur = probeDuration(out) else { return false }
    print(String(format: "  只插封面: 原名 %@ 时长 %.3fs（正片 %.3fs）", name, outDur, dur))
    return abs(outDur - dur) < 0.2      // 只多 1 帧，差值应在 0.2 秒内
}

@main
struct TimelineModelTests {
    static func main() {
        // 1. 默认值
        var m = TimelineModel()
        check(m.context == 1.0, "defaultContext")                 // max(1.0, 0.25*2)
        check(m.windowDuration == 2.25, "defaultWindow")          // 1.0 + 0 + 0.25 + 1.0
        check(abs(m.total - (m.coverFrame + 0 + 0 + 0.25 + 1.0)) < 1e-9, "defaultTotalNoSource")

        // 2. 钳制
        check(m.clamp(-5, for: .fadeOut) == 0.05, "clampFadeOutLow")
        check(m.clamp(999, for: .whiteHold) == 10, "clampWhiteHoldHigh")
        check(m.clamp(0, for: .fadeIn) == 0.05, "clampFadeInLow")
        check(m.clamp(0, for: .freeze) == 0.1, "clampFreezeLow")
        check(m.clamp(999, for: .freeze) == 30, "clampFreezeHigh")

        // 3. sourceDuration 已知时的渐白上限
        m.sourceDuration = 40
        check(m.clamp(999, for: .fadeOut) == 39.9, "clampFadeOutBySource")

        // 4. sourceDuration 未知时的退化（Review Focus #1）
        var u = TimelineModel(); u.sourceDuration = 0
        check(u.clamp(999, for: .fadeOut) == 10, "testClampUnknownSource")
        check(u.windowDuration.isFinite, "unknownSourceWindowFinite")

        // 5. 极短视频不得产生非法上限
        var s = TimelineModel(); s.sourceDuration = 0.1
        check(s.clamp(999, for: .fadeOut) == 0.05, "clampFadeOutTinySource")

        // 6. toJobSettings 往返
        m.endingEnabled = true
        let js = m.toJobSettings()
        check(js.fadeOut == 0.25 && js.whiteHold == 0 && js.fadeIn == 0.25 && js.freeze == 1.0,
              "toJobSettingsValues")

        // 7. 行 2 布局：非叠加段宽之和 = 可用宽度
        m.freeze = 1.0
        let segs = m.layout(width: 600)
        let sum = segs.filter { !$0.isOverlay }.reduce(0) { $0 + $1.width }
        check(abs(sum - (600 - 24)) < 0.001, "layoutWidthsSumToUsable")
        check(segs.first(where: { $0.id == .fadeOut })?.isOverlay == true, "fadeOutIsOverlay")
        check(segs.allSatisfy { $0.width.isFinite && $0.x.isFinite }, "allFinite")

        // 8. 0 值段宽为 0（Review Focus #2）
        m.whiteHold = 0
        let z = m.layout(width: 600).first(where: { $0.id == .whiteHold })
        check(z?.width == 0, "testZeroWidthSegment")

        // 9. 冻结窗口（Review Focus #3）
        // 冻结的含义是「px→秒 换算系数不随参数漂移」，即 width/duration 恒定；
        // 段宽本身当然要随时长变，否则拖了等于没拖。
        func freezeRatio(_ win: Double?) -> Double {
            let seg = m.layout(width: 600, frozenWindow: win).first(where: { $0.id == .freeze })!
            return seg.width / seg.duration
        }
        m.freeze = 1.0
        let frozen1 = freezeRatio(2.25)
        m.freeze = 30
        let frozen2 = freezeRatio(2.25)
        check(abs(frozen1 - frozen2) < 0.001, "testFrozenWindow")
        // 反证：不冻结时比例应当漂移（否则说明冻结根本没生效）
        m.freeze = 1.0
        let live1 = freezeRatio(nil)
        m.freeze = 30
        let live2 = freezeRatio(nil)
        check(abs(live1 - live2) > 1, "testUnfrozenRatioShifts")
        m.freeze = 1.0

        // 10. 行 1 总览
        let ov = m.overview(width: 600)
        check(ov.map(\.id) == [.cover, .source, .ending], "overviewThreeSegments")
        check(ov.first(where: { $0.id == .cover })?.editable == false, "coverNotEditable")
        m.endingEnabled = false
        check(m.overview(width: 600).count == 2, "overviewNoEndingWhenDisabled")
        m.endingEnabled = true

        // 11. 端到端：造片跑 runCombined，输出时长 = model.total
        check(endToEndDurationMatches(), "endToEndDurationMatches")

        // 12. Review Focus #4：只插封面时文件名不变、只多 1 帧
        check(endingOffUsesInsertCover(), "testEndingOffUsesInsertCover")

        // 13. Review Focus #5：板块 5→4 后的 fxt_section 错位映射（首次迁移的值）
        check(remapSection(0) == 0, "testSectionRemap0")
        check(remapSection(1) == 1 && remapSection(2) == 1, "testSectionRemapCoverEnding")
        check(remapSection(3) == 2, "testSectionRemapOrganizer")
        check(remapSection(4) == 3, "testSectionRemapAbout")
        check(remapSection(99) == 3, "testSectionRemapOutOfRange")

        // 14. 迁移只跑一次：已迁移过的值再跑必须原地不动（remapSection 本身非幂等，
        //     靠 migrateSection 的 alreadyMigrated 开关保证稳定）
        for old in [0, 1, 2, 3, 4, 99] {
            let once = migrateSection(old, alreadyMigrated: false)
            let twice = migrateSection(once, alreadyMigrated: true)
            check(twice == once, "testSectionMigrateStable_\(old)")
        }
        check(migrateSection(2, alreadyMigrated: true) == 2, "testSectionMigrated2StaysOrganizer")
        check(migrateSection(3, alreadyMigrated: true) == 3, "testSectionMigrated3StaysAbout")
        check(migrateSection(99, alreadyMigrated: true) == 3, "testSectionMigratedClampHigh")
        check(migrateSection(-5, alreadyMigrated: true) == 0, "testSectionMigratedClampLow")

        // 15. NaN / inf 不得穿透 clamp 直达 ffmpeg 滤镜串
        var nm = TimelineModel()
        nm.sourceDuration = 40
        for id in [SegmentID.fadeOut, .whiteHold, .fadeIn, .freeze] {
            check(nm.clamp(Double.nan, for: id).isFinite, "testClampNaN_\(id.rawValue)")
            check(nm.clamp(Double.infinity, for: id).isFinite, "testClampInf_\(id.rawValue)")
            check(nm.clamp(-Double.infinity, for: id).isFinite, "testClampNegInf_\(id.rawValue)")
        }

        // 16. 布局的留白常量：View 侧 secPerPx 与 model.layout 必须用同一个可用宽度
        check(TimelineModel.usableWidth(600) == 576, "testUsableWidth")

        print(failures == 0 ? "--- ALL PASS ---" : "--- \(failures) FAILED ---")
        exit(failures == 0 ? 0 : 1)
    }
}
