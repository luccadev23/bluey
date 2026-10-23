import Foundation
import GooglyShared

public struct WebSearchProviderInfo: Equatable, Sendable {
    public let id: String
    public let title: String
    public let credentialID: String
    public init(id: String, title: String, credentialID: String) {
        self.id = id; self.title = title; self.credentialID = credentialID
    }
}

public struct WebSearchProviderResponse: Sendable {
    public var answer: WebSearchAnswer?
    public var sources: [WebSearchSource]
    public var limitations: [String]
    public var requestID: String?
    public var costUSD: Double?
    public init(answer: WebSearchAnswer? = nil, sources: [WebSearchSource], limitations: [String] = [],
                requestID: String? = nil, costUSD: Double? = nil) {
        self.answer = answer; self.sources = sources; self.limitations = limitations
        self.requestID = requestID; self.costUSD = costUSD
    }
}

public protocol WebSearchProvider {
    var info: WebSearchProviderInfo { get }
    func search(_ request: WebSearchRequest, apiKey: String) async throws -> WebSearchProviderResponse
}

public struct WebSearchProviderError: Error {
    public let code: WebSearchIssue.Code
    public let requestID: String?
    public let costUSD: Double?
    public init(_ code: WebSearchIssue.Code, requestID: String? = nil, costUSD: Double? = nil) {
        self.code = code; self.requestID = requestID; self.costUSD = costUSD
    }
}

/// Selection is captured per request. No fallback, retries, or dependency on the conversation provider.
public struct WebSearchService {
    private let providers: [any WebSearchProvider]
    public var availableProviders: [WebSearchProviderInfo] { providers.map(\.info) }
    public init(providers: [any WebSearchProvider]) { self.providers = providers }

    public func unavailable(_ request: WebSearchRequest, selected: String?, apiKey: String?) -> WebSearchResult? {
        let code: WebSearchIssue.Code
        if providers.isEmpty { code = .noProviders }
        else if selected == nil { code = .disabled }
        else if !providers.contains(where: { $0.info.id == selected }) { code = .noProviders }
        else if apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { code = .missingKey }
        else { return nil }
        return failure(request, selected: selected, code: code, status: .unavailable)
    }

    public func search(_ request: WebSearchRequest, selected: String?, apiKey: String?) async -> WebSearchResult {
        if let result = unavailable(request, selected: selected, apiKey: apiKey) { return result }
        guard !request.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return failure(request, selected: selected, code: .invalidRequest)
        }
        guard let provider = providers.first(where: { $0.info.id == selected }), let apiKey else {
            return failure(request, selected: selected, code: .noProviders, status: .unavailable)
        }
        do {
            try Task.checkCancellation()
            let response = try await provider.search(request, apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
            try Task.checkCancellation()
            var seen = Set<String>()
            let sources = response.sources.compactMap { source -> WebSearchSource? in
                guard var url = URLComponents(url: source.url, resolvingAgainstBaseURL: false),
                      ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                      let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
                url.scheme = url.scheme?.lowercased(); url.host = host.lowercased(); url.fragment = nil
                url.queryItems = url.queryItems?.filter { !$0.name.lowercased().hasPrefix("utm_") }
                if url.queryItems?.isEmpty == true { url.queryItems = nil }
                guard let cleaned = url.url, seen.insert(cleaned.absoluteString).inserted else { return nil }
                let title = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let excerpt = source.excerpt?.trimmingCharacters(in: .whitespacesAndNewlines)
                return WebSearchSource(id: "source-\(seen.count)", title: title.isEmpty ? host.lowercased() : title,
                    url: cleaned, excerpt: excerpt?.isEmpty == false ? excerpt : nil, publishedDate: source.publishedDate)
            }
            let answer = response.answer.map { WebSearchAnswer(
                title: $0.title.trimmingCharacters(in: .whitespacesAndNewlines),
                paragraphs: $0.paragraphs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }) }
            guard !sources.isEmpty, answer.map({
                !$0.title.isEmpty && $0.title.split(whereSeparator: \.isWhitespace).count < 8
                    && !$0.title.contains("\n") && (1...4).contains($0.paragraphs.count)
                    && $0.paragraphs.allSatisfy { !$0.isEmpty }
            }) ?? true else {
                return failure(request, selected: selected, code: .invalidResponse,
                               requestID: response.requestID, costUSD: response.costUSD)
            }
            return WebSearchResult(request: request, provider: selected, status: answer == nil ? .partial : .success,
                answer: answer, sources: sources, limitations: response.limitations,
                providerRequestID: response.requestID, costUSD: response.costUSD)
        } catch let error as WebSearchProviderError {
            return failure(request, selected: selected, code: error.code, requestID: error.requestID, costUSD: error.costUSD)
        } catch is CancellationError {
            return failure(request, selected: selected, code: .cancelled)
        } catch let error as URLError {
            return failure(request, selected: selected, code: error.code == .timedOut ? .timeout : .network)
        } catch {
            return failure(request, selected: selected, code: .providerFailure)
        }
    }

    private func failure(_ request: WebSearchRequest, selected: String?, code: WebSearchIssue.Code,
                         status: WebSearchResult.Status = .failure, requestID: String? = nil,
                         costUSD: Double? = nil) -> WebSearchResult {
        let name = availableProviders.first(where: { $0.id == selected })?.title ?? selected ?? "Web Search"
        let pt = request.language.hasPrefix("pt")
        let message: String
        switch code {
        case .disabled: message = pt
            ? "Minha pesquisa na web está desativada. Você pode ativá-la em Web Search no menu do Bluey."
            : "My web search is disabled. You can enable it under Web Search in Bluey's menu."
        case .noProviders: message = pt
            ? "A pesquisa na web não está disponível: nenhum provedor de pesquisa está integrado ou o provedor selecionado não está disponível."
            : "Web search is unavailable: no search provider is integrated, or the selected provider is unavailable."
        case .missingKey: message = pt
            ? "Minha pesquisa na web ainda não está configurada. Adicione a API key do \(name) em Web Search no menu do Bluey."
            : "My web search is not configured yet. Add the \(name) API key under Web Search in Bluey's menu."
        case .invalidKey: message = pt
            ? "O \(name) recusou a chave de pesquisa. Verifique a API key em Web Search no menu do Bluey."
            : "\(name) rejected the search key. Check the API key under Web Search in Bluey's menu."
        case .creditsExhausted: message = pt
            ? "Os créditos de pesquisa do \(name) acabaram. Verifique seu saldo no provedor."
            : "\(name)'s search credits are exhausted. Check your balance with the provider."
        case .rateLimited: message = pt
            ? "O \(name) atingiu o limite de requisições. Tente a pesquisa novamente mais tarde."
            : "\(name)'s request limit was reached. Try the search again later."
        case .timeout: message = pt ? "A pesquisa demorou demais e foi interrompida. Tente novamente." : "The search timed out. Please try again."
        case .network: message = pt ? "Não consegui conectar ao serviço de pesquisa. Verifique a conexão." : "I couldn't connect to the search service. Check your connection."
        case .invalidResponse: message = pt ? "A pesquisa não trouxe uma resposta válida com fontes verificáveis." : "The search did not return a valid response with usable sources."
        case .invalidRequest: message = pt ? "O que você gostaria que eu pesquisasse?" : "What would you like me to research?"
        case .cancelled: message = pt ? "A pesquisa foi cancelada." : "The search was cancelled."
        case .providerFailure: message = pt ? "O serviço de pesquisa está indisponível no momento. Tente novamente mais tarde." : "The search service is currently unavailable. Try again later."
        }
        return WebSearchResult(request: request, provider: selected, status: status,
            error: WebSearchIssue(code: code, message: message), providerRequestID: requestID, costUSD: costUSD)
    }
}
