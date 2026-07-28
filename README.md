# MacMusicPlayer

一个给 Apple Silicon Mac（M4）用的本地音乐播放器。SwiftUI + AVFoundation，零第三方依赖，不联网。

## 功能

- 选择文件夹，递归扫描音乐（mp3 / m4a / aac / flac / wav / aiff / alac / caf）
- 播放、暂停、停止、上一首、下一首、拖动进度、音量调节
- 四种播放顺序：顺序播放 → 列表循环 → 单曲循环 → 随机（点左下角按钮循环切换）
- 歌词显示：同名 `.lrc` 优先，其次读音频内嵌歌词；逐行高亮并自动滚动，点某行可跳播
- 记住上次的文件夹、播放模式和音量，下次启动自动恢复

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

## 快捷键

| 操作 | 快捷键 |
|---|---|
| 播放 / 暂停 | `空格` 或 `⌘P` |
| 停止 | `⌘.` |
| 上一首 / 下一首 | `⌘←` / `⌘→` |
| 切换播放顺序 | `⌘L` |
| 选择文件夹 | `⌘O` |

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
    Lyrics/             LRCParser（解析）、LyricsProvider（查找）
    Playback/           PlaybackQueue（顺序逻辑）、PlayerEngine（AVPlayer 封装）
    ViewModel/          PlayerViewModel（UI 唯一数据源）
    Views/              ContentView / TrackListView / NowPlayingView / LyricsView / ControlsBar
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
