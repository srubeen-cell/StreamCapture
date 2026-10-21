import AVFoundation
import CoreAudio
import CoreMedia

/// An output device on this Mac (speakers, headphones, AirPods, BlackHole, ...).
struct AudioOutputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
}

enum AudioDevices {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    static func outputDevices() -> [AudioOutputDevice] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard outputChannelCount(id) > 0, let name = name(of: id) else { return nil }
            return AudioOutputDevice(id: id, name: name)
        }
    }

    static func defaultOutputID() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    @discardableResult
    static func setDefaultOutput(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = id
        return AudioObjectSetPropertyData(system, &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &value) == noErr
    }

    static func name(of id: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr,
              let value = name?.takeRetainedValue() else { return nil }
        return value as String
    }

    private static func outputChannelCount(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, list) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Virtual devices that swallow sound instead of playing it out loud.
    static func isSilentRouting(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("blackhole") || lower.contains("soundflower") || lower.contains("loopback")
    }
}

extension CMSampleBuffer {
    /// Copies the audio in this buffer into an AVAudioPCMBuffer.
    func toPCMBuffer() -> AVAudioPCMBuffer? {
        guard let desc = formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { return nil }
        var streamDesc = asbd.pointee
        guard let format = AVAudioFormat(streamDescription: &streamDesc) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        return status == noErr ? pcm : nil
    }
}

enum AudioLevel {
    /// Loudness of a buffer on a 0...1 scale (-60 dB ... 0 dB).
    static func level(of buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return 0 }
        var sum: Float = 0
        var count = 0

        if let data = buffer.floatChannelData {
            let interleaved = buffer.format.isInterleaved
            for ch in 0..<(interleaved ? 1 : channels) {
                let n = interleaved ? frames * channels : frames
                let samples = data[ch]
                for i in 0..<n { sum += samples[i] * samples[i] }
                count += n
            }
        } else if let data = buffer.int16ChannelData {
            let interleaved = buffer.format.isInterleaved
            for ch in 0..<(interleaved ? 1 : channels) {
                let n = interleaved ? frames * channels : frames
                let samples = data[ch]
                for i in 0..<n {
                    let s = Float(samples[i]) / Float(Int16.max)
                    sum += s * s
                }
                count += n
            }
        }
        guard count > 0 else { return 0 }
        let rms = sqrt(sum / Float(count))
        let db = 20 * log10(max(rms, 0.000_001))
        return min(1, max(0, (db + 60) / 60))
    }
}

/// Plays the captured audio out of a chosen device, like Loopback's monitor.
/// Useful when the Mac's own output is pointed at BlackHole and you'd hear nothing.
final class AudioMonitor {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var connectedFormat: AVAudioFormat?
    private let lock = NSLock()

    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    init(deviceID: AudioDeviceID, volume: Float) throws {
        guard let unit = engine.outputNode.audioUnit else { throw RecorderError.monitorUnavailable }
        var id = deviceID
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw RecorderError.monitorUnavailable }
        engine.attach(player)
        player.volume = volume
    }

    func play(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        if connectedFormat == nil {
            engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
            connectedFormat = buffer.format
            do { try engine.start() } catch { return }
            player.play()
        }
        guard buffer.format == connectedFormat else { return }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        player.stop()
        engine.stop()
    }
}
