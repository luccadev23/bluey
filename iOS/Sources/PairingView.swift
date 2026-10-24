import SwiftUI

/// Shown until the phone finds the Mac: a sleepy blob and how to wake him up.
struct PairingView: View {
    var onPlay: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            SleepyBlob()
                .frame(width: 220, height: 190)

            VStack(spacing: 12) {
                Text("Wake me up from your Mac")
                    .font(.fredoka(30))
                    .foregroundStyle(Color(hex: 0xF4F1FA))
                    .multilineTextAlignment(.center)
                Text("Open Bluey in your Mac's menu bar. Keep both on the same Wi-Fi and I'll find it.")
                    .font(.plexSans(16))
                    .foregroundStyle(Color(hex: Palette.inkSoft))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            HStack(spacing: 10) {
                ProgressView().tint(Color(hex: Palette.berry1))
                Text("Looking for your Mac")
                    .font(.plexMono(13))
                    .foregroundStyle(Color(hex: Palette.inkSoft))
            }

            Button(action: onPlay) {
                Text("Play without the Mac")
                    .font(.plexSans(15).weight(.semibold))
                    .foregroundStyle(Color(hex: 0xF4F1FA))
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(Color(hex: Palette.panel), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

private struct SleepyBlob: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                BlobShape()
                    .fill(BlobShape.linear)
                    .overlay(BlobShape().fill(RadialGradient(colors: [.white.opacity(0.5), .white.opacity(0)],
                                                             center: UnitPoint(x: 0.3, y: 0.22), startRadius: 0, endRadius: 80)))
                    .opacity(0.9)
                // Closed eyes and a small half-moon mouth.
                HStack(spacing: 30) {
                    ForEach(0..<2, id: \.self) { _ in
                        Capsule().fill(Color(hex: Palette.ink)).frame(width: 46, height: 8)
                    }
                }
                .offset(y: -28)
                UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 14, bottomTrailingRadius: 14, topTrailingRadius: 3)
                    .fill(Color(hex: Palette.nose))
                    .frame(width: 34, height: 14)
                    .offset(y: 26)
                Text("z").font(.fredoka(26)).foregroundStyle(Color(hex: Palette.berry3))
                    .offset(x: 110, y: -95 - 4 * sin(t * 1.5))
                Text("z").font(.fredoka(18)).foregroundStyle(Color(hex: Palette.berry4))
                    .offset(x: 128, y: -122 - 4 * sin(t * 1.5 + 1))
            }
            .scaleEffect(1 + 0.02 * sin(t * 1.1), anchor: .bottom)
        }
    }
}
