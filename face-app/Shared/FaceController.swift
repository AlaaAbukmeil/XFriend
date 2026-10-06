import Foundation
import SwiftUI

/// Wires the link, the audio engine and the model together.
@MainActor
final class FaceController {
    let model = FaceModel()
    private let link: FaceLink
    private let audio = AudioIO()
    private var statsTimer: Timer?

    init(port: UInt16 = 7777) {
        link = FaceLink(port: port)
    }

    func start() {
        let screen = BuildInfo.screen
        link.helloPayload = { BuildInfo.hello(screen: screen) }
        link.onConnectionChange = { [weak self] connected in
            guard let self else { return }
            self.model.connected = connected
            if !connected {
                self.audio.stopPlayback()
                self.model.state = .idle
            }
        }
        link.onFrame = { [weak self] frame in self?.handle(frame) }
        audio.onMicChunk = { [link] chunk in link.send(.micAudio, chunk) }
        link.start()

        Task {
            model.audioStatus = await audio.start()
        }
        // Copy audio counters into the model at 2 Hz rather than 50 Hz.
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.micChunksSent = self.audio.micChunksSent
                self.model.ttsBytesReceived = self.audio.ttsBytesReceived
            }
        }
    }

    func toggleMute() {
        model.muted.toggle()
        audio.muted = model.muted
        Log.app.notice(model.muted ? "muted" : "unmuted")
        link.sendJSON(.touch, ["kind": "mute_toggle", "muted": model.muted])
    }

    private func handle(_ frame: Frame) {
        guard let type = frame.type else { return }  // unknown types are ignored by design
        switch type {
        case .ttsAudio:
            audio.play(pcm16: frame.payload)
            return  // too frequent for lastMessage
        case .mood:
            if let raw = frame.json()["mood"] as? String, let mood = Mood(rawValue: raw) {
                model.mood = mood
            }
        case .state:
            if let raw = frame.json()["state"] as? String, let state = BrainState(rawValue: raw) {
                model.state = state
            }
        case .stop:
            audio.stopPlayback()
        case .requestFrame:
            break  // camera arrives in Phase 2
        case .hello, .micAudio, .touch, .cameraFrame:
            break  // face -> brain only
        }
        let text = String(data: frame.payload.prefix(60), encoding: .utf8) ?? ""
        model.lastMessage = "\(type) \(text)"
        Log.link.info("recv \(type) \(text)")
    }
}
