import SwiftUI
import NetCheckerTrafficCore

public struct NetCheckerTrafficUI_WebSocketDetailView: View {
    let record: TrafficRecord
    
    public init(record: TrafficRecord) {
        self.record = record
    }
    
    public var body: some View {
        if record.webSocketMessages.isEmpty {
            VStack {
                Image(systemName: "network")
                    .font(.system(size: 40))
                    .foregroundColor(.secondary)
                    .padding()
                Text("No WebSocket messages captured")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.gray.opacity(0.1))
        } else {
            List {
                ForEach(record.webSocketMessages) { message in
                    WebSocketMessageRow(message: message)
                }
            }
            .listStyle(.plain)
        }
    }
}

struct WebSocketMessageRow: View {
    let message: WebSocketMessage
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if message.direction == .sent {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundColor(.green)
                    Text("Sent")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.green)
                } else {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundColor(.blue)
                    Text("Received")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.blue)
                }
                
                Spacer()
                
                Text(formatTimestamp(message.timestamp))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            if message.type == .string {
                if let stringData = message.stringData {
                    Text(formatJSONString(stringData))
                        .font(.system(.subheadline, design: .monospaced))
                }
            } else {
                if let data = message.binaryData {
                    Text("Binary Data (\(data.count) bytes)")
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
    
    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }
    
    private func formatJSONString(_ string: String) -> String {
        guard let data = string.data(using: .utf8),
              let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []),
              let prettyData = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys]),
              let prettyString = String(data: prettyData, encoding: .utf8) else {
            return string
        }
        return prettyString
    }
}
