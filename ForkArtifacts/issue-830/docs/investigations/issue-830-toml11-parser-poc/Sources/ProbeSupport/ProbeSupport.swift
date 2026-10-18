import Foundation

public struct ProbeLimits: Sendable {
    public static let required = ProbeLimits()
    public let inputBytes = 1_048_576
    public let depth = 128
    public let nodes = 50_000
    public let arrayElements = 10_000
    public let stringBytes = 262_144
    public let mcpServers = 256
    public init() {}
}

public struct ProbeMetrics: Codable, Sendable {
    public var inputBytes: Int
    public var nodeCount = 0
    public var maximumDepth = 0
    public var maximumArrayElements = 0
    public var maximumStringBytes = 0
    public var mcpServerCount = 0
    public init(inputBytes: Int) { self.inputBytes = inputBytes }
}

public struct SelectedMCPServer: Codable, Equatable, Sendable {
    public let name: String
    public let command: String?
    public let url: String?
    public let enabled: Bool?
    public let arguments: [String]?
    public let env: [String: String]?
    public let httpHeaders: [String: String]?
    /// Keys literally present under this server's table. A comparison can then require a value
    /// for every field the source specifies, instead of passing when the parser omits one.
    public let specifiedKeys: [String]
    public init(name: String, command: String?, url: String?, enabled: Bool?, arguments: [String]?, env: [String: String]? = nil, httpHeaders: [String: String]? = nil, specifiedKeys: [String] = []) {
        self.name = name; self.command = command; self.url = url; self.enabled = enabled; self.arguments = arguments
        self.env = env; self.httpHeaders = httpHeaders; self.specifiedKeys = specifiedKeys
    }
}

/// How much of the document an engine actually turned into values.
///
/// Only `fullRecursiveTraversal` proves every scalar was evaluated. The narrower cases exist
/// because an engine can accept a document while leaving scalars unevaluated, and recording
/// that as complete materialization would overstate what the run demonstrated.
public enum ProbeMaterialization: String, Codable, Sendable {
    case notAttempted = "not_attempted"
    case failed = "failed"
    case rootDecodeOnly = "root_decode_only"
    case rootTableOnly = "root_table_only"
    case recursiveTraversalInterrupted = "recursive_traversal_interrupted"
    case fullRecursiveTraversal = "full_recursive_traversal"
}

public struct ProbeDiagnostic: Codable, Equatable, Sendable {
    public let category: String
    public let message: String
    public let line: Int?
    public let column: Int?
    public init(category: String, message: String, line: Int? = nil, column: Int? = nil) {
        self.category = category; self.message = message; self.line = line; self.column = column
    }
}

public struct ProbeRecord: Codable, Sendable {
    public let schema = 3
    public let engine: String
    public let version: String
    public let accepted: Bool
    public let outcome: String
    public let parserInvoked: Bool
    public let materialization: ProbeMaterialization
    public let orderedMCPServers: [String]
    public let selectedMCPServers: [SelectedMCPServer]
    public let diagnostic: ProbeDiagnostic?
    public let metrics: ProbeMetrics
    public let durationNanoseconds: UInt64
    public init(engine: String, version: String, accepted: Bool, outcome: String, parserInvoked: Bool, materialization: ProbeMaterialization, orderedMCPServers: [String] = [], selectedMCPServers: [SelectedMCPServer] = [], diagnostic: ProbeDiagnostic? = nil, metrics: ProbeMetrics, durationNanoseconds: UInt64) {
        self.engine = engine; self.version = version; self.accepted = accepted; self.outcome = outcome; self.parserInvoked = parserInvoked; self.materialization = materialization; self.orderedMCPServers = orderedMCPServers; self.selectedMCPServers = selectedMCPServers; self.diagnostic = diagnostic; self.metrics = metrics; self.durationNanoseconds = durationNanoseconds
    }
}

public func elapsedNanoseconds(since start: ContinuousClock.Instant) -> UInt64 {
    let duration = start.duration(to: .now).components
    return UInt64(duration.seconds) * 1_000_000_000 + UInt64(duration.attoseconds / 1_000_000_000)
}

public func emit(_ record: ProbeRecord) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(record)); FileHandle.standardOutput.write(Data("\n".utf8))
}

public func inputURL() -> URL {
    guard CommandLine.arguments.count == 2 else { FileHandle.standardError.write(Data("usage: probe <fixture>\n".utf8)); exit(64) }
    return URL(fileURLWithPath: CommandLine.arguments[1])
}
