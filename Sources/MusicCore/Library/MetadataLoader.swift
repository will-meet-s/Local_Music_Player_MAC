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

        if let all = try? await asset.load(.metadata) {
            track.embeddedLyrics = await extractLyrics(from: all)
        }

        track.metadataLoaded = true
        return track
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
            for item in matches {
                if let s = try? await item.load(.stringValue),
                   !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return s
                }
            }
        }
        return nil
    }
}
