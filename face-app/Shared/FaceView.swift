import SwiftUI

struct FaceView: View {
    let controller: FaceController
    private var model: FaceModel { controller.model }

    var body: some View {
        EyesView(mood: model.mood, state: model.state, connected: model.connected)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { controller.toggleMute() }
            .overlay(alignment: .bottomTrailing) {
                if model.muted {
                    Image(systemName: "mic.slash.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.red.opacity(0.85))
                        .padding(24)
                }
            }
            .overlay(alignment: .topLeading) {
                if model.showDebug { DebugOverlay(model: model).padding(12) }
            }
            .focusable()
            .focusEffectDisabled()
            .onKeyPress("d") {
                model.showDebug.toggle()
                return .handled
            }
            .onKeyPress("m") {
                controller.toggleMute()
                return .handled
            }
    }
}

struct DebugOverlay: View {
    let model: FaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("brain: \(model.connected ? "connected" : "waiting on :7777")")
            Text("state: \(model.state.rawValue)   mood: \(model.mood.rawValue)")
            Text("audio: \(model.audioStatus)")
            Text("mic chunks sent: \(model.micChunksSent)\(model.muted ? " (muted)" : "")")
            Text("tts bytes received: \(model.ttsBytesReceived)")
            Text("last: \(model.lastMessage)").lineLimit(1)
        }
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(.green)
        .padding(10)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 520, alignment: .leading)
    }
}
