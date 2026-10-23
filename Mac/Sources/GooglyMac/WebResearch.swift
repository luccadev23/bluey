import Foundation
import GooglyShared
import BlueyWebSearch
import OSLog

/// The menu and tool share this registry. Adding a provider does not change the tool or its output.
@MainActor
enum WebResearch {
    static let service = WebSearchService(providers: [ExaWebSearchProvider()])
    private static let logger = Logger(subsystem: "dev.luccabonim.bluey", category: "WebSearch")

    static func credentialSlot(for provider: WebSearchProviderInfo) -> Keychain.Key {
        .init(rawValue: provider.credentialID)!
    }

    static func research(_ request: WebSearchRequest, onStart: () -> Void) async -> WebSearchResult {
        // Capture settings before suspending: a menu change cannot redirect an in-flight call.
        let selected = Settings.shared.webSearchProvider
        let key = service.availableProviders.first(where: { $0.id == selected })
            .flatMap { Keychain.get(credentialSlot(for: $0)) }
        let start = Date()
        let result: WebSearchResult
        if let unavailable = service.unavailable(request, selected: selected, apiKey: key) {
            result = unavailable
        } else {
            if !request.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { onStart() }
            result = await service.search(request, selected: selected, apiKey: key)
        }
        let duration = Int(Date().timeIntervalSince(start) * 1000)
        // Metadata only: never keys, questions, screen contents, or raw provider error bodies.
        logger.info("request=\(request.id.uuidString, privacy: .public) provider=\(selected ?? "disabled", privacy: .public) status=\(result.status.rawValue, privacy: .public) error=\(result.error?.code.rawValue ?? "none", privacy: .public) duration_ms=\(duration) cost_usd=\(result.costUSD.map { String($0) } ?? "unknown", privacy: .public) provider_request=\(result.providerRequestID ?? "unknown", privacy: .public)")
        return result
    }
}
