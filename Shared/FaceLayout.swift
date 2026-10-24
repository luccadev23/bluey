import CoreGraphics
import Foundation

/// Where everything on Bluey's portrait face sits, in a 390 × 844 design space (the Pencil canvas).
/// The design is scaled by the screen's width and anchored to its bottom edge, so the head always
/// peeks up from the bottom and nothing is cropped on narrower or taller phones.
public enum FaceLayout {
    public static let design = CGSize(width: 390, height: 844)

    /// His body. Wider than the screen on purpose; the dome only reaches the screen edges lower down.
    public static let body = CGRect(x: -50, y: 300, width: 490, height: 620)
    /// Corner radii (top-left, top-right, bottom-right, bottom-left) of the body, in design points.
    public static let bodyRadii: [CGFloat] = [250, 230, 220, 240]

    public static let eyeCenters: [CGFloat] = [120, 270]
    /// Eyes and mouth sit 40 pt higher than when he had brows; the freed space is just forehead.
    public static let eyeY: CGFloat = 434
    public static let eyeSize = CGSize(width: 124, height: 108)
    public static let pupilRadius: CGFloat = 30
    /// How far a pupil may travel from the eye's center. Smaller than half the eye, so it never leaves the white.
    public static let gazeReach = CGSize(width: 30, height: 22)

    public static let mouthCenterX: CGFloat = 195
    public static let mouthTop: CGFloat = 544

    /// Highest point anything on the face can reach (the floating z's rise from y 330 to 262), used to keep clear of the top chrome.
    public static let topmostFeatureY: CGFloat = 262
    public static let lowestFeatureY: CGFloat = 600

    public static func scale(for size: CGSize) -> CGFloat {
        size.width > 0 ? size.width / design.width : 1
    }

    /// Screen y where the top of the design lands (negative on short phones; only empty black is cropped).
    public static func originY(for size: CGSize) -> CGFloat {
        size.height - design.height * scale(for: size)
    }

    /// Radius of the phone's own screen corners, so the mode border lines up with the glass.
    /// Keyed on the screen's native pixel height. Unknown phones get the common modern value.
    public static func screenCornerRadius(nativeHeight: Double) -> CGFloat {
        switch Int(nativeHeight.rounded()) {
        case 1334, 1920: return 0        // home-button phones
        case 2436: return 39             // X, XS, 11 Pro
        case 1792, 2688: return 41.5     // XR, 11, XS Max
        case 2340: return 44             // 12 mini, 13 mini
        case 2532: return 47.33          // 12, 13, 14
        case 2778: return 53.33          // 12/13 Pro Max
        case 2622, 2868: return 62       // 16 Pro, 16 Pro Max
        default: return 55               // 14 Pro and newer standard sizes
        }
    }
}
