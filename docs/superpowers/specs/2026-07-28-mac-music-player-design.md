# macOS 本地音乐播放器 — 设计文档

日期：2026-07-28
目标平台：macOS 14+（Apple Silicon / M4）

## 1. 目标

一个纯本地、零网络依赖的音乐播放器，覆盖以下基础能力：

- 选择并递归扫描本地文件夹，建立曲目列表
- 播放 / 暂停 / 停止
- 上一首 / 下一首
- 四种播放顺序：顺序播放、列表循环、单曲循环、随机
- 歌词显示（逐行高亮 + 自动滚动）
- 进度条拖动、音量调节

## 2. 明确不做（YAGNI）

播放列表管理与收藏、均衡器、频谱可视化、媒体键与 Now Playing 集成、ID3 标签编辑、在线歌词下载、多窗口、迷你播放器。

## 3. 技术选型

| 项 | 选择 | 理由 |
|---|---|---|
| UI | SwiftUI | 原生，M4 上能耗与流畅度最佳 |
| 音频 | AVFoundation (`AVPlayer`) | 系统解码器，支持 mp3/m4a/aac/flac/wav/aiff |
| 元数据 | `AVURLAsset` 异步 metadata API | 无需第三方标签库 |
| 构建 | Swift Package Manager | 纯文本工程，可 `open Package.swift` 用 Xcode 打开；`make app` 打包 .app |
| 依赖 | 无第三方依赖 | — |
| 沙盒 | 关闭 | 避免 security-scoped bookmark 复杂度；个人本地工具 |

工程拆成两个 target：

- `MusicCore`（library）— 所有模型、逻辑与视图，可被测试 target 依赖
- `MacMusicPlayer`（executable）— 仅 `@main` App 入口与 `NSApplicationDelegate`

## 4. 模块划分

| 模块 | 职责 | 依赖 | 可单测 |
|---|---|---|---|
| `Track` | 曲目模型（url/标题/艺术家/专辑/时长/封面/内嵌歌词） | Foundation | — |
| `LyricLine` | 单行歌词（时间戳 + 文本） | Foundation | — |
| `PlayMode` | 四种播放顺序枚举 | Foundation | — |
| `LibraryScanner` | 递归扫描目录，按扩展名过滤，路径自然序排序 | FileManager | ✅ |
| `MetadataLoader` | 异步读取单个文件的元数据，失败降级为文件名 | AVFoundation | 需 AV |
| `LRCParser` | 解析 `.lrc`：`[mm:ss.xx]`、一行多时间戳、忽略元标签、按时间排序 | Foundation | ✅ |
| `LyricsProvider` | 同名 `.lrc`（UTF-8 → GB18030 兜底）优先，内嵌歌词次之 | LRCParser | ✅ |
| `PlaybackQueue` | 依据 `PlayMode` 计算 next / previous，随机模式用预生成顺序表 | Foundation | ✅ |
| `PlayerEngine` | `AVPlayer` 封装：load/play/pause/stop/seek/volume，0.1s 进度回调，播完与错误回调 | AVFoundation | 需 AV |
| `Preferences` | `UserDefaults` 持久化：上次文件夹、播放模式、音量 | Foundation | — |
| `PlayerViewModel` | `@MainActor ObservableObject`，UI 唯一数据源，串联上述所有模块 | 全部 | — |
| Views | `ContentView` / `TrackListView` / `LyricsView` / `ControlsBar` / `NowPlayingView` | SwiftUI | — |

## 5. 界面布局

```
┌───────────────────────────────────────────────┐
│ [选择文件夹]  /Users/x/Music        123 首     │  header
├──────────────┬────────────────────────────────┤
│ 曲目列表      │  封面                          │
│ 双击播放      │  标题 / 艺术家 / 专辑           │
│ 当前项高亮    │  歌词（当前行高亮，自动滚动）    │
├──────────────┴────────────────────────────────┤
│ ⏮ ▶/⏸ ⏹ ⏭   0:12 ━━●━━━━ 4:05   🔀   🔊━━━ │  controls
└───────────────────────────────────────────────┘
```

## 6. 关键行为

**扫描**：选择文件夹后立即用文件名生成曲目列表并展示（不阻塞），随后后台按序异步补全元数据，逐条就地更新。

**播放顺序**：`PlaybackQueue` 内部维护索引顺序表 `order` 与位置 `pos`。
- 顺序播放：`order` 为自然序；播到末尾自动停止（`next(auto:)` 返回 nil）
- 列表循环：末尾回到开头
- 单曲循环：自动切歌时返回当前索引；手动点下一首仍前进
- 随机：切入随机模式时生成 `shuffled()` 顺序表并把当前曲目置于表首，保证「上一首」可正确回退、一轮内不重复

**歌词同步**：进度回调（0.1s）中二分查找当前行索引，仅当索引变化时才更新 `@Published`，避免每帧重绘。`ScrollViewReader` 平滑滚动。无歌词显示占位。

**歌词来源优先级**：同目录同名 `.lrc` → 音频文件内嵌歌词（ID3 USLT / iTunes lyrics）→ 无。`.lrc` 读取先试 UTF-8，失败退 GB18030。

## 7. 错误处理

| 场景 | 行为 |
|---|---|
| 文件夹内无音频 | 列表区显示空状态提示 |
| 单曲元数据读取失败 | 降级用文件名作标题，继续扫描其余文件 |
| 播放失败（编码不支持 / 文件已删） | 顶部红色 banner 提示，自动跳下一首 |
| 上次记录的文件夹已不存在 | 静默忽略，不自动扫描 |
| `.lrc` 编码非 UTF-8 | 退 GB18030；仍失败则视为无歌词 |

## 8. 持久化

`UserDefaults` 键：`lastFolderPath`、`playMode`、`volume`。启动时若上次文件夹仍存在则自动重扫。

## 9. 测试

`Tests/MusicCoreTests/` 覆盖三个纯逻辑模块：

- `LRCParserTests` — 时间戳格式、一行多时间戳、元标签过滤、乱序排序、空输入
- `PlaybackQueueTests` — 四种模式的 next/previous 边界与环绕、随机不重复、列表变更后的重建
- `LibraryScannerTests` — 扩展名过滤、递归子目录、隐藏文件跳过、排序稳定

不对 `PlayerEngine` / `MetadataLoader` 写单测（需真实音频设备与样本文件），由手动验收覆盖。

## 10. 构建与运行

```bash
swift build -c release   # 编译
swift test               # 跑单测
make app                 # 生成 MacMusicPlayer.app
make run                 # 构建并启动
```

`make app` 用 `Makefile` 内联生成 `Info.plist` 并组装 bundle，无需 Xcode 工程文件。
