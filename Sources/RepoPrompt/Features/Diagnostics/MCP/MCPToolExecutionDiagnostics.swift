import Foundation
import RepoPromptShared

enum MCPToolExecutionHandlerPhase: String, Equatable {
    case manageSelectionAutoSelectionDrain = "manage_selection.auto_selection_drain"
    case manageSelectionIngressWait = "manage_selection.ingress_wait"
    case manageSelectionConstruction = "manage_selection.selection_construction"
    case manageSelectionPersistence = "manage_selection.persistence"
    case manageSelectionReplyConstruction = "manage_selection.reply_construction"
    case fileActionsPreMutationChecks = "file_actions.pre_mutation_checks"
    case fileActionsCatalogEligibility = "file_actions.catalog_eligibility"
    case fileActionsMutationIO = "file_actions.mutation_io"
    case fileActionsPostMutationCatalog = "file_actions.post_mutation_catalog"
    case fileActionsPostMutationSelection = "file_actions.post_mutation_selection"
    case fileActionsReplyConstruction = "file_actions.reply_construction"
    case readFileRequestResolution = "read_file.request_resolution"
    case readFileContentRead = "read_file.content_read"
    case readFileAutoSelection = "read_file.auto_selection"
    case getFileTreeRequestResolution = "get_file_tree.request_resolution"
    case getFileTreeIngressWait = "get_file_tree.ingress_wait"
    case getFileTreeConstruction = "get_file_tree.construction"
    // Graph-first get_code_structure execution stages.
    case getCodeStructureSeedResolution = "get_code_structure.seed_resolution"
    case getCodeStructureGraphSnapshot = "get_code_structure.graph_snapshot"
    case getCodeStructureGraphTraversal = "get_code_structure.graph_traversal"
    case getCodeStructureGraphRevalidation = "get_code_structure.graph_revalidation"
    case getCodeStructureRenderDemand = "get_code_structure.render_demand"
    case getCodeStructureFreeze = "get_code_structure.freeze"
    case getCodeStructureRender = "get_code_structure.render"
    case getCodeStructureAssembly = "get_code_structure.assembly"
}

enum MCPToolExecutionHandlerPhaseTransition: String, Equatable {
    case started
    case completed
}

struct MCPToolExecutionHandlerPhaseSnapshot: Equatable {
    let phase: MCPToolExecutionHandlerPhase
    let transition: MCPToolExecutionHandlerPhaseTransition
    let elapsedMilliseconds: Double
}

/// Per-invocation progress state. Providers use the task-local accessor while the
/// connection manager retains this recorder explicitly for watchdog escalation.
final class MCPToolExecutionHandlerPhaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let origin: Duration
    private let now: @Sendable () async -> Duration
    private var latestSnapshot: MCPToolExecutionHandlerPhaseSnapshot?

    #if DEBUG
        private let operationIdentity: MCPToolOperationIdentity
        private let appConnectionID: UUID
        private let correlationConnectionID: MCPDiagnosticBoundedString
        private let invocationID: UUID
        let historyEpoch: UInt64?
        private let phaseHistory: MCPToolExecutionPhaseHistoryRecorder

        init(
            operationIdentity: MCPToolOperationIdentity,
            appConnectionID: UUID,
            correlationConnectionID: MCPDiagnosticBoundedString,
            invocationID: UUID,
            origin: Duration,
            now: @escaping @Sendable () async -> Duration,
            phaseHistory: MCPToolExecutionPhaseHistoryRecorder = .shared
        ) {
            self.operationIdentity = operationIdentity
            self.appConnectionID = appConnectionID
            self.correlationConnectionID = correlationConnectionID
            self.invocationID = invocationID
            historyEpoch = phaseHistory.captureEpochForRecorder()
            self.origin = origin
            self.now = now
            self.phaseHistory = phaseHistory
        }
    #else
        init(
            origin: Duration,
            now: @escaping @Sendable () async -> Duration
        ) {
            self.origin = origin
            self.now = now
        }
    #endif

    func report(
        _ phase: MCPToolExecutionHandlerPhase,
        transition: MCPToolExecutionHandlerPhaseTransition
    ) async {
        let current = await now()
        store(MCPToolExecutionHandlerPhaseSnapshot(
            phase: phase,
            transition: transition,
            elapsedMilliseconds: max(0, current.mcpMilliseconds - origin.mcpMilliseconds)
        ))
    }

    func snapshot() -> MCPToolExecutionHandlerPhaseSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return latestSnapshot
    }

    #if DEBUG
        func reset() {
            lock.lock()
            latestSnapshot = nil
            lock.unlock()
        }
    #endif

    private func store(_ snapshot: MCPToolExecutionHandlerPhaseSnapshot) {
        lock.lock()
        latestSnapshot = snapshot
        #if DEBUG
            defer { lock.unlock() }
            if let historyEpoch {
                phaseHistory.recordHandlerPhase(
                    snapshot,
                    operationIdentity: operationIdentity,
                    appConnectionID: appConnectionID,
                    correlationConnectionID: correlationConnectionID,
                    invocationID: invocationID,
                    epoch: historyEpoch
                )
            }
        #else
            lock.unlock()
        #endif
    }
}

#if DEBUG
    struct MCPToolExecutionPhaseHistoryEvent: Equatable {
        enum Kind: String, Equatable {
            case handlerPhase = "handler_phase"
            case executionLifecycle = "execution_lifecycle"
        }

        enum TerminalOutcome: String, Equatable {
            case success
            case cancellation
            case error
            case detached
            case forceDisconnected = "force_disconnected"
        }

        let ingestionSequence: UInt64
        let observedElapsedMilliseconds: Double
        let kind: Kind
        let handlerPhase: MCPToolExecutionHandlerPhase?
        let handlerTransition: MCPToolExecutionHandlerPhaseTransition?
        let executionPhase: MCPToolExecutionTraceEvent.Phase?
        let cancellationRequested: Bool?
        let cancellationOrigin: MCPToolExecutionCancellationOrigin?
        let terminalOutcome: TerminalOutcome?
    }

    struct MCPToolExecutionPhaseInvocationHistory: Equatable {
        let canonicalToolName: String
        let appConnectionID: UUID
        let correlationConnectionID: MCPDiagnosticBoundedString
        let invocationID: UUID
        let droppedEventCount: UInt64
        let events: [MCPToolExecutionPhaseHistoryEvent]
    }

    final class MCPToolExecutionPhaseHistoryRecorder: @unchecked Sendable {
        static let shared = MCPToolExecutionPhaseHistoryRecorder(requiresActiveCapture: true)
        static let defaultMaximumEventsPerInvocation = 128

        private struct InvocationKey: Hashable {
            let appConnectionID: UUID
            let invocationID: UUID
        }

        private struct InvocationState {
            let operationIdentity: MCPToolOperationIdentity
            let correlationConnectionID: MCPDiagnosticBoundedString
            var nextSequence: UInt64 = 0
            var droppedEventCount: UInt64 = 0
            var events: [MCPToolExecutionPhaseHistoryEvent] = []
        }

        private let lock = NSLock()
        private let maximumInvocationCount: Int
        private let maximumEventsPerInvocation: Int
        private let requiresActiveCapture: Bool
        private var epoch: UInt64 = 0
        private var invocationOrder: [InvocationKey] = []
        private var states: [InvocationKey: InvocationState] = [:]

        init(
            maximumInvocationCount: Int = 64,
            maximumEventsPerInvocation: Int = MCPToolExecutionPhaseHistoryRecorder.defaultMaximumEventsPerInvocation,
            requiresActiveCapture: Bool = false
        ) {
            self.maximumInvocationCount = max(1, maximumInvocationCount)
            self.maximumEventsPerInvocation = max(1, maximumEventsPerInvocation)
            self.requiresActiveCapture = requiresActiveCapture
        }

        func recordHandlerPhase(
            _ snapshot: MCPToolExecutionHandlerPhaseSnapshot,
            operationIdentity: MCPToolOperationIdentity,
            appConnectionID: UUID,
            correlationConnectionID: MCPDiagnosticBoundedString,
            invocationID: UUID,
            epoch: UInt64
        ) {
            append(
                operationIdentity: operationIdentity,
                appConnectionID: appConnectionID,
                correlationConnectionID: correlationConnectionID,
                invocationID: invocationID,
                epoch: epoch,
                observedElapsedMilliseconds: snapshot.elapsedMilliseconds,
                kind: .handlerPhase,
                handlerPhase: snapshot.phase,
                handlerTransition: snapshot.transition
            )
        }

        func recordExecutionTrace(_ trace: MCPToolExecutionTraceEvent) {
            guard let historyEpoch = trace.historyEpoch,
                  !requiresActiveCapture || MCPDiagnosticCaptureCoordinator.isCaptureActive
            else { return }
            append(
                operationIdentity: trace.operationIdentity,
                appConnectionID: trace.connectionID,
                correlationConnectionID: trace.correlationConnectionID,
                invocationID: trace.invocationID,
                epoch: historyEpoch,
                observedElapsedMilliseconds: trace.elapsedMilliseconds,
                kind: .executionLifecycle,
                executionPhase: trace.phase,
                cancellationRequested: trace.cancellationRequested,
                cancellationOrigin: trace.cancellationOrigin,
                terminalOutcome: Self.terminalOutcome(for: trace)
            )
        }

        func snapshot() -> [MCPToolExecutionPhaseInvocationHistory] {
            MCPDiagnosticCaptureCoordinator.withBoundary(operation: .captureMutation) {
                lock.lock()
                defer { lock.unlock() }
                return invocationOrder.compactMap { key in
                    guard let state = states[key] else { return nil }
                    return MCPToolExecutionPhaseInvocationHistory(
                        canonicalToolName: state.operationIdentity.canonicalTool,
                        appConnectionID: key.appConnectionID,
                        correlationConnectionID: state.correlationConnectionID,
                        invocationID: key.invocationID,
                        droppedEventCount: state.droppedEventCount,
                        events: state.events
                    )
                }
            }
        }

        func reset() {
            MCPDiagnosticCaptureCoordinator.withBoundary(operation: .captureMutation) {
                lock.lock()
                epoch &+= 1
                invocationOrder.removeAll(keepingCapacity: true)
                states.removeAll(keepingCapacity: true)
                lock.unlock()
            }
        }

        func captureEpoch() -> UInt64 {
            MCPDiagnosticCaptureCoordinator.withBoundary(operation: .captureMutation) {
                lock.lock()
                defer { lock.unlock() }
                return epoch
            }
        }

        func captureEpochForRecorder() -> UInt64? {
            guard !requiresActiveCapture || MCPDiagnosticCaptureCoordinator.isCaptureActive else { return nil }
            return MCPDiagnosticCaptureCoordinator.withBoundary(operation: .captureMutation) {
                guard !requiresActiveCapture || MCPDiagnosticCaptureCoordinator.isCaptureActive else { return nil }
                lock.lock()
                defer { lock.unlock() }
                return epoch
            }
        }

        private func append(
            operationIdentity: MCPToolOperationIdentity,
            appConnectionID: UUID,
            correlationConnectionID: MCPDiagnosticBoundedString,
            invocationID: UUID,
            epoch: UInt64,
            observedElapsedMilliseconds: Double,
            kind: MCPToolExecutionPhaseHistoryEvent.Kind,
            handlerPhase: MCPToolExecutionHandlerPhase? = nil,
            handlerTransition: MCPToolExecutionHandlerPhaseTransition? = nil,
            executionPhase: MCPToolExecutionTraceEvent.Phase? = nil,
            cancellationRequested: Bool? = nil,
            cancellationOrigin: MCPToolExecutionCancellationOrigin? = nil,
            terminalOutcome: MCPToolExecutionPhaseHistoryEvent.TerminalOutcome? = nil
        ) {
            guard !requiresActiveCapture || MCPDiagnosticCaptureCoordinator.isCaptureActive else { return }
            MCPDiagnosticCaptureCoordinator.withBoundary(operation: .phasePublication) {
                guard !requiresActiveCapture || MCPDiagnosticCaptureCoordinator.isCaptureActive else { return }
                let key = InvocationKey(appConnectionID: appConnectionID, invocationID: invocationID)
                lock.lock()
                defer { lock.unlock() }
                guard epoch == self.epoch else { return }

                if states[key] == nil {
                    if invocationOrder.count == maximumInvocationCount,
                       let droppedKey = invocationOrder.first
                    {
                        invocationOrder.removeFirst()
                        states.removeValue(forKey: droppedKey)
                        MCPDiagnosticCaptureCoordinator.recordLoss(.phaseHistoryInvocationCapacity)
                    }
                    invocationOrder.append(key)
                    states[key] = InvocationState(
                        operationIdentity: operationIdentity,
                        correlationConnectionID: correlationConnectionID
                    )
                }
                guard var state = states[key] else { return }
                state.nextSequence &+= 1
                state.events.append(MCPToolExecutionPhaseHistoryEvent(
                    ingestionSequence: state.nextSequence,
                    observedElapsedMilliseconds: observedElapsedMilliseconds,
                    kind: kind,
                    handlerPhase: handlerPhase,
                    handlerTransition: handlerTransition,
                    executionPhase: executionPhase,
                    cancellationRequested: cancellationRequested,
                    cancellationOrigin: cancellationOrigin,
                    terminalOutcome: terminalOutcome
                ))
                if state.events.count > maximumEventsPerInvocation {
                    let overflow = state.events.count - maximumEventsPerInvocation
                    state.events.removeFirst(overflow)
                    state.droppedEventCount &+= UInt64(overflow)
                    for _ in 0 ..< overflow {
                        MCPDiagnosticCaptureCoordinator.recordLoss(.phaseHistoryEventCapacity)
                    }
                }
                states[key] = state
            }
        }

        private static func terminalOutcome(
            for trace: MCPToolExecutionTraceEvent
        ) -> MCPToolExecutionPhaseHistoryEvent.TerminalOutcome? {
            switch trace.phase {
            case .detachedForSettlement:
                return .detached
            case .connectionForceDisconnectRequested:
                return .forceDisconnected
            case .handlerCompleted, .settledDuringGrace, .detachedSettled:
                guard let rawOutcome = trace.cancellationOutcome,
                      let settlement = MCPToolExecutionSettlement(rawValue: rawOutcome)
                else { return nil }
                switch settlement {
                case .success: return .success
                case .cancellation: return .cancellation
                case .error: return .error
                }
            case .contractSelected, .started, .deadlineExpired, .cancellationRequested,
                 .cleanupGraceExpired:
                return nil
            }
        }
    }
#endif

enum MCPToolExecutionHandlerPhaseContext {
    @TaskLocal
    static var recorder: MCPToolExecutionHandlerPhaseRecorder?

    static func report(
        _ phase: MCPToolExecutionHandlerPhase,
        transition: MCPToolExecutionHandlerPhaseTransition = .started
    ) async {
        guard let recorder else { return }
        await recorder.report(phase, transition: transition)
    }
}

struct MCPToolExecutionTraceEvent: Equatable, CustomStringConvertible {
    enum Phase: String, Equatable {
        case contractSelected = "execution_contract_selected"
        case started = "execution_started"
        case handlerCompleted = "execution_handler_completed"
        case deadlineExpired = "execution_deadline_expired"
        case cancellationRequested = "execution_cancellation_requested"
        case settledDuringGrace = "execution_settled_during_grace"
        case cleanupGraceExpired = "execution_cleanup_grace_expired"
        case detachedForSettlement = "execution_detached_for_settlement"
        case detachedSettled = "execution_detached_settled"
        case connectionForceDisconnectRequested = "connection_force_disconnect_requested"

        var isAlwaysEmitted: Bool {
            switch self {
            case .deadlineExpired, .cancellationRequested, .settledDuringGrace,
                 .cleanupGraceExpired, .detachedForSettlement, .detachedSettled,
                 .connectionForceDisconnectRequested:
                true
            case .contractSelected, .started, .handlerCompleted:
                false
            }
        }
    }

    let toolName: String
    let operationIdentity: MCPToolOperationIdentity
    let connectionID: UUID
    #if DEBUG
        let correlationConnectionID: MCPDiagnosticBoundedString
    #endif
    let invocationID: UUID
    let runID: UUID?
    let contractKind: MCPToolExecutionContract.Kind
    let executionDeadlineSeconds: Double?
    let cleanupGraceSeconds: Double?
    let cleanupDisposition: MCPToolExecutionCleanupDisposition?
    let phase: Phase
    let elapsedMilliseconds: Double
    let cancellationRequested: Bool?
    let cancellationOutcome: String?
    let cancellationOrigin: MCPToolExecutionCancellationOrigin?
    let settlement: String?
    let graceOutcome: String?
    let escalationReason: String?
    let handlerPhase: MCPToolExecutionHandlerPhaseSnapshot?
    let handlerPhaseAgeMilliseconds: Double?
    #if DEBUG
        var historyEpoch: UInt64?

        static func boundedCorrelationConnectionID(_ identifier: String?) -> MCPDiagnosticBoundedString {
            MCPDiagnosticBoundedString(identifier)
        }
    #endif

    var isAlwaysEmitted: Bool {
        phase.isAlwaysEmitted
    }

    var description: String {
        var fields = [
            "phase=\(phase.rawValue)",
            "tool=\(toolName)",
            "operation=\(operationIdentity.normalizedOperation)"
        ]
        #if DEBUG
            fields.append("app_connection_id=\(connectionID.uuidString)")
        #else
            fields.append("connection_id=\(connectionID.uuidString)")
        #endif
        fields += [
            "invocation_id=\(invocationID.uuidString)",
            "contract=\(contractKind.rawValue)",
            "elapsed_ms=\(String(format: "%.3f", elapsedMilliseconds))"
        ]
        #if DEBUG
            if let correlationConnectionID = correlationConnectionID.value {
                fields.append("correlation_connection_id=\(correlationConnectionID)")
            } else if correlationConnectionID.omitted {
                fields.append("correlation_connection_id=<omitted>")
                fields.append("correlation_connection_id_omitted=true")
                fields.append("correlation_connection_id_truncated=\(correlationConnectionID.truncated)")
                if let byteCount = correlationConnectionID.originalUTF8ByteCount {
                    fields.append("correlation_connection_id_utf8_byte_count=\(byteCount)")
                }
            }
        #endif
        if let runID { fields.append("run_id=\(runID.uuidString)") }
        if let executionDeadlineSeconds { fields.append("deadline_s=\(executionDeadlineSeconds)") }
        if let cleanupGraceSeconds { fields.append("grace_s=\(cleanupGraceSeconds)") }
        if let cleanupDisposition { fields.append("cleanup_disposition=\(cleanupDisposition.rawValue)") }
        if let cancellationRequested { fields.append("cancellation_requested=\(cancellationRequested)") }
        if let cancellationOutcome { fields.append("cancellation_outcome=\(cancellationOutcome)") }
        if let cancellationOrigin { fields.append("cancellation_origin=\(cancellationOrigin.rawValue)") }
        if let settlement { fields.append("settlement=\(settlement)") }
        if let graceOutcome { fields.append("grace_outcome=\(graceOutcome)") }
        if let escalationReason { fields.append("escalation_reason=\(escalationReason)") }
        if let handlerPhase {
            fields.append("handler_phase=\(handlerPhase.phase.rawValue)")
            fields.append("handler_phase_transition=\(handlerPhase.transition.rawValue)")
            fields.append("handler_phase_elapsed_ms=\(String(format: "%.3f", handlerPhase.elapsedMilliseconds))")
        }
        if let handlerPhaseAgeMilliseconds {
            fields.append("handler_phase_age_ms=\(String(format: "%.3f", handlerPhaseAgeMilliseconds))")
        }
        return fields.joined(separator: " ")
    }
}

enum MCPToolExecutionTracer {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var testSink: (@Sendable (MCPToolExecutionTraceEvent) -> Void)?
    }

    private static let state = State()

    static var successTracingEnabled: Bool {
        #if DEBUG
            ProcessInfo.processInfo.environment["REPOPROMPT_MCP_EXECUTION_TRACE"] == "1"
                || UserDefaults.standard.bool(forKey: "enableMCPToolExecutionTrace")
        #else
            UserDefaults.standard.bool(forKey: "enableMCPToolExecutionTrace")
        #endif
    }

    static func emit(_ event: MCPToolExecutionTraceEvent) {
        #if DEBUG
            MCPToolExecutionPhaseHistoryRecorder.shared.recordExecutionTrace(event)
        #endif
        // Release-safe concurrency evidence ingestion (counts and bounded latency
        // aggregates only; see MCPToolConcurrencyEvidenceRecorder).
        MCPToolConcurrencyEvidenceRecorder.shared.recordExecutionTraceEvent(event)
        let sink: (@Sendable (MCPToolExecutionTraceEvent) -> Void)?
        state.lock.lock()
        sink = state.testSink
        state.lock.unlock()
        sink?(event)

        guard event.isAlwaysEmitted || successTracingEnabled else { return }
        guard let data = "[MCPToolExecution] \(event)\n".data(using: .utf8) else { return }
        state.lock.lock()
        defer { state.lock.unlock() }
        // Best-effort raw write; FileHandle.write raises an uncatchable ObjC
        // exception if stderr's pipe is already closed.
        BestEffortStderrWriter.write(data)
    }

    #if DEBUG
        static func setTestSink(_ sink: (@Sendable (MCPToolExecutionTraceEvent) -> Void)?) {
            state.lock.lock()
            state.testSink = sink
            state.lock.unlock()
        }
    #endif
}

extension Duration {
    var mcpSeconds: Double {
        let components = components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    var mcpMilliseconds: Double {
        mcpSeconds * 1000
    }
}
