import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        let c = Palette.rgb(hex)
        self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: opacity)
    }
}

extension Font {
    /// Rounded display face from the design. Falls back to SF Rounded until Fredoka is bundled.
    static func fredoka(_ size: CGFloat) -> Font {
        UIFontCheck.has("Fredoka") ? .custom("Fredoka", size: size).weight(.bold) : .system(size: size, weight: .bold, design: .rounded)
    }

    static func plexSans(_ size: CGFloat) -> Font {
        UIFontCheck.has("IBM Plex Sans") ? .custom("IBM Plex Sans", size: size) : .system(size: size)
    }

    static func plexMono(_ size: CGFloat) -> Font {
        UIFontCheck.has("IBM Plex Mono") ? .custom("IBM Plex Mono", size: size) : .system(size: size, design: .monospaced)
    }
}

enum UIFontCheck {
    private static let families: Set<String> = {
        #if canImport(UIKit)
        return Set(UIFont.familyNames)
        #else
        return []
        #endif
    }()

    static func has(_ family: String) -> Bool { families.contains(family) }
}

/// The blob outline: a rounded dome whose corner radii follow the Pencil design (250/230/220/240 on a 490 × 620 body).
struct BlobShape: Shape {
    func path(in rect: CGRect) -> Path {
        BlobShape.path(in: rect)
    }

    /// Corner radii as fractions of the width: top-left, top-right, bottom-right, bottom-left.
    private static let radii: [CGFloat] = FaceLayout.bodyRadii.map { $0 / FaceLayout.body.width }

    static func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        var tl = radii[0] * w, tr = radii[1] * w, br = radii[2] * w, bl = radii[3] * w
        // Keep neighbouring corners from overlapping on short or narrow shapes.
        let fit = min(1, h / max(tl + bl, 1), h / max(tr + br, 1), w / max(tl + tr, 1), w / max(bl + br, 1))
        tl *= fit; tr *= fit; br *= fit; bl *= fit
        let k: CGFloat = 0.5523  // cubic approximation of a quarter circle
        var p = Path()
        p.move(to: CGPoint(x: r.minX + tl, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - tr, y: r.minY))
        p.addCurve(to: CGPoint(x: r.maxX, y: r.minY + tr),
                   control1: CGPoint(x: r.maxX - tr * (1 - k), y: r.minY),
                   control2: CGPoint(x: r.maxX, y: r.minY + tr * (1 - k)))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - br))
        p.addCurve(to: CGPoint(x: r.maxX - br, y: r.maxY),
                   control1: CGPoint(x: r.maxX, y: r.maxY - br * (1 - k)),
                   control2: CGPoint(x: r.maxX - br * (1 - k), y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + bl, y: r.maxY))
        p.addCurve(to: CGPoint(x: r.minX, y: r.maxY - bl),
                   control1: CGPoint(x: r.minX + bl * (1 - k), y: r.maxY),
                   control2: CGPoint(x: r.minX, y: r.maxY - bl * (1 - k)))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + tl))
        p.addCurve(to: CGPoint(x: r.minX + tl, y: r.minY),
                   control1: CGPoint(x: r.minX, y: r.minY + tl * (1 - k)),
                   control2: CGPoint(x: r.minX + tl * (1 - k), y: r.minY))
        p.closeSubpath()
        return p
    }

    /// The blueberry gradient at 150°, like the design.
    static func fill(in r: CGRect) -> GraphicsContext.Shading {
        .linearGradient(gradient,
                        startPoint: CGPoint(x: r.minX + 0.25 * r.width, y: r.minY + 0.067 * r.height),
                        endPoint: CGPoint(x: r.minX + 0.75 * r.width, y: r.minY + 0.933 * r.height))
    }

    static var gradient: Gradient {
        Gradient(stops: zip(Palette.gradient, Palette.gradientStops).map {
            Gradient.Stop(color: Color(hex: $0.0), location: $0.1)
        })
    }

    static var linear: LinearGradient {
        LinearGradient(gradient: gradient, startPoint: UnitPoint(x: 0.25, y: 0.067), endPoint: UnitPoint(x: 0.75, y: 0.933))
    }
}
