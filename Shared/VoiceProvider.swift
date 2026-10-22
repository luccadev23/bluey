import Foundation

/// Which service handles text conversations. Speech recognition is shared by every provider.
public enum VoiceProvider: String, CaseIterable, Codable {
    case openai, gemini

    public var title: String {
        switch self {
        case .openai: return "OpenAI"
        case .gemini: return "Gemini"
        }
    }

    public var textConversation: any TextConversationAdapter {
        switch self {
        case .openai: return OpenAITextConversation()
        case .gemini: return GeminiTextConversation()
        }
    }
}
