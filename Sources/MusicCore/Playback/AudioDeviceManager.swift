import Foundation
import CoreAudio

/// 把系统默认输出设备的采样率切换到与当前曲目一致，避免系统做重采样。
///
/// 两点必须清楚：
/// - 这改的是**系统级**设置，会影响所有正在出声的 App，切换瞬间可能有轻微爆音或停顿。
/// - 只有接了像样的 DAC / 耳放才可能听得出差别；蓝牙耳机和内置扬声器上基本是心理作用。
///
/// 因此默认关闭，由用户显式开启。
public enum AudioDeviceManager {

    /// 当前默认输出设备的采样率（Hz）。取不到时返回 nil。
    public static func currentSampleRate() -> Double? {
        guard let device = defaultOutputDevice() else { return nil }
        return nominalSampleRate(of: device)
    }

    /// 若默认输出设备支持 `sampleRate` 且当前不是该值，则切过去。
    ///
    /// - Returns: 是否真的做了切换。设备已经是目标采样率、或不支持该采样率时返回 false。
    @discardableResult
    public static func matchSampleRate(_ sampleRate: Double) -> Bool {
        guard sampleRate > 0, let device = defaultOutputDevice() else { return false }

        if let current = nominalSampleRate(of: device), isSameRate(current, sampleRate) {
            return false
        }

        // 设备不支持的采样率不能硬设，否则要么报错要么落到一个意外的值
        guard supportedSampleRates(of: device).contains(where: { isSameRate($0, sampleRate) }) else {
            return false
        }

        return setNominalSampleRate(sampleRate, on: device)
    }

    /// 浮点采样率比较：44100 和 44100.000001 应视作同一个。
    private static func isSameRate(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) < 1
    }

    // MARK: - CoreAudio 查询

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )

        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func nominalSampleRate(of device: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var rate = Double(0)
        var size = UInt32(MemoryLayout<Double>.size)

        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        guard status == noErr, rate > 0 else { return nil }
        return rate
    }

    /// 设备支持的采样率。可能是离散值，也可能是连续区间（mMinimum != mMaximum）。
    private static func supportedSampleRates(of device: AudioDeviceID) -> [Double] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioValueRange>.size
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: count)

        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &ranges)
        guard status == noErr else { return [] }

        // 连续区间取常见采样率里落在区间内的那些
        var rates: [Double] = []
        for range in ranges {
            if isSameRate(range.mMinimum, range.mMaximum) {
                rates.append(range.mMinimum)
            } else {
                rates.append(contentsOf: commonRates.filter { $0 >= range.mMinimum && $0 <= range.mMaximum })
            }
        }
        return rates
    }

    private static let commonRates: [Double] = [
        44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000
    ]

    private static func setNominalSampleRate(_ rate: Double, on device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else {
            return false
        }

        var value = rate
        let status = AudioObjectSetPropertyData(
            device,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Double>.size),
            &value
        )
        return status == noErr
    }
}
