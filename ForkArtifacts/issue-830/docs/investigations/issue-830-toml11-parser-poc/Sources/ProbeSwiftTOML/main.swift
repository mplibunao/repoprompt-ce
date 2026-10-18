import Foundation
import ProbeSupport
import TOML

/// swift-toml exposes no public parsed tree, so the probe can only prove that the decoder
/// accepted the document. Nothing below the root is materialized, which is why this engine
/// reports `rootDecodeOnly` rather than a full traversal.
struct Root: Decodable {}
let started = ContinuousClock.now
let data = try Data(contentsOf: inputURL())
let limits = ProbeLimits.required
let metrics = ProbeMetrics(inputBytes: data.count)

if data.count > limits.inputBytes {
    try emit(ProbeRecord(engine: "swift-toml", version: "2.0.0", accepted: false, outcome: "input_too_large", parserInvoked: false, materialization: .notAttempted, diagnostic: ProbeDiagnostic(category: "input_too_large", message: "input exceeds configured byte limit"), metrics: metrics, durationNanoseconds: elapsedNanoseconds(since: started)))
    exit(0)
}

do {
    _ = try TOMLDecoder().decode(Root.self, from: data)
    try emit(ProbeRecord(engine: "swift-toml", version: "2.0.0", accepted: true, outcome: "accepted", parserInvoked: true, materialization: .rootDecodeOnly, metrics: metrics, durationNanoseconds: elapsedNanoseconds(since: started)))
} catch let error as TOMLDecodingError {
    let diagnostic: ProbeDiagnostic
    if case let .invalidSyntax(line, column, message) = error {
        diagnostic = ProbeDiagnostic(category: "invalid_syntax", message: message, line: line, column: column)
    } else {
        diagnostic = ProbeDiagnostic(category: "decode_error", message: error.description)
    }
    try emit(ProbeRecord(engine: "swift-toml", version: "2.0.0", accepted: false, outcome: "syntax_error", parserInvoked: true, materialization: .failed, diagnostic: diagnostic, metrics: metrics, durationNanoseconds: elapsedNanoseconds(since: started)))
}
