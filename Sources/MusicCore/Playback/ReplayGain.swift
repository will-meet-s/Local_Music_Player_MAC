import Foundation

/// ReplayGain 音量归一化信息。
///
/// 不同来源的文件响度能差 10dB 以上，一首听着刚好、下一首震耳朵。ReplayGain 是
/// 事实标准：打标签的软件预先算好该曲相对参考响度的增益，播放器照着补偿即可。
///
/// 只处理**曲目级**（TRACK）而不是专辑级（ALBUM）增益 —— 随机播放是常态，
/// 专辑级增益只在整张连听时才正确。
public struct ReplayGain: Equatable, Sendable {

    /// 相对参考响度的增益，单位 dB。负值表示这首偏响、需要衰减。
    public var trackGainDB: Double?
    /// 峰值采样电平（1.0 = 满刻度）。用来防止补偿后削波。
    public var trackPeak: Double?

    public init(trackGainDB: Double? = nil, trackPeak: Double? = nil) {
        self.trackGainDB = trackGainDB
        self.trackPeak = trackPeak
    }

    public var isEmpty: Bool { trackGainDB == nil && trackPeak == nil }

    // MARK: - 解析

    /// 解析增益字段，例如 `-6.54 dB`、`+2.10dB`、`-3`。
    public static func parseGain(_ raw: String) -> Double? {
        let cleaned = raw
            .replacingOccurrences(of: "dB", with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(cleaned)
    }

    /// 解析峰值字段，例如 `0.988525`。超出合理范围的值视为无效。
    public static func parsePeak(_ raw: String) -> Double? {
        guard let value = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        guard value > 0, value <= 8 else { return nil }
        return value
    }

    /// 字段名是否是 ReplayGain 的曲目增益 / 峰值（大小写与前后缀都宽松匹配）。
    public static func isTrackGainKey(_ key: String) -> Bool {
        key.uppercased().contains("REPLAYGAIN_TRACK_GAIN")
    }

    public static func isTrackPeakKey(_ key: String) -> Bool {
        key.uppercased().contains("REPLAYGAIN_TRACK_PEAK")
    }

    // MARK: - 增益计算

    /// 增益系数的安全上下限。标签写错时不至于把耳朵震坏或彻底静音。
    public static let minFactor: Float = 0.05
    public static let maxFactor: Float = 4.0

    /// 换算成线性增益系数（1 表示不做处理）。
    ///
    /// - Parameter preampDB: 额外的统一前置增益。ReplayGain 参考响度偏保守，
    ///   多数人会加几 dB 补回来。
    ///
    /// 若已知峰值，会保证补偿后不削波：`peak * factor <= 1`。
    public func linearGain(preampDB: Double = 0) -> Float {
        guard let gain = trackGainDB else { return 1 }

        var factor = pow(10.0, (gain + preampDB) / 20.0)

        if let peak = trackPeak, peak > 0, peak * factor > 1 {
            factor = 1 / peak
        }

        return min(Self.maxFactor, max(Self.minFactor, Float(factor)))
    }
}
