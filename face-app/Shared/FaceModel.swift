import Foundation
import Observation

enum Mood: String, CaseIterable {
    case neutral, happy, sarcastic, sleepy, surprised, thinking, excited, sad, angry
}

enum BrainState: String {
    case idle, listening, thinking, speaking
}

/// Everything the face displays. Nothing here is persisted: the Mac brain is the
/// single source of truth, and the face only mirrors what it's told.
@Observable
final class FaceModel {
    var connected = false
    var mood: Mood = .neutral
    var state: BrainState = .idle
    var muted = false
    var showDebug = false

    // Debug counters
    var micChunksSent = 0
    var ttsBytesReceived = 0
    var lastMessage = "—"
    var audioStatus = "starting"
}
