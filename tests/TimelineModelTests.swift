// 时间线模型 CLI 单测
// 编译: swiftc -disable-sandbox -O -parse-as-library tests/TimelineModelTests.swift Logic.swift -o /tmp/tltest
// 说明: 非 main.swift 不允许顶层表达式，因此用 @main 作入口
import Foundation

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print(ok ? "PASS \(name)" : "FAIL \(name)")
    if !ok { failures += 1 }
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

        print(failures == 0 ? "--- ALL PASS ---" : "--- \(failures) FAILED ---")
        exit(failures == 0 ? 0 : 1)
    }
}
