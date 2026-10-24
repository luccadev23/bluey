import Foundation

/// Blueberry colors from the design canvas, as 0xRRGGBB.
public enum Palette {
    public static let berry1: UInt32 = 0xA9BCFF  // light periwinkle
    public static let berry2: UInt32 = 0x6C86F5
    public static let berry3: UInt32 = 0x4254D6
    public static let berry4: UInt32 = 0x2B2F8F  // deep indigo
    public static let nose: UInt32 = 0x1C1F66
    public static let ink: UInt32 = 0x17151F
    public static let inkSoft: UInt32 = 0xB9B2CC
    public static let panel: UInt32 = 0x1E1B29

    // Status and mode colors used around the app.
    public static let modeBlue: UInt32 = 0x4F8BFF  // listening / holding to ask
    public static let modeYellow: UInt32 = 0xFFD66B  // waking up
    public static let modePurple: UInt32 = 0xC79BFF  // thinking
    public static let modePink: UInt32 = 0xFF9AD0  // replying
    public static let online: UInt32 = 0x5BE49B
    public static let danger: UInt32 = 0xE5547A
    public static let reportPanel: UInt32 = 0x1B2145
    public static let reportText: UInt32 = 0xE4E6FF

    public static let gradient: [UInt32] = [berry1, berry2, berry3, berry4]
    public static let gradientStops: [Double] = [0, 0.34, 0.68, 1]

    public static func rgb(_ hex: UInt32) -> (r: Double, g: Double, b: Double) {
        (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }
}
