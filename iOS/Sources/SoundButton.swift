import SwiftUI

/// A small, quiet speaker button in the top-right corner. Tap it for the chirp volume, a test hi, and which Mac to pair with.
struct SoundButton: View {
    @ObservedObject var link: MacLink
    @ObservedObject var live: LiveVoice
    /// Top of the usable screen, below the Dynamic Island.
    let chromeTop: CGFloat
    @State private var volume = 1.0
    @State private var open = false
    @State private var lastTouch = Date()

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            Button {
                withAnimation(.spring(duration: 0.3)) { open.toggle() }
                lastTouch = Date()
            } label: {
                Image(systemName: open ? "xmark" : speakerIcon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(open ? 0.9 : 0.6))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.white.opacity(open ? 0.14 : 0.12)).frame(width: 40, height: 40))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 54)  // sits left of the Open Bluey button; the panel below lines up with the screen margin
            .accessibilityLabel(open ? "Close sound settings" : "Sound settings")

            if open {
                panel.transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .topTrailing)))
            }
        }
        .padding(.top, chromeTop - 1)
        .padding(.trailing, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .onAppear { volume = live.volume }
        .task(id: lastTouch) {
            // Tuck the panel away after a few quiet seconds so it never ends up in a shot.
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { withAnimation(.easeOut(duration: 0.25)) { open = false } }
        }
    }

    private var speakerIcon: String {
        volume < 0.01 ? "speaker.slash.fill" : volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Chirp volume")
                    .font(.plexMono(12))
                    .textCase(.uppercase)
                    .foregroundStyle(Color(hex: Palette.inkSoft))
                Spacer()
                Text("\(Int((volume * 100).rounded()))%")
                    .font(.plexMono(13))
                    .foregroundStyle(.white)
            }
            Slider(value: Binding(get: { volume }, set: { volume = $0; live.volume = $0; lastTouch = Date() }), in: 0...1)
                .tint(Color(hex: Palette.berry2))
            Button {
                live.sayHi()
                lastTouch = Date()
            } label: {
                Text(live.state == .asleep ? "Wake him up" : "Say hi")
                    .font(.plexSans(15).weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(BlobShape.linear, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(!link.connected)
            .opacity(link.connected ? 1 : 0.4)
            if link.macs.count > 1 {
                Text("Mac")
                    .font(.plexMono(12))
                    .textCase(.uppercase)
                    .foregroundStyle(Color(hex: Palette.inkSoft))
                ForEach(link.macs, id: \.self) { name in
                    Button {
                        link.choose(name)
                        lastTouch = Date()
                    } label: {
                        HStack {
                            Text(name).font(.plexSans(14)).foregroundStyle(.white).lineLimit(1)
                            Spacer()
                            if name == link.currentMac {
                                Image(systemName: link.connected ? "checkmark" : "ellipsis")
                                    .foregroundStyle(Color(hex: Palette.berry2))
                            }
                        }
                        .frame(minHeight: 36)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if !link.connected {
                Text("Connect to your Mac to talk to him.")
                    .font(.plexSans(12))
                    .foregroundStyle(Color(hex: Palette.inkSoft))
            }
        }
        .padding(16)
        .frame(width: 260)
        .background(Color(hex: Palette.panel).opacity(0.95), in: RoundedRectangle(cornerRadius: 18))
    }
}
