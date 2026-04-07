import XCTest
@testable import NetCheckerTrafficCore

@MainActor
final class TrafficTests: XCTestCase {

    @MainActor
    func testTrafficStoreInitialization() {
        let store = TrafficStore.shared
        XCTAssertNotNil(store)
    }

    func testHTTPMethodRawValues() {
        XCTAssertEqual(HTTPMethod.get.rawValue, "GET")
        XCTAssertEqual(HTTPMethod.post.rawValue, "POST")
        XCTAssertEqual(HTTPMethod.put.rawValue, "PUT")
        XCTAssertEqual(HTTPMethod.delete.rawValue, "DELETE")
    }

    func testStatusCategoryClassification() {
        XCTAssertEqual(StatusCategory(statusCode: 200), .success)
        XCTAssertEqual(StatusCategory(statusCode: 301), .redirect)
        XCTAssertEqual(StatusCategory(statusCode: 404), .clientError)
        XCTAssertEqual(StatusCategory(statusCode: 500), .serverError)
    }

    func testContentTypeDetection() {
        let ctJson = ContentType(headers: ["Content-Type": "application/json"])
        XCTAssertEqual(ctJson, .json)
        
        let ctHtml = ContentType(headers: ["Content-Type": "text/html"])
        XCTAssertEqual(ctHtml, .html)
        
        let ctPlain = ContentType(headers: ["Content-Type": "text/plain"])
        XCTAssertEqual(ctPlain, .plainText)
    }

    func testCURLFormatting() {
        let request = RequestData(
            url: URL(string: "https://api.example.com/users")!,
            method: .get,
            headers: ["Authorization": "Bearer token123"]
        )
        let record = TrafficRecord(request: request)
        let curl = CURLFormatter.format(record: record)

        XCTAssertTrue(curl.contains("curl"))
        XCTAssertTrue(curl.contains("https://api.example.com/users"))
        XCTAssertTrue(curl.contains("Authorization"))
    }

    @MainActor
    func testWebSocketConnection() async throws {
        TrafficStore.shared.clear()
        TrafficInterceptor.shared.start(level: .basic)
        
        let url = URL(string: "wss://echo.websocket.org")!
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        
        task.resume()
        
        try await task.send(.string("Hello"))
        let response = try await task.receive()
        
        print("Response: \(response)")
        
        // Let asynchronous store updates finish
        try await Task.sleep(nanoseconds: 500_000_000)
        
        let records = TrafficStore.shared.records
        XCTAssertFalse(records.isEmpty, "Should have created a traffic record")
        
        let wsRecord = records.first(where: { $0.request.url.absoluteString.contains("echo.websocket") })
        XCTAssertNotNil(wsRecord, "Should find the WS record")
        
        if let wsRecord = wsRecord {
            XCTAssertFalse(wsRecord.webSocketMessages.isEmpty, "Should have captured WebSocket messages")
        }
        
        TrafficInterceptor.shared.stop()
    }
}
