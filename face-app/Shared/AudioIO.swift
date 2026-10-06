import AVFoundation
import Foundation
#if os(macOS)
import CoreAudio
#endif

/// One AVAudioEngine for both directions. Voice processing on the input node gives
/// Apple's echo cancellation; because TTS plays through the same engine, the canceller
/// knows exactly what the robot is saying and removes it from the mic signal.
final class AudioIO {
    /// Called on the audio thread with exactly 20 ms (640 bytes) of 16 kHz Int16 mono PCM.
    var onMicChunk: ((Data) -> Void)?
    var muted = false

    private(set) var micChunksSent = 0
    private(set) var ttsBytesReceived = 0

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playFormat = AVAudioFormat(standardFormatWithSampleRate: ProtocolConstants.ttsSampleRate, channels: 1)!
    private let micFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: ProtocolConstants.micSampleRate,
                                          channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private var pending = Data()
    private var configObserver: NSObjectProtocol?
    private var hasMic = false
    private var voiceProcessing = false
    private var micName = ""
    private var micNote = ""

    /// Returns a human-readable status for the debug overlay. Never crashes: with no
    /// microphone (a Mac mini has none built in) the face still plays the robot's voice.
    func start() async -> String {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setPreferredSampleRate(48_000)
            try session.setActive(true)
        } catch {
            Log.audio.error("audio session error: \(error.localizedDescription)")
        }
        #endif

        if let mic = Self.microphoneName() {
            if await Self.requestMicPermission() {
                hasMic = true
                micName = mic
                enableVoiceProcessing()
            } else {
                micNote = "mic permission denied"
                Log.audio.error("microphone permission denied; playback only")
            }
        } else {
            micNote = "no microphone"
            Log.audio.notice("no input device found; playback only")
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)

        let status = startEngine()
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            // Device changed (e.g. headset plugged in): rebuild the tap and restart.
            Log.audio.notice("audio configuration changed, restarting engine")
            _ = self?.startEngine()
        }
        return status
    }

    /// Queue a chunk of 24 kHz Int16 mono TTS audio for playback.
    func play(pcm16 data: Data) {
        let frames = data.count / 2
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(frames))
        else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        let out = buffer.floatChannelData![0]
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<frames {
                out[i] = Float(Int16(littleEndian: samples[i])) / 32768
            }
        }
        ttsBytesReceived += data.count
        player.scheduleBuffer(buffer)
        if !player.isPlaying { player.play() }
    }

    /// Barge-in: drop everything queued, immediately.
    func stopPlayback() {
        player.stop()
        player.play()
    }

    // MARK: - Private

    private func enableVoiceProcessing() {
        var swiftError: Error?
        var objcError: NSError?
        let ok = BuddyCatchObjC({
            do { try self.engine.inputNode.setVoiceProcessingEnabled(true) } catch { swiftError = error }
        }, &objcError)
        if let error = swiftError ?? (ok ? nil : objcError) {
            Log.audio.error("voice processing unavailable, no echo cancellation: \(error.localizedDescription)")
            return
        }
        voiceProcessing = true
        if #available(macOS 14.0, iOS 17.0, *) {
            // Don't let voice processing crush other audio (music etc.) on the device.
            engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                .init(enableAdvancedDucking: false, duckingLevel: .min)
        }
    }

    private func startEngine() -> String {
        engine.stop()
        var micStatus = micNote
        if hasMic {
            let input = engine.inputNode
            input.removeTap(onBus: 0)
            let inFormat = input.outputFormat(forBus: 0)
            if inFormat.sampleRate > 0, inFormat.channelCount > 0 {
                converter = AVAudioConverter(from: inFormat, to: micFormat)
                pending.removeAll()
                input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
                    self?.handleMic(buffer)
                }
                micStatus = "mic \(micName) \(Int(inFormat.sampleRate)) Hz\(voiceProcessing ? ", echo cancel" : ", NO echo cancel")"
            } else {
                micStatus = "mic has no usable format"
            }
        }
        var startError: NSError?
        var swiftError: Error?
        let ok = BuddyCatchObjC({
            self.engine.prepare()
            do { try self.engine.start() } catch { swiftError = error }
        }, &startError)
        if let error = swiftError ?? (ok ? nil : startError) {
            Log.audio.error("engine failed to start: \(error.localizedDescription)")
            return "engine error: \(error.localizedDescription)"
        }
        player.play()
        let status = hasMic ? micStatus : "playback only (\(micStatus))"
        Log.audio.notice("audio running: \(status)")
        return status
    }

    private func handleMic(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = micFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: micFormat, frameCapacity: capacity) else { return }

        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData?[0] else { return }
        pending.append(Data(bytes: samples, count: Int(out.frameLength) * 2))

        while pending.count >= ProtocolConstants.micChunkBytes {
            let chunk = pending.prefix(ProtocolConstants.micChunkBytes)
            pending = pending.dropFirst(ProtocolConstants.micChunkBytes)
            if !muted {
                micChunksSent += 1
                onMicChunk?(Data(chunk))
            }
        }
    }

    /// Name of a usable input device, or nil if there is none.
    private static func microphoneName() -> String? {
        #if os(iOS)
        return AVAudioSession.sharedInstance().isInputAvailable ? "built-in" : nil
        #else
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown
        else { return nil }

        addr.mSelector = kAudioDevicePropertyStreamConfiguration
        addr.mScope = kAudioDevicePropertyScopeInput
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr, size > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, raw) == noErr else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        guard buffers.reduce(0, { $0 + Int($1.mNumberChannels) }) > 0 else { return nil }

        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioObjectPropertyName
        addr.mScope = kAudioObjectPropertyScopeGlobal
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &name) == noErr, let name else { return "input" }
        return name.takeRetainedValue() as String
        #endif
    }

    private static func requestMicPermission() async -> Bool {
        #if os(iOS)
        return await AVAudioApplication.requestRecordPermission()
        #else
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
        #endif
    }
}
