import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Small pills at the bottom of the screen after a dictation is pasted: "Pasted successfully",
/// then, while clean-up runs, "Further polishing… Press ESC to cancel". Pressing Esc then stops
/// the clean-up (that Esc press goes no further, so it doesn't also close a dialog in your app).
@MainActor
final class PasteStatus {
    private let state = PasteStatusState()
    private var panel: NSPanel?
    private var escTap: EventTap?
    private var showPolishing: DispatchWorkItem?
    private var hideLater: DispatchWorkItem?
    private var onCancel: (() -> Void)?
    /// Which dictation the pills are showing, so an older one finishing doesn't hide a newer one's.
    private var current = 0

    /// Shows "Pasted successfully"; after half a second, if `polishing`, the polishing pill.
    @discardableResult
    func pasted(polishing: Bool, onCancel: @escaping () -> Void) -> Int {
        current += 1
        cancelTimers()
        self.onCancel = onCancel
        state.phase = .pasted
        present()
        guard polishing else {
            schedule(hide: 1.2)
            return current
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.onCancel != nil else { return }
                self.state.phase = .polishing
                self.listenForEsc()
            }
        }
        showPolishing = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        return current
    }

    /// Clean-up finished for dictation `id`: its pills go away (unless a newer dictation's show).
    func done(_ id: Int) {
        guard id == current else { return }
        done()
    }

    private func done() {
        onCancel = nil
        stopListening()
        cancelTimers()
        hide()
    }

    private func listenForEsc() {
        guard escTap == nil else { return }
        let tap = EventTap(types: [.keyDown]) { [weak self] _, event in
            let isEsc = event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Escape)
            let plain = event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty
            guard isEsc, plain else { return true }
            MainActor.assumeIsolated {
                let cancel = self?.onCancel
                self?.done()
                cancel?()
            }
            return false
        }
        if tap.install() { escTap = tap }
    }

    private func stopListening() {
        escTap?.remove()
        escTap = nil
    }

    private func cancelTimers() {
        showPolishing?.cancel()
        hideLater?.cancel()
        showPolishing = nil
        hideLater = nil
    }

    private func schedule(hide delay: Double) {
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.done() } }
        hideLater = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func present() {
        let size = CGSize(width: 420, height: 60)
        let panel = self.panel ?? {
            let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: true)
            panel.level = .statusBar
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: PasteStatusView(state: state))
            return panel
        }()
        self.panel = panel
        if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.minY + 52))
        }
        panel.orderFrontRegardless()
    }

    private func hide() {
        state.phase = .hidden
        panel?.orderOut(nil)
    }
}

@MainActor
final class PasteStatusState: ObservableObject {
    enum Phase { case hidden, pasted, polishing }
    @Published var phase = Phase.hidden
}

private struct PasteStatusView: View {
    @ObservedObject var state: PasteStatusState

    var body: some View {
        ZStack {
            switch state.phase {
            case .hidden:
                EmptyView()
            case .pasted:
                pill {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(hex: 0x34C759))
                    Text("Pasted successfully")
                }
            case .polishing:
                pill {
                    ProgressView().controlSize(.mini).tint(.white)
                    Text("Further polishing… Press")
                    Text("ESC").font(.system(size: 11, weight: .heavy))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 5))
                    Text("to cancel")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.easeOut(duration: 0.15), value: state.phase)
    }

    private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) { content() }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(Color.black.opacity(0.85)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.14)))
            .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}
