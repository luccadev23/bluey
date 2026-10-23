import Foundation

/// The provider-independent request. Screen context is untrusted reference material.
public struct WebSearchRequest: Codable, Equatable, Sendable {
    public let id: UUID
    public let question: String
    public let context: String?
    public let language: String
    public let date: Date

    public init(id: UUID = UUID(), question: String, context: String? = nil,
                language: String = Locale.current.identifier, date: Date = Date()) {
        self.id = id; self.question = question; self.context = context
        let tag = language.trimmingCharacters(in: .whitespacesAndNewlines)
        self.language = tag.count <= 64 && tag.range(of: #"^[A-Za-z]{2,3}(?:[-_][A-Za-z0-9]{2,8})*$"#,
            options: .regularExpression) != nil ? tag : "en"
        // The wire format uses ISO 8601 seconds. Keep equality stable across Mac/phone serialization.
        self.date = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }
}

public struct WebSearchAnswer: Codable, Equatable, Sendable {
    public let title: String
    public let paragraphs: [String]
    public init(title: String, paragraphs: [String]) {
        self.title = title; self.paragraphs = paragraphs
    }
}

public struct WebSearchSource: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let url: URL
    public let excerpt: String?
    /// Preserves the provider's date, including its original precision. Never inferred.
    public let publishedDate: String?
    public init(id: String, title: String, url: URL, excerpt: String? = nil, publishedDate: String? = nil) {
        self.id = id; self.title = title; self.url = url
        self.excerpt = excerpt; self.publishedDate = publishedDate
    }
}

public struct WebSearchIssue: Codable, Equatable, Sendable {
    public enum Code: String, Codable, Sendable {
        case disabled, noProviders, missingKey, invalidKey, creditsExhausted, rateLimited
        case timeout, network, invalidResponse, providerFailure, invalidRequest, cancelled
    }
    public let code: Code
    public let message: String
    public init(code: Code, message: String) { self.code = code; self.message = message }
}

/// Tool data only. Agent behavior is defined in the tool guide, never mixed into this payload.
public struct WebSearchResult: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case success, partial, unavailable, failure }
    public let kind: String
    public let version: Int
    public let requestID: UUID
    public let provider: String?
    public let status: Status
    public let question: String
    public let language: String
    public let searchedAt: Date
    public let answer: WebSearchAnswer?
    public let sources: [WebSearchSource]
    public let limitations: [String]
    public let error: WebSearchIssue?
    public let providerRequestID: String?
    public let costUSD: Double?

    public init(request: WebSearchRequest, provider: String?, status: Status,
                answer: WebSearchAnswer? = nil, sources: [WebSearchSource] = [],
                limitations: [String] = [], error: WebSearchIssue? = nil,
                providerRequestID: String? = nil, costUSD: Double? = nil) {
        self.kind = "web_search_result"; self.version = 1; self.requestID = request.id
        self.provider = provider; self.status = status; self.question = request.question
        self.language = request.language; self.searchedAt = request.date
        self.answer = answer; self.sources = sources; self.limitations = limitations
        self.error = error; self.providerRequestID = providerRequestID
        self.costUSD = costUSD.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }

    public func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    public static func decode(_ text: String) -> WebSearchResult? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let result = try? decoder.decode(Self.self, from: Data(text.utf8)),
              result.kind == "web_search_result", result.version == 1 else { return nil }
        return result
    }

    public var title: String {
        answer?.title ?? (language.hasPrefix("pt") ? "Pesquisa na web" : "Web research")
    }

    /// The same readable presentation is used by the Mac card and phone history.
    public var displayParagraphs: [String] {
        if let error { return [error.message] }
        var paragraphs = answer?.paragraphs ?? []
        if answer == nil {
            paragraphs.append(language.hasPrefix("pt")
                ? "Estas são as fontes encontradas; não há um relatório pronto. Links sem trechos não confirmam o conteúdo das páginas."
                : "These are the sources found; no report was generated. Links without excerpts do not confirm page contents.")
            paragraphs += sources.compactMap { source in
                source.excerpt.map { "\(source.title): \($0)" }
            }
        }
        return paragraphs + limitations
    }

    public var plainText: String {
        var blocks = [title] + displayParagraphs
        if !sources.isEmpty {
            blocks.append((language.hasPrefix("pt") ? "Fontes" : "Sources") + "\n" + sources.map {
                "\($0.title)\($0.publishedDate.map { " (\($0))" } ?? "")\n\($0.url.absoluteString)"
            }.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n")
    }

    /// Older Macs used a marker followed by a human-readable report. Existing sessions stay unchanged.
    public static func reportText(from toolOutput: String) -> String? {
        if let result = decode(toolOutput) { return result.plainText }
        guard let marker = toolOutput.range(of: "\n---REPORT---\n") else { return nil }
        return String(toolOutput[marker.upperBound...])
    }
}
