# 封面与结尾 · 时间线 UI 设计

日期：2026-10-10
目标版本：v3.18.0
状态：已与用户逐节确认，待实施

---

## 1. 背景与目标

Video Post-Production 目前有五个板块，其中「插入封面」和「结尾处理」是两个连续的
手工步骤：先在插入封面把封面图插到视频开头，再点「继续到结尾处理」跨板块带入，
才能一次编码出片。

两个板块都是表单式 UI（拖文件 + 一排数字输入框 + 日志 + 大按钮）。结尾处理的五个
时间参数（渐白 / 全白保持 / 渐显 / 定格 / 音效偏移）只以纯数字呈现，用户无法直观
看出它们在成片里的先后位置、相对比例，以及与正片尾部的重叠关系。

**目标**：把两个板块合并成一个「封面与结尾」板块，用一条时间线呈现成片结构，
并支持直接在时间线上拖拽调整结尾各段时长。

**成功标准**：
- 一眼能看出成片由哪些片段组成、各占多长、谁和谁重叠
- 结尾四段可直接拖拽调整，与数字输入框双向同步
- 一次编码完成「插封面 + 做结尾」，不再需要跨板块流转
- 输出的 ffmpeg 命令与改动前完全一致（本次不改编码逻辑）

---

## 2. 现状事实（改动前）

| 事实 | 位置 |
|---|---|
| `InsertCoverView` 约 434 行 | App.swift 939–1372 |
| `EndingView` 约 561 行 | App.swift 1373–1933 |
| 五个板块常驻 ZStack，按 `fxt_section` 切换 | App.swift 291–297 |
| 封面只占 **1 帧**（`stillDur = 1/fps`） | Logic.swift 926 |
| `fadeOut` 起点是 `dur - fadeOut`，即**叠在正片尾部** | Logic.swift 1125 |
| `EndingEngine.runCombined` 已支持封面+结尾一次编码 | Logic.swift 1345 |
| `insertCoverToVideo` 负责纯插封面 | Logic.swift 908 |
| 参数钳制：`fadeOut ≥ 0.05`、`fadeIn ≥ 0.05`、`freeze ≥ 0.1`、`whiteHold ≥ 0` | App.swift 1435–1446 |
| ffmpeg 前置校验 `dur > fadeOut + 0.1` | Logic.swift 1183、1320 |

**关键约束**：正片通常 40 分钟，结尾总长只有 1.5 秒。真按比例画，结尾段占 0.06%，
既看不见也拖不动 —— 这是本设计要解决的首要问题。

---

## 3. 已确认的决定

| 议题 | 决定 |
|---|---|
| 时间线范围 | 合并成**一个新板块**，替换原来的「插入封面」「结尾处理」两个板块 |
| 交互程度 | **可拖拽编辑**，数字输入框与时间线双向同步 |
| 封面时长 | **保持 1 帧锁死**，封面段不可拖（它是给成片当首帧海报用的，不能改） |
| 缩放策略 | **尾部放大窗口**（方案 A）：正片折叠成标签，末尾单独放大成足够宽的可拖区 |
| 板块命名 | **封面与结尾** |
| 实现路径 | 时间线模型抽到 `Logic.swift`，View 只管渲染与手势 |

---

## 4. 板块与导航

### 4.1 导航从 5 项变 4 项

| 现在（tag） | 之后（tag） |
|---|---|
| 视频抽帧 (0) | 视频抽帧 (0) |
| 插入封面 (1) | **封面与结尾 (1)** |
| 结尾处理 (2) | （并入上面） |
| 整理归档 (3) | 整理归档 (2) |
| 关于与更新 (4) | 关于与更新 (3) |

侧边栏图标用 `flag.checkered`（沿用结尾处理）—— 时间线的主体是结尾四段，封面是锁死的辅助项。

### 4.2 删除范围

- `InsertCoverView`（App.swift 939–1372）整段删除
- `EndingView`（App.swift 1373–1933）整段删除，但其中的 `endField` 辅助方法、
  `parseNum`、批量执行循环、日志/进度逻辑需要保留到新的 `ComposeView`
- 「继续到结尾处理」跨板块流转按钮、`fxt_endLocked` 锁定横幅 —— 合并后不再需要，删除
- `sectionLayer` 从 5 层减到 4 层

---

## 5. 数据模型（新增到 Logic.swift）

模型是纯数据，不引用 `SwiftUI` / `Color`，以便用 CLI harness 单测。

```swift
enum SegmentID: String, CaseIterable {
    case cover, source, fadeOut, whiteHold, fadeIn, freeze
}

/// 时间线上的一段
struct TimelineSegment: Identifiable {
    let id: SegmentID
    let title: String        // 封面 / 正片 / 渐白 / 全白 / 渐显 / 定格
    var duration: Double     // 秒；0 表示当前不生效
    let editable: Bool       // 封面与正片恒 false
}

/// 时间线模型：负责时长换算、布局、钳制。不涉及任何 UI
struct TimelineModel {
    var sourceDuration: Double = 0      // ffprobe 得到的真实时长，未知时为 0
    var coverFrame: Double = 1.0 / 24   // 锁死，等于 1/fps
    var fadeOut: Double = 0.25
    var whiteHold: Double = 0.0
    var fadeIn: Double = 0.25
    var freeze: Double = 1.0
    var endingEnabled: Bool = true

    /// 正片尾部可视长度：保证渐白这一段看得见
    var context: Double { max(1.0, fadeOut * 2) }

    /// 尾部窗口总时长
    var windowDuration: Double { context + whiteHold + fadeIn + freeze }

    /// 成片总时长（结尾关闭时 = 封面 + 正片）
    var total: Double {
        guard endingEnabled else { return coverFrame + sourceDuration }
        return coverFrame + sourceDuration + whiteHold + fadeIn + freeze
    }

    /// frozenWindow 非空时用它做像素换算（拖拽期间冻结，见第 7.2 节）
    func toJobSettings() -> JobSettings
    func clamp(_ value: Double, for id: SegmentID) -> Double
    func layout(width: CGFloat, frozenWindow: Double? = nil) -> [LaidOutSegment]
}

/// 布局结果：一段在时间线上的像素区间
struct LaidOutSegment {
    let id: SegmentID
    let title: String
    let x: CGFloat
    let width: CGFloat
    let editable: Bool
    /// 渐白为 true：画成叠在正片尾部之上的半透明层，而非排在后面
    let isOverlay: Bool
}
```

---

## 6. 时间线布局

### 6.1 两行结构

**行 1 · 总览（只读）**
```
[封面 1帧][正片 40:12 ████████████████████][结尾 1.50s]
```
封面固定 10px 窄条；正片占剩余绝大部分；结尾窄条用虚线框引出到行 2。

**行 2 · 尾部放大窗口（可拖）**
窗口总时长 `windowDuration` 铺满整个可用宽度（约 600px @960 窗口）。

排列（左→右）：
1. 正片尾部（灰，只读）宽 = `context`
2. **渐白**：半透明蓝 + 虚线描边，**叠在正片尾部条的右端**（`isOverlay = true`），
   宽 = `fadeOut`，右缘与正片结束点对齐
3. 全白保持（琥珀）宽 = `whiteHold`，为 0 时画成一条虚线缝 + 标注「全白 0s」
4. 渐显（紫）宽 = `fadeIn`
5. 定格（绿）宽 = `freeze`

### 6.2 像素换算

```swift
let usable = width - 2 * padding          // padding = 12
let secPerPx = windowDuration / usable
let px = duration / secPerPx              // 段宽
```

### 6.3 配色（沿用 Theme）

| 段 | 颜色 |
|---|---|
| 封面 | `Color.gray`（#888780） |
| 正片 | 浅灰（#D3D1C7 系） |
| 渐白 | 蓝 `Theme.accent`（#5B6CFF）半透明 |
| 全白 | 琥珀 `Theme.warn`（#FF9F0A） |
| 渐显 | 紫 `Theme.accentDeep`（#8B5CF6） |
| 定格 | 绿 `Theme.ok`（#34C759） |

---

## 7. 拖拽交互

### 7.1 可拖边界与钳制

| 手柄 | 参数 | 允许范围 | 说明 |
|---|---|---|---|
| 渐白左缘 | `fadeOut` | `0.05 … sourceDuration − 0.1`；`sourceDuration` 未知时上限取 10 | 对应 ffmpeg 的 `dur > fadeOut + 0.1` 校验 |
| 全白右缘 | `whiteHold` | `0 … 10` | |
| 渐显右缘 | `fadeIn` | `0.05 … 10` | |
| 定格右缘 | `freeze` | `0.1 … 30` | |

封面段与正片尾部不可拖。四个手柄画成 5px 宽的深色圆角条，高度略超出时间线条以提示可抓。

### 7.2 手感关键：按下瞬间冻结窗口总时长

拖拽时改变任意一段都会改变 `windowDuration`，若每次 `onChanged` 都重算，
像素比例随之变化，被拖的边界会往回缩 —— 表现为「拖不动」。

做法：
- `DragGesture.onChanged` 首次触发时把当前 `windowDuration` 存进 `@State frozenWindow`
- 换算全程用 `frozenWindow`，直到 `onEnded`
- `context` 是 `windowDuration` 的一部分，因此一并被冻结，拖 `fadeOut` 时正片尾部条不会抖动
- `onEnded` 清除冻结、重算布局

### 7.3 步进与显示

- 拖拽过程：数字框实时显示 2 位小数
- 松手：值 round 到 **0.05 秒** 的整数倍，避免 0.2473 这类脏值
- 拖到钳制上限就停住，不弹错误框；手柄染红 + 行下提示
  「渐白最长 X 秒（正片 Y 秒）」

### 7.4 其他状态

- **没选视频**：两行都显示灰骨架 + 「拖入视频后显示时间线」
- **结尾开关关闭**：行 2 整行隐藏；主按钮文案变回「把封面插入视频开头」
- **批量**：只 ffprobe 第一个视频的时长，行 1 标注「以第一个视频为准」

---

## 8. 与 ffmpeg 的对接

时间线只产出 `JobSettings`，**不改动任何 ffmpeg 命令**。两条出片路径由
`endingEnabled` 决定：

| 结尾开关 | 引擎 | 输出位置 | 文件名 |
|---|---|---|---|
| 开 + 有封面 | `EndingEngine.runCombined` | 视频同目录或自定义目录 | 原名 + suffix（默认「定格白场」） |
| 开 + 无封面 | `EndingEngine.run` | 同上 | 同上 |
| 关 | `insertCoverToVideo` | 视频旁的「加封面」文件夹 | 原名不变 |

其余设置（音效、音频淡出、编码速度、输出体积、后缀、覆盖）沿用现有控件与
`AppStorage` key，只是从 `EndingView` 搬到 `ComposeView`。

---

## 9. 迁移与兼容

- **时间参数 key 全部复用**：`fxt_endFadeOut`、`fxt_endWhiteHold`、`fxt_endFadeIn`、
  `fxt_endFreeze`、`fxt_endSfxOffset`、`fxt_endSfx`、`fxt_endSuffix`、`fxt_endRename`、
  `fxt_endOverwrite`、`fxt_endOutDir`、`fxt_endAFade`、`fxt_endAFadeDur`、`fxt_endSpeed`、
  `fxt_sizeMode` —— 语义未变，用户升级后无需重设
- **文件列表用新 key**：`fxt_compVideos` / `fxt_compCovers`；首次启动做一次性迁移，
  若新 key 为空且 `fxt_endVideos` / `fxt_insVideos` 有值，搬过来
- **新增 key**：`fxt_compEndingOn`（结尾开关，默认 true）
- **`fxt_section` 错位修正**：`ContentView.onAppear` 里做一次映射
  旧 0→0、旧 1→1、旧 2→1、旧 3→2、旧 4→3。否则升级后侧边栏会指向空白页
- **旧 key 保留不删**：`fxt_insVideos` / `fxt_insCovers` / `fxt_insOutDir` /
  `fxt_endLocked` 不再读写，但保留定义以便回退旧版本时设置还在
- **CLI 不受影响**：`main.swift` 的 `--cover` / `--ending` 参数与 `Logic.swift` 引擎不变

---

## 10. 错误处理

| 情况 | 处理 |
|---|---|
| 渐白拖过 `sourceDuration − 0.1` | 停在上限，手柄染红 + 行下提示上限值，不弹框 |
| 没选封面但开着结尾 | 正常运行（只做结尾）；行 1 封面位显示虚线「未选封面」 |
| ffprobe 读不出时长 | 行 1 显示「时长未知」；`sourceDuration = 0`，`fadeOut` 上限退化为固定 10 秒，仍可编辑不阻断 |
| 拖拽中视频列表被清空 | 时间线回到骨架态，冻结值丢弃 |
| 编码失败 | 沿用现有日志面板与失败汇总，行为不变 |

---

## 11. 测试

沿用现有 CLI harness（`main.swift Logic.swift` 编译成命令行程序），不开 App：

1. **`layout()` 正确性**：给定一组参数，断言各段像素宽之和 = 可用宽度；
   `whiteHold = 0` 时段宽为 0
2. **钳制**：对每段传入 −100、0、1000 等值，断言结果落在第 7.1 节范围内
3. **往返一致性**：`toJobSettings()` → `EndingEngine.timeline()` 得到的 `total`，
   与 `TimelineModel.total` 一致
4. **端到端**：一条真实视频跑 `runCombined`，用 ffprobe 比对输出时长 = 预期总时长

UI 侧（需人工确认）：拖动手柄后数字框同步；改数字框后时间线重绘；
结尾开关关闭时行 2 消失且按钮文案变化。

---

## 12. 不做的事（Out of scope）

- 封面时长可调（已确认锁死 1 帧）
- 在时间线上调整正片内容（裁剪、分段、转场）
- 时间线上拖动音效偏移 `sfxOffset`（仍是数字输入，因为它语义是相对偏移可为负）
- 多视频各自独立的时间线（批量共用一套参数，只展示第一个视频的时长）
- 把 `TimelineBar` 抽象成可复用组件（当前只有一个使用者）
- 保留旧的「插入封面」「结尾处理」板块（已确认替换）

---

## 13. 版本

新功能 → 按项目约定进 `y` 且 `z` 归 0：**v3.17.0 → v3.18.0**

发版前需同步：
- `Info.plist` 的 `CFBundleShortVersionString`（改后必须重新 `codesign --force -s -`）
- README 版本徽章 + 板块说明
- 分享包 `使用说明.txt` 的板块清单
- `调试记录.md` 追加一条
