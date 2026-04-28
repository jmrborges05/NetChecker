import SwiftUI
import NetCheckerTrafficCore

private enum JSONHighlighter {
    static let stringRegex = try? NSRegularExpression(pattern: #""[^"\\]*(?:\\.[^"\\]*)*""#)
    static let numberRegex = try? NSRegularExpression(pattern: #"(?<=[\s,:\[])(-?\d+\.?\d*(?:[eE][+-]?\d+)?)"#)
    static let keywordRegex = try? NSRegularExpression(pattern: #"\b(true|false|null)\b"#)
    static let keyRegex = try? NSRegularExpression(pattern: #""([^"]+)"\s*:"#)

    static func highlight(_ line: String) -> AttributedString {
        var attributed = AttributedString(line)
        let nsRange = NSRange(line.startIndex..., in: line)

        if let regex = stringRegex {
            for match in regex.matches(in: line, range: nsRange) {
                if let r = Range(match.range, in: line), let a = Range(r, in: attributed) {
                    attributed[a].foregroundColor = .orange
                }
            }
        }
        if let regex = numberRegex {
            for match in regex.matches(in: line, range: nsRange) {
                if let r = Range(match.range, in: line), let a = Range(r, in: attributed) {
                    attributed[a].foregroundColor = .cyan
                }
            }
        }
        if let regex = keywordRegex {
            for match in regex.matches(in: line, range: nsRange) {
                if let r = Range(match.range, in: line), let a = Range(r, in: attributed) {
                    attributed[a].foregroundColor = .purple
                }
            }
        }
        if let regex = keyRegex {
            for match in regex.matches(in: line, range: nsRange) {
                if let r = Range(match.range(at: 1), in: line), let a = Range(r, in: attributed) {
                    attributed[a].foregroundColor = .blue
                }
            }
        }
        return attributed
    }
}

/// View displaying JSON with syntax highlighting
public struct NetCheckerTrafficUI_JSONSyntaxView: View {
    let json: String
    let maxLines: Int?

    @State private var isExpanded = false
    @State private var highlightedJson: String = ""
    @State private var highlightedLines: [AttributedString] = []

    public init(json: String, maxLines: Int? = nil) {
        self.json = json
        self.maxLines = maxLines
    }

    // Returns highlighted lines if the task is done for the current json,
    // otherwise plain lines — so stale highlighted content from a previous
    // record is never shown.
    private var lines: [AttributedString] {
        guard highlightedJson == json else {
            return json.components(separatedBy: "\n").map { AttributedString($0) }
        }
        return highlightedLines
    }

    private var collapsedLines: [AttributedString] {
        guard let maxLines else { return lines }
        return Array(lines.prefix(maxLines))
    }

    private var extraLines: [AttributedString] {
        guard let maxLines else { return [] }
        return Array(lines.dropFirst(maxLines))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(collapsedLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: false)
                    }

                    if isExpanded {
                        ForEach(Array(extraLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                }
            }

            if let maxLines, lines.count > maxLines && !isExpanded {
                Button {
                    isExpanded = true
                } label: {
                    HStack {
                        Text("Show more (\(lines.count - maxLines) more lines)")
                            .font(.caption)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .foregroundColor(.accentColor)
                }
                .padding(.top, 8)
            }
        }
        .task(id: json) {
            let result = await Task.detached(priority: .userInitiated) {
                json.components(separatedBy: "\n").map { JSONHighlighter.highlight($0) }
            }.value
            highlightedLines = result
            highlightedJson = json
        }
    }
}

/// Collapsible JSON view with copy button
public struct CollapsibleJSONView: View {
    let title: String
    let json: String

    @State private var isExpanded = true

    public init(title: String, json: String) {
        self.title = title
        self.json = json
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    withAnimation {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                        Text(title)
                            .font(.headline)
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                NetCheckerTrafficUI_CopyButton(text: json)
            }

            if isExpanded {
                NetCheckerTrafficUI_JSONSyntaxView(json: json)
                    .padding(8)
                    .background(Color.gray.opacity(0.15))
                    .cornerRadius(8)
            }
        }
    }
}

#Preview {
    ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            NetCheckerTrafficUI_JSONSyntaxView(json: """
            {
                "name": "John Doe",
                "age": 30,
                "isActive": true,
                "balance": 1234.56,
                "email": null,
                "tags": ["swift", "ios"]
            }
            """)
            .padding()
        }
    }
}
