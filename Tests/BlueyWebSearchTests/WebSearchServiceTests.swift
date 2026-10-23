import XCTest
import GooglyShared
@testable import BlueyWebSearch

final class WebSearchServiceTests: XCTestCase {
    private final class Provider: WebSearchProvider {
        let info = WebSearchProviderInfo(id: "test", title: "Test", credentialID: "test-key")
        var calls = 0
        var response = WebSearchProviderResponse(sources: [])
        var error: Error?
        func search(_ request: WebSearchRequest, apiKey: String) async throws -> WebSearchProviderResponse {
            calls += 1
            if let error { throw error }
            return response
        }
    }
    private let request = WebSearchRequest(question: "notícias", language: "pt-BR")
    private let source = WebSearchSource(id: "1", title: "Source", url: URL(string: "https://example.com/news")!, excerpt: "Verified excerpt")

    func testUnavailableStatesNeverCallAnyProvider() async {
        let provider = Provider()
        let service = WebSearchService(providers: [provider])
        for (selected, key, expected) in [
            (nil, "key", WebSearchIssue.Code.disabled),
            ("test", nil, .missingKey), ("test", "  ", .missingKey), ("absent", "key", .noProviders)
        ] as [(String?, String?, WebSearchIssue.Code)] {
            let result = await service.search(request, selected: selected, apiKey: key)
            XCTAssertEqual(result.status, .unavailable)
            XCTAssertEqual(result.error?.code, expected)
            XCTAssertNil(result.answer)
        }
        let empty = await WebSearchService(providers: []).search(request, selected: "test", apiKey: "key")
        XCTAssertEqual(empty.error?.code, .noProviders)
        XCTAssertEqual(provider.calls, 0)
    }

    func testEmptyQuestionDoesNotCallProvider() async {
        let provider = Provider()
        let result = await WebSearchService(providers: [provider]).search(WebSearchRequest(question: " \n "), selected: "test", apiKey: "key")
        XCTAssertEqual(result.error?.code, .invalidRequest)
        XCTAssertEqual(provider.calls, 0)
    }

    func testEvidenceOnlyProviderNeedsNoChangesToContractOrConsumer() async throws {
        let provider = Provider()
        provider.response = WebSearchProviderResponse(sources: [source], limitations: ["No summary available"])
        let result = await WebSearchService(providers: [provider]).search(request, selected: "test", apiKey: "key")
        XCTAssertEqual(result.status, .partial)
        XCTAssertNil(result.answer)
        XCTAssertEqual(result.sources.first?.excerpt, "Verified excerpt")
        XCTAssertTrue(result.plainText.contains("No summary available"))
        XCTAssertEqual(WebSearchResult.decode(try result.encoded()), result)
    }

    func testSuccessfulAnswerIsNormalizedAndSourcesAreValidatedAndDeduplicated() async {
        let provider = Provider()
        provider.response = WebSearchProviderResponse(answer: WebSearchAnswer(title: " Title ", paragraphs: [" Answer "]), sources: [
            WebSearchSource(id: "x", title: " ", url: URL(string: "https://EXAMPLE.com/news?utm_source=exa#top")!),
            source,
            WebSearchSource(id: "bad", title: "Bad", url: URL(string: "file:///etc/passwd")!),
            WebSearchSource(id: "bad", title: "Bad", url: URL(string: "javascript:alert(1)")!),
            WebSearchSource(id: "bad", title: "Bad", url: URL(string: "https://user:password@example.org/")!)
        ], requestID: "request-1", costUSD: 0.005)
        let result = await WebSearchService(providers: [provider]).search(request, selected: "test", apiKey: "key")
        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.answer?.title, "Title")
        XCTAssertEqual(result.answer?.paragraphs, ["Answer"])
        XCTAssertEqual(result.sources.count, 1)
        XCTAssertEqual(result.sources.first?.url.absoluteString, "https://example.com/news")
        XCTAssertEqual(result.sources.first?.title, "example.com")
        XCTAssertEqual(result.costUSD, 0.005)
        XCTAssertEqual(result.providerRequestID, "request-1")
    }

    func testInvalidAnswersOrNoSourcesCannotBecomeSuccessfulReports() async {
        let provider = Provider()
        let service = WebSearchService(providers: [provider])
        for answer in [WebSearchAnswer(title: "", paragraphs: ["text"]),
                       WebSearchAnswer(title: "Title", paragraphs: []),
                       WebSearchAnswer(title: "Title", paragraphs: [" "]),
                       WebSearchAnswer(title: "Title", paragraphs: Array(repeating: "text", count: 5)),
                       WebSearchAnswer(title: "one two three four five six seven eight", paragraphs: ["text"])] {
            provider.response = WebSearchProviderResponse(answer: answer, sources: [source])
            let result = await service.search(request, selected: "test", apiKey: "key")
            XCTAssertEqual(result.error?.code, .invalidResponse)
            XCTAssertNil(result.answer)
        }
        provider.response = WebSearchProviderResponse(answer: WebSearchAnswer(title: "Title", paragraphs: ["Answer"]), sources: [])
        let result = await service.search(request, selected: "test", apiKey: "key")
        XCTAssertEqual(result.error?.code, .invalidResponse)
    }

    func testErrorsAreMappedWithoutRetriesOrLeakingProviderMessages() async {
        let provider = Provider()
        let service = WebSearchService(providers: [provider])
        let errors: [(Error, WebSearchIssue.Code)] = [
            (URLError(.timedOut), .timeout), (URLError(.notConnectedToInternet), .network),
            (CancellationError(), .cancelled),
            (WebSearchProviderError(.creditsExhausted, requestID: "id"), .creditsExhausted),
            (NSError(domain: "secret-raw-input", code: 999), .providerFailure)
        ]
        for (error, expected) in errors {
            provider.error = error
            let result = await service.search(request, selected: "test", apiKey: "secret-key")
            XCTAssertEqual(result.status, .failure)
            XCTAssertEqual(result.error?.code, expected)
            XCTAssertFalse(result.plainText.contains("secret"))
        }
        XCTAssertEqual(provider.calls, errors.count)
    }
}
