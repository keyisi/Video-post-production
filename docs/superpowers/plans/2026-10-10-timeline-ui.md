# 封面与结尾 · 时间线 UI 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把「插入封面」和「结尾处理」两个表单式板块合并成一个「封面与结尾」板块，用两行时间线呈现成片结构，并支持直接在时间线上拖拽调整结尾四段时长。

**Architecture:** 时间线的时长换算、布局、钳制抽到 `Logic.swift` 的纯数据结构 `TimelineModel`（只 import Foundation，可用 CLI 单测）；`ComposeView` 只负责 SwiftUI 渲染与拖拽手势。编码层完全不动——时间线只产出 `JobSettings`，仍交给现成的 `EndingEngine.runCombined` / `run` / `insertCoverToVideo`。

**Tech Stack:** Swift 5 / SwiftUI / macOS 13.0+ / 内置 ffmpeg+ffprobe / 零第三方依赖 / swiftc 直接编译（无 Xcode 工程、无 SwiftPM）

**Spec:** `docs/superpowers/specs/2026-10-10-timeline-ui-design.md`（本计划从该规格推导，执行时两者都要读）

## Global Constraints

- 板块命名：**封面与结尾**；侧边栏图标 `flag.checkered`
- 导航从 5 项变 4 项：视频抽帧(0) / 封面与结尾(1) / 整理归档(2) / 关于与更新(3)
- **封面锁死 1 帧**（`coverFrame = 1/fps`），`SegmentID.cover` 的 `editable` 恒为 false
- 可拖段只有四个：渐白左缘 / 全白右缘 / 渐显右缘 / 定格右缘
- 拖拽步进 **0.05 秒**；拖拽过程显示 2 位小数，松手 round 到 0.05 的整数倍
- 钳制范围：`fadeOut ∈ [0.05, sourceDuration−0.1]`（`sourceDuration` 未知时上限 10）、`whiteHold ∈ [0, 10]`、`fadeIn ∈ [0.05, 10]`、`freeze ∈ [0.1, 30]`
- `context = max(1.0, fadeOut * 2)`；`windowDuration = context + whiteHold + fadeIn + freeze`
- 时间线左右 padding = **12**；行 1 封面段宽 **10**、结尾段宽 **60**（均为固定像素，非比例）
- **渐白是叠在正片尾部之上**（`isOverlay = true`），不是排在正片后面
- 拖拽期间必须冻结 `windowDuration`（含 `context`），松手才重算
- **不改动任何 ffmpeg 命令**；`Logic.swift` 现有的 `EndingEngine` / `insertCoverToVideo` / `cliMain()` 行为不变
- `Logic.swift` 只 import Foundation——模型层不得出现 `CGFloat` / `Color` / SwiftUI 类型
- GUI 编译：`swiftc -disable-sandbox -O -parse-as-library Logic.swift App.swift -o "build/Video Post-Production.app/Contents/MacOS/VideoFrameTool"`（**可执行文件叫 VideoFrameTool，不是 App 显示名**）
- 改 `Info.plist` 的 `CFBundleShortVersionString` 后必须重新 `codesign --force -s -`
- 版本：`3.17.0 → 3.18.0`（新功能进 `y`，`z` 归 0）
- **不得主动发 Release / 上传 dmg-zip / 更新分享包**——只有用户明确说「发布」才做对外发布
- `调试记录.md`：每次排查/修复追加一条，格式「现象 → 排查过程 → 根因 → 修复 → 验证 → 版本/commit」，**新条目插在最前面**

## Review Focus

规格暗示了但各任务测试未必覆盖的五类输入/失败模式，按最可能咬人排序；每类后面标了负责钉住它的任务：

1. **`sourceDuration` 未知（ffprobe 失败或还没选视频）** —— 用户仍能编辑时间线，`fadeOut` 上限退化为 10，不得出现 NaN 或崩溃 → Test: Task 1 `testClampUnknownSource`
2. **`whiteHold = 0`** —— 段宽必须是 0 且不产生除零/NaN，渲染成虚线缝 → Test: Task 2 `testZeroWidthSegment`
3. **把 `freeze` 拖到极大（30 秒）** —— 拖拽期间窗口比例冻结，松手后整体重排，被拖边界不得往回缩 → Test: Task 2 `testFrozenWindow`
4. **结尾开关关闭** —— 必须走 `insertCoverToVideo`，输出到视频旁的「加封面」文件夹、**文件名不变**；suffix 不生效 → Test: Task 5 `testEndingOffUsesInsertCover`
5. **升级后 `fxt_section` 仍是 3 或 4 的用户** —— 必须映射到 2（整理归档）/ 3（关于与更新），侧边栏不能指向空白页 → Test: Task 6 `testSectionRemap`

---

### Task 1: TimelineModel 数据模型与钳制

**Files:**
- Modify: `Logic.swift`（在 `EndingEngine` 之后、`cliMain()` 之前新增一个 `// MARK: - 时间线模型` 区块）
- Create: `tests/TimelineModelTests.swift`

**Interfaces:**
- Consumes: `JobSettings`（Logic.swift:1058）、`humanDuration`（Logic.swift:1074）——已存在
- Produces: `SegmentID`、`TimelineModel`（含 `context` / `windowDuration` / `total` / `clamp` / `toJobSettings`）；Task 2 会在此基础上加 `layout` / `overview` 与 `LaidOutSegment`

- [ ] **Step 1: 写失败测试**

新建 `tests/TimelineModelTests.swift`（独立可执行文件，含顶层代码，自行统计失败数并以非 0 退出）：

```swift
import Foundation

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print(ok ? "PASS \(name)" : "FAIL \(name)")
    if !ok { failures += 1 }
}

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
check(js.fadeOut == 0.25 && js.whiteHold == 0 && js.fadeIn == 0.25 && js.freeze == 1.0, "toJobSettingsValues")

exit(failures == 0 ? 0 : 1)
```

- [ ] **Step 2: 跑一次确认它失败**

Run: `swiftc -disable-sandbox -O tests/TimelineModelTests.swift Logic.swift -o /tmp/tltest 2>&1 | grep -c "error:"`
Expected: 输出 > 0（报 `TimelineModel` 未定义）

- [ ] **Step 3: 在 `Logic.swift` 实现模型**

```swift
enum SegmentID: String, CaseIterable {
    case cover, source, fadeOut, whiteHold, fadeIn, freeze
    /// 仅用于行 1 总览里的「结尾」汇总段，不参与行 2 布局
    case ending
}

struct TimelineModel {
    var sourceDuration: Double = 0
    var coverFrame: Double = 1.0 / 24
    var fadeOut: Double = 0.25
    var whiteHold: Double = 0.0
    var fadeIn: Double = 0.25
    var freeze: Double = 1.0
    var endingEnabled: Bool = true

    var context: Double { max(1.0, fadeOut * 2) }
    var windowDuration: Double { context + whiteHold + fadeIn + freeze }

    var total: Double {
        guard endingEnabled else { return coverFrame + sourceDuration }
        return coverFrame + sourceDuration + whiteHold + fadeIn + freeze
    }

    func clamp(_ value: Double, for id: SegmentID) -> Double
    func toJobSettings() -> JobSettings
}
```

`clamp` 的边界（逐字照规格）：`fadeOut` 下限 0.05、上限 `sourceDuration > 0 ? max(0.05, sourceDuration - 0.1) : 10`；`whiteHold ∈ [0, 10]`；`fadeIn ∈ [0.05, 10]`；`freeze ∈ [0.1, 30]`；`cover` / `source` 原样返回。`toJobSettings()` 复用 `EndingView.settings` 现有派生规则（含 `suffix` 为空回落「定格白场」），但只映射时间线自己拥有的四个字段，其余交给调用方补齐。

- [ ] **Step 4: 跑测试确认通过**

Run: `swiftc -disable-sandbox -O tests/TimelineModelTests.swift Logic.swift -o /tmp/tltest && /tmp/tltest`
Expected: 全部 PASS，退出码 0

- [ ] **Step 5: 提交**

```bash
git add Logic.swift tests/TimelineModelTests.swift
git commit -m "feat: TimelineModel 时间线数据模型与参数钳制（含 CLI 单测）"
```

---

### Task 2: layout / overview 布局计算

**Files:**
- Modify: `Logic.swift`（同区块，新增 `LaidOutSegment`、`layout`、`overview`）
- Modify: `tests/TimelineModelTests.swift`（追加断言）

**Interfaces:**
- Consumes: Task 1 的 `TimelineModel`、`SegmentID`
- Produces: `LaidOutSegment`、`TimelineModel.layout(width:frozenWindow:)`、`TimelineModel.overview(width:)` —— Task 3/4 的视图直接消费

- [ ] **Step 1: 追加失败测试**

在 `tests/TimelineModelTests.swift` 的 `exit` 之前追加：

```swift
// 7. 行 2 布局：段宽之和 = 可用宽度
let segs = m.layout(width: 600)
let sum = segs.filter { !$0.isOverlay }.reduce(0) { $0 + $1.width }
check(abs(sum - (600 - 24)) < 0.001, "layoutWidthsSumToUsable")
check(segs.first(where: { $0.id == .fadeOut })?.isOverlay == true, "fadeOutIsOverlay")

// 8. 0 值段宽为 0（Review Focus #2）
m.whiteHold = 0
let z = m.layout(width: 600).first(where: { $0.id == .whiteHold })
check(z?.width == 0, "testZeroWidthSegment")
check(segs.allSatisfy { $0.width.isFinite && $0.x.isFinite }, "allFinite")

// 9. 冻结窗口（Review Focus #3）：冻结后改 freeze 不改变布局
m.freeze = 1.0
let beforeFreeze = m.layout(width: 600, frozenWindow: 2.25)
    .first(where: { $0.id == .freeze })!.width
m.freeze = 30
let afterFreeze = m.layout(width: 600, frozenWindow: 2.25)
    .first(where: { $0.id == .freeze })!.width
check(abs(beforeFreeze - afterFreeze) < 0.001, "testFrozenWindow")

// 10. 行 1 总览
let ov = m.overview(width: 600)
check(ov.map(\.id) == [.cover, .source, .ending], "overviewThreeSegments")
check(ov.first(where: { $0.id == .cover })?.editable == false, "coverNotEditable")
m.endingEnabled = false
check(m.overview(width: 600).count == 2, "overviewNoEndingWhenDisabled")
```

- [ ] **Step 2: 跑一次确认失败**

Run: `swiftc -disable-sandbox -O tests/TimelineModelTests.swift Logic.swift -o /tmp/tltest 2>&1 | grep -c "error:"`
Expected: 输出 > 0（`layout` / `overview` 未定义）

- [ ] **Step 3: 实现 `LaidOutSegment`、`layout`、`overview`**

```swift
struct LaidOutSegment {
    let id: SegmentID
    let title: String
    let x: Double
    let width: Double
    let duration: Double
    let editable: Bool
    let isOverlay: Bool
}
```

`layout(width:frozenWindow:)` 算法（padding = 12，`usable = max(width - 24, 1)`，`secPerPx = (frozenWindow ?? windowDuration) / usable`）：
按 `source → fadeOut(overlay) → whiteHold → fadeIn → freeze` 顺序排布；`source` 宽 `context/secPerPx`；`fadeOut` 是 overlay，**右缘对齐 `source` 右缘**、宽 `fadeOut/secPerPx`；其后三段依次首尾相接。段标题固定为「正片」「渐白」「全白」「渐显」「定格」。`editable`：`source` 为 false，其余为 true。

`overview(width:)`：封面宽固定 10，结尾宽固定 60，`endingEnabled == false` 时省略结尾段，正片吃掉剩余宽度；`editable` 全为 false，标题「封面」「正片」「结尾」。

- [ ] **Step 4: 跑测试确认通过**

Run: `swiftc -disable-sandbox -O tests/TimelineModelTests.swift Logic.swift -o /tmp/tltest && /tmp/tltest`
Expected: 全部 PASS

- [ ] **Step 5: 端到端时长校验**

用内置 ffmpeg 造一条 3 秒测试片，跑 `runCombined`，用 ffprobe 比对输出时长 = `TimelineModel.total`：

```bash
FF=$(find "build/Video Post-Production.app/Contents/Resources" -name ffmpeg 2>/dev/null | head -1)
"$FF" -f lavfi -i testsrc=size=320x240:rate=24 -t 3 -pix_fmt yuv420p /tmp/tl_in.mp4 -y
```

把这条断言加进测试（`sourceDuration` 用 `probeDuration("/tmp/tl_in.mp4")` 填），断言 `abs(probeDuration(out) - m.total) < 0.2`。

- [ ] **Step 6: 提交**

```bash
git add Logic.swift tests/TimelineModelTests.swift
git commit -m "feat: 时间线布局计算 layout/overview（含冻结窗口与端到端时长校验）"
```

---

### Task 3: 时间线视图组件（渲染，不含手势）

**Files:**
- Modify: `App.swift`（在 `// MARK: - 通用小组件` 区块、`LogPanel` 之后新增 `TimelineBar`）

**Interfaces:**
- Consumes: Task 2 的 `LaidOutSegment`、`TimelineModel.layout/overview`
- Produces: `struct TimelineBar: View`，签名 `init(model: TimelineModel, width: CGFloat, frozenWindow: Double? = nil, onDragChanged: ((SegmentID, Double) -> Void)? = nil, onDragEnded: (() -> Void)? = nil)` —— Task 4 会接上这两个闭包，Task 5 会把它放进 `ComposeView`

- [ ] **Step 1: 实现渲染**

两行结构：行 1 用 `model.overview(width:)`，行 2 用 `model.layout(width:frozenWindow:)`。行 2 里 `isOverlay` 的段画成半透明 + 虚线描边叠在 `source` 段之上（用 `ZStack(alignment: .leading)` 加 `.offset(x:)` 定位，不要用 GeometryReader 递归）。配色：封面灰 `#888780`、正片浅灰、渐白蓝 `Theme.accent`、全白琥珀 `Theme.warn`、渐显紫 `Theme.accentDeep`、定格绿 `Theme.ok`。段内显示标题，宽度不足 46 时只显示标题不显示秒数。`whiteHold` 宽为 0 时画一条虚线缝 + 上方标注「全白 0s」。

- [ ] **Step 2: 编译验证**

Run: `swiftc -disable-sandbox -O -parse-as-library Logic.swift App.swift -o /tmp/vpp_tl 2>&1 | grep -c "error:"`
Expected: `0`

- [ ] **Step 3: 提交**

```bash
git add App.swift
git commit -m "feat: TimelineBar 时间线渲染组件（两行：总览 + 尾部放大窗口）"
```

---

### Task 4: 拖拽手势与冻结窗口

**Files:**
- Modify: `App.swift`（`TimelineBar` 内部新增手柄与手势；新增 `struct DragHandle: View`）

**Interfaces:**
- Consumes: Task 3 的 `TimelineBar` 闭包参数、Task 1 的 `TimelineModel.clamp`
- Produces: 可拖的 `TimelineBar`；`ComposeView`（Task 5）通过 `onDragChanged` 收到 `(SegmentID, 新时长)`、`onDragEnded` 收到结束信号

- [ ] **Step 1: 实现手柄与手势**

四个手柄：`.fadeOut`（拖左缘）、`.whiteHold` / `.fadeIn` / `.freeze`（拖右缘）。每个手柄是一个宽 5、高度超出时间线条 8pt 的圆角条，挂 `DragGesture(minimumDistance: 1)`。

`onChanged` 首次进入时把 `model.windowDuration` 存进 `@State frozenWindow` 并传给 `layout`；换算 `delta = translation.width * secPerPx(frozen)`，新值 = `clamp(原值 + delta)`。`onEnded` 时把值 round 到 0.05 的整数倍、清空 `frozenWindow`、调用 `onDragEnded`。

拖到钳制上限就停住，不弹框：手柄染红，并在时间线下方显示「渐白最长 X 秒（正片 Y 秒）」。

- [ ] **Step 2: 编译验证**

Run: `swiftc -disable-sandbox -O -parse-as-library Logic.swift App.swift -o /tmp/vpp_tl 2>&1 | grep -c "error:"`
Expected: `0`

- [ ] **Step 3: 人工验证**

编译进 App 并用 `defaults write local.workbuddy.videoframetool fxt_section -int 1` 打开板块，确认：拖动手柄数字框同步变化、拖到上限停住、松手后值落在 0.05 的倍数上。

- [ ] **Step 4: 提交**

```bash
git add App.swift
git commit -m "feat: 时间线拖拽手势（冻结窗口换算 + 0.05 秒步进 + 上限提示）"
```

---

### Task 5: ComposeView 组装与两条执行路径

**Files:**
- Modify: `App.swift`（新增 `struct ComposeView: View`，放在原 `InsertCoverView` 的位置）

**Interfaces:**
- Consumes: Task 4 的 `TimelineBar`、`TimelineModel.toJobSettings`、`insertCoverToVideo`（Logic.swift:908）、`EndingEngine.runCombined`（Logic.swift:1345）、`EndingEngine.run`（Logic.swift:1205）、`findCover`（Logic.swift:802）、`probeDuration`（Logic.swift:710）
- Produces: `ComposeView` —— Task 6 会把它挂进导航

- [ ] **Step 1: 迁移状态与文件选择**

新建 `ComposeView`，`AppStorage` key：文件列表用 **`fxt_compVideos` / `fxt_compCovers`**；时间参数**复用现有 key**（`fxt_endFadeOut`、`fxt_endWhiteHold`、`fxt_endFadeIn`、`fxt_endFreeze`、`fxt_endSfxOffset`、`fxt_endSfx`、`fxt_endSuffix`、`fxt_endRename`、`fxt_endOverwrite`、`fxt_endOutDir`、`fxt_endAFade`、`fxt_endAFadeDur`、`fxt_endSpeed`、`fxt_sizeMode`）；新增 `fxt_compEndingOn`（默认 true）。

`onAppear` 做一次性迁移：若 `fxt_compVideos` 为空，依次尝试 `fxt_endVideos`、`fxt_insVideos`，取第一个非空值写入。保留原 `DropZone` 两个（视频 / 封面）、`matchPairs` / `unusedCovers` 匹配预览、`pickVideos` / `pickCovers` / `collectURLs` / `handleDropVideos` / `handleDropCovers`（从 `InsertCoverView` 原样搬过来）。

- [ ] **Step 2: 接上时间线与参数区**

`sourceDuration` 用 `@State`，在视频列表变化时对**第一个视频**调 `probeDuration` 填充，行 1 标注「以第一个视频为准」；probe 失败时保持 0 并显示「时长未知」。

参数区保留 `endField` / `parseNum`（原样搬来）与 `TimelineBar` 并排；结尾开关 `Toggle("处理结尾", isOn: $endingEnabled)`，关闭时隐藏行 2、主按钮文案变「把封面插入视频开头」。

原 `EndingView` 的这些控件**原样搬来、行为不变**：音效选择（`pickSFX`）、原视频音频淡出开关与时长、编码速度 `EncodeSpeed`、输出体积 `SizeMode`、输出目录（`pickOutDir` + 打开输出文件夹）、文件名后缀、覆盖已存在文件。

拖拽中若视频列表被清空，丢弃 `frozenWindow`、时间线回到骨架态，不得残留旧时长。

- [ ] **Step 3: 两条执行路径**

`start()` 分支（Review Focus #4）：
- `endingEnabled == false` → 走 `insertCoverToVideo`，输出目录 `currentOutDir(for:)`（视频旁的「**加封面**」文件夹）、**文件名不变**
- `endingEnabled == true` 且有匹配封面 → `EndingEngine.runCombined`
- `endingEnabled == true` 但无封面 → `EndingEngine.run`
- 输出目录：自定义优先，否则视频旁的「**加结尾**」文件夹

批量循环、`RunControl` 取消、`NiceProgress`、`LogPanel`、summary 文案从 `EndingView.start()`（App.swift:1817-1922）与 `InsertCoverView.insertCovers()`（App.swift:1284-1361）原样搬来。`stop()` 同 `EndingView.stop()`。

**删除**：`continueToEnding()`（App.swift:1193）与 `fxt_endLocked` 相关逻辑。

- [ ] **Step 4: 编译验证**

Run: `swiftc -disable-sandbox -O -parse-as-library Logic.swift App.swift -o /tmp/vpp_tl 2>&1 | grep -c "error:"`
Expected: `0`

- [ ] **Step 5: 端到端跑一条真视频**

造 3 秒测试片 + 一张封面图，分别跑「结尾开」和「结尾关」两条路径，确认：结尾开 → 输出文件名带 suffix、时长 = `model.total`；结尾关 → 输出在「加封面」文件夹、文件名不变。把这条断言记为 `testEndingOffUsesInsertCover` 并在 `调试记录.md` 记录结果。

- [ ] **Step 6: 提交**

```bash
git add App.swift
git commit -m "feat: ComposeView 组装（文件选择 + 时间线 + 两条执行路径）"
```

---

### Task 6: 导航改 4 项与 fxt_section 迁移

**Files:**
- Modify: `App.swift`（`ContentView`：`navItems`、`ZStack` 层数、`onAppear` 迁移）

**Interfaces:**
- Consumes: Task 5 的 `ComposeView`
- Produces: 4 项导航；Task 7 删除旧板块后仍能正确渲染

- [ ] **Step 1: 写失败测试**

在 `tests/TimelineModelTests.swift` 追加（纯函数，不依赖 UI）：

```swift
check(remapSection(0) == 0, "testSectionRemap0")
check(remapSection(1) == 1 && remapSection(2) == 1, "testSectionRemapCoverEnding")
check(remapSection(3) == 2, "testSectionRemapOrganizer")
check(remapSection(4) == 3, "testSectionRemapAbout")
check(remapSection(99) == 3, "testSectionRemapOutOfRange")
```

- [ ] **Step 2: 实现导航改动**

在 `Logic.swift` 新增自由函数（View 与测试共用同一份，不要各写一遍）：

```swift
/// 板块从 5 个减到 4 个后的 tag 映射（旧 1/2 合并为 1，旧 3→2，旧 4→3）
func remapSection(_ old: Int) -> Int {
    switch old {
    case 0: return 0
    case 1, 2: return 1
    case 3: return 2
    default: return 3
    }
}
```

`navItems` 改为 4 项并更新 tag；`ZStack` 从 5 层减到 4 层（`sectionLayer(1) { ComposeView() }`）；`ContentView` 加 `.onAppear { section = remapSection(section) }`。

- [ ] **Step 3: 编译 + 跑测试**

Run: `swiftc -disable-sandbox -O tests/TimelineModelTests.swift Logic.swift -o /tmp/tltest && /tmp/tltest` 与 `swiftc -disable-sandbox -O -parse-as-library Logic.swift App.swift -o /tmp/vpp_tl 2>&1 | grep -c "error:"`
Expected: 全部 PASS / `0`

- [ ] **Step 4: 提交**

```bash
git add App.swift Logic.swift tests/TimelineModelTests.swift
git commit -m "feat: 导航改 4 项，新增 fxt_section 错位迁移"
```

---

### Task 7: 删除旧板块与版本收尾

**Files:**
- Modify: `App.swift`（删除 `InsertCoverView` 939–1372、`EndingView` 1373–1933）
- Modify: `build/Video Post-Production.app/Contents/Info.plist`（版本 → 3.18.0）
- Modify: `README.md`、`Video Post-Production 分享包/使用说明.txt`、`调试记录.md`、`docs/superpowers/specs/2026-10-10-timeline-ui-design.md`（无需改）

**Interfaces:**
- Consumes: Task 6 的 4 项导航（旧板块此时已无人引用）

- [ ] **Step 1: 删除两个旧 View**

整段删除；保留 `endField` / `parseNum` / `collectURLs` 等已被 `ComposeView` 复制走的成员不再需要单独保留。确认全局无 `InsertCoverView` / `EndingView` / `fxt_endLocked` / `continueToEnding` 残留引用。

- [ ] **Step 2: 重新编译并签名到 3.18.0**

```bash
swiftc -disable-sandbox -O -parse-as-library Logic.swift App.swift -o "build/Video Post-Production.app/Contents/MacOS/VideoFrameTool"
swiftc -disable-sandbox -O main.swift Logic.swift -o build/videopost-cli
plutil -replace CFBundleShortVersionString -string "3.18.0" "build/Video Post-Production.app/Contents/Info.plist"
codesign --force -s - "build/Video Post-Production.app"
codesign --force -s - build/videopost-cli
```

Expected: `grep -c "error:"` 为 0；`codesign -v "build/Video Post-Production.app"` 通过

- [ ] **Step 3: 真机冒烟**

启动 App，`defaults write local.workbuddy.videoframetool fxt_section -int 1` 打开新板块，确认 4 项导航都在、切换正常、时间线渲染与拖拽可用、旧板块入口已消失。

- [ ] **Step 4: 文档与调试记录**

README 徽章 `version-3.18.0-blue` + 板块说明改为「封面与结尾（时间线）」；分享包 `使用说明.txt` 同步板块清单并升版本号；`调试记录.md` **在最前面**追加一条（现象 → 排查过程 → 根因 → 修复 → 验证 → 版本/commit）。

- [ ] **Step 5: 备份、提交并推送**

```bash
cd .. && ditto -c -k --sequesterRsrc --keepParent video2frames-app "版本备份/Video_Post-Production_v3.18.0_封面与结尾时间线_2026-10-10.源码.zip"
git add -A && git commit -m "v3.18.0: 合并插入封面与结尾处理为「封面与结尾」时间线板块（可拖拽调整结尾四段，删除旧两个板块）"
for i in 1 2 3; do git -c http.version=HTTP/1.1 push && break; sleep 3; done
```

推送若撞 502，去掉直连改走 `git -c http.version=HTTP/1.1 -c http.proxy=http://127.0.0.1:7890 push`。

**不要发 Release、不要更新分享包里的 App。**

- [ ] **Step 6: 报告**

向用户汇报：版本号、commit hash、删除了什么、新增了什么，以及「未发 Release」的确认。
