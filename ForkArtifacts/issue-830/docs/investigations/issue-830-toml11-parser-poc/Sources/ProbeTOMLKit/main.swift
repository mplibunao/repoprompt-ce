import Foundation
import ProbeSupport
import TOMLKit

let started = ContinuousClock.now
let data = try Data(contentsOf: inputURL())
let limits = ProbeLimits.required
let metrics = ProbeMetrics(inputBytes: data.count)

if data.count > limits.inputBytes {
    try emit(ProbeRecord(engine: "TOMLKit", version: "0.6.0", accepted: false, outcome: "input_too_large", parserInvoked: false, materialization: .notAttempted, diagnostic: ProbeDiagnostic(category: "input_too_large", message: "input exceeds configured byte limit"), metrics: metrics, durationNanoseconds: elapsedNanoseconds(since: started)))
    exit(0)
}

guard let source = String(data: data, encoding: .utf8) else {
    try emit(ProbeRecord(engine: "TOMLKit", version: "0.6.0", accepted: false, outcome: "invalid_utf8", parserInvoked: false, materialization: .notAttempted, diagnostic: ProbeDiagnostic(category: "invalid_utf8", message: "input is not valid UTF-8"), metrics: metrics, durationNanoseconds: elapsedNanoseconds(since: started)))
    exit(0)
}

do {
    // Constructing the root table is the whole of what this proves: TOMLKit does not traverse
    // or evaluate nested scalars here, so the status stays `rootTableOnly`.
    _ = try TOMLTable(string: source)
    try emit(ProbeRecord(engine: "TOMLKit", version: "0.6.0", accepted: true, outcome: "accepted", parserInvoked: true, materialization: .rootTableOnly, metrics: metrics, durationNanoseconds: elapsedNanoseconds(since: started)))
} catch let error as TOMLParseError {
    try emit(ProbeRecord(engine: "TOMLKit", version: "0.6.0", accepted: false, outcome: "syntax_error", parserInvoked: true, materialization: .failed, diagnostic: ProbeDiagnostic(category: "invalid_syntax", message: error.description, line: error.source.begin.line, column: error.source.begin.column), metrics: metrics, durationNanoseconds: elapsedNanoseconds(since: started)))
}
