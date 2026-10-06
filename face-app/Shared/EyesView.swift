import SwiftUI

/// Shape parameters for one eye. All lengths are fractions of the base eye size.
struct EyeParams: Equatable {
    var width: CGFloat = 1
    var height: CGFloat = 1
    var corner: CGFloat = 0.32     // fraction of the shorter side
    var topLid: CGFloat = 0        // 0 = open, 1 = fully covered from the top
    var topTilt: Double = 0        // degrees; + lowers the inner corner (angry), - the outer (sad)
    var bottomLid: CGFloat = 0     // curved lid from below: happy "^ ^" eyes
    var lift: CGFloat = 0          // vertical shift, fraction of eye height (+ = down)
}

struct EyePair: Equatable {
    var left = EyeParams()
    var right = EyeParams()
    var color = Color(red: 0.36, green: 0.88, blue: 0.95)

    static func symmetric(_ p: EyeParams, color: Color? = nil) -> EyePair {
        var pair = EyePair(left: p, right: p)
        if let color { pair.color = color }
        return pair
    }

    static func forMood(_ mood: Mood) -> EyePair {
        switch mood {
        case .neutral:
            return .symmetric(EyeParams())
        case .happy:
            return .symmetric(EyeParams(height: 0.95, corner: 0.45, bottomLid: 0.45))
        case .sarcastic:
            return EyePair(left: EyeParams(height: 0.9, topLid: 0.42, topTilt: -4),
                           right: EyeParams(height: 0.75, topLid: 0.52, topTilt: 2, lift: 0.04))
        case .sleepy:
            return .symmetric(EyeParams(height: 0.9, topLid: 0.62, topTilt: -8, lift: 0.08),
                              color: Color(red: 0.30, green: 0.70, blue: 0.85))
        case .surprised:
            return .symmetric(EyeParams(width: 0.95, height: 1.25, corner: 0.5))
        case .thinking:
            return EyePair(left: EyeParams(height: 0.95, topLid: 0.18),
                           right: EyeParams(height: 0.8, topLid: 0.3, topTilt: -6))
        case .excited:
            return .symmetric(EyeParams(width: 1.05, height: 1.1, corner: 0.45, bottomLid: 0.32),
                              color: Color(red: 0.45, green: 0.98, blue: 0.80))
        case .sad:
            return .symmetric(EyeParams(height: 0.9, topLid: 0.3, topTilt: -18, lift: 0.1),
                              color: Color(red: 0.40, green: 0.60, blue: 0.95))
        case .angry:
            return .symmetric(EyeParams(height: 0.95, topLid: 0.36, topTilt: 20),
                              color: Color(red: 1.0, green: 0.38, blue: 0.30))
        }
    }
}

struct EyeView: View {
    let params: EyeParams
    let isLeft: Bool
    let base: CGSize
    let color: Color
    let background: Color

    var body: some View {
        let w = base.width * params.width
        let h = base.height * params.height
        let tilt = isLeft ? params.topTilt : -params.topTilt
        ZStack {
            RoundedRectangle(cornerRadius: min(w, h) * params.corner, style: .continuous)
                .fill(color)
            Rectangle()
                .fill(background)
                .frame(width: w * 1.8, height: h)
                .rotationEffect(.degrees(tilt))
                .offset(y: -h + h * params.topLid)
            Ellipse()
                .fill(background)
                .frame(width: w * 1.6, height: h)
                .offset(y: h - h * params.bottomLid)
        }
        .frame(width: w, height: h)
        .clipped()
        .shadow(color: color.opacity(0.55), radius: w * 0.12)
        .offset(y: base.height * params.lift)
    }
}

/// The whole face: two eyes plus idle life (blinks, glances) and state cues.
struct EyesView: View {
    let mood: Mood
    let state: BrainState
    let connected: Bool

    @State private var blinking = false
    @State private var glance: CGSize = .zero

    private let background = Color.black

    var body: some View {
        GeometryReader { geo in
            let eyeW = min(geo.size.width * 0.22, geo.size.height * 0.42 / 1.2)
            let base = CGSize(width: eyeW, height: eyeW * 1.2)
            let pair = EyePair.forMood(connected ? mood : .sleepy)
            let closed = !connected || blinking

            TimelineView(.animation(paused: state != .speaking)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let bob = state == .speaking ? sin(t * 9) * base.height * 0.025 : 0

                HStack(spacing: eyeW * 0.55) {
                    EyeView(params: pair.left, isLeft: true, base: base, color: pair.color, background: background)
                    EyeView(params: pair.right, isLeft: false, base: base, color: pair.color, background: background)
                }
                .scaleEffect(x: 1, y: closed ? 0.07 : 1)
                .scaleEffect(state == .listening ? 1.06 : 1)
                .offset(x: lookOffset(base).width, y: lookOffset(base).height + bob)
                .opacity(connected ? 1 : 0.45)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .bottom) {
                StateCue(state: state, connected: connected, color: pair.color)
                    .padding(.bottom, geo.size.height * 0.1)
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: pair)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: state)
            .animation(.easeInOut(duration: 0.25), value: glance)
            .animation(.easeInOut(duration: 0.07), value: blinking)
        }
        .background(background)
        .task { await blinkLoop() }
        .task { await glanceLoop() }
    }

    private func lookOffset(_ base: CGSize) -> CGSize {
        if state == .thinking || mood == .thinking {
            return CGSize(width: base.width * 0.25, height: -base.height * 0.15)
        }
        return CGSize(width: glance.width * base.width, height: glance.height * base.height)
    }

    private func blinkLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 3...6)))
            await blink()
            if Double.random(in: 0...1) < 0.2 {  // occasional double blink
                try? await Task.sleep(for: .milliseconds(120))
                await blink()
            }
        }
    }

    @MainActor private func blink() async {
        blinking = true
        try? await Task.sleep(for: .milliseconds(110))
        blinking = false
    }

    private func glanceLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 2...5)))
            await MainActor.run {
                if state == .idle && Double.random(in: 0...1) < 0.6 {
                    glance = CGSize(width: .random(in: -0.25...0.25), height: .random(in: -0.12...0.12))
                } else {
                    glance = .zero
                }
            }
        }
    }
}

/// Small indicator under the eyes so you always know what the robot is doing.
struct StateCue: View {
    let state: BrainState
    let connected: Bool
    let color: Color

    @State private var pulse = false

    var body: some View {
        Group {
            if !connected {
                Text("z z z")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(color.opacity(0.5))
            } else {
                switch state {
                case .listening:
                    Capsule()
                        .fill(color.opacity(pulse ? 0.9 : 0.35))
                        .frame(width: pulse ? 90 : 60, height: 8)
                        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                case .thinking:
                    TimelineView(.animation) { timeline in
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        HStack(spacing: 14) {
                            ForEach(0..<3) { i in
                                Circle()
                                    .fill(color)
                                    .frame(width: 12, height: 12)
                                    .opacity(0.3 + 0.7 * max(0, sin(t * 5 - Double(i) * 0.9)))
                            }
                        }
                    }
                default:
                    Color.clear.frame(height: 12)
                }
            }
        }
        .onAppear { pulse = true }
    }
}
