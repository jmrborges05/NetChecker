import Foundation

// MARK: - WebSocket

/// WebSocket message
public struct WebSocketMessage: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let direction: Direction
    public let type: MessageType
    public let stringData: String?
    public let binaryData: Data?

    public enum Direction: String, Codable, Sendable, Hashable {
        case sent
        case received
    }

    public enum MessageType: Int, Codable, Sendable, Hashable {
        case data = 0
        case string = 1
    }
    
    public init(id: UUID = UUID(), timestamp: Date = Date(), direction: Direction, type: MessageType, stringData: String? = nil, binaryData: Data? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.direction = direction
        self.type = type
        self.stringData = stringData
        self.binaryData = binaryData
    }
}

/// Traffic record state
public enum TrafficRecordState: Codable, Sendable, Hashable {
    case pending
    case completed
    case failed(TrafficError)
    case cancelled
    case mocked

    public var displayName: String {
        switch self {
        case .pending: return "Pending"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .mocked: return "Mocked"
        }
    }

    public var systemImage: String {
        switch self {
        case .pending: return "clock"
        case .completed: return "checkmark.circle"
        case .failed: return "xmark.circle"
        case .cancelled: return "nosign"
        case .mocked: return "theatermasks"
        }
    }

    public var isFinished: Bool {
        switch self {
        case .pending:
            return false
        case .completed, .failed, .cancelled, .mocked:
            return true
        }
    }
}

/// Full network request record
public struct TrafficRecord: Codable, Sendable, Identifiable, Hashable {
    // MARK: - Identity

    /// Unique identifier
    public let id: UUID

    /// Request start timestamp
    public let timestamp: Date

    // MARK: - State

    /// Total request duration
    public var duration: TimeInterval

    /// Record state
    public var state: TrafficRecordState

    // MARK: - Request/Response

    /// Request data
    public let request: RequestData

    /// Response data (nil if pending/failed)
    public var response: ResponseData?

    // MARK: - Timing & Security

    /// Detailed timings
    public var timings: RequestTimings?

    /// Security information
    public var security: SecurityInfo?

    // MARK: - Error & Metadata

    /// Error (if state == .failed)
    public var error: TrafficError?

    /// Metadata
    public var metadata: TrafficMetadata

    /// Redirect history
    public var redirects: [RedirectHop]

    /// WebSocket messages
    public var webSocketMessages: [WebSocketMessage] = []

    // MARK: - Initialization

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        duration: TimeInterval = 0,
        state: TrafficRecordState = .pending,
        request: RequestData,
        response: ResponseData? = nil,
        timings: RequestTimings? = nil,
        security: SecurityInfo? = nil,
        error: TrafficError? = nil,
        metadata: TrafficMetadata? = nil,
        redirects: [RedirectHop] = []
    ) {
        self.id = id
        self.timestamp = timestamp
        self.duration = duration
        self.state = state
        self.request = request
        self.response = response
        self.timings = timings
        self.security = security
        self.error = error
        self.metadata = metadata ?? TrafficMetadata(from: request.url)
        self.redirects = redirects
    }

    /// Create from URLRequest
    public init(from urlRequest: URLRequest) {
        self.id = UUID()
        self.timestamp = Date()
        self.duration = 0
        self.state = .pending
        self.request = RequestData(from: urlRequest)
        self.response = nil
        self.timings = nil
        self.security = nil
        self.error = nil
        self.metadata = TrafficMetadata(from: urlRequest.url ?? URL(string: "about:blank")!)
        self.redirects = []
    }

    // MARK: - Computed Properties

    /// Request URL
    public var url: URL {
        request.url
    }

    /// HTTP method
    public var method: HTTPMethod {
        request.method
    }

    /// Response status code
    public var statusCode: Int? {
        response?.statusCode
    }

    /// Status category
    public var statusCategory: StatusCategory? {
        response?.statusCategory
    }

    /// Host
    public var host: String {
        metadata.host
    }

    /// Path
    public var path: String {
        metadata.path
    }

    /// Whether the request succeeded
    public var isSuccess: Bool {
        if case .completed = state {
            return response?.isSuccess ?? false
        }
        return false
    }

    /// Whether the request is an error
    public var isError: Bool {
        if case .failed = state { return true }
        return response?.isError ?? false
    }

    /// Formatted duration
    public var formattedDuration: String {
        formatDuration(duration)
    }

    /// Request size
    public var requestSize: Int64 {
        request.bodySize
    }

    /// Response size
    public var responseSize: Int64 {
        response?.bodySize ?? 0
    }

    /// Total size
    public var totalSize: Int64 {
        requestSize + responseSize
    }

    /// Formatted response size
    public var formattedResponseSize: String {
        ByteCountFormatter.string(fromByteCount: responseSize, countStyle: .file)
    }

    /// Composite ID that includes state for SwiftUI diffing
    /// This ensures the row updates when the record state changes
    public var compositeId: String {
        "\(id.uuidString)-\(state.displayName)-\(statusCode ?? 0)"
    }

    /// Short description for list display
    public var shortDescription: String {
        "\(method.rawValue) \(path)"
    }

    /// Full description
    public var fullDescription: String {
        var desc = "\(method.rawValue) \(url.absoluteString)"
        if let status = statusCode {
            desc += " → \(status)"
        }
        desc += " (\(formattedDuration))"
        return desc
    }

    // MARK: - Mutating Methods

    /// Complete the request with a response
    public mutating func complete(
        with response: ResponseData,
        timings: RequestTimings? = nil,
        security: SecurityInfo? = nil
    ) {
        self.response = response
        self.timings = timings
        self.security = security
        self.duration = Date().timeIntervalSince(timestamp)
        self.state = .completed
    }

    /// Mark as failed
    public mutating func fail(with error: Error) {
        self.error = TrafficError(from: error)
        self.duration = Date().timeIntervalSince(timestamp)
        self.state = .failed(self.error!)
    }

    /// Mark as cancelled
    public mutating func cancel() {
        self.duration = Date().timeIntervalSince(timestamp)
        self.state = .cancelled
    }

    /// Mark as mocked
    public mutating func markAsMocked() {
        self.state = .mocked
    }

    /// Add a redirect hop
    public mutating func addRedirect(_ hop: RedirectHop) {
        redirects.append(hop)
    }

    /// Add a WebSocket message
    public mutating func addWebSocketMessage(_ message: WebSocketMessage) {
        webSocketMessages.append(message)
    }

    // MARK: - Private

    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 0.001 {
            return "<1 ms"
        } else if duration < 1 {
            return String(format: "%.0f ms", duration * 1000)
        } else if duration < 60 {
            return String(format: "%.2f s", duration)
        } else {
            let minutes = Int(duration / 60)
            let seconds = duration.truncatingRemainder(dividingBy: 60)
            return String(format: "%d min %.0f s", minutes, seconds)
        }
    }
}

// MARK: - Hashable

extension TrafficRecord {
    public static func == (lhs: TrafficRecord, rhs: TrafficRecord) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Comparable by Timestamp

extension TrafficRecord: Comparable {
    public static func < (lhs: TrafficRecord, rhs: TrafficRecord) -> Bool {
        lhs.timestamp < rhs.timestamp
    }
}
