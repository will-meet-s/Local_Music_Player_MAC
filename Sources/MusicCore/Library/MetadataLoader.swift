import Foundation
import AVFoundation

/// 用 AVFoundation 读取音频文件的元数据。
///
/// 任何一步失败都只是让对应字段留空，不会抛错 —— 扫描过程不应因单个坏文件中断。
public enum MetadataLoader {

    /// 读取 `url` 的元数据，返回填充后的 `Track`。
    public static func load(url: URL) async -> Track {
        var track = Track(url: url)
        let asset = AVURLAsset(url: url)

        if let duration = try? await asset.load(.duration) {
            let seconds = duration.seconds
            if seconds.isFinite && seconds > 0 {
                track.duration = seconds
            }
        }

        if let common = try? await asset.load(.commonMetadata) {
            await applyCommonMetadata(common, to: &track)
        }

        let allItems = await gatherAllMetadata(from: asset)
        track.embeddedLyrics = await extractLyrics(from: allItems)
        track.replayGain = await extractReplayGain(from: allItems)
        track.sampleRate = await readSampleRate(from: asset)

        // FLAC 用 Vorbis Comment 存标签，AVFoundation 不解析它，只能自己读。
        applyFlacFallback(to: &track)

        track.metadataLoaded = true
        return track
    }

    /// 读取音频轨的采样率（Hz）。
    private static func readSampleRate(from asset: AVAsset) async -> Double? {
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let descriptions = try? await track.load(.formatDescriptions),
              let description = descriptions.first else {
            return nil
        }

        guard let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
            return nil
        }

        let rate = basic.pointee.mSampleRate
        return rate > 0 ? rate : nil
    }

    /// ReplayGain 在 mp3 里存于 ID3 的 TXXX 自定义帧，描述字段才是键名。
    private static func extractReplayGain(from items: [AVMetadataItem]) async -> ReplayGain? {
        var gain = ReplayGain()

        for item in items {
            let description = await replayGainKeyDescription(of: item)
            guard !description.isEmpty else { continue }

            let isGain = ReplayGain.isTrackGainKey(description)
            let isPeak = ReplayGain.isTrackPeakKey(description)
            guard isGain || isPeak else { continue }

            guard let value = try? await item.load(.stringValue) else { continue }

            if isGain, gain.trackGainDB == nil {
                gain.trackGainDB = ReplayGain.parseGain(value)
            } else if isPeak, gain.trackPeak == nil {
                gain.trackPeak = ReplayGain.parsePeak(value)
            }
        }

        return gain.isEmpty ? nil : gain
    }

    /// 取出条目的「键名」用于匹配 ReplayGain 字段。
    ///
    /// ID3 的 TXXX 是自定义帧，真正的键名在 extraAttributes 的 info 里，
    /// `item.key` 只是 "TXXX" 本身。其他格式直接用 key。
    private static func replayGainKeyDescription(of item: AVMetadataItem) async -> String {
        if let key = item.key as? String,
           ReplayGain.isTrackGainKey(key) || ReplayGain.isTrackPeakKey(key) {
            return key
        }

        guard let attributes = try? await item.load(.extraAttributes),
              let info = attributes[.info] as? String else {
            return ""
        }
        return info
    }

    /// 收集所有可用元数据格式里的条目。
    ///
    /// `asset.metadata` 只返回容器认定的「主要」格式，一个文件同时带 ID3v2 和
    /// iTunes 标签时会漏掉其中一套，所以这里逐个格式取。
    private static func gatherAllMetadata(from asset: AVAsset) async -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []

        if let formats = try? await asset.load(.availableMetadataFormats) {
            for format in formats {
                if let formatItems = try? await asset.loadMetadata(for: format) {
                    items.append(contentsOf: formatItems)
                }
            }
        }

        if items.isEmpty, let fallback = try? await asset.load(.metadata) {
            items = fallback
        }

        return items
    }

    /// FLAC 走自研的 Vorbis Comment 解析，只填 AVFoundation 没能填上的字段。
    private static func applyFlacFallback(to track: inout Track) {
        guard track.url.pathExtension.lowercased() == "flac" else { return }

        let needsSomething = track.artist == nil
            || track.album == nil
            || track.artworkData == nil
            || track.embeddedLyrics == nil
            || track.replayGain == nil
        guard needsSomething, let tags = FlacMetadata.read(url: track.url) else { return }

        // 标题只在 AVFoundation 也没给出时才覆盖 —— 默认值是文件名
        if let title = tags.title, track.title == track.url.deletingPathExtension().lastPathComponent {
            track.title = title
        }
        if track.artist == nil { track.artist = tags.artist }
        if track.album == nil { track.album = tags.album }
        if track.artworkData == nil { track.artworkData = tags.artwork }
        if track.embeddedLyrics == nil { track.embeddedLyrics = tags.lyrics }
        if track.replayGain == nil, !tags.replayGain.isEmpty { track.replayGain = tags.replayGain }
    }

    private static func applyCommonMetadata(_ items: [AVMetadataItem], to track: inout Track) async {
        for item in items {
            guard let key = item.commonKey else { continue }
            switch key {
            case .commonKeyTitle:
                if let s = try? await item.load(.stringValue), !s.isEmpty {
                    track.title = s
                }
            case .commonKeyArtist, .commonKeyAuthor:
                if track.artist == nil, let s = try? await item.load(.stringValue), !s.isEmpty {
                    track.artist = s
                }
            case .commonKeyAlbumName:
                if let s = try? await item.load(.stringValue), !s.isEmpty {
                    track.album = s
                }
            case .commonKeyArtwork:
                if track.artworkData == nil, let d = try? await item.load(.dataValue) {
                    track.artworkData = d
                }
            default:
                break
            }
        }
    }

    /// ID3 的 USLT 帧与 iTunes 的 lyrics 原子是内嵌歌词最常见的两种载体。
    private static func extractLyrics(from items: [AVMetadataItem]) async -> String? {
        let identifiers: [AVMetadataIdentifier] = [
            .id3MetadataUnsynchronizedLyric,
            .iTunesMetadataLyrics
        ]
        for identifier in identifiers {
            let matches = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier)
            if let text = await firstNonEmptyString(in: matches) { return text }
        }

        // 有些打标签软件把歌词塞进自定义键（ID3 TXXX、iTunes ----），
        // 这类条目没有标准 identifier，只能按键名兜底匹配。
        let byKey = items.filter { item in
            // iTunes 的四字符键是 NSNumber，转不成 String，所以 identifier 也一并看
            let key = (item.key as? String) ?? ""
            let identifier = item.identifier?.rawValue ?? ""
            return (key + identifier).uppercased().contains("LYRIC")
        }
        return await firstNonEmptyString(in: byKey)
    }

    private static func firstNonEmptyString(in items: [AVMetadataItem]) async -> String? {
        for item in items {
            if let s = try? await item.load(.stringValue),
               !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return s
            }
        }
        return nil
    }
}
