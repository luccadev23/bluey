import SwiftUI

/// A tiny damped spring, so every part of the face moves with a little life.
private struct Spring {
    var value: Double
    var velocity = 0.0
    let stiffness: Double
    let damping: Double  // 1 = no overshoot, lower = bouncier

    init(_ value: Double, stiffness: Double = 200, damping: Double = 0.7) {
        self.value = value
        self.stiffness = stiffness
        self.damping = damping
    }

    mutating func step(to target: Double, dt: Double) {
        let c = 2 * sqrt(stiffness) * damping
        velocity += (stiffness * (target - value) - c * velocity) * dt
        value += velocity * dt
    }
}

/// Smooths what the Mac asks for into lifelike motion: darting eyes, blinks, leaning, hops.
final class FaceAnimator {
    struct Frame {
        var gaze: CGPoint
        var mood: Mood
        var talk: Double
        var closed: Double      // 0 open … 1 shut (blink)
        var breathe: Double
        var time: Double
        var pupil: Double       // pupil size multiplier
        var lean: Double        // head tilt toward where he's looking (radians)
        var hop: Double         // little idle hop (design px, up is +)
        var squint: Double      // 0…1 happy squint from below
        var mouthW: Double      // mouth size and tilt (design px, radians)
        var mouthH: Double
        var mouthTilt: Double
    }

    private var target = FaceState()
    private var lastPacket = -100.0
    private var gazeX = Spring(0, stiffness: 260, damping: 0.82)
    private var gazeY = Spring(0, stiffness: 260, damping: 0.82)
    private var pupil = Spring(1, stiffness: 160, damping: 0.5)
    private var lean = Spring(0, stiffness: 60, damping: 0.8)
    private var hop = Spring(0, stiffness: 260, damping: 0.35)
    private var mouthW = Spring(74, stiffness: 300, damping: 0.8)
    private var mouthH = Spring(36, stiffness: 300, damping: 0.8)
    private var mouthTilt = Spring(0.05, stiffness: 200, damping: 0.7)
    private var squint = Spring(0, stiffness: 150, damping: 0.7)
    private var talk = 0.0
    private var mood: Mood = .listening
    private var moodChanged = 0.0
    private var blinkStart = -1.0
    private var doubleBlink = false
    private var nextBlink = 2.0
    private var lastTime: Double?
    private var nextSaccade = 0.0
    private var wanderTarget = CGPoint(x: 0, y: -0.3)
    private var jitter = CGPoint.zero
    private var nextJitter = 0.0
    private var nextHop = 6.0

    /// Set while a finger is on the screen, in -1…1 gaze units.
    var touchGaze: CGPoint?
    /// Mood set on the phone itself (waking up, talking).
    var localMood: Mood?
    /// Loudness of the voice playing on this phone, 0…1.
    var localTalk: () -> Double = { 0 }
    /// True while he's awake and talking with you. In follow mode his eyes stay locked on your mouse.
    var awake = false

    func receive(_ face: FaceState, at time: Double) {
        target = face
        lastPacket = time
    }

    func step(_ now: Double) -> Frame {
        let dt = min(now - (lastTime ?? now), 1.0 / 20)
        lastTime = now

        let live = now - lastPacket < 2.5
        let wantedMood = localMood ?? (live ? target.mood : .listening)
        if wantedMood != mood {
            mood = wantedMood
            moodChanged = now
            blinkStart = now          // blink through every mood change
            if mood != .sleepy && mood != .resting {
                hop.velocity += 260   // and a little bounce of surprise
                pupil.velocity += 3
            }
        }

        // Where to look, plus tiny darting movements so the eyes never sit dead still.
        var want: CGPoint
        if let touchGaze {
            want = touchGaze
        } else if live {
            want = CGPoint(x: target.gazeX, y: target.gazeY)
        } else {
            if now > nextSaccade {
                wanderTarget = CGPoint(x: .random(in: -0.9...0.9), y: .random(in: -0.9...0.4))
                nextSaccade = now + .random(in: 0.6...2.2)
            }
            want = wanderTarget
        }
        if mood == .thinking { want = CGPoint(x: 0.6 + 0.08 * sin(now * 1.3), y: -0.85) }
        if now > nextJitter {
            // While he's listening his eyes stay on your mouse; the livelier darting is for replying.
            let amount = !awake ? 0.015 : (mood == .talking ? 0.07 : mood == .thinking ? 0.05 : 0.02)
            jitter = CGPoint(x: .random(in: -amount...amount), y: .random(in: -amount...amount))
            nextJitter = now + .random(in: 0.5...1.4)
        }
        gazeX.step(to: want.x + jitter.x, dt: dt)
        gazeY.step(to: want.y + jitter.y, dt: dt)

        var wantTalk = live ? target.talk : (localMood == .talking ? 0.5 + 0.5 * sin(now * 19) * sin(now * 7.3) : 0)
        wantTalk = max(wantTalk, localTalk())
        talk += (wantTalk - talk) * min(1, dt * 25)

        // Expression targets per mood. Mouth sizes are in design px; tilt is in radians.
        var wantPupil = 1.0, wantSquint = 0.0
        var wantMouth = (w: 74.0, h: 36.0, tilt: 0.05)
        switch mood {
        case .listening:
            wantPupil = 1.12
        case .talking:
            wantPupil = 1.05
        case .pointing:
            wantPupil = 0.95
            wantMouth = (50, 10, 0)
        case .thinking:
            wantPupil = 0.9
            wantMouth = (44, 10, -0.1)
        case .happy:
            wantPupil = 1.2; wantSquint = 1
            wantMouth = (100, 52, 0)
        case .resting:
            wantPupil = 0.9
            wantMouth = (46, 14, 0)
        case .sleepy:
            wantPupil = 0.88
            wantMouth = (34, 26, 0)
        }
        pupil.step(to: wantPupil, dt: dt)
        squint.step(to: wantSquint, dt: dt)
        // His mouth opens with the voice on top of whatever the mood asks for.
        mouthW.step(to: wantMouth.w + talk * 6, dt: dt)
        mouthH.step(to: wantMouth.h + talk * 26, dt: dt)
        mouthTilt.step(to: wantMouth.tilt, dt: dt)
        lean.step(to: -gazeX.value * 0.045, dt: dt)

        // An occasional happy little hop when nothing much is going on.
        if now > nextHop {
            if talk < 0.05, mood != .sleepy, mood != .resting { hop.velocity += .random(in: 180...320) }
            nextHop = now + .random(in: 7...14)
        }
        hop.step(to: 0, dt: dt)

        // Blinks, sometimes doubled. When he's drowsy they're slow and heavy.
        let drowsy = mood == .sleepy
        if now > nextBlink {
            blinkStart = now
            doubleBlink = !drowsy && Double.random(in: 0...1) < 0.25
            nextBlink = now + (drowsy ? .random(in: 1.6...3.0) : .random(in: 2.0...5.0))
        }
        let p = (now - blinkStart) / (drowsy ? 0.7 : 0.15)
        var closed = (0...1).contains(p) ? sin(.pi * p) : 0
        if doubleBlink, (1.3...2.3).contains(p) { closed = sin(.pi * (p - 1.3)) }

        let breathe = sin(now * (mood == .resting ? 1.1 : 1.8))
        return Frame(gaze: CGPoint(x: gazeX.value, y: gazeY.value), mood: mood, talk: talk, closed: closed,
                     breathe: breathe, time: now, pupil: pupil.value, lean: lean.value, hop: hop.value,
                     squint: max(0, min(1, squint.value)),
                     mouthW: max(8, mouthW.value), mouthH: max(6, mouthH.value), mouthTilt: mouthTilt.value)
    }
}

/// The portrait face on pure black: he fills the width and peeks up from the bottom edge.
/// Everything is drawn in the 390 × 844 design space of `FaceLayout`, scaled by the screen's width.
struct FaceView: View {
    let animator: FaceAnimator

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                let frame = animator.step(timeline.date.timeIntervalSinceReferenceDate)
                FaceView.draw(frame, in: &ctx, size: size)
            }
        }
        .background(Color.black)
        .ignoresSafeArea()
    }

    /// Fills a shape with his skin (gradient plus the same soft shine), for eyelids.
    private static func fillSkin(_ path: Path, in ctx: inout GraphicsContext, body: CGRect) {
        ctx.fill(path, with: BlobShape.fill(in: body))
        ctx.fill(path, with: shine(in: body))
    }

    private static func shine(in body: CGRect) -> GraphicsContext.Shading {
        .radialGradient(Gradient(colors: [.white.opacity(0.5), .white.opacity(0)]),
                        center: CGPoint(x: body.minX + 147, y: body.minY + 75),
                        startRadius: 0, endRadius: 146)
    }

    /// His mouth: a half-moon that opens as he talks, with a flat top.
    private static func mouthPath(_ rect: CGRect) -> Path {
        let bottom = rect.height >= 20 ? min(rect.width / 2, rect.height) : rect.height / 2
        let top = min(4, rect.height / 2)
        return UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom,
                                      bottomTrailingRadius: bottom, topTrailingRadius: top).path(in: rect)
    }

    static func draw(_ f: FaceAnimator.Frame, in ctx: inout GraphicsContext, size: CGSize) {
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))

        let scale = FaceLayout.scale(for: size)
        ctx.translateBy(x: 0, y: FaceLayout.originY(for: size))
        ctx.scaleBy(x: scale, y: scale)

        // Whole-body motion: breathing, talking bounce, idle hops, and leaning toward what he looks at.
        let bounce = -f.talk * 16 + f.breathe * 3 - f.hop
        var body = FaceLayout.body
        body.origin.y += bounce
        let pivot = CGPoint(x: body.midX, y: body.maxY)
        ctx.translateBy(x: pivot.x, y: pivot.y)
        ctx.rotate(by: .radians(f.lean))
        let stretch = 1 + min(0.03, max(-0.03, f.hop / 900))
        ctx.scaleBy(x: 2 - stretch, y: stretch)
        ctx.translateBy(x: -pivot.x, y: -pivot.y)

        let blob = BlobShape.path(in: body)

        var glow = ctx
        glow.addFilter(.shadow(color: Color(hex: Palette.berry2, opacity: 0.5), radius: 35, x: 0, y: -8))
        glow.fill(blob, with: .color(Color(hex: Palette.berry3)))

        ctx.fill(blob, with: BlobShape.fill(in: body))
        var shine = ctx
        shine.clip(to: blob)
        shine.fill(blob, with: FaceView.shine(in: body))

        let navy = Color(hex: Palette.nose)
        let ink = Color(hex: Palette.ink)

        let eyeY = FaceLayout.eyeY + bounce
        let eyes = FaceLayout.eyeCenters.map { CGPoint(x: $0, y: eyeY) }
        let squash = 1 - f.talk * 0.12
        let eyeW = FaceLayout.eyeSize.width, eyeH = FaceLayout.eyeSize.height

        for (i, c) in eyes.enumerated() {
            let side: CGFloat = i == 0 ? -1 : 1

            switch f.mood {
            case .resting:
                // Peacefully closed: a soft downward curve.
                var shut = Path()
                shut.move(to: CGPoint(x: c.x - 47, y: c.y + 6))
                shut.addQuadCurve(to: CGPoint(x: c.x + 47, y: c.y + 6), control: CGPoint(x: c.x, y: c.y + 100))
                ctx.stroke(shut, with: .color(ink), style: StrokeStyle(lineWidth: 16, lineCap: .butt))

            case .happy where f.squint > 0.6:
                var arc = Path()
                arc.move(to: CGPoint(x: c.x - 46, y: c.y + 16))
                arc.addQuadCurve(to: CGPoint(x: c.x + 46, y: c.y + 16), control: CGPoint(x: c.x, y: c.y - 76))
                ctx.stroke(arc, with: .color(ink), style: StrokeStyle(lineWidth: 18, lineCap: .butt))

            default:
                let sleepy = f.mood == .sleepy
                let open = max(0.06, 1 - f.closed) * squash
                // Half-open and sunk a little when he's drowsy; a full oval otherwise.
                let height = sleepy ? 60 : eyeH
                let centerY = sleepy ? c.y + 8 : c.y
                let white = CGRect(x: c.x - eyeW / 2, y: centerY - height / 2 * open, width: eyeW, height: height * open)
                let whitePath = Path(ellipseIn: white)
                ctx.fill(whitePath, with: .color(.white))
                guard open > 0.2 else { continue }

                var g = f.gaze
                let len = hypot(g.x, g.y)
                if len > 1 { g = CGPoint(x: g.x / len, y: g.y / len) }
                // The pupil travels on a small ellipse so it never leaves the white; eyes converge a touch.
                let r = (sleepy ? 28 : FaceLayout.pupilRadius) * f.pupil
                var pupil = CGPoint(x: c.x + g.x * FaceLayout.gazeReach.width - side * 2,
                                    y: centerY + g.y * FaceLayout.gazeReach.height * open)
                if sleepy { pupil.y = centerY + 6 }  // eyes sink under heavy lids
                var inside = ctx
                inside.clip(to: whitePath)
                inside.fill(Path(ellipseIn: CGRect(x: pupil.x - r, y: pupil.y - r, width: r * 2, height: r * 2)), with: .color(ink))
                // Two catchlights make them shine.
                inside.fill(Path(ellipseIn: CGRect(x: pupil.x - r * 0.58, y: pupil.y - r * 0.72, width: r * 0.56, height: r * 0.56)),
                            with: .color(.white))
                inside.fill(Path(ellipseIn: CGRect(x: pupil.x + r * 0.28, y: pupil.y + r * 0.22, width: r * 0.24, height: r * 0.24)),
                            with: .color(.white.opacity(0.85)))
                // Happy cheeks push up from below as he smiles.
                if f.squint > 0.02 {
                    let lid = CGRect(x: c.x - 66, y: c.y + eyeH / 2 * open - 42 * f.squint, width: 132, height: 96)
                    fillSkin(Path(ellipseIn: lid), in: &inside, body: body)
                }
                // A flat navy lid line sits on his heavy eyes when he's sleepy.
                if sleepy {
                    ctx.fill(Path(roundedRect: CGRect(x: c.x - 66, y: white.minY - 4, width: 132, height: 10), cornerRadius: 5),
                             with: .color(navy))
                }
                // A soft upper lid when he's focused on pointing.
                if f.mood == .pointing {
                    fillSkin(Path(CGRect(x: c.x - 66, y: white.minY - 12, width: 132, height: 24)), in: &inside, body: body)
                }
            }
        }

        if f.mood == .resting || f.mood == .sleepy {
            // Little z's floating up while he naps.
            for i in 0..<3 {
                let phase = (f.time * 0.35 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                let fontSize = 26 + CGFloat(i) * 8
                let point = CGPoint(x: 290 + CGFloat(phase) * 60 + CGFloat(sin(phase * 6)) * 8,
                                    y: 330 + bounce - CGFloat(phase) * 68)
                ctx.draw(Text("z").font(.fredoka(fontSize)).foregroundColor(.white.opacity(0.9 * sin(.pi * phase))), at: point)
            }
        }

        if f.mood == .thinking {
            for i in 0..<3 {
                let wobble = sin(f.time * 3 + Double(i)) * 4
                let dot = CGRect(x: 300 + CGFloat(i) * 24, y: 290 + bounce - CGFloat(i) * 12 + wobble, width: 16, height: 16)
                ctx.fill(Path(ellipseIn: dot), with: .color(.white.opacity(1 - Double(i) * 0.3)))
            }
        }

        // His mouth: a half-moon that opens as he talks and widens into a grin when he's happy.
        let mouthW = f.mouthW, mouthH = f.mouthH
        let mouthCenter = CGPoint(x: FaceLayout.mouthCenterX, y: FaceLayout.mouthTop + bounce - f.talk * 2 + mouthH / 2)
        var mouth = ctx
        mouth.translateBy(x: mouthCenter.x, y: mouthCenter.y)
        mouth.rotate(by: .radians(f.mouthTilt))
        mouth.fill(mouthPath(CGRect(x: -mouthW / 2, y: -mouthH / 2, width: mouthW, height: mouthH)), with: .color(navy))
    }
}

#if DEBUG
/// Lets Xcode previews (and a quick look on the simulator) show every mood next to the Pencil frames.
private struct MoodPreview: View {
    let mood: Mood
    @State private var animator = FaceAnimator()

    var body: some View {
        FaceView(animator: animator)
            .onAppear {
                animator.localMood = mood
                animator.awake = true
                animator.receive(FaceState(gazeX: 0.2, gazeY: -0.1, mood: mood, talk: mood == .talking ? 0.6 : 0), at: Date().timeIntervalSinceReferenceDate)
            }
    }
}

#Preview("Listening") { MoodPreview(mood: .listening) }
#Preview("Talking") { MoodPreview(mood: .talking) }
#Preview("Pointing") { MoodPreview(mood: .pointing) }
#Preview("Thinking") { MoodPreview(mood: .thinking) }
#Preview("Happy") { MoodPreview(mood: .happy) }
#Preview("Resting") { MoodPreview(mood: .resting) }
#Preview("Sleepy") { MoodPreview(mood: .sleepy) }
#endif
