import Foundation
import ProbeSupport
import TOMLDecoder

enum LimitFailure: Error {
    case exceeded(String, Int, Int)
}

func account(_ value: Any, depth: Int, metrics: inout ProbeMetrics, limits: ProbeLimits) throws {
    metrics.maximumDepth = max(metrics.maximumDepth, depth)
    if depth > limits.depth { throw LimitFailure.exceeded("depth", depth, limits.depth) }

    if let table = value as? [String: Any] {
        for child in table.values {
            metrics.nodeCount += 1
            if metrics.nodeCount > limits.nodes { throw LimitFailure.exceeded("nodes", metrics.nodeCount, limits.nodes) }
            try account(child, depth: depth + 1, metrics: &metrics, limits: limits)
        }
    } else if let array = value as? [Any] {
        metrics.maximumArrayElements = max(metrics.maximumArrayElements, array.count)
        if array.count > limits.arrayElements { throw LimitFailure.exceeded("array_elements", array.count, limits.arrayElements) }
        for child in array {
            metrics.nodeCount += 1
            if metrics.nodeCount > limits.nodes { throw LimitFailure.exceeded("nodes", metrics.nodeCount, limits.nodes) }
            try account(child, depth: depth + 1, metrics: &metrics, limits: limits)
        }
    } else if let string = value as? String {
        let bytes = string.utf8.count
        metrics.maximumStringBytes = max(metrics.maximumStringBytes, bytes)
        if bytes > limits.stringBytes { throw LimitFailure.exceeded("string_bytes", bytes, limits.stringBytes) }
    }
}

/// Project a string-valued table such as `env` or `http_headers`.
///
/// A non-string value is preserved as its description rather than dropped, so a document that
/// declares an unexpected shape still shows up in the comparison instead of silently matching.
func stringTable(_ value: Any?) -> [String: String]? {
    guard let table = value as? [String: Any] else { return nil }
    return table.mapValues { $0 as? String ?? String(describing: $0) }
}

func selectedServers(from materialized: [String: Any], order: [String]) -> [SelectedMCPServer] {
    guard let servers = materialized["mcp_servers"] as? [String: Any] else { return [] }
    return order.compactMap { name in
        guard let server = servers[name] as? [String: Any] else { return nil }
        return SelectedMCPServer(
            name: name,
            command: server["command"] as? String,
            url: server["url"] as? String,
            enabled: server["enabled"] as? Bool,
            arguments: server["args"] as? [String],
            env: stringTable(server["env"]),
            httpHeaders: stringTable(server["http_headers"]),
            specifiedKeys: server.keys.sorted()
        )
    }
}

let started = ContinuousClock.now
let data = try Data(contentsOf: inputURL())
let limits = ProbeLimits.required
var metrics = ProbeMetrics(inputBytes: data.count)

if data.count > limits.inputBytes {
    try emit(ProbeRecord(engine: "TOMLDecoder", version: "0.4.5", accepted: false, outcome: "input_too_large", parserInvoked: false, materialization: .notAttempted, diagnostic: ProbeDiagnostic(category: "input_too_large", message: "input exceeds configured byte limit"), metrics: metrics, durationNanoseconds: elapsedNanoseconds(since: started)))
    exit(0)
}

guard String(data: data, encoding: .utf8) != nil else {
    try emit(ProbeRecord(engine: "TOMLDecoder", version: "0.4.5", accepted: false, outcome: "invalid_utf8", parserInvoked: false, materialization: .notAttempted, diagnostic: ProbeDiagnostic(category: "invalid_utf8", message: "input is not valid UTF-8"), metrics: metrics, durationNanoseconds: elapsedNanoseconds(since: started)))
    exit(0)
}

do {
    let table = try TOMLTable(source: data)
    let materialized: [String: Any] = try Dictionary(table)
    try account(materialized, depth: 0, metrics: &metrics, limits: limits)
    let mcpTable = try? table.table(forKey: "mcp_servers")
    let order = mcpTable?.keys ?? []
    metrics.mcpServerCount = order.count
    if order.count > limits.mcpServers { throw LimitFailure.exceeded("mcp_servers", order.count, limits.mcpServers) }
    try emit(ProbeRecord(engine: "TOMLDecoder", version: "0.4.5", accepted: true, outcome: "accepted", parserInvoked: true, materialization: .fullRecursiveTraversal, orderedMCPServers: order, selectedMCPServers: selectedServers(from: materialized, order: order), metrics: metrics, durationNanoseconds: elapsedNanoseconds(since: started)))
} catch let LimitFailure.exceeded(kind, actual, limit) {
    try emit(ProbeRecord(engine: "TOMLDecoder", version: "0.4.5", accepted: false, outcome: "resource_limit", parserInvoked: true, materialization: .recursiveTraversalInterrupted, diagnostic: ProbeDiagnostic(category: "resource_limit_\(kind)", message: "observed \(actual), limit \(limit)"), metrics: metrics, durationNanoseconds: elapsedNanoseconds(since: started)))
} catch let error as TOMLError {
    try emit(ProbeRecord(engine: "TOMLDecoder", version: "0.4.5", accepted: false, outcome: "syntax_error", parserInvoked: true, materialization: .failed, diagnostic: ProbeDiagnostic(category: "invalid_syntax", message: error.description), metrics: metrics, durationNanoseconds: elapsedNanoseconds(since: started)))
}
