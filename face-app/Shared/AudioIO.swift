import AVFoundation
import Foundation
#if os(macOS)
import CoreAudio
#endif

/// One AVAudioEngine for both directions. Voice processing on the input node gives
/// Apple's echo cancellation; because TTS plays through the same engine, the canceller
/// knows exactly what the robot is saying and removes it from the mic signal.
///
/// Whenever audio devices change (a Bluetooth headset connects, a USB mic is unplugged)
/// the whole engine is rebuilt and the mic is detected again, so the face never needs
/// a restart. With no mic at all (a bare Mac mini) it runs playback-only.
@MainActor
final class AudioIO {
    /// Called on the audio thread with exactly 20 ms (640 bytes) of 16 kHz Int16 mono PCM.
    nonisolated(unsafe) var onMicChunk: ((Data) -> Void)?
    /// Human-readable status for the debug overlay, called on the main thread.
    var onStatus: ((String) -> Void)?
    nonisolated(unsafe) var muted = false

    nonisolated(unsafe) private(set) var micChunksSent = 0
    private(set) var ttsBytesReceived = 0

    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private let playFormat = AVAudioFormat(standardFormatWithSampleRate: ProtocolConstants.ttsSampleRate, channels: 1)!
    private var configObserver: NSObjectProtocol?
    private var rebuildTask: Task<Void, Never>?

    func start() async {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setPreferredSampleRate(48_000)
            try session.setActive(true)
        } catch {
            Log.audio.error("audio session error: \(error.localizedDescription)")
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRebuild(reason: "audio route changed") }
        }
        #else
        watchDefaultDevices()
        #endif
        await rebuild()
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
        guard engine.isRunning else { return }
        player.scheduleBuffer(buffer)
        if !player.isPlaying { player.play() }
    }

    /// Barge-in: drop everything queued, immediately.
    func stopPlayback() {
        player.stop()
        if engine.isRunning { player.play() }
    }

    // MARK: - Engine lifecycle

    /// Device changes arrive in bursts, so wait for things to settle before rebuilding.
    private func scheduleRebuild(reason: String, from first: Mode = .echoCancelledMic) {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            Log.audio.notice("\(reason), rebuilding audio engine")
            await self.rebuild(from: first)
        }
    }

    /// How much of the audio stack to bring up. If a level fails to start (some
    /// Bluetooth headsets reject voice processing), the next one down is tried.
    private enum Mode: CaseIterable {
        case echoCancelledMic, plainMic, playbackOnly
    }

    /// Mode that last started successfully; config changes resume from here instead of
    /// re-trying modes this device already rejected.
    private var workingMode: Mode?
    private var tappedMic: String?
    private var tappedRate: Double = 0

    private func rebuild(from first: Mode = .echoCancelledMic) async {
        for mode in Mode.allCases.drop(while: { $0 != first }) {
            if await build(mode) {
                workingMode = mode
                return
            }
        }
        workingMode = nil
        onStatus?("audio failed to start (see face.log)")
    }

    /// Engine configuration changed (e.g. a Bluetooth headset switching to its call
    /// profile when the mic opens). If it's the same mic at the same rate, just restart;
    /// otherwise rebuild, keeping the mode that already works.
    private func handleConfigChange() {
        let sameMic = Self.microphoneName() == tappedMic
        let sameRate = tappedMic == nil || engine.inputNode.outputFormat(forBus: 0).sampleRate == tappedRate
        if sameMic && sameRate {
            var error: NSError?
            var swiftError: Error?
            let engine = self.engine
            let ok = XFCatchObjC({ do { try engine.start() } catch { swiftError = error } }, &error)
            if ok && swiftError == nil {
                player.play()
                Log.audio.info("audio configuration changed, engine restarted")
                return
            }
        }
        scheduleRebuild(reason: "audio configuration changed", from: workingMode ?? .echoCancelledMic)
    }

    /// Returns true if the engine started.
    private func build(_ mode: Mode) async -> Bool {
        teardown()
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()

        var micStatus = ""
        var useMic = false
        if mode != .playbackOnly {
            guard let mic = Self.microphoneName() else {
                return await build(.playbackOnly, note: "no microphone")
            }
            guard await Self.requestMicPermission() else {
                return await build(.playbackOnly, note: "mic permission denied")
            }
            useMic = true
            micStatus = "mic \(mic)"
            if mode == .echoCancelledMic {
                guard enableVoiceProcessing() else { return false }
                micStatus += ", echo cancel"
            } else {
                micStatus += ", NO echo cancel (use headphones)"
            }
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)

        if useMic {
            let input = engine.inputNode
            let inFormat = input.outputFormat(forBus: 0)
            guard inFormat.sampleRate > 0, inFormat.channelCount > 0, let chunker = MicChunker(from: inFormat) else {
                Log.audio.error("\(mode): mic has no usable format")
                return false
            }
            chunker.onChunk = { [weak self] chunk in
                guard let self, !self.muted else { return }
                self.micChunksSent += 1
                self.onMicChunk?(chunk)
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { buffer, _ in
                chunker.handle(buffer)
            }
            micStatus += ", \(Int(inFormat.sampleRate)) Hz"
            tappedRate = inFormat.sampleRate
        }
        tappedMic = useMic ? Self.microphoneName() : nil

        var startError: NSError?
        var swiftError: Error?
        let engine = self.engine
        let ok = XFCatchObjC({
            engine.prepare()
            do { try engine.start() } catch { swiftError = error }
        }, &startError)
        if let error = swiftError ?? (ok ? nil : startError) {
            Log.audio.error("\(mode) failed to start: \(error.localizedDescription)")
            return false
        }
        player.play()
        let status = useMic ? micStatus : "playback only (\(pendingNote ?? "mic unavailable"))"
        pendingNote = nil
        Log.audio.notice("audio running: \(status)")
        onStatus?(status)

        // Only a running engine gets to trigger rebuilds; a failed start also posts
        // configuration changes, which would otherwise loop forever.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleConfigChange() }
        }
        return true
    }

    private var pendingNote: String?

    private func build(_ mode: Mode, note: String) async -> Bool {
        pendingNote = note
        return await build(mode)
    }

    private func teardown() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
    }

    /// Returns true if echo cancellation is on.
    private func enableVoiceProcessing() -> Bool {
        var swiftError: Error?
        var objcError: NSError?
        let input = engine.inputNode
        let ok = XFCatchObjC({
            do { try input.setVoiceProcessingEnabled(true) } catch { swiftError = error }
        }, &objcError)
        if let error = swiftError ?? (ok ? nil : objcError) {
            Log.audio.error("voice processing unavailable, no echo cancellation: \(error.localizedDescription)")
            return false
        }
        if #available(macOS 14.0, iOS 17.0, *) {
            // Don't let voice processing crush other audio (music etc.) on the device.
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        }
        return true
    }

    #if os(macOS)
    /// AVAudioEngine doesn't always notice a new default device (e.g. a Bluetooth headset
    /// connecting while the app runs), so listen to CoreAudio directly too.
    private func watchDefaultDevices() {
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice] {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.scheduleRebuild(reason: "default audio device changed") }
            }
        }
    }
    #endif

    /// Name of a usable input device, or nil if there is none.
    nonisolated private static func microphoneName() -> String? {
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

    nonisolated private static func requestMicPermission() async -> Bool {
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

/// Converts the mic's native format to 16 kHz Int16 mono and slices it into 20 ms
/// chunks. Lives on the audio thread; one instance per engine build.
private final class MicChunker {
    var onChunk: ((Data) -> Void)?
    private let converter: AVAudioConverter
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: ProtocolConstants.micSampleRate,
                                          channels: 1, interleaved: true)!
    private var pending = Data()

    init?(from inFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else { return nil }
        self.converter = converter
    }

    func handle(_ buffer: AVAudioPCMBuffer) {
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }

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
            let chunk = Data(pending.prefix(ProtocolConstants.micChunkBytes))
            pending = Data(pending.dropFirst(ProtocolConstants.micChunkBytes))
            onChunk?(chunk)
        }
    }
}
