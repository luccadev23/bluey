import Foundation

/// Which realtime service runs his voice session.
public enum VoiceProvider: String, CaseIterable, Codable {
    case openai, gemini

    public var title: String {
        switch self {
        case .openai: return "OpenAI"
        case .gemini: return "Gemini"
        }
    }
}
