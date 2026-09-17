import Darwin
import Foundation

private enum FixtureScenario {
    case response(status: Int, body: Data)
    case failure(URLError.Code)
    case redirect
    case hang
}

private final class FixtureState: @unchecked Sendable {
    let lock = NSLock()
    var scenario: FixtureScenario = .hang
    var requests: [URLRequest] = []
    var stopCount = 0
    var starts = 0
    var startWaiters: [CheckedContinuation<Void, Never>] = []
}

private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    private static let state = FixtureState()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    static func configure(_ scenario: FixtureScenario) {
        state.lock.lock()
        state.scenario = scenario
        state.requests.removeAll(keepingCapacity: false)
        state.stopCount = 0
        state.starts = 0
        state.lock.unlock()
    }

    static var requestCount: Int {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.requests.count
    }

    static var latestRequest: URLRequest? {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.requests.last
    }

    static var stoppedRequestCount: Int {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.stopCount
    }

    static func waitForStart() async {
        await withCheckedContinuation { continuation in
            state.lock.lock()
            if state.starts > 0 {
                state.lock.unlock()
                continuation.resume()
                return
            }
            state.startWaiters.append(continuation)
            state.lock.unlock()
        }
    }

    override func startLoading() {
        let scenario: FixtureScenario
        let waiters: [CheckedContinuation<Void, Never>]
        Self.state.lock.lock()
        Self.state.requests.append(request)
        Self.state.starts += 1
        scenario = Self.state.scenario
        waiters = Self.state.startWaiters
        Self.state.startWaiters.removeAll(keepingCapacity: false)
        Self.state.lock.unlock()
        for waiter in waiters { waiter.resume() }

        switch scenario {
        case .response(let status, let body):
            finish(status: status, body: body)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .redirect:
            if request.url?.host == "redirect.invalid" {
                finish(status: 200, body: Data(Self.completedResponse.utf8))
                return
            }
            let redirectURL = URL(string: "https://redirect.invalid/received")!
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": redirectURL.absoluteString]
            )!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirectURL), redirectResponse: response)
        case .hang:
            break
        }
    }

    override func stopLoading() {
        Self.state.lock.lock()
        Self.state.stopCount += 1
        Self.state.lock.unlock()
    }

    private func finish(status: Int, body: Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static let completedResponse = """
    {"status":"completed","output":[{"type":"message","status":"completed","content":[{"type":"output_text","text":"Redirected text."}]}]}
    """
}

@main
@MainActor
struct OpenAITextCleanerSmoke {
    static func check(_ condition: Bool, _ message: String) {
        guard condition else {
            print("FAIL \(message)")
            exit(1)
        }
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }

    private static func clean(
        _ scenario: FixtureScenario,
        text: String = "Um, dit is een synthetic transcript.",
        apiKey: String = "fake-key"
    ) async throws -> String {
        FixtureURLProtocol.configure(scenario)
        return try await OpenAITextCleaner(session: makeSession()).clean(text, apiKey: apiKey)
    }

    private static func expectError(
        _ expected: OpenAITextCleanerError,
        scenario: FixtureScenario,
        text: String = "Um, dit is een synthetic transcript.",
        apiKey: String = "fake-key",
        expectedRequests: Int = 1
    ) async {
        do {
            _ = try await clean(scenario, text: text, apiKey: apiKey)
            check(false, "\(expected) unexpectedly succeeded")
        } catch let error as OpenAITextCleanerError {
            check(error == expected, "expected \(expected), got \(error)")
            let description = error.localizedDescription
            check(!description.contains("synthetic provider detail"), "provider detail leaked in \(error)")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                check(!description.contains(text), "transcript leaked in \(error)")
            }
            if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                check(!description.contains(apiKey), "credential leaked in \(error)")
            }
        } catch {
            check(false, "expected \(expected), got \(error)")
        }
        check(FixtureURLProtocol.requestCount == expectedRequests, "\(expected) used an unexpected request count")
    }

    private static func response(_ json: String, status: Int = 200) -> FixtureScenario {
        .response(status: status, body: Data(json.utf8))
    }

    static func requestJSON() throws -> [String: Any] {
        guard let request = FixtureURLProtocol.latestRequest,
              let body = requestBody(from: request),
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            check(false, "request body was absent or invalid JSON")
            return [:]
        }
        return object
    }

    static func requestBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }

        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = buffer.withUnsafeMutableBufferPointer {
                stream.read($0.baseAddress!, maxLength: $0.count)
            }
            if count > 0 {
                body.append(contentsOf: buffer.prefix(count))
            } else {
                return count == 0 ? body : nil
            }
        }
    }

    static func main() async throws {
        let exactOutput = "\nDit is de gecorrigeerde tekst.\n"
        let source = "Um, dit is een synthetic transcript."
        let result = try await clean(
            response("""
            {"status":"completed","output":[{"type":"message","status":"completed","content":[{"type":"output_text","text":"\\nDit is de gecorrigeerde tekst.\\n"}]}]}
            """),
            text: source
        )
        check(result == exactOutput, "completed output was changed instead of returned exactly")

        let request = FixtureURLProtocol.latestRequest
        check(request?.url?.absoluteString == "https://api.openai.com/v1/responses", "wrong Responses endpoint")
        check(request?.httpMethod == "POST", "Responses request was not POST")
        check(request?.value(forHTTPHeaderField: "Authorization") == "Bearer fake-key", "authorization was not serialized")
        let payload = try requestJSON()
        check(payload["model"] as? String == "gpt-5.6-terra", "wrong model")
        check(payload["store"] as? Bool == false, "request storage was not disabled")
        check(payload["tools"] == nil, "request unexpectedly included tools")
        check((payload["reasoning"] as? [String: Any])?["effort"] as? String == "none", "wrong reasoning effort")
        check(payload["max_output_tokens"] as? Int == OpenAITextCleaner.maximumOutputTokens, "wrong output limit")
        guard let input = payload["input"] as? [[String: Any]], input.count == 2,
              let developerContent = input[0]["content"] as? [[String: String]],
              let transcriptContent = input[1]["content"] as? [[String: String]] else {
            check(false, "request did not serialize the two-message input")
            return
        }
        check(input[0]["role"] as? String == "developer", "developer instruction was not serialized")
        check(developerContent.first?["type"] == "input_text", "developer content had the wrong type")
        check(input[1]["role"] as? String == "user", "transcript data was not serialized as user input")
        check(transcriptContent.first?["type"] == "input_text", "transcript content had the wrong type")
        check(transcriptContent.first?["text"]?.contains(source) == true, "transcript text was not serialized")

        let errorBody = """
        {"error":{"message":"synthetic provider detail","type":"test_error"}}
        """
        await expectError(.missingAPIKey, scenario: .hang, apiKey: "   ", expectedRequests: 0)
        await expectError(.emptyInput, scenario: .hang, text: "", expectedRequests: 0)
        await expectError(
            .inputTooLarge,
            scenario: .hang,
            text: String(repeating: "x", count: OpenAITextCleaner.maximumInputUTF8Bytes + 1),
            expectedRequests: 0
        )
        await expectError(.authenticationFailed, scenario: response(errorBody, status: 401))
        await expectError(.authenticationFailed, scenario: response(errorBody, status: 403))
        await expectError(.quotaExceeded, scenario: response(errorBody, status: 402))
        await expectError(.rateOrQuotaLimited, scenario: response(errorBody, status: 429))
        await expectError(.inputTooLarge, scenario: response(errorBody, status: 413))
        await expectError(.timedOut, scenario: response(errorBody, status: 504))
        await expectError(.requestFailed, scenario: response(errorBody, status: 500))
        await expectError(.timedOut, scenario: .failure(.timedOut))
        await expectError(.networkFailed, scenario: .failure(.notConnectedToInternet))
        await expectError(.malformedResponse, scenario: response("{"))
        await expectError(.incompleteResponse, scenario: response("{\"status\":\"incomplete\",\"output\":[]}"))
        await expectError(
            .incompleteResponse,
            scenario: response("{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"status\":\"in_progress\",\"content\":[]}]}")
        )
        await expectError(
            .refusedResponse,
            scenario: response("{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"status\":\"completed\",\"content\":[{\"type\":\"refusal\",\"refusal\":\"synthetic provider detail\"}]}]}")
        )
        await expectError(
            .emptyOutput,
            scenario: response("{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"status\":\"completed\",\"content\":[]}]}")
        )

        await expectError(.redirectRejected, scenario: .redirect)
        check(FixtureURLProtocol.requestCount == 1, "redirect followed with the transcript")

        FixtureURLProtocol.configure(.hang)
        let cancellation = Task {
            try await OpenAITextCleaner(session: makeSession()).clean("Cancellation fixture.", apiKey: "fake-key")
        }
        await FixtureURLProtocol.waitForStart()
        cancellation.cancel()
        do {
            _ = try await cancellation.value
            check(false, "canceled request unexpectedly succeeded")
        } catch is CancellationError {
            check(FixtureURLProtocol.stoppedRequestCount > 0, "cancellation did not reach URLSession")
        } catch {
            check(false, "cancellation became \(error)")
        }

        print("PASS OpenAI text cleaner serializes one bounded Responses request and preserves failure boundaries")
    }
}
