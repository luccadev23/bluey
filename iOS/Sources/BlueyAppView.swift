import SwiftUI

/// Bluey's own app screen: start or end a session, see past sessions and their transcripts, and settings.
/// Opened from the faint button in the top-right corner of his face.
struct BlueyAppView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var live: LiveVoice
    @ObservedObject var link: MacLink
    var onClose: () -> Void
    @State private var volume = 1.0
    @AppStorage("speechLocale") private var speechLocale = ""

    var body: some View {
        NavigationStack {
            List {
                header
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 4, trailing: 20))
                    .listRowSeparator(.hidden)

                Section {
                    startButton
                    Text(live.state == .asleep
                         ? "He listens the whole session. Hold his face to ask something, let go and he answers."
                         : "Session running. Hold his face to ask; everything you say is saved here.")
                        .font(.plexSans(13))
                        .foregroundStyle(Color(hex: Palette.inkSoft))
                        .listRowSeparator(.hidden)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))

                Section {
                    if store.sessions.isEmpty {
                        emptyState
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    } else {
                        sessionPager
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    HStack {
                        Text("Sessions")
                            .font(.fredoka(22))
                            .foregroundStyle(.white)
                        Spacer()
                        Text("\(store.sessions.count)")
                            .font(.plexMono(13))
                            .foregroundStyle(Color(hex: Palette.inkSoft))
                    }
                    .textCase(nil)
                }

                Section {
                    Picker("Speech language", selection: $speechLocale) {
                        Text("Device language").tag("")
                        Text("Português (Brasil)").tag("pt-BR")
                        Text("English (US)").tag("en-US")
                        Text("English (UK)").tag("en-GB")
                    }
                    .disabled(live.state != .asleep)
                    .listRowBackground(Color(hex: Palette.panel))

                    HStack(spacing: 12) {
                        Image(systemName: "speaker.wave.2.fill")
                            .foregroundStyle(Color(hex: Palette.inkSoft))
                        Slider(value: Binding(get: { volume }, set: { volume = $0; live.volume = $0 }), in: 0...1)
                        Text("\(Int((volume * 100).rounded()))%")
                            .font(.plexMono(13))
                            .foregroundStyle(.white)
                            .frame(width: 44, alignment: .trailing)
                    }
                    .listRowBackground(Color(hex: Palette.panel))

                    if link.macs.count > 1 {
                        ForEach(link.macs, id: \.self) { name in
                            Button { link.choose(name) } label: {
                                HStack {
                                    Text(name).font(.plexSans(15)).foregroundStyle(.white).lineLimit(1)
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
                            .listRowBackground(Color(hex: Palette.panel))
                        }
                    }
                } header: {
                    label("Settings")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Speech is transcribed on your iPhone. Requires iOS 26 and a supported device and language.")
                        if let message = live.statusMessage {
                            Text(message).foregroundStyle(.white)
                        }
                    }
                    .font(.plexSans(12))
                    .foregroundStyle(Color(hex: Palette.inkSoft))
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.insetGrouped)
            .background(Color.black)
            .navigationDestination(for: UUID.self) { id in
                SessionDetailView(store: store, id: id)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .tint(Color(hex: Palette.berry1))
        .onAppear { volume = live.volume }
    }

    // MARK: Pieces

    /// At most this many sessions show at once; with more, the list scrolls inside its own box.
    private static let visibleSessions = 3
    private static let sessionRowHeight: CGFloat = 64

    private var sessionPager: some View {
        let count = store.sessions.count
        return List {
            ForEach(store.sessions) { session in
                NavigationLink(value: session.id) {
                    SessionRow(session: session, live: session.id == store.currentID)
                        .frame(height: Self.sessionRowHeight - 16)
                }
                .listRowBackground(Color(hex: Palette.panel))
            }
            .onDelete { offsets in
                offsets.map { store.sessions[$0].id }.forEach(store.delete)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, Self.sessionRowHeight)
        .frame(height: CGFloat(min(count, Self.visibleSessions)) * Self.sessionRowHeight)
        .scrollDisabled(count <= Self.visibleSessions)
        .background(Color(hex: Palette.panel))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 12) {
            MiniBluey()
                .frame(width: 54, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text("Bluey")
                    .font(.fredoka(28))
                    .foregroundStyle(.white)
                HStack(spacing: 6) {
                    Circle()
                        .fill(link.connected ? Color(hex: Palette.online) : Color(hex: Palette.inkSoft).opacity(0.5))
                        .frame(width: 7, height: 7)
                    Text(link.connected ? (link.macName ?? link.currentMac ?? "Mac") : "Looking for your Mac")
                        .font(.plexSans(13))
                        .foregroundStyle(Color(hex: Palette.inkSoft))
                        .lineLimit(1)
                }
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to his face")
        }
    }

    private var startButton: some View {
        Button {
            let starting = live.state == .asleep
            live.toggle()
            if starting { onClose() }  // back to his face when starting
        } label: {
            HStack(spacing: 10) {
                Image(systemName: live.state == .asleep ? "play.fill" : "stop.fill")
                Text(live.state == .asleep ? "Start session" : "End session")
            }
            .font(.fredoka(18))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background {
                if live.state == .asleep {
                    RoundedRectangle(cornerRadius: 16).fill(BlobShape.linear)
                } else {
                    RoundedRectangle(cornerRadius: 16).fill(Color(hex: Palette.danger))
                }
            }
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.bubble")
                .font(.system(size: 34))
                .foregroundStyle(Color(hex: Palette.berry2))
            Text("No sessions yet")
                .font(.fredoka(18))
                .foregroundStyle(.white)
            Text("Start one and your transcript and his replies show up here.")
                .font(.plexSans(13))
                .foregroundStyle(Color(hex: Palette.inkSoft))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.plexMono(11))
            .textCase(.uppercase)
            .foregroundStyle(Color(hex: Palette.inkSoft))
    }
}

private struct SessionRow: View {
    let session: BlueySession
    let live: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(session.started.formatted(date: .abbreviated, time: .shortened))
                        .font(.plexSans(15).weight(.semibold))
                        .foregroundStyle(.white)
                    if live {
                        Text("LIVE")
                            .font(.plexMono(10).weight(.bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(hex: Palette.online), in: Capsule())
                    }
                }
                Text(session.summary)
                    .font(.plexSans(13))
                    .foregroundStyle(Color(hex: Palette.inkSoft))
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(Self.duration(session.duration))
                    .font(.plexMono(12))
                    .foregroundStyle(Color(hex: Palette.inkSoft))
                Text("\(session.questionCount) asked")
                    .font(.plexMono(11))
                    .foregroundStyle(Color(hex: Palette.berry1))
            }
        }
        .padding(.vertical, 4)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// One session as a chat: what you said in grey, your questions in blue, his replies in white bubbles.
struct SessionDetailView: View {
    @ObservedObject var store: SessionStore
    let id: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    /// A prompt for an agent (like Claude Code on the Mac) that points it at this session's notes files.
    private func copyPrompt(_ session: BlueySession) {
        let root = "~/Documents/Bluey Notes"
        let path = session.notesPath.map { p -> String in
            // Show the Mac path with ~ for the home folder.
            if let range = p.range(of: "/Documents/Bluey Notes") { return "~" + p[range.lowerBound...] }
            return p
        } ?? "\(root)/ (the folder starting \(session.started.formatted(.iso8601.year().month().day())))"
        let prompt = """
        I recorded a meeting with my Bluey app on \(session.started.formatted(date: .complete, time: .shortened)). \
        The notes are on my Mac in \(path)

        - notes.md: the local transcript with timestamps (older sessions may retain speaker labels), plus \
        my questions to Bluey, its replies and research reports. Start here.
        - session.json: the same data, structured.
        - audio/: the original recording in five-minute chunks.

        All my sessions are in \(root)/, one folder per session (see README.md there). Read the notes, then help me \
        with: 
        """
        #if canImport(UIKit)
        UIPasteboard.general.string = prompt
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }

    private var session: BlueySession? { store.sessions.first { $0.id == id } }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .background(Color.white.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session?.started.formatted(date: .abbreviated, time: .shortened) ?? "Session")
                            .font(.fredoka(20))
                            .foregroundStyle(.white)
                        if let session {
                            Text("\(SessionRow.duration(session.duration)) · \(session.questionCount) asked")
                                .font(.plexMono(12))
                                .foregroundStyle(Color(hex: Palette.inkSoft))
                        }
                    }
                    Spacer(minLength: 0)
                    if let session {
                        ShareLink(item: session.exportText) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: 44, height: 44)
                                .background(Color.white.opacity(0.08), in: Circle())
                        }
                    }
                }
                if let session {
                    Button { copyPrompt(session) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            Text(copied ? "Copied" : "Copy prompt for agent")
                        }
                        .font(.plexSans(14).weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color(hex: Palette.berry3), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    let notes = [session.transcribing > 0 ? "\(session.transcribing) recordings await local recovery" : nil,
                                 session.archiving > 0 ? "saving \(session.archiving) recordings" : nil].compactMap { $0 }
                    if !notes.isEmpty {
                        Text(notes.joined(separator: " · "))
                            .font(.plexMono(11))
                            .foregroundStyle(Color(hex: Palette.inkSoft))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let error = session.recoveryError {
                        Text(error).font(.plexSans(12)).foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 12)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(session?.displayEntries ?? []) { entry in
                            EntryView(entry: entry).id(entry.id)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
                .onAppear { if let last = session?.entries.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                .onChange(of: session?.entries.count) { _, _ in
                    if let last = session?.entries.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
        }
        .background(Color.black)
        .background(SwipeBackEnabler())
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// Hiding the navigation bar also turns off swiping back from the left edge; this turns it back on.
private struct SwipeBackEnabler: UIViewControllerRepresentable {
    final class Controller: UIViewController {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            navigationController?.interactivePopGestureRecognizer?.delegate = nil
            navigationController?.interactivePopGestureRecognizer?.isEnabled = true
        }
    }

    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}
}

private struct EntryView: View {
    static func speakerColor(_ speaker: String?) -> Color {
        let colors: [UInt32] = [0x8FB3FF, 0x5BE49B, 0xFFB86B, 0xFF9AD0, 0xC79BFF, 0x6BE3E0]
        guard let first = speaker?.unicodeScalars.first?.value, speaker != "?" else { return Color(hex: Palette.inkSoft) }
        return Color(hex: colors[Int(first) % colors.count])
    }

    let entry: TranscriptEntry
    @State private var open = false

    var body: some View {
        switch entry.kind {
        case .transcript:
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(entry.speaker.map { "Speaker \($0)" } ?? "Speech")
                        .font(.plexMono(11).weight(.medium))
                        .foregroundStyle(Self.speakerColor(entry.speaker))
                    Spacer()
                    Text(entry.time.formatted(date: .omitted, time: .shortened))
                        .font(.plexMono(10))
                        .foregroundStyle(Color(hex: Palette.inkSoft).opacity(0.7))
                }
                Text(entry.text)
                    .font(.plexSans(15))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .heard:
            Text(entry.text)
                .font(.plexSans(14))
                .foregroundStyle(Color(hex: Palette.inkSoft))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 4)
        case .asked:
            HStack {
                Spacer(minLength: 48)
                VStack(alignment: .trailing, spacing: 3) {
                    Text("You asked")
                        .font(.plexMono(10))
                        .foregroundStyle(Color(hex: Palette.berry1))
                    Text(entry.text)
                        .font(.plexSans(15).weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(BlobShape.linear, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
        case .reply:
            HStack(alignment: .bottom, spacing: 8) {
                MiniBluey().frame(width: 28, height: 25)
                Text(entry.text)
                    .font(.fredoka(16))
                    .foregroundStyle(Color(hex: Palette.ink))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Spacer(minLength: 48)
            }
        case .report:
            let lines = entry.text.components(separatedBy: "\n\n")
            VStack(alignment: .leading, spacing: 8) {
                Button { withAnimation(.spring(duration: 0.3)) { open.toggle() } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass").foregroundStyle(Color(hex: Palette.berry1))
                        Text(lines.first ?? "Research")
                            .font(.fredoka(16))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: open ? "minus" : "plus")
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color(hex: Palette.berry2)))
                    }
                }
                .buttonStyle(.plain)
                Text(lines.dropFirst().joined(separator: "\n\n"))
                    .font(.plexSans(14))
                    .foregroundStyle(Color(hex: Palette.reportText))
                    .lineLimit(open ? nil : 3)
            }
            .padding(14)
            .background(Color(hex: Palette.reportPanel), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color(hex: Palette.berry2), lineWidth: 2))

        }
    }
}

/// A tiny Bluey: the blob with two googly eyes and his half-moon mouth.
struct MiniBluey: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                BlobShape().fill(BlobShape.linear)
                HStack(spacing: w * 0.1) {
                    ForEach(0..<2, id: \.self) { _ in
                        Circle()
                            .fill(.white)
                            .frame(width: w * 0.26, height: w * 0.26)
                            .overlay(Circle().fill(Color(hex: Palette.ink)).frame(width: w * 0.12).offset(x: w * 0.02, y: w * 0.03))
                    }
                }
                .offset(y: -w * 0.09)
                UnevenRoundedRectangle(topLeadingRadius: w * 0.02, bottomLeadingRadius: w * 0.15,
                                       bottomTrailingRadius: w * 0.15, topTrailingRadius: w * 0.02)
                    .fill(Color(hex: Palette.nose))
                    .frame(width: w * 0.3, height: w * 0.15)
                    .offset(y: w * 0.23)
            }
        }
    }
}
