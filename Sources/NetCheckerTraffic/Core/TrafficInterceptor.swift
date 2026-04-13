import Foundation
import Combine

/// Main class for managing traffic interception
@MainActor
public final class TrafficInterceptor: ObservableObject {
    // MARK: - Singleton

    /// Shared instance
    public static let shared = TrafficInterceptor()

    // MARK: - Published Properties

    /// Whether interception is running
    @Published public private(set) var isRunning: Bool = false

    /// Number of intercepted requests
    @Published public private(set) var requestCount: Int = 0

    /// Number of errors
    @Published public private(set) var errorCount: Int = 0

    // MARK: - Configuration

    /// Current configuration
    public private(set) var configuration: InterceptorConfiguration = .default

    // MARK: - Engines

    /// Mock engine
    public let mockEngine = MockEngine.shared

    /// Breakpoint engine
    public let breakpointEngine = BreakpointEngine.shared

    /// Environment store
    public let environmentStore = EnvironmentStore.shared

    /// MCP server
    public let mcpServer = MCPServer.shared

    // MARK: - Private Properties

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    private init() {
        setupObservers()
    }

    // MARK: - Public Methods

    /// Start interception with default configuration
    public func start() {
        start(configuration: .default)
    }

    /// Start interception with the specified level
    public func start(level: InterceptionLevel) {
        var config = InterceptorConfiguration.default
        config.level = level
        start(configuration: config)
    }

    /// Start interception with the specified configuration
    public func start(configuration: InterceptorConfiguration) {
        guard !isRunning else {
            print("[NetChecker] Traffic interception is already running")
            return
        }

        self.configuration = configuration

        // Update thread-safe state for URLProtocol access
        NetCheckerURLProtocol.updateConfiguration(configuration)
        NetCheckerURLProtocol.setIntercepting(true)

        // Configure store
        TrafficStore.shared.maxRecords = configuration.maxRecords

        // Register protocol based on level
        switch configuration.level {
        case .basic:
            URLProtocol.registerClass(NetCheckerURLProtocol.self)
            WebSocketInspector.shared.activate()

        case .full:
            URLProtocol.registerClass(NetCheckerURLProtocol.self)
            SessionSwizzler.shared.activate()
            WebSocketInspector.shared.activate()

        case .manual:
            // User must manually add protocol to their sessions
            break
        }

        // Auto-start MCP server if enabled in configuration
        if configuration.mcp.enabled {
            mcpServer.start(port: configuration.mcp.port)
        }

        isRunning = true
        print("[NetChecker] Traffic interception started (level: \(configuration.level.rawValue))")
    }

    /// Stop interception
    public func stop() {
        guard isRunning else { return }

        // Stop MCP server if running
        if mcpServer.isRunning {
            mcpServer.stop()
        }

        // Update thread-safe state
        NetCheckerURLProtocol.setIntercepting(false)

        // Unregister protocol
        URLProtocol.unregisterClass(NetCheckerURLProtocol.self)

        // Deactivate swizzling if was used
        if configuration.level == .full {
            SessionSwizzler.shared.deactivate()
        }
        
        WebSocketInspector.shared.deactivate()

        isRunning = false
        print("[NetChecker] Traffic interception stopped")
    }

    /// Clear all records
    public func clearRecords() {
        TrafficStore.shared.clear()
        requestCount = 0
        errorCount = 0
    }

    /// Get protocol classes for manual session configuration
    public static func protocolClasses() -> [AnyClass] {
        [NetCheckerURLProtocol.self]
    }

    // MARK: - MCP Management

    /// Start the MCP server to receive logs from AI tools
    public func startMCP(port: UInt16 = 9876) {
        mcpServer.start(port: port)
    }

    /// Stop the MCP server
    public func stopMCP() {
        mcpServer.stop()
    }

    // MARK: - Environment Management

    /// Add an environment group
    public func addEnvironment(
        group: String,
        source: String,
        environments: [Environment]
    ) {
        environmentStore.addGroup(
            EnvironmentGroup(
                name: group,
                sourcePattern: source,
                environments: environments
            )
        )
    }

    /// Switch active environment
    public func switchEnvironment(group: String, to environmentName: String) {
        environmentStore.switchEnvironment(group: group, to: environmentName)
    }

    /// Quick override for a host
    public func override(
        host: String,
        with newHost: String,
        autoDisableAfter: TimeInterval? = nil
    ) {
        environmentStore.addQuickOverride(
            from: host,
            to: newHost,
            autoDisableAfter: autoDisableAfter
        )
    }

    /// Remove host override
    public func removeOverride(for host: String) {
        environmentStore.removeQuickOverride(for: host)
    }

    /// Get an environment variable value
    public func variable(_ key: String) -> String? {
        environmentStore.variable(key)
    }

    // MARK: - Private Methods

    private func setupObservers() {
        TrafficStore.shared.$records
            .receive(on: DispatchQueue.main)
            .map(\.count)
            .removeDuplicates()
            .assign(to: &$requestCount)

        TrafficStore.shared.$records
            .receive(on: DispatchQueue.main)
            .map { $0.filter { $0.isError }.count }
            .removeDuplicates()
            .assign(to: &$errorCount)
    }
}

// MARK: - Convenience Extensions

public extension TrafficInterceptor {
    /// Start with a host filter
    func start(hosts: Set<String>) {
        var config = InterceptorConfiguration.default
        config.captureHosts = hosts
        start(configuration: config)
    }

    /// Start while ignoring specified hosts
    func start(ignoring hosts: Set<String>) {
        var config = InterceptorConfiguration.default
        config.ignoreHosts = hosts
        start(configuration: config)
    }

    /// Enable SSL bypass for specified hosts
    func allowSelfSignedCertificates(for hosts: Set<String>) {
        var config = configuration
        config.ssl.trustMode = .allowSelfSigned(hosts: hosts)
        self.configuration = config
    }

    /// Enable proxy mode (Charles/Proxyman)
    func enableProxyMode(for hosts: Set<String>) {
        var config = configuration
        config.ssl.trustMode = .allowProxy(proxyHosts: hosts)
        self.configuration = config
    }
}
