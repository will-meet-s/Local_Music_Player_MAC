# MacMusicPlayer

一个给 Apple Silicon Mac（M4）用的本地音乐播放器。SwiftUI + AVFoundation，零第三方依赖，不联网。

## 功能

- 选择文件夹，递归扫描音乐（mp3 / m4a / aac / flac / wav / aiff / alac / caf）
- 手动刷新曲库：同步新增 / 删除的文件，不打断播放
- 播放、暂停、停止、上一首、下一首、拖动进度、音量调节
- 四种播放顺序：顺序播放 → 列表循环 → 单曲循环 → 随机（点左下角按钮循环切换）
- 歌词显示：同名 `.lrc` 优先，其次读音频内嵌歌词；逐行高亮并自动滚动，点某行可跳播
- 记住上次的文件夹、播放模式和音量，下次启动自动恢复
- 顶部状态栏常驻控制板：当前曲目 + 上一首 / 播放暂停 / 下一首 + 播放顺序
- 搜索（歌名 / 歌手 / 专辑）与排序（文件顺序 / 歌曲名 / 歌手名，可升降序）
- **无缝切歌**（gapless）：提前缓冲下一首，曲目之间没有空白
- **音量归一化**（ReplayGain）：自动补偿不同文件的响度差异
- **匹配输出采样率**（可选）：避免系统重采样
- 磨砂半透明窗口背景（`NSVisualEffectView`，能透出桌面），不透明度可调
- 右侧区域三种展示模式：封面 + 歌词 / 只看封面 / 只看歌词

## 展示模式

右侧区域**右上角浮着一个小方块**，里面是当前布局的缩略示意图，点一下循环切换到下一种模式：

| 模式 | 内容 |
|---|---|
| 封面 + 歌词 | 默认。180pt 封面 + 曲目信息 + 歌词 |
| 只看封面 | 封面放大到填满区域（保持正方形），下方一行曲目信息 |
| 只看歌词 | 曲目信息压成单行，歌词占满整区 |

选择会被记住，下次启动沿用。

切换入口做成右上角的浮动小方块、而不是让整块区域响应点击，是为了不和歌词行的
**点击跳播**抢手势 —— 点歌词任意一行可跳播到该行。

## 外观

窗口用 `NSVisualEffectView` 做整窗磨砂 —— 注意这和 SwiftUI 自带的 `.ultraThinMaterial`
不是一回事，后者只在同一窗口内的图层间模糊，透不出桌面。

**背景不透明度**可在界面上调：顶部标题栏右侧的半圆图标 → 滑块，范围 **20% – 100%**，
设置会被记住。调的只是背景磨砂层，文字和控件始终 100% 不透明，所以拉到最低仍能看清内容。

想调材质或关掉，改 `Sources/MusicCore/Views/VisualEffect.swift`：

- 换风格：`frostedBackground()` 的默认参数 `.underWindowBackground`
  换成 `.hudWindow`（更暗）、`.sidebar`（更通透）、`.contentBackground`（几乎不透）
- 完全关掉：把 `ContentView` 上的 `.frostedBackground()` 和 `TrackListView` 上的
  `.background(VisualEffectView(material: .sidebar))` 两行删掉即可

## 刷新曲库

**不会自动监听文件夹变化。** 目录下新增或删除了歌曲后，点标题栏文件夹路径左边的
**↻ 按钮**（状态栏面板里也有「刷新曲库」）重新扫描。

刷新与「选择文件夹」的区别：

| | 选择文件夹 | 刷新 |
|---|---|---|
| 播放 | 停止 | **继续，不打断** |
| 搜索词 / 排序 | 清空 / 保留 | 都保留 |
| 已读的元数据 | 全部重读 | 复用，只读新文件 |

## 音频处理

顶部标题栏右侧的滑块图标 → 设置面板。

### 无缝切歌（始终开启）

播放引擎用 `AVQueuePlayer`，当前曲开始播放后立刻把下一首插入队列缓冲，播完自动推进，
中间没有加载空档。听现场专辑、古典、或任何连续编排的专辑时差别明显。

有一个例外：**随机模式每轮的最后一次切歌不是无缝的**。下一轮的随机顺序要到真正翻页时
才洗出来，预加载阶段无从得知，只能退回普通加载。

### 音量归一化（默认开启）

读文件里的 `REPLAYGAIN_TRACK_GAIN` / `REPLAYGAIN_TRACK_PEAK` 标签，自动补偿响度差异，
解决「一首听着刚好、下一首震耳朵」。

- 只用**曲目级**增益，不用专辑级 —— 随机播放是常态，专辑级只在整张连听时才正确
- 用 `AVAudioMix` 施加增益而非 `player.volume`：后者上限是 1，无法为偏轻的曲目提升音量，
  而且那是用户的音量旋钮，两者必须分开
- 已知峰值时会保证补偿后不削波（`peak × factor ≤ 1`）
- 增益系数钳制在 0.05–4 倍，标签写错不至于炸耳朵
- **没打标签的文件不受任何影响**。FLAC 的标签由自研解析器读取，mp3 走 ID3 的 TXXX 帧

### 匹配输出采样率（默认关闭）

把系统输出设备切到与当前文件相同的采样率，避免 CoreAudio 重采样。

必须清楚两点，所以默认关闭：

- 这是**系统级**设置，会影响所有正在出声的 App，切换瞬间可能有轻微爆音
- 与无缝播放冲突 —— 相邻曲目采样率不同时，设备切换会带来明显停顿
- 只有接了像样的 DAC / 耳放才可能听出差别；蓝牙耳机和内置扬声器上基本是心理作用

## 搜索与排序

列表上方是搜索框和排序控件。搜索匹配**歌名、歌手、专辑**三个字段，忽略大小写与音调符号
（输 `cafe` 能搜到 `Café`）。

排序维度：**文件顺序**（默认，按路径自然序，专辑目录结构最直观）、**歌曲名**、**歌手名**。
右侧箭头切升序 / 降序。没有歌手信息的曲目在按歌手排序时始终垫底，正序倒序都一样。

排序和搜索会同时改变**播放顺序** —— 列表里看到的顺序就是「下一首」走的顺序。搜索状态下
按下一首只在匹配结果里循环。如果正在播的歌被搜索过滤掉了，**歌继续放**，只是列表里没有
高亮项，右侧「正在播放」区照常显示它。

排序维度和升降序会被记住，下次启动沿用。

## 状态栏控制板

菜单栏右侧有个音符图标，点开是一个小面板，不用切回主窗口就能切歌和暂停。

**关掉主窗口后 App 不会退出**，继续在状态栏里放歌 —— 这是「常驻」的前提。要真正退出用
`⌘Q`，或点面板里的「退出」。想把主窗口叫回来，点面板里的「显示主窗口」或 Dock 图标。

## 环境要求

macOS 14+，Xcode 15+（或 Swift 5.9+ 命令行工具）。

## 构建运行

```bash
cd MacMusicPlayer

swift test          # 跑单元测试（需要完整版 Xcode，XCTest 不随 Command Line Tools 提供）
make app            # 生成 build/MacMusicPlayer.app
make run            # 构建并启动
make dmg            # 生成 build/MacMusicPlayer-1.0.0.dmg
```

`swift test` 报 `no such module 'XCTest'` 时，说明 `xcode-select` 指向了 Command Line Tools：

```bash
xcode-select -p                                                      # 确认
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer      # 切到 Xcode
```

## App 图标

图标源图是 `Resources/AppIcon.png`（1024×1024）。`make app` 会自动把它转成 `.icns` 并打进
bundle，无需手动操作。

**换成自己的图标**：用一张 1024×1024 的 PNG 覆盖 `Resources/AppIcon.png`，然后

```bash
rm -f Resources/AppIcon.icns   # 强制重新生成
make app
```

**重新生成默认图标**（紫粉渐变 + 八分音符）：

```bash
python3 scripts/generate-icon.py     # 需要 pip install Pillow
```

改完图标后 Finder / Dock 可能还显示旧图标 —— 那是图标缓存，重启 Dock 即可：

```bash
killall Dock
```

## 分发

`make dmg` 产出的磁盘映像装载后是「App 图标 + Applications 快捷方式」的拖拽安装界面。

映像只做了 ad-hoc 签名，没有开发者证书和公证，因此**在别人的 Mac 上会被 Gatekeeper 拦截**。
对方拖进 `/Applications` 后需要执行一次：

```bash
xattr -dr com.apple.quarantine /Applications/MacMusicPlayer.app
```

想免掉这一步就得加入 Apple Developer Program（$99/年），用 Developer ID 证书签名并公证：

```bash
codesign --force --deep --options runtime --timestamp \
  --sign "Developer ID Application: 你的名字 (TEAMID)" build/MacMusicPlayer.app
xcrun notarytool submit build/MacMusicPlayer-1.0.0.dmg \
  --apple-id you@example.com --team-id TEAMID --password <app-专用密码> --wait
xcrun stapler staple build/MacMusicPlayer-1.0.0.dmg
```

也可以直接 `open Package.swift` 用 Xcode 打开，选 `MacMusicPlayer` scheme 运行。

开发时想快速跑一下：`swift run MacMusicPlayer`（窗口会正常出现，只是没有独立的 .app 图标）。

## 歌词

把 `.lrc` 文件和音频文件放在同一目录、取同样的文件名即可：

```
Music/
  周杰伦 - 晴天.mp3
  周杰伦 - 晴天.lrc
```

支持 `[mm:ss.xx]`、一行多时间戳、`[offset:N]` 校准；`[ti:]` `[ar:]` 等元信息标签会被忽略。
文件编码优先按 UTF-8 读，失败自动退 GB18030（兼容常见中文歌词文件）。

没有 `.lrc` 时会尝试读音频内嵌歌词。内嵌歌词若没有时间戳，只静态展示全文，不做高亮滚动。

各格式的内嵌歌词支持情况：

| 格式 | 标签载体 | 支持 | 说明 |
|---|---|---|---|
| mp3 | ID3 USLT | ✅ | AVFoundation |
| m4a / aac / alac | iTunes `©lyr` | ✅ | AVFoundation |
| **flac** | **Vorbis Comment** | ✅ | AVFoundation 不解析 Vorbis Comment，由 `FlacMetadata` 自行读取 |
| aiff | ID3 chunk | ⚠️ | 取决于系统是否暴露该 chunk |
| wav | — | ❌ | 格式本身没有标准歌词标签，只能用 `.lrc` |

FLAC 的标题 / 艺术家 / 专辑 / 封面同样走 `FlacMetadata` 兜底，所以这些字段也能正常显示。

## 代码结构

```
Sources/
  MacMusicPlayer/       @main 入口 + NSApplicationDelegate
  MusicCore/
    Models/             Track / LyricLine / PlayMode
    Library/            LibraryScanner（扫描）、MetadataLoader（元数据）、FlacMetadata（Vorbis Comment）
                        TrackFilter（搜索 + 排序）
    Lyrics/             LRCParser（解析）、LyricsProvider（查找）
    Playback/           PlaybackQueue（顺序逻辑）、PlayerEngine（AVQueuePlayer 无缝播放）
                        ReplayGain（音量归一化）、AudioDeviceManager（CoreAudio 采样率）
    ViewModel/          PlayerViewModel（UI 唯一数据源）
    Views/              ContentView / TrackListView / NowPlayingView / LyricsView / ControlsBar
                        MenuBarPanel（状态栏控制板）、LayoutThumbnail（布局切换缩略图）
                        VisualEffect（磨砂背景桥接）
    Support/            Preferences（UserDefaults）、TimeFormat
Tests/MusicCoreTests/   LRCParser / PlaybackQueue / LibraryScanner / LyricsProvider 单测
docs/superpowers/specs/ 设计文档
```

播放顺序逻辑（`PlaybackQueue`）和歌词解析（`LRCParser`）都是不碰音频设备的纯逻辑，
因此可以完整单测；`PlayerEngine` 与 `MetadataLoader` 依赖真实音频文件，由手动验收覆盖。

## 已知限制

- 应用未沙盒化、只做 ad-hoc 签名，仅供本机使用；分发给别人需要开发者证书公证
- 不做在线歌词下载、标签编辑、均衡器、媒体键集成
- WAV 没有标准歌词标签，只能靠同名 `.lrc`
