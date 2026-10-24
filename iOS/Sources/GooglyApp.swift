import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

@main
struct GooglyApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    @StateObject private var link = MacLink()
    @StateObject private var live = LiveVoice()
    @StateObject private var store = SessionStore()
    @State private var showApp = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var animator = FaceAnimator()
    @State private var showPairing = true
    @State private var holdStart: DispatchWorkItem?
    @State private var holdingToAsk = false
    @AppStorage("hasWokenBluey") private var hasWoken = false

    /// A quiet line near the bottom: how to wake him until you have, and what letting go does while you hold.
    private var hint: (icon: String, text: String)? {
        if live.state == .asking { return ("hand.tap.fill", "Release and he answers") }
        if live.state == .asleep && !hasWoken && !(showPairing && !link.connected) { return ("hand.tap", "Double-tap to wake him up") }
        return nil
    }

    var body: some View {
        // Read the top safe area here, before ignoring it, so the controls clear the Dynamic Island.
        GeometryReader { geo in
            let chromeTop = max(geo.safeAreaInsets.top, 20)
            ZStack {
                FaceView(animator: animator)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { live.toggle() }  // double tap: wake up / back to follow mode
                    .simultaneousGesture(holdToAsk)

                ModeIndicator(state: live.state, chromeTop: chromeTop)

                if let message = live.statusMessage {
                    Text(message)
                        .font(.plexSans(14))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(12)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 24)
                        .padding(.bottom, 40)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .allowsHitTesting(false)
                } else if let hint {
                    HintPill(icon: hint.icon, text: hint.text)
                        .padding(.bottom, 44)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                SoundButton(link: link, live: live, chromeTop: chromeTop)

                // Bluey's app: sessions, transcripts and settings.
                Button { showApp = true } label: {
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.white.opacity(0.12)).frame(width: 40, height: 40))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open Bluey")
                .padding(.top, chromeTop - 1)
                .padding(.trailing, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

                if showPairing && !link.connected {
                    PairingView { withAnimation(.easeOut(duration: 0.3)) { showPairing = false } }
                        .transition(.opacity)
                }
            }
            .ignoresSafeArea()
        }
        .background(Color.black)
        .phoneChrome()
        .fullScreenCover(isPresented: $showApp) {
            BlueyAppView(store: store, live: live, link: link) { showApp = false }
        }
        .onAppear {
            link.onFace = { [animator] face in animator.receive(face, at: Date().timeIntervalSinceReferenceDate) }
            animator.localTalk = { [live] in live.level }
            wireLiveVoice()
            link.start()
        }
        .onChange(of: link.connected) { _, connected in
            if connected {
                withAnimation(.easeOut(duration: 0.4)) { showPairing = false }
                NotesSync.retryPending(store: store, link: link)
                if live.state == .asleep { NotesSync.recoverPending(store: store, link: link) }
                store.resyncRecent()
            }
        }
        .onChange(of: live.state) { _, state in
            if state != .asleep { hasWoken = true }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { link.start() }
            else if phase == .background { live.sleep(); link.stop() }
        }
    }

    /// Press and hold the screen to ask him something; let go and he answers.
    private var holdToAsk: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard holdStart == nil, !holdingToAsk else { return }
                let work = DispatchWorkItem {
                    holdingToAsk = true
                    #if canImport(UIKit)
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    #endif
                    live.beginAsk()
                }
                holdStart = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)  // a quick tap isn't a hold
            }
            .onEnded { _ in
                holdStart?.cancel()
                holdStart = nil
                if holdingToAsk {
                    holdingToAsk = false
                    #if canImport(UIKit)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    #endif
                    live.endAsk()
                }
            }
    }

    /// Connects the live voice to the Mac: keys, tools, captions and wake/sleep.
    private func wireLiveVoice() {
        live.requestToken = { [link] done in
            link.request(Packet(command: "realtimeToken")) { reply in done(reply?.text) }
        }
        live.runTool = { [link] name, arguments, done in
            link.request(Packet(command: "tool", tool: name, text: arguments), timeout: 300) { reply in
                done(reply?.text ?? "The Mac didn't answer.", reply?.image)
            }
        }
        live.onSessionStart = { [store] id, started in
            store.start(id: id, started: started)
        }
        live.resumeContext = { [store] in store.recentText() }
        live.recorder.onChunk = { [store, link] chunk in
            store.addPending(chunk.sessionID, index: chunk.index, started: chunk.started,
                             needsRecovery: chunk.needsLocalRecovery)
            NotesSync.upload(chunk.sessionID, index: chunk.index, started: chunk.started, store: store, link: link)
        }
        store.onSync = { [store, link] sessions in NotesSync.send(sessions, store: store, link: link) }
        live.onSessionEnd = { [store, link] in
            store.end()
            NotesSync.recoverPending(store: store, link: link)
        }
        live.onLocalSpeech = { [store] id, segment, started in store.localSpeech(session: id, segment: segment, started: started) }
        live.onReply = { [store] text in store.reply(text) }
        live.onReport = { [store] text in store.report(text) }
        live.onCaption = { [link] text, finished in
            link.send(Packet(command: finished ? "captionDone" : "caption", text: text))
        }
        live.onStateChange = { [link, animator] state in
            switch state {
            case .asleep:
                animator.awake = false
                animator.localMood = nil
                link.send(Packet(command: "asleep"))
            case .waking:
                animator.awake = true
                animator.localMood = .happy
            case .listening:
                animator.awake = true
                animator.localMood = nil
                link.send(Packet(command: "awake"))
            case .asking:
                animator.awake = true
                animator.localMood = .listening  // all ears while you hold
                link.send(Packet(command: "awake"))
            case .thinking:
                animator.localMood = .thinking
            case .speaking:
                animator.localMood = .talking
            }
        }
        link.onCommand = { [live] command in
            switch command {
            case "wake": live.wake()
            case "sleep": live.sleep()
            default: break
            }
        }
    }
}

/// A small dark pill with a hint, like "Double-tap to wake him up".
struct HintPill: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold))
            Text(text).font(.plexSans(14).weight(.semibold))
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 18)
        .frame(minHeight: 40)
        .background(Capsule().fill(Color.black.opacity(0.55)))
    }
}

/// Shows which mode he's in: a solid border hugging the screen's own rounded corners (blue while he listens),
/// plus a small label in the top-left corner. Following your mouse (asleep) shows nothing; his face says it. No glows.
struct ModeIndicator: View {
    let state: LiveVoice.State
    /// Top of the usable screen (below the Dynamic Island), so the label lines up with the buttons on the right.
    let chromeTop: CGFloat

    private struct Look {
        let color: Color
        let label: String?
        let icon: String
        let border: CGFloat   // 0 = no border
        let pulse: Double     // pulses per second (opacity only)
        var textColor: Color = .white
    }

    private var look: Look {
        switch state {
        case .asleep:    return Look(color: Color(hex: Palette.inkSoft), label: nil, icon: "eye.fill", border: 0, pulse: 0)
        case .waking:    return Look(color: Color(hex: Palette.modeYellow), label: "Waking up", icon: "sun.max.fill", border: 4, pulse: 1.6, textColor: Color(hex: Palette.ink))
        case .listening: return Look(color: Color(hex: Palette.modeBlue), label: "Listening · hold to ask", icon: "ear", border: 6, pulse: 0)
        case .asking:    return Look(color: Color(hex: Palette.modeBlue), label: "I'm all ears", icon: "mic.fill", border: 10, pulse: 1.2)
        case .thinking:  return Look(color: Color(hex: Palette.modePurple), label: "Thinking", icon: "sparkles", border: 6, pulse: 1.1)
        case .speaking:  return Look(color: Color(hex: Palette.modePink), label: "Replying", icon: "bubble.left.fill", border: 6, pulse: 0, textColor: Color(hex: Palette.ink))
        }
    }

    /// The phone screen's own corner radius, so the border lines up with the glass.
    private static let screenCornerRadius: CGFloat = {
        #if canImport(UIKit)
        return FaceLayout.screenCornerRadius(nativeHeight: Double(UIScreen.main.nativeBounds.height))
        #else
        return 55
        #endif
    }()

    var body: some View {
        let look = look
        let radius = Self.screenCornerRadius
        TimelineView(.animation(paused: look.pulse == 0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let wave = look.pulse > 0 ? 0.5 + 0.5 * sin(t * look.pulse * 2 * .pi) : 1
            ZStack(alignment: .topLeading) {
                if look.border > 0 {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(look.color, lineWidth: look.border)
                        .opacity(look.pulse > 0 ? 0.65 + 0.35 * wave : 1)
                }
                if state == .asking {
                    // A fainter ring just inside the border that breathes while he's listening to your question.
                    RoundedRectangle(cornerRadius: max(radius - look.border - 6, 16), style: .continuous)
                        .strokeBorder(look.color, lineWidth: 3)
                        .padding(look.border + 6)
                        .opacity(0.15 + 0.35 * wave)
                }
                // Asleep he just follows your mouse, and his face already says so: nothing to show.
                if let label = look.label {
                    HStack(spacing: 7) {
                        Image(systemName: look.icon)
                            .font(.system(size: 14, weight: .bold))
                        Text(label).font(.fredoka(16))
                    }
                    .foregroundStyle(look.textColor)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 34)
                    .background(Capsule().fill(look.color))
                    .padding(.top, chromeTop + 4)
                    .padding(.leading, 24 + look.border)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.25), value: state)
    }
}

private extension View {
    /// Hides the status bar and home indicator and keeps the screen awake.
    func phoneChrome() -> some View {
        #if os(iOS)
        return self
            .statusBarHidden(true)
            .persistentSystemOverlays(.hidden)
            .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        #else
        return self
        #endif
    }
}
