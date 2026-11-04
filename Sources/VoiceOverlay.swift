import AppKit
import SwiftUI

/// What voice typing shows at the bottom of the screen: a pill with a glowing, flowing gradient
/// edge and a waveform of the voice it hears, and above it a box with the words recognized so far.
@MainActor
final class VoiceOverlay {
    enum Content: Equatable {
        /// The text heard so far; empty until the first words come back.
        case listening(String)
        /// After the key is let go, until the text is typed. The words stay up.
        case transcribing
        case failed(String)
    }

    /// The microphone's loudness right now (RMS), for the waveform and the glow.
    var level: () -> Float = { 0 }

    private let state = VoiceOverlayState()
    private var panel: NSPanel?
    private var timer: Timer?

    /// Room for the text box above the pill and the glow around it; the panel never changes size,
    /// so nothing jumps as words come in.
    private static let size = CGSize(width: 560, height: 300)

    func show(_ content: Content) {
        switch content {
        case .listening(let text):
            if state.phase != .listening { state.levels = Array(repeating: 0, count: VoiceOverlayState.barCount) }
            state.phase = .listening
            state.text = text
        case .transcribing:
            state.phase = .transcribing
        case .failed(let message):
            state.phase = .failed
            state.text = message
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if let screen = NSScreen.main {
            // The pill's bottom edge sits where the old pill's did.
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - Self.size.width / 2, y: screen.visibleFrame.minY + 40))
        }
        panel.orderFrontRegardless()
        startMeter()
    }

    func hide() {
        panel?.orderOut(nil)
        timer?.invalidate()
        timer = nil
        state.phase = .hidden
        state.text = ""
    }

    /// Reads the microphone level 30 times a second while showing.
    private func startMeter() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let heard = state.phase == .listening ? Self.loudness(level()) : 0
        // Eases over about a second each way, so the glow breathes with the voice instead of flickering.
        state.smoothed = state.smoothed * 0.96 + heard * 0.04
        if state.phase == .listening {
            state.levels.removeFirst()
            state.levels.append(heard)
        }
    }

    /// 0 for silence to 1 for loud speech, on a decibel scale like the ear's.
    private static func loudness(_ rms: Float) -> Float {
        let db = 20 * log10(max(rms, 1e-6))
        return min(max((db + 55) / 40, 0), 1)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: VoiceOverlayView(state: state))
        return panel
    }
}

@MainActor
final class VoiceOverlayState: ObservableObject {
    enum Phase { case hidden, listening, transcribing, failed }

    static let barCount = 26

    @Published var phase = Phase.hidden
    @Published var text = ""
    /// Recent loudness, oldest first, one per waveform bar.
    @Published var levels = Array(repeating: Float(0), count: barCount)
    /// The loudness, eased slowly, for the glow.
    @Published var smoothed: Float = 0
}

struct VoiceOverlayView: View {
    @ObservedObject var state: VoiceOverlayState

    var body: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            if !state.text.isEmpty {
                TextBox(text: state.text, isError: state.phase == .failed)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            GlowingPill(state: state)
        }
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.easeOut(duration: 0.18), value: state.text.isEmpty)
    }
}

/// The words recognized so far. The newest stay in view; older ones scroll off the top.
private struct TextBox: View {
    let text: String
    let isError: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(isError ? Color(red: 1, green: 0.55, blue: 0.5) : .white)
            .lineSpacing(2)
            .lineLimit(5)
            .truncationMode(.head)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: 460, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.85)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
    }
}

/// A fixed-size dark pill whose edge glows with a gradient that flows around it, brighter as the
/// voice gets louder, with a waveform inside.
private struct GlowingPill: View {
    @ObservedObject var state: VoiceOverlayState

    private static let size = CGSize(width: 176, height: 40)
    /// The plasma's colors: hot pink, lavender, periwinkle blue, a near-white glint, joined back to
    /// the start for a seamless loop.
    private static let pink = Color(red: 1.0, green: 0.45, blue: 0.82)
    private static let lavender = Color(red: 0.80, green: 0.66, blue: 1.0)
    private static let blue = Color(red: 0.45, green: 0.56, blue: 1.0)
    private static let glint = Color(red: 0.96, green: 0.90, blue: 1.0)
    private static let rim: [Color] = [pink, lavender, blue, glint, blue, lavender, pink]

    var body: some View {
        TimelineView(.animation) { timeline in
            let seconds = timeline.date.timeIntervalSinceReferenceDate
            let level = Double(state.smoothed)
            // The rim's colors drift once around every 40 seconds.
            let rim = AngularGradient(colors: Self.rim, center: .center,
                                      angle: .degrees((seconds * 9).truncatingRemainder(dividingBy: 360)))
            // A faint breath every 8 seconds, and a little more light while speaking.
            let glow = 0.88 + 0.05 * sin(seconds * 2 * .pi / 8) + 0.12 * level
            ZStack {
                // Bloom around the rim, like light through haze.
                Capsule().stroke(rim, lineWidth: 6).blur(radius: 16).opacity(0.75 * glow)
                Capsule().stroke(rim, lineWidth: 3).blur(radius: 5).opacity(0.9 * glow)
                // The dark inside, faintly violet.
                Capsule().fill(Color(red: 0.03, green: 0.02, blue: 0.06))
                // Soft ribbons of light drifting slowly inside, behind the waveform.
                ZStack {
                    Ribbon(seconds: seconds, speed: 0.22, amplitude: 9, waves: 1.1, offset: 0)
                        .stroke(Self.pink, lineWidth: 6).blur(radius: 4).opacity(0.7)
                    Ribbon(seconds: seconds, speed: -0.16, amplitude: 11, waves: 0.8, offset: 2.1)
                        .stroke(Self.blue, lineWidth: 7).blur(radius: 5).opacity(0.75)
                    Ribbon(seconds: seconds, speed: 0.12, amplitude: 6, waves: 1.4, offset: 4.0)
                        .stroke(Self.glint, lineWidth: 2).blur(radius: 2).opacity(0.4)
                }
                .opacity(0.75 + 0.25 * level)
                .blendMode(.screen)
                .clipShape(Capsule())
                // Light glowing in from the rim.
                Capsule().strokeBorder(rim, lineWidth: 5).blur(radius: 4).opacity(0.65 * glow)
                // The rim itself: colored, with a white-hot line along its middle.
                Capsule().strokeBorder(rim, lineWidth: 3)
                Capsule().strokeBorder(Color.white.opacity(0.6), lineWidth: 1).padding(1)
                content
            }
            .frame(width: Self.size.width, height: Self.size.height)
        }
    }

    @ViewBuilder private var content: some View {
        switch state.phase {
        case .transcribing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).colorScheme(.dark)
                Text("Typing…").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
            }
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        case .listening, .hidden:
            Waveform(levels: state.levels)
        }
    }
}

/// A slow wave across the pill, for the ribbons of light inside it.
private struct Ribbon: Shape {
    let seconds: Double
    /// Drift in radians per second; negative drifts the other way.
    let speed: Double
    let amplitude: CGFloat
    /// How many waves fit across the pill.
    let waves: Double
    let offset: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let phase = seconds * speed + offset
        // The ribbon also rises and falls a little, on its own slower rhythm.
        let lift = CGFloat(sin(seconds * abs(speed) * 0.6 + offset)) * rect.height * 0.12
        for step in 0...40 {
            let x = rect.minX + rect.width * CGFloat(step) / 40
            let angle = Double(step) / 40 * waves * 2 * .pi + phase
            let point = CGPoint(x: x, y: rect.midY + lift + CGFloat(sin(angle)) * amplitude)
            step == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        return path
    }
}

/// Bars for the last second of sound, newest on the right, mirrored around the middle line.
private struct Waveform: View {
    let levels: [Float]

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(0.55 + Double(levels[index]) * 0.45))
                    .frame(width: 2.5, height: 3 + CGFloat(levels[index]) * 20)
            }
        }
        .frame(height: 24)
        .animation(.linear(duration: 1.0 / 30), value: levels)
    }
}
