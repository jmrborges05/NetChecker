import Foundation
import Combine

/// Central store for traffic records
@MainActor
public final class TrafficStore: ObservableObject {
    // MARK: - Singleton

    /// Shared instance
    public static let shared = TrafficStore()

    // MARK: - Published Properties

    /// All records
    @Published public private(set) var records: [TrafficRecord] = []

    /// Record count (derived, no extra notification)
    public var count: Int { records.count }

    /// Error count (derived, no extra notification)
    public var errorCount: Int { _errorCount }
    private var _errorCount: Int = 0

    /// Pending request count (derived, no extra notification)
    public var pendingCount: Int { _pendingCount }
    private var _pendingCount: Int = 0

    // MARK: - Configuration

    /// Maximum number of records (ring buffer)
    public var maxRecords: Int = 1000

    /// Whether recording is enabled
    public var isRecordingEnabled: Bool = true

    // MARK: - Private Properties

    private var recordsById: [UUID: Int] = [:]
    private let queue = DispatchQueue(label: "com.netchecker.trafficstore", qos: .utility)

    // MARK: - Callbacks

    /// Callback on new record added
    public var onNewRecord: ((TrafficRecord) -> Void)?

    /// Callback on record updated
    public var onRecordUpdated: ((TrafficRecord) -> Void)?

    /// Callback on error
    public var onError: ((TrafficRecord) -> Void)?

    // MARK: - Publishers

    /// Publisher for record changes
    public var recordsPublisher: AnyPublisher<[TrafficRecord], Never> {
        $records.eraseToAnyPublisher()
    }

    // MARK: - Initialization

    public init(maxRecords: Int = 1000) {
        self.maxRecords = maxRecords
    }

    // MARK: - Public Methods

    /// Add a new record
    public func add(_ record: TrafficRecord) {
        guard isRecordingEnabled else { return }

        // Ring buffer — remove oldest records
        while records.count >= maxRecords {
            let removed = records.removeFirst()
            recordsById.removeValue(forKey: removed.id)
        }

        records.append(record)
        recordsById[record.id] = records.count - 1

        updateCounts()
        onNewRecord?(record)
    }

    /// Update an existing record
    public func update(_ record: TrafficRecord) {
        guard let index = recordsById[record.id], index < records.count else {
            // Record not found, add it
            add(record)
            return
        }

        // Must explicitly notify - in-place array mutation may not trigger @Published
        objectWillChange.send()
        records[index] = record
        updateCounts()
        onRecordUpdated?(record)

        if case .failed = record.state {
            onError?(record)
        }
    }

    /// Update a record by ID
    public func update(id: UUID, with modifier: (inout TrafficRecord) -> Void) {
        guard let index = recordsById[id], index < records.count else { return }

        var record = records[index]
        modifier(&record)

        // Must explicitly notify - in-place array mutation may not trigger @Published
        objectWillChange.send()
        records[index] = record

        updateCounts()
        onRecordUpdated?(record)

        if case .failed = record.state {
            onError?(record)
        }
    }

    /// Complete a record with a response
    public func complete(
        id: UUID,
        response: ResponseData,
        timings: RequestTimings? = nil,
        security: SecurityInfo? = nil
    ) {
        update(id: id) { record in
            record.complete(with: response, timings: timings, security: security)
        }
    }

    /// Mark a record as failed
    public func fail(id: UUID, error: Error) {
        update(id: id) { record in
            record.fail(with: error)
        }
    }

    /// Add a WebSocket message to a record
    public func addWebSocketMessage(id: UUID, message: WebSocketMessage) {
        update(id: id) { record in
            record.addWebSocketMessage(message)
        }
    }

    /// Get a record by ID
    public func record(for id: UUID) -> TrafficRecord? {
        guard let index = recordsById[id], index < records.count else { return nil }
        return records[index]
    }

    /// Clear all records
    public func clear() {
        records.removeAll()
        recordsById.removeAll()
        updateCounts()
    }

    /// Remove records matching a filter
    public func remove(matching filter: TrafficFilter) {
        let filtered = filter.apply(to: records)
        let idsToRemove = Set(filtered.map { $0.id })

        records.removeAll { idsToRemove.contains($0.id) }
        rebuildIndex()
        updateCounts()
    }

    /// Remove a record by ID
    public func remove(id: UUID) {
        guard let index = recordsById[id], index < records.count else { return }
        records.remove(at: index)
        rebuildIndex()
        updateCounts()
    }

    /// Get records matching a filter
    public func records(matching filter: TrafficFilter) -> [TrafficRecord] {
        filter.apply(to: records)
    }

    /// Get the last N records
    public func lastRecords(_ count: Int) -> [TrafficRecord] {
        Array(records.suffix(count))
    }

    /// Get records within a time range
    public func records(from: Date, to: Date) -> [TrafficRecord] {
        records.filter { $0.timestamp >= from && $0.timestamp <= to }
    }

    // MARK: - AsyncStream

    /// AsyncStream for receiving new records
    public func recordsStream() -> AsyncStream<TrafficRecord> {
        AsyncStream { continuation in
            let callback = self.onNewRecord
            self.onNewRecord = { record in
                callback?(record)
                continuation.yield(record)
            }

            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor in
                    self?.onNewRecord = callback
                }
            }
        }
    }

    // MARK: - Private Methods

    private func updateCounts() {
        _errorCount = records.filter { $0.isError }.count
        _pendingCount = records.filter {
            if case .pending = $0.state { return true }
            return false
        }.count
    }

    private func rebuildIndex() {
        recordsById.removeAll()
        for (index, record) in records.enumerated() {
            recordsById[record.id] = index
        }
    }
}

// MARK: - Export

extension TrafficStore {
    /// Export records in the specified format
    public func export(format: ExportFormat, filter: TrafficFilter? = nil) -> Data? {
        let recordsToExport = filter?.apply(to: records) ?? records

        switch format {
        case .json:
            return try? JSONEncoder().encode(recordsToExport)
        case .har:
            return HARFormatter.format(records: recordsToExport)
        case .curl:
            let curls = recordsToExport.map { CURLFormatter.format(record: $0) }
            return curls.joined(separator: "\n\n---\n\n").data(using: .utf8)
        }
    }
}

/// Export format
public enum ExportFormat: String, CaseIterable, Sendable {
    case json
    case har
    case curl

    public var fileExtension: String {
        switch self {
        case .json: return "json"
        case .har: return "har"
        case .curl: return "sh"
        }
    }

    public var mimeType: String {
        switch self {
        case .json: return "application/json"
        case .har: return "application/json"
        case .curl: return "text/plain"
        }
    }
}
