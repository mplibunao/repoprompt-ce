// MARK: - DEBUG MCP Read/Search Latency Diagnostics

import Darwin
import Foundation
import MCP
import RepoPromptShared

enum MCPDiagnosticCaptureCoordinationOperation {
    case captureMutation
    case phasePublication
    case deliveryPublication
    case workCountPublication
}

struct MCPDiagnosticCaptureLossSnapshot: Equatable {
    let coordinatorBoundaryContention: UInt64
    let tracerLockContention: UInt64
    let deliveryHistoryCapacity: UInt64
    let phaseHistoryInvocationCapacity: UInt64
    let phaseHistoryEventCapacity: UInt64
    let workHistorySnapshotCapacity: UInt64

    var incompleteCapture: Bool {
        coordinatorBoundaryContention > 0
            || tracerLockContention > 0
            || deliveryHistoryCapacity > 0
            || phaseHistoryInvocationCapacity > 0
            || phaseHistoryEventCapacity > 0
            || workHistorySnapshotCapacity > 0
    }
}

enum MCPDiagnosticCaptureLossReason {
    case coordinatorBoundaryContention
    case tracerLockContention
    case deliveryHistoryCapacity
    case phaseHistoryInvocationCapacity
    case phaseHistoryEventCapacity
    case workHistorySnapshotCapacity
}

enum MCPDiagnosticCaptureCoordinator {
    #if DEBUG
        private static let boundary = NSRecursiveLock()
        private nonisolated(unsafe) static var active: Int32 = 0
        private nonisolated(unsafe) static var lossRecorderCount: Int32 = 0
        private nonisolated(unsafe) static var coordinatorBoundaryContention: Int64 = 0
        private nonisolated(unsafe) static var tracerLockContention: Int64 = 0
        private nonisolated(unsafe) static var deliveryHistoryCapacity: Int64 = 0
        private nonisolated(unsafe) static var phaseHistoryInvocationCapacity: Int64 = 0
        private nonisolated(unsafe) static var phaseHistoryEventCapacity: Int64 = 0
        private nonisolated(unsafe) static var workHistorySnapshotCapacity: Int64 = 0
        private static let testSinkLock = NSLock()
        private nonisolated(unsafe) static var testWillEnterSink: (@Sendable (MCPDiagnosticCaptureCoordinationOperation) -> Void)?
        private static let deliveryHooks = MCPResponseDeliveryCaptureHooks(
            isActive: { isCaptureActive },
            tryWithBoundary: { body in
                tryWithBoundary(operation: .deliveryPublication, body)
            },
            recordLoss: { reason in
                switch reason {
                case .coordinatorBoundaryContention:
                    recordLoss(.coordinatorBoundaryContention)
                case .tracerLockContention:
                    recordLoss(.tracerLockContention)
                case .historyCapacity:
                    recordLoss(.deliveryHistoryCapacity)
                }
            }
        )
        private static let deliveryHooksInstallation: Void = {
            MCPResponseDeliveryCapturePublication.install(deliveryHooks)
        }()
    #endif

    static func withBoundary<T>(
        operation: MCPDiagnosticCaptureCoordinationOperation,
        _ body: () throws -> T
    ) rethrows -> T {
        #if DEBUG
            notifyWillEnter(operation)
            boundary.lock()
            defer { boundary.unlock() }
            return try body()
        #else
            return try body()
        #endif
    }

    static func tryWithBoundary<T>(
        operation: MCPDiagnosticCaptureCoordinationOperation,
        _ body: () throws -> T
    ) rethrows -> T? {
        #if DEBUG
            notifyWillEnter(operation)
            guard boundary.try() else { return nil }
            defer { boundary.unlock() }
            return try body()
        #else
            return try body()
        #endif
    }

    static var isCaptureActive: Bool {
        #if DEBUG
            OSAtomicAdd32Barrier(0, &active) == 1
        #else
            false
        #endif
    }

    static func beginCapture() {
        #if DEBUG
            ensureDeliveryHooksInstalled()
            OSAtomicCompareAndSwap32Barrier(1, 0, &active)
            waitForLossRecorders()
            OSAtomicAdd64Barrier(-OSAtomicAdd64Barrier(0, &coordinatorBoundaryContention), &coordinatorBoundaryContention)
            OSAtomicAdd64Barrier(-OSAtomicAdd64Barrier(0, &tracerLockContention), &tracerLockContention)
            OSAtomicAdd64Barrier(-OSAtomicAdd64Barrier(0, &deliveryHistoryCapacity), &deliveryHistoryCapacity)
            OSAtomicAdd64Barrier(-OSAtomicAdd64Barrier(0, &phaseHistoryInvocationCapacity), &phaseHistoryInvocationCapacity)
            OSAtomicAdd64Barrier(-OSAtomicAdd64Barrier(0, &phaseHistoryEventCapacity), &phaseHistoryEventCapacity)
            OSAtomicAdd64Barrier(-OSAtomicAdd64Barrier(0, &workHistorySnapshotCapacity), &workHistorySnapshotCapacity)
            MCPResponseDeliveryCapturePublication.beginCapture()
            OSAtomicCompareAndSwap32Barrier(0, 1, &active)
        #endif
    }

    static func finishCapture() -> MCPDiagnosticCaptureLossSnapshot {
        #if DEBUG
            OSAtomicCompareAndSwap32Barrier(1, 0, &active)
            let hookLookupContention = MCPResponseDeliveryCapturePublication.finishCaptureAndDrainHookLookupContention()
            if hookLookupContention > 0 {
                OSAtomicAdd64Barrier(Int64(hookLookupContention), &coordinatorBoundaryContention)
            }
            waitForLossRecorders()
        #endif
        return lossSnapshot()
    }

    static func lossSnapshot() -> MCPDiagnosticCaptureLossSnapshot {
        #if DEBUG
            MCPDiagnosticCaptureLossSnapshot(
                coordinatorBoundaryContention: UInt64(max(0, OSAtomicAdd64Barrier(0, &coordinatorBoundaryContention)))
                    + MCPResponseDeliveryCapturePublication.hookLookupContentionSnapshot(),
                tracerLockContention: UInt64(max(0, OSAtomicAdd64Barrier(0, &tracerLockContention))),
                deliveryHistoryCapacity: UInt64(max(0, OSAtomicAdd64Barrier(0, &deliveryHistoryCapacity))),
                phaseHistoryInvocationCapacity: UInt64(max(0, OSAtomicAdd64Barrier(0, &phaseHistoryInvocationCapacity))),
                phaseHistoryEventCapacity: UInt64(max(0, OSAtomicAdd64Barrier(0, &phaseHistoryEventCapacity))),
                workHistorySnapshotCapacity: UInt64(max(0, OSAtomicAdd64Barrier(0, &workHistorySnapshotCapacity)))
            )
        #else
            MCPDiagnosticCaptureLossSnapshot(
                coordinatorBoundaryContention: 0,
                tracerLockContention: 0,
                deliveryHistoryCapacity: 0,
                phaseHistoryInvocationCapacity: 0,
                phaseHistoryEventCapacity: 0,
                workHistorySnapshotCapacity: 0
            )
        #endif
    }

    static func recordLoss(_ reason: MCPDiagnosticCaptureLossReason) {
        #if DEBUG
            OSAtomicIncrement32Barrier(&lossRecorderCount)
            defer { OSAtomicDecrement32Barrier(&lossRecorderCount) }
            guard OSAtomicAdd32Barrier(0, &active) == 1 else { return }
            switch reason {
            case .coordinatorBoundaryContention:
                OSAtomicIncrement64Barrier(&coordinatorBoundaryContention)
            case .tracerLockContention:
                OSAtomicIncrement64Barrier(&tracerLockContention)
            case .deliveryHistoryCapacity:
                OSAtomicIncrement64Barrier(&deliveryHistoryCapacity)
            case .phaseHistoryInvocationCapacity:
                OSAtomicIncrement64Barrier(&phaseHistoryInvocationCapacity)
            case .phaseHistoryEventCapacity:
                OSAtomicIncrement64Barrier(&phaseHistoryEventCapacity)
            case .workHistorySnapshotCapacity:
                OSAtomicIncrement64Barrier(&workHistorySnapshotCapacity)
            }
        #endif
    }

    #if DEBUG
        static func setTestWillEnterSink(
            _ sink: (@Sendable (MCPDiagnosticCaptureCoordinationOperation) -> Void)?
        ) {
            testSinkLock.lock()
            testWillEnterSink = sink
            testSinkLock.unlock()
        }

        private static func ensureDeliveryHooksInstalled() {
            _ = deliveryHooksInstallation
        }

        private static func notifyWillEnter(_ operation: MCPDiagnosticCaptureCoordinationOperation) {
            testSinkLock.lock()
            let sink = testWillEnterSink
            testSinkLock.unlock()
            sink?(operation)
        }

        private static func waitForLossRecorders() {
            while OSAtomicAdd32Barrier(0, &lossRecorderCount) != 0 {
                sched_yield()
            }
        }
    #endif
}

#if DEBUG
    extension ServerNetworkManager {
        func debugMCPReadSearchCaptureBeginPayload(op: String, arguments: [String: Value]) -> CallTool.Result {
            guard let rawLabel = debugString(arguments, "label"),
                  let label = debugMCPReadSearchCaptureLabel(rawLabel)
            else {
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "Missing required non-empty string argument `label`.")
            }

            let maxSamples: Int
            switch debugBoundedInt(arguments, "max_samples", defaultValue: 20000, range: 100 ... 100_000) {
            case let .value(parsed), let .defaulted(parsed):
                maxSamples = parsed
            case .invalid:
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "`max_samples` must be an integer between 100 and 100000.")
            }

            return MCPDiagnosticCaptureCoordinator.withBoundary(operation: .captureMutation) {
                switch EditFlowPerf.beginDebugCapture(label: label, maxSamples: maxSamples) {
                case let .started(snapshot):
                    MCPDiagnosticCaptureCoordinator.beginCapture()
                    MCPResponseDeliveryTracer.resetDebugEvents()
                    MCPToolExecutionPhaseHistoryRecorder.shared.reset()
                    MCPToolWorkCountDiagnostics.resetDebugHistory()
                    return debugDiagnosticsResult([
                        "ok": true,
                        "op": op,
                        "capture": snapshot.payload()
                    ])
                case let .busy(snapshot):
                    return debugDiagnosticsError(
                        op: op,
                        code: "capture_busy",
                        message: "A read/search latency capture is already active with label `\(snapshot.label)`."
                    )
                }
            }
        }

        func debugMCPReadSearchCaptureSnapshotPayload(op: String, arguments: [String: Value]) -> CallTool.Result {
            let finish = debugBool(arguments, "finish") ?? true
            let includeTimeline = debugBool(arguments, "include_timeline") ?? true
            return MCPDiagnosticCaptureCoordinator.withBoundary(operation: .captureMutation) {
                let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: finish)
                let deliveryEvents = MCPResponseDeliveryTracer.debugEventSnapshot()
                let phaseHistories = MCPToolExecutionPhaseHistoryRecorder.shared.snapshot()
                let workCounts = MCPToolWorkCountDiagnostics.debugSnapshots()
                let losses = finish
                    ? MCPDiagnosticCaptureCoordinator.finishCapture()
                    : MCPDiagnosticCaptureCoordinator.lossSnapshot()
                return debugDiagnosticsResult([
                    "ok": true,
                    "op": op,
                    "capture": snapshot.payload(includeTimeline: includeTimeline),
                    "capture_scope": [
                        "process": "app",
                        "coordinated_delivery_through": "app_uds_transport.transport_write_completed",
                        "proxy_stdout_evidence": "external_cli_completion_or_timeout_required",
                        "same_process_proxy_coverage": "unit_tests_only"
                    ],
                    "delivery_event_losses": [
                        "coordinator_boundary_contention": losses.coordinatorBoundaryContention,
                        "tracer_lock_contention": losses.tracerLockContention,
                        "history_capacity": losses.deliveryHistoryCapacity
                    ],
                    "evidence_retention_losses": [
                        "phase_history_invocation_capacity": losses.phaseHistoryInvocationCapacity,
                        "phase_history_event_capacity": losses.phaseHistoryEventCapacity,
                        "work_history_snapshot_capacity": losses.workHistorySnapshotCapacity
                    ],
                    "incomplete_capture": losses.incompleteCapture || !finish,
                    "delivery_events": Self.debugPhaseAttributionDeliveryPayloads(deliveryEvents),
                    "phase_histories": phaseHistories.map(\.debugPayload),
                    "work_count_evidence": [
                        "git": workCounts.git.map(gitWorkPayload),
                        "read_file": workCounts.readFile.map(readFileWorkPayload)
                    ]
                ])
            }
        }

        func debugMCPReadFileAutoSelectionProbeBeginPayload(
            op: String,
            arguments: [String: Value]
        ) async -> CallTool.Result {
            let windowID: Int
            switch debugBoundedInt(arguments, "window_id", defaultValue: 0, range: 1 ... Int.max) {
            case let .value(parsed):
                windowID = parsed
            case .defaulted, .invalid:
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "`window_id` is required and must be a positive integer.")
            }

            guard let targetConnectionID = debugOptionalUUID(arguments, "target_connection_id", op: op),
                  let agentSessionID = debugOptionalUUID(arguments, "agent_session_id", op: op),
                  let tabID = debugOptionalUUID(arguments, "tab_id", op: op),
                  let expectedRunID = debugOptionalUUID(arguments, "expected_run_id", op: op)
            else {
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "Connection, session, tab, and run identifiers must be UUID strings when provided.")
            }

            let forceAuthoritative = debugBool(arguments, "force_authoritative") ?? false
            let expiryMilliseconds: Int
            switch debugBoundedInt(
                arguments,
                "expiry_ms",
                defaultValue: 30 * 60 * 1000,
                range: 100 ... 30 * 60 * 1000
            ) {
            case let .value(parsed), let .defaulted(parsed):
                expiryMilliseconds = parsed
            case .invalid:
                return debugDiagnosticsError(
                    op: op,
                    code: "invalid_params",
                    message: "`expiry_ms` must be an integer between 100 and 1800000."
                )
            }

            let usesConnectionTarget = targetConnectionID != nil
            let usesSessionTarget = agentSessionID != nil || tabID != nil
            guard usesConnectionTarget != usesSessionTarget,
                  usesConnectionTarget || (agentSessionID != nil && tabID != nil)
            else {
                return debugDiagnosticsError(
                    op: op,
                    code: "invalid_params",
                    message: "Provide either `target_connection_id`, or both `agent_session_id` and `tab_id`."
                )
            }

            let resolved = await MainActor.run { () -> (
                serverIdentity: ObjectIdentifier,
                targets: [MCPServerViewModel.DebugReadFileAutoSelectionTarget]
            )? in
                guard let window = WindowStatesManager.shared.allWindows.first(where: { $0.windowID == windowID }) else {
                    return nil
                }
                return (
                    ObjectIdentifier(window.mcpServer),
                    window.mcpServer.debugResolveReadFileAutoSelectionTargets(
                        targetConnectionID: targetConnectionID,
                        agentSessionID: agentSessionID,
                        tabID: tabID,
                        expectedRunID: expectedRunID
                    )
                )
            }
            guard let resolved else {
                return debugDiagnosticsError(op: op, code: "no_window", message: "No RepoPrompt window matched window_id \(windowID).")
            }
            guard resolved.targets.count == 1, let target = resolved.targets.first else {
                let code = resolved.targets.isEmpty ? "no_target" : "ambiguous_target"
                return debugDiagnosticsError(
                    op: op,
                    code: code,
                    message: resolved.targets.isEmpty
                        ? "No current bound read-file auto-selection context matched the requested identity."
                        : "Multiple current bound read-file auto-selection contexts matched the requested identity."
                )
            }
            let probeID = UUID()
            let createdAt = Date()
            guard let reservation = await MCPReadFileAutoSelectionProbeRegistry.shared.reserve(
                probeID: probeID,
                createdAt: createdAt
            ) else {
                return debugDiagnosticsError(
                    op: op,
                    code: "probe_capacity",
                    message: "The DEBUG read-file auto-selection probe registry is at its 16-probe capacity."
                )
            }
            guard let baseline = await MainActor.run(body: {
                WindowStatesManager.shared.allWindows
                    .first(where: {
                        $0.windowID == windowID && ObjectIdentifier($0.mcpServer) == resolved.serverIdentity
                    })?
                    .mcpServer.debugBeginReadFileAutoSelectionProbe(
                        probeID: probeID,
                        forceAuthoritative: forceAuthoritative,
                        for: target
                    )
            }) else {
                await MCPReadFileAutoSelectionProbeRegistry.shared.release(reservation)
                return debugDiagnosticsError(
                    op: op,
                    code: "stale_target",
                    message: "The matched auto-selection context became stale before the probe began."
                )
            }
            let releaseForceAuthoritative: @Sendable () async -> Void = {
                guard forceAuthoritative else { return }
                await MainActor.run {
                    WindowStatesManager.shared.allWindows
                        .first(where: {
                            $0.windowID == windowID && ObjectIdentifier($0.mcpServer) == resolved.serverIdentity
                        })?
                        .mcpServer.debugReleaseReadFileAutoSelectionForcedAuthoritativeProbe(
                            probeID: probeID,
                            for: target
                        )
                }
            }
            let entry = MCPReadFileAutoSelectionProbeRegistry.Entry(
                probeID: probeID,
                createdAt: createdAt,
                expiryMilliseconds: expiryMilliseconds,
                windowID: windowID,
                serverIdentity: resolved.serverIdentity,
                target: target,
                baseline: baseline,
                forceAuthoritative: forceAuthoritative,
                releaseForceAuthoritative: releaseForceAuthoritative
            )
            let committed = await MCPReadFileAutoSelectionProbeRegistry.shared.commit(
                reservation,
                entry: entry
            )
            guard committed else {
                await releaseForceAuthoritative()
                return debugDiagnosticsError(
                    op: op,
                    code: "probe_admission_failed",
                    message: "The reserved DEBUG read-file auto-selection probe admission could not be committed."
                )
            }

            return debugDiagnosticsResult([
                "ok": true,
                "op": op,
                "probe_id": probeID.uuidString,
                "window_id": windowID,
                "connection_id": target.connectionID.uuidString,
                "run_id": Self.debugOptionalValue(target.runID?.uuidString),
                "agent_session_id": Self.debugOptionalValue(target.agentSessionID?.uuidString),
                "workspace_id": Self.debugOptionalValue(target.workspaceID?.uuidString),
                "tab_id": target.tabID.uuidString,
                "route": target.route,
                "binding_generation": target.bindingGeneration,
                "force_authoritative": forceAuthoritative,
                "expiry_ms": expiryMilliseconds,
                "baseline": readFileAutoSelectionContextPayload(baseline)
            ])
        }

        func debugMCPReadFileAutoSelectionProbeDrainPayload(
            op: String,
            arguments: [String: Value]
        ) async -> CallTool.Result {
            guard let rawProbeID = debugString(arguments, "probe_id"),
                  let probeID = UUID(uuidString: rawProbeID)
            else {
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "`probe_id` is required and must be a UUID string.")
            }
            guard let entry = await MCPReadFileAutoSelectionProbeRegistry.shared.take(probeID) else {
                return debugDiagnosticsError(op: op, code: "unknown_probe", message: "The probe was not found, expired, or already consumed.")
            }

            let server = await MainActor.run {
                WindowStatesManager.shared.allWindows
                    .first(where: {
                        $0.windowID == entry.windowID && ObjectIdentifier($0.mcpServer) == entry.serverIdentity
                    })?
                    .mcpServer
            }
            guard let server,
                  await server.debugReadFileAutoSelectionContextSnapshot(for: entry.target) != nil
            else {
                await entry.releaseForceAuthoritative()
                return debugDiagnosticsResult(readFileAutoSelectionStaleProbePayload(op: op, entry: entry))
            }

            let clock = ContinuousClock()
            let drainStartedAt = clock.now
            guard let drain = await server.debugDrainReadFileAutoSelection(for: entry.target) else {
                await entry.releaseForceAuthoritative()
                return debugDiagnosticsResult(readFileAutoSelectionStaleProbePayload(op: op, entry: entry))
            }
            await entry.releaseForceAuthoritative()
            let drainElapsedMS = Self.debugDurationMilliseconds(drainStartedAt.duration(to: clock.now))

            let settleStartedAt = clock.now
            let settleDeadline = settleStartedAt.advanced(by: .seconds(1))
            var final = await server.debugReadFileAutoSelectionContextSnapshot(for: entry.target)
            while let snapshot = final,
                  snapshot.workerActive || snapshot.pendingWork,
                  clock.now < settleDeadline
            {
                try? await Task.sleep(for: .milliseconds(10))
                final = await server.debugReadFileAutoSelectionContextSnapshot(for: entry.target)
            }
            guard let final else {
                return debugDiagnosticsResult(readFileAutoSelectionStaleProbePayload(op: op, entry: entry))
            }
            let settleElapsedMS = Self.debugDurationMilliseconds(settleStartedAt.duration(to: clock.now))
            let result = drain.result == .completed ? "completed" : "cancelled"
            let delta = readFileAutoSelectionDeltaPayload(baseline: entry.baseline, final: final)

            return debugDiagnosticsResult([
                "ok": true,
                "op": op,
                "probe_id": probeID.uuidString,
                "result": result,
                "captured_target_sequence": drain.capturedTargetSequence,
                "drain_elapsed_ms": Self.debugRoundedMS(drainElapsedMS),
                "settle_elapsed_ms": Self.debugRoundedMS(settleElapsedMS),
                "completed_through_target": final.completedHighWaterSequence >= drain.capturedTargetSequence,
                "baseline": readFileAutoSelectionContextPayload(entry.baseline),
                "final": readFileAutoSelectionContextPayload(final),
                "delta": delta,
                "worker_idle": !final.workerActive,
                "pending_work": final.pendingWork,
                "waiter_count": final.waiterCount,
                "sample_overflow_count": debugCounterDelta(final.sampleOverflowCount, entry.baseline.sampleOverflowCount)
            ])
        }

        func debugMCPReadFileAutoSelectionProbeCancelPayload(
            op: String,
            arguments: [String: Value]
        ) async -> CallTool.Result {
            guard let rawProbeID = debugString(arguments, "probe_id"),
                  let probeID = UUID(uuidString: rawProbeID)
            else {
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "`probe_id` is required and must be a UUID string.")
            }
            guard let entry = await MCPReadFileAutoSelectionProbeRegistry.shared.cancel(probeID) else {
                return debugDiagnosticsError(op: op, code: "unknown_probe", message: "The probe was not found, expired, or already consumed.")
            }
            return debugDiagnosticsResult([
                "ok": true,
                "op": op,
                "probe_id": probeID.uuidString,
                "result": "cancelled",
                "force_authoritative": entry.forceAuthoritative
            ])
        }

        func debugMCPReadSearchAdmissionSnapshotPayload(
            op: String,
            arguments: [String: Value]
        ) async -> CallTool.Result {
            let requestedWindowID: Int?
            switch debugSearchLaneWindowID(arguments, op: op) {
            case let .success(windowID):
                requestedWindowID = windowID
            case let .failure(result):
                return result
            }

            let targets = await debugSearchLaneTargets(windowID: requestedWindowID)
            if let requestedWindowID, targets.isEmpty {
                return debugDiagnosticsError(op: op, code: "no_window", message: "No RepoPrompt window matched window_id \(requestedWindowID).")
            }
            let entries = await debugSearchLaneSnapshots(targets)
            return debugDiagnosticsResult([
                "ok": true,
                "op": op,
                "admission": searchLaneAdmissionPayload(entries)
            ])
        }

        func debugMCPReadSearchAdmissionConfigurePayload(op: String, arguments: [String: Value]) async -> CallTool.Result {
            let requestedWindowID: Int?
            switch debugSearchLaneWindowID(arguments, op: op) {
            case let .success(windowID):
                requestedWindowID = windowID
            case let .failure(result):
                return result
            }

            let maxQueueWaitMilliseconds: Int
            switch debugBoundedInt(arguments, "max_queue_wait_ms", defaultValue: 0, range: 100 ... 60000) {
            case let .value(parsed):
                maxQueueWaitMilliseconds = parsed
            case .defaulted, .invalid:
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "`max_queue_wait_ms` must be an integer between 100 and 60000.")
            }

            let retryAfterMilliseconds: Int
            switch debugBoundedInt(arguments, "retry_after_ms", defaultValue: 1000, range: 0 ... 60000) {
            case let .value(parsed), let .defaulted(parsed):
                retryAfterMilliseconds = parsed
            case .invalid:
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "`retry_after_ms` must be an integer between 0 and 60000.")
            }

            let productionConfiguration = StoreBackedWorkspaceSearchLane.Configuration.production
            let maxActiveLeases: Int
            switch debugBoundedInt(
                arguments,
                "max_active_leases",
                defaultValue: productionConfiguration.maxActiveLeases,
                range: 1 ... 64
            ) {
            case let .value(parsed), let .defaulted(parsed):
                maxActiveLeases = parsed
            case .invalid:
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "`max_active_leases` must be an integer between 1 and 64.")
            }

            let maxQueuedWaiters: Int
            switch debugBoundedInt(
                arguments,
                "max_queued_waiters",
                defaultValue: productionConfiguration.maxQueuedWaiters,
                range: 1 ... 64
            ) {
            case let .value(parsed), let .defaulted(parsed):
                maxQueuedWaiters = parsed
            case .invalid:
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "`max_queued_waiters` must be an integer between 1 and 64.")
            }

            let targets = await debugSearchLaneTargets(windowID: requestedWindowID)
            guard !targets.isEmpty else {
                let message = requestedWindowID.map { "No RepoPrompt window matched window_id \($0)." }
                    ?? "No RepoPrompt windows are available for search-lane configuration."
                return debugDiagnosticsError(op: op, code: "no_window", message: message)
            }

            let before = await debugSearchLaneSnapshots(targets)
            guard before.allSatisfy(\.snapshot.isIdle) else {
                return debugDiagnosticsResult([
                    "ok": false,
                    "op": op,
                    "code": "admission_busy",
                    "error": "Search-lane configuration can only change while every targeted lane is idle.",
                    "admission": searchLaneAdmissionPayload(before)
                ], isError: true)
            }

            let configuration = StoreBackedWorkspaceSearchLane.Configuration(
                maxActiveLeases: maxActiveLeases,
                maxQueuedWaiters: maxQueuedWaiters,
                maxQueueWait: .milliseconds(maxQueueWaitMilliseconds),
                retryAfterMilliseconds: retryAfterMilliseconds
            )
            var didRaceBusy = false
            for target in targets {
                switch await target.store.configureSearchLaneForTesting(configuration) {
                case .applied:
                    break
                case .busy:
                    didRaceBusy = true
                }
            }
            let after = await debugSearchLaneSnapshots(targets)
            if didRaceBusy {
                return debugDiagnosticsResult([
                    "ok": false,
                    "op": op,
                    "code": "admission_busy",
                    "error": "A targeted search lane became busy while DEBUG configuration was being applied.",
                    "partial": true,
                    "admission": searchLaneAdmissionPayload(after)
                ], isError: true)
            }
            return debugDiagnosticsResult([
                "ok": true,
                "op": op,
                "admission": searchLaneAdmissionPayload(after)
            ])
        }

        func debugMCPReadSearchContentReadSchedulerSnapshotPayload(op: String) async -> CallTool.Result {
            let snapshot = await FileSystemService.contentReadWorkerLimiterSnapshotForTesting()
            return debugDiagnosticsResult([
                "ok": true,
                "op": op,
                "scheduler": snapshot.payload()
            ])
        }

        func debugMCPReadSearchRuntimeSnapshotPayload(
            op: String,
            connectionID: UUID,
            arguments: [String: Value]
        ) async -> CallTool.Result {
            guard let requestedConnectionID = debugOptionalUUID(arguments, "connection_id", op: op) else {
                return debugDiagnosticsError(
                    op: op,
                    code: "invalid_params",
                    message: "`connection_id` must be a UUID string when provided."
                )
            }

            let requestedWindowID: Int?
            switch debugSearchLaneWindowID(arguments, op: op) {
            case let .success(windowID):
                requestedWindowID = windowID
            case let .failure(result):
                return result
            }

            let recentPublicationLimit: Int
            switch debugBoundedInt(arguments, "recent_publication_limit", defaultValue: 8, range: 0 ... 32) {
            case let .value(parsed), let .defaulted(parsed):
                recentPublicationLimit = parsed
            case .invalid:
                return debugDiagnosticsError(
                    op: op,
                    code: "invalid_params",
                    message: "`recent_publication_limit` must be an integer between 0 and 32."
                )
            }

            let rootLimit: Int
            switch debugBoundedInt(arguments, "root_limit", defaultValue: 64, range: 1 ... 256) {
            case let .value(parsed), let .defaulted(parsed):
                rootLimit = parsed
            case .invalid:
                return debugDiagnosticsError(
                    op: op,
                    code: "invalid_params",
                    message: "`root_limit` must be an integer between 1 and 256."
                )
            }

            let targets = await debugReadSearchRuntimeTargets(windowID: requestedWindowID)
            if let requestedWindowID, targets.isEmpty {
                return debugDiagnosticsError(
                    op: op,
                    code: "no_window",
                    message: "No RepoPrompt window matched window_id \(requestedWindowID)."
                )
            }

            var windows: [[String: Any]] = []
            var duplicationByPhysicalRoot: [String: DebugPhysicalRootDuplicationAccumulator] = [:]
            windows.reserveCapacity(targets.count)
            for target in targets {
                let snapshots = await target.store.readSearchRootDiagnosticsSnapshot(
                    recentPublicationLimit: recentPublicationLimit
                )
                let storeWork = await target.store.storeWorkDiagnosticsSnapshot()
                let searchWork = await target.searchService.workDiagnosticsSnapshot()
                let ordered = snapshots.sorted { $0.rootToken.uuidString < $1.rootToken.uuidString }
                for root in ordered {
                    var duplication = duplicationByPhysicalRoot[root.rootPath]
                        ?? DebugPhysicalRootDuplicationAccumulator(rootKinds: [])
                    duplication.windowIDs.insert(target.windowID)
                    duplication.rootKinds.insert(root.rootKind)
                    duplication.watcherCount += root.watcherActive ? 1 : 0
                    duplication.crawlCount += root.crawlCount
                    duplication.currentFreshnessFlightCount += (root.barrier.active == nil ? 0 : 1)
                        + (root.barrier.pending == nil ? 0 : 1)
                    duplication.totalFreshnessFlightLaunchCount += root.barrier.launchCount
                    duplicationByPhysicalRoot[root.rootPath] = duplication
                }
                let included = Array(ordered.prefix(rootLimit))
                windows.append([
                    "window_id": target.windowID,
                    "root_count": ordered.count,
                    "omitted_root_count": max(0, ordered.count - included.count),
                    "handled_projection_event_count": target.projection.handledEventCount,
                    "projection_direct_file_id_lookup_count": target.projection.directFileIDLookupCount,
                    "projection_direct_folder_id_lookup_count": target.projection.directFolderIDLookupCount,
                    "projection_direct_id_lookup_miss_count": target.projection.directIDLookupMissCount,
                    "projection_canonical_resync_count": target.projection.canonicalResyncCount,
                    "ui_index_rebuild": uiIndexRebuildPayload(target.projection),
                    "store_work": storeWorkPayload(storeWork),
                    "search_rebuild": searchRebuildPayload(searchWork),
                    "read_file_auto_selection": readFileAutoSelectionPayload(target.readFileAutoSelection),
                    "roots": included.map { root in
                        readSearchRuntimeRootPayload(
                            root,
                            handledGeneration: target.projection.handledGenerationByRootID[root.rootID] ?? 0
                        )
                    }
                ])
            }

            let toolWork = MCPToolWorkCountDiagnostics.debugSnapshots()
            let targetConnectionID = requestedConnectionID ?? connectionID
            let limiter = await connectionLimiterDiagnosticsSnapshot(connectionID: targetConnectionID)
            var limiterPayload = limiter.map { readSearchLimiterPayload($0) } ?? ["found": false]
            limiterPayload["connection_id"] = targetConnectionID.uuidString
            return debugDiagnosticsResult([
                "ok": true,
                "op": op,
                "runtime": [
                    "consistency": "best_effort",
                    "limiter": limiterPayload,
                    "observers": [
                        "tool_event_observer_count": toolEventObserverCount()
                    ],
                    "window_count": windows.count,
                    "windows": windows,
                    "physical_root_duplication": duplicationByPhysicalRoot.keys.sorted().map { rootPath in
                        physicalRootDuplicationPayload(
                            rootPath: rootPath,
                            accumulator: duplicationByPhysicalRoot[rootPath]!
                        )
                    },
                    "tool_work": [
                        "git_invocations": toolWork.git.map(gitWorkPayload),
                        "read_file_invocations": toolWork.readFile.map(readFileWorkPayload)
                    ]
                ]
            ])
        }

        private struct DebugReadSearchRuntimeTarget {
            let windowID: Int
            let store: WorkspaceFileContextStore
            let searchService: WorkspaceSearchService
            let projection: WorkspaceFilesViewModel.AppliedIndexProjectionDiagnosticsSnapshot
            let readFileAutoSelection: MCPReadFileAutoSelectionCoordinator.DebugSnapshot
        }

        private struct DebugPhysicalRootDuplicationAccumulator {
            var windowIDs = Set<Int>()
            var rootKinds: Set<String>
            var watcherCount = 0
            var crawlCount = 0
            var currentFreshnessFlightCount = 0
            var totalFreshnessFlightLaunchCount = 0
        }

        private enum DebugSearchLaneWindowIDResult {
            case success(Int?)
            case failure(CallTool.Result)
        }

        private func debugSearchLaneWindowID(
            _ arguments: [String: Value],
            op: String
        ) -> DebugSearchLaneWindowIDResult {
            guard arguments["window_id"] != nil else { return .success(nil) }
            switch debugBoundedInt(arguments, "window_id", defaultValue: 0, range: 1 ... Int.max) {
            case let .value(windowID):
                return .success(windowID)
            case .defaulted, .invalid:
                return .failure(debugDiagnosticsError(
                    op: op,
                    code: "invalid_params",
                    message: "`window_id` must be a positive integer."
                ))
            }
        }

        private func debugReadSearchRuntimeTargets(windowID: Int?) async -> [DebugReadSearchRuntimeTarget] {
            await MainActor.run {
                WindowStatesManager.shared.allWindows
                    .filter { windowID == nil || $0.windowID == windowID }
                    .sorted { $0.windowID < $1.windowID }
                    .map { window in
                        DebugReadSearchRuntimeTarget(
                            windowID: window.windowID,
                            store: window.workspaceFileContextStore,
                            searchService: window.workspaceSearchService,
                            projection: window.workspaceFilesViewModel.appliedIndexProjectionDiagnosticsSnapshot(),
                            readFileAutoSelection: window.mcpServer.readFileAutoSelectionDiagnosticsSnapshot()
                        )
                    }
            }
        }

        private func storeWorkPayload(
            _ snapshot: WorkspaceFileContextStore.StoreWorkDiagnosticsSnapshot
        ) -> [String: Any] {
            [
                "invalidations": snapshot.invalidations.map { event in
                    [
                        "sequence": event.sequence,
                        "reasons": event.reasons,
                        "affected_root_ids": event.affectedRootIDs.map(\.uuidString),
                        "affected_root_kinds": event.affectedRootKinds,
                        "evicted_scopes": event.evictedScopes
                    ]
                },
                "catalog_rebuild": [
                    "count": snapshot.catalogRebuild.rebuildCount,
                    "filter_us": snapshot.catalogRebuild.filterMicroseconds,
                    "sort_us": snapshot.catalogRebuild.sortMicroseconds,
                    "materialization_us": snapshot.catalogRebuild.materializationMicroseconds,
                    "total_us": snapshot.catalogRebuild.totalMicroseconds,
                    "last_file_count": snapshot.catalogRebuild.lastFileCount,
                    "last_root_count": snapshot.catalogRebuild.lastRootCount
                ],
                "root_catalog_shards": [
                    "live_generation_cap_per_root": snapshot.rootCatalogShards.liveGenerationCapPerRoot,
                    "max_patch_logical_mutation_count": snapshot.rootCatalogShards.maxPatchLogicalMutationCount,
                    "published_shard_count": snapshot.rootCatalogShards.publishedShardCount,
                    "total_build_count": snapshot.rootCatalogShards.totalBuildCount,
                    "total_backstop_count": snapshot.rootCatalogShards.totalBackstopCount,
                    "shadow_comparison_count": snapshot.rootCatalogShards.shadowComparisonCount,
                    "shadow_mismatch_count": snapshot.rootCatalogShards.shadowMismatchCount,
                    "last_shadow_byte_count": snapshot.rootCatalogShards.lastShadowByteCount,
                    "roots": snapshot.rootCatalogShards.roots.map { root in
                        [
                            "root_id": root.rootID.uuidString,
                            "lifetime_id": root.lifetimeID.map { $0.uuidString as Any } ?? NSNull(),
                            "published_topology_generation": root.publishedTopologyGeneration.map { $0 as Any } ?? NSNull(),
                            "live_topology_generations": root.liveTopologyGenerations,
                            "retained_topology_generations": root.retainedTopologyGenerations,
                            "build_count": root.buildCount,
                            "patch_count": root.patchCount,
                            "authoritative_rebuild_count": root.authoritativeRebuildCount,
                            "fallback_count": root.fallbackCount,
                            "fallback_reason_counts": Dictionary(uniqueKeysWithValues: root.fallbackReasonCounts.map {
                                ($0.key.rawValue, $0.value)
                            }),
                            "last_applied_index_generation": root.lastAppliedIndexGeneration.map { $0 as Any } ?? NSNull(),
                            "delta_state_dirty": root.deltaStateDirty,
                            "backstop_count": root.backstopCount,
                            "max_live_generation_count": root.maxLiveGenerationCount
                        ]
                    }
                ]
            ]
        }

        private func searchRebuildPayload(
            _ snapshot: WorkspaceSearchService.RebuildWorkDiagnosticsSnapshot
        ) -> [String: Any] {
            [
                "count": snapshot.rebuildCount,
                "order_us": snapshot.orderMicroseconds,
                "materialization_us": snapshot.materializationMicroseconds,
                "c_index_build_us": snapshot.cIndexBuildMicroseconds,
                "total_us": snapshot.totalMicroseconds,
                "debounce_cancellation_count": snapshot.debounceCancellationCount,
                "stale_discarded_count": snapshot.staleDiscardedCount,
                "last_entry_count": snapshot.lastEntryCount
            ]
        }

        private func uiIndexRebuildPayload(
            _ snapshot: WorkspaceFilesViewModel.AppliedIndexProjectionDiagnosticsSnapshot
        ) -> [String: Any] {
            [
                "count": snapshot.indexRebuildCount,
                "total_duration_ms": snapshot.indexRebuildTotalDurationMS,
                "traversal_duration_ms": snapshot.indexRebuildTraversalDurationMS,
                "visited_folder_count": snapshot.indexRebuildVisitedFolderCount,
                "visited_file_count": snapshot.indexRebuildVisitedFileCount
            ]
        }

        private func physicalRootDuplicationPayload(
            rootPath: String,
            accumulator: DebugPhysicalRootDuplicationAccumulator
        ) -> [String: Any] {
            [
                "physical_root": rootPath,
                "root_kinds": accumulator.rootKinds.sorted(),
                "window_count": accumulator.windowIDs.count,
                "window_ids": accumulator.windowIDs.sorted(),
                "watcher_count": accumulator.watcherCount,
                "crawl_count": accumulator.crawlCount,
                "current_freshness_flight_count": accumulator.currentFreshnessFlightCount,
                "total_freshness_flight_launch_count": accumulator.totalFreshnessFlightLaunchCount
            ]
        }

        private func gitWorkPayload(
            _ snapshot: MCPToolWorkCountDiagnostics.GitInvocationSnapshot
        ) -> [String: Any] {
            [
                "operation": snapshot.operation,
                "request_identity": workRequestIdentityPayload(snapshot.requestIdentity),
                "repositories": snapshot.repositories,
                "command_count": snapshot.commandCount,
                "command_counts_by_repository": snapshot.commandCountsByRepository,
                "process_global_limit": GitProcessAdmissionController.defaultGlobalLimit,
                "process_per_repository_limit": GitProcessAdmissionController.defaultPerRepositoryLimit,
                "process_queue_wait_us": snapshot.processQueueWaitMicroseconds,
                "spawn_us": snapshot.spawnMicroseconds,
                "output_bytes": snapshot.outputBytes,
                "parse_us": snapshot.parseMicroseconds,
                "commands": snapshot.commands,
                "outcome": snapshot.outcome
            ]
        }

        private func readFileWorkPayload(
            _ snapshot: MCPToolWorkCountDiagnostics.ReadFileInvocationSnapshot
        ) -> [String: Any] {
            [
                "request_identity": workRequestIdentityPayload(snapshot.requestIdentity),
                "source": snapshot.source,
                "read_bytes": snapshot.readBytes,
                "returned_bytes": snapshot.returnedBytes,
                "returned_lines": snapshot.returnedLines,
                "decode_us": snapshot.decodeMicroseconds,
                "cache_hit": snapshot.cacheHit,
                "outcome": snapshot.outcome
            ]
        }

        private func workRequestIdentityPayload(_ identity: MCPRequestTimelineIdentity?) -> Any {
            guard let identity else { return NSNull() }
            let requestID = identity.jsonRPCRequestID
            let connectionID = MCPDiagnosticBoundedString(identity.connectionID)
            let invocationID = MCPDiagnosticBoundedString(identity.appInvocationID)
            return [
                "jsonrpc_request_id": requestID?.boundedDiagnosticDescription ?? NSNull(),
                "jsonrpc_request_id_omitted": requestID?.diagnosticStringOmitted ?? false,
                "jsonrpc_request_id_truncated": requestID?.diagnosticStringTruncated ?? false,
                "jsonrpc_request_id_utf8_byte_count": requestID?.diagnosticStringUTF8ByteCount ?? NSNull(),
                "connection_id": connectionID.value ?? NSNull(),
                "connection_id_omitted": connectionID.omitted,
                "connection_id_truncated": connectionID.truncated,
                "connection_id_utf8_byte_count": connectionID.originalUTF8ByteCount ?? NSNull(),
                "connection_generation": Self.debugOptionalValue(identity.connectionGeneration),
                "app_invocation_id": invocationID.value ?? NSNull(),
                "app_invocation_id_omitted": invocationID.omitted,
                "app_invocation_id_truncated": invocationID.truncated,
                "app_invocation_id_utf8_byte_count": invocationID.originalUTF8ByteCount ?? NSNull(),
                "request_ordinal": Self.debugOptionalValue(identity.requestOrdinal)
            ] as [String: Any]
        }

        private func readFileAutoSelectionContextPayload(
            _ snapshot: MCPReadFileAutoSelectionCoordinator.DebugContextSnapshot
        ) -> [String: Any] {
            [
                "accepted_high_water_sequence": snapshot.acceptedHighWaterSequence,
                "completed_high_water_sequence": snapshot.completedHighWaterSequence,
                "accepted_intent_count": snapshot.acceptedIntentCount,
                "completed_intent_count": snapshot.completedIntentCount,
                "canonical_apply_attempt_count": snapshot.canonicalApplyAttemptCount,
                "changed_apply_count": snapshot.changedApplyCount,
                "semantic_noop_apply_count": snapshot.semanticNoOpApplyCount,
                "rejected_apply_count": snapshot.rejectedApplyCount,
                "changed_intent_count": snapshot.changedIntentCount,
                "semantic_noop_intent_count": snapshot.semanticNoOpIntentCount,
                "rejected_intent_count": snapshot.rejectedIntentCount,
                "invalidated_intent_count": snapshot.invalidatedIntentCount,
                "coverage_certificate_hit_count": snapshot.coverageCertificateHitCount,
                "authoritative_fallback_count": snapshot.authoritativeFallbackCount,
                "coverage_certificate_miss_reason_counts": Dictionary(uniqueKeysWithValues: snapshot.coverageCertificateMissReasonCounts.map {
                    ($0.key.rawValue, $0.value)
                }),
                "mutation_total_ms": Self.debugRoundedMS(snapshot.mutationTotalMilliseconds),
                "mutation_samples": snapshot.mutationSamples.map(readFileAutoSelectionMutationSamplePayload),
                "sample_overflow_count": snapshot.sampleOverflowCount,
                "worker_active": snapshot.workerActive,
                "worker_idle": !snapshot.workerActive,
                "pending_work": snapshot.pendingWork,
                "waiter_count": snapshot.waiterCount
            ]
        }

        private func readFileAutoSelectionMutationSamplePayload(
            _ sample: MCPReadFileAutoSelectionCoordinator.DebugCanonicalApplySample
        ) -> [String: Any] {
            [
                "ordinal": sample.ordinal,
                "duration_ms": Self.debugRoundedMS(sample.durationMilliseconds),
                "outcome": sample.outcome.rawValue,
                "accepted_intent_count": sample.acceptedIntentCount,
                "completed_high_water_sequence": sample.completedHighWaterSequence,
                "coverage_certificate_outcome": readFileAutoSelectionCoverageCertificateOutcomePayload(
                    sample.coverageCertificateOutcome
                )
            ]
        }

        private func readFileAutoSelectionDeltaPayload(
            baseline: MCPReadFileAutoSelectionCoordinator.DebugContextSnapshot,
            final: MCPReadFileAutoSelectionCoordinator.DebugContextSnapshot
        ) -> [String: Any] {
            let acceptedIntentCount = debugCounterDelta(final.acceptedIntentCount, baseline.acceptedIntentCount)
            let baselineSampleOrdinal = baseline.mutationSamples.last?.ordinal ?? 0
            let samples = final.mutationSamples
                .filter { $0.ordinal > baselineSampleOrdinal }
                .map(readFileAutoSelectionMutationSamplePayload)
            let mutationTotalMS = max(0, final.mutationTotalMilliseconds - baseline.mutationTotalMilliseconds)
            let missReasonCounts = Dictionary(uniqueKeysWithValues: ReadFileAutoSelectionCoverageCertificateMissReason.allCases.map { reason in
                (
                    reason.rawValue,
                    debugCounterDelta(
                        final.coverageCertificateMissReasonCounts[reason, default: 0],
                        baseline.coverageCertificateMissReasonCounts[reason, default: 0]
                    )
                )
            }.filter { $0.1 > 0 })
            return [
                "accepted_intent_count": acceptedIntentCount,
                "completed_intent_count": debugCounterDelta(final.completedIntentCount, baseline.completedIntentCount),
                "canonical_apply_attempt_count": debugCounterDelta(final.canonicalApplyAttemptCount, baseline.canonicalApplyAttemptCount),
                "changed_apply_count": debugCounterDelta(final.changedApplyCount, baseline.changedApplyCount),
                "semantic_noop_apply_count": debugCounterDelta(final.semanticNoOpApplyCount, baseline.semanticNoOpApplyCount),
                "rejected_apply_count": debugCounterDelta(final.rejectedApplyCount, baseline.rejectedApplyCount),
                "changed_intent_count": debugCounterDelta(final.changedIntentCount, baseline.changedIntentCount),
                "semantic_noop_intent_count": debugCounterDelta(final.semanticNoOpIntentCount, baseline.semanticNoOpIntentCount),
                "rejected_intent_count": debugCounterDelta(final.rejectedIntentCount, baseline.rejectedIntentCount),
                "invalidated_intent_count": debugCounterDelta(final.invalidatedIntentCount, baseline.invalidatedIntentCount),
                "coverage_certificate_hit_count": debugCounterDelta(
                    final.coverageCertificateHitCount,
                    baseline.coverageCertificateHitCount
                ),
                "authoritative_fallback_count": debugCounterDelta(
                    final.authoritativeFallbackCount,
                    baseline.authoritativeFallbackCount
                ),
                "coverage_certificate_miss_reason_counts": missReasonCounts,
                "mutation_total_ms": Self.debugRoundedMS(mutationTotalMS),
                "mutation_ms_per_accepted_intent": acceptedIntentCount > 0
                    ? Self.debugRoundedMS(mutationTotalMS / Double(acceptedIntentCount))
                    : 0,
                "mutation_samples": samples
            ]
        }

        private func readFileAutoSelectionCoverageCertificateOutcomePayload(
            _ outcome: MCPReadFileAutoSelectionCoordinator.CoverageCertificateOutcome?
        ) -> Any {
            switch outcome {
            case .hit:
                ["kind": "hit"]
            case let .authoritativeFallback(reason):
                ["kind": "authoritative_fallback", "miss_reason": reason.rawValue]
            case nil:
                NSNull()
            }
        }

        private func readFileAutoSelectionStaleProbePayload(
            op: String,
            entry: MCPReadFileAutoSelectionProbeRegistry.Entry
        ) -> [String: Any] {
            [
                "ok": true,
                "op": op,
                "probe_id": entry.probeID.uuidString,
                "result": "stale",
                "captured_target_sequence": entry.baseline.acceptedHighWaterSequence,
                "drain_elapsed_ms": 0,
                "settle_elapsed_ms": 0,
                "completed_through_target": false,
                "baseline": readFileAutoSelectionContextPayload(entry.baseline),
                "final": NSNull(),
                "delta": [String: Any](),
                "worker_idle": false,
                "pending_work": false,
                "waiter_count": 0,
                "sample_overflow_count": 0
            ]
        }

        private nonisolated func debugCounterDelta(_ final: UInt64, _ baseline: UInt64) -> UInt64 {
            final >= baseline ? final - baseline : 0
        }

        private nonisolated static func debugDurationMilliseconds(_ duration: Duration) -> Double {
            let components = duration.components
            return Double(components.seconds) * 1000
                + Double(components.attoseconds) / 1_000_000_000_000_000
        }

        private func readFileAutoSelectionPayload(
            _ snapshot: MCPReadFileAutoSelectionCoordinator.DebugSnapshot
        ) -> [String: Any] {
            [
                "canonical_lane_count": snapshot.canonicalLaneCount,
                "canonical_worker_count": snapshot.canonicalWorkerCount,
                "mirror_lane_count": snapshot.mirrorLaneCount,
                "mirror_worker_count": snapshot.mirrorWorkerCount,
                "closing_context_count": snapshot.closingContextCount,
                "pending_canonical_batch_count": snapshot.pendingCanonicalBatchCount,
                "pending_mirror_batch_count": snapshot.pendingMirrorBatchCount
            ]
        }

        private func readSearchLimiterPayload(
            _ snapshot: MCPConnectionCallLimiterDebugSnapshot
        ) -> [String: Any] {
            [
                "found": true,
                "lane_count": snapshot.laneCount,
                "limit": snapshot.limit,
                "permits": snapshot.permits,
                "active_permit_count": snapshot.activePermitCount,
                "waiter_count": snapshot.waiterCount,
                "in_flight_count": snapshot.inFlight,
                "oldest_waiter_age_ms": Self.debugOptionalValue(snapshot.oldestWaiterAgeMilliseconds),
                "cancelled_waiter_count": snapshot.cancelledWaiterCount,
                "is_closed": snapshot.isClosed,
                "is_idle": snapshot.isIdle,
                "lanes": [
                    MCPConnectionCallLane.ordinary.rawValue: readSearchLimiterLanePayload(snapshot.ordinary),
                    MCPConnectionCallLane.control.rawValue: readSearchLimiterLanePayload(snapshot.control),
                    MCPConnectionCallLane.smallRead.rawValue: readSearchLimiterLanePayload(snapshot.smallRead),
                    MCPConnectionCallLane.fileRead.rawValue: readSearchLimiterLanePayload(snapshot.fileRead),
                    MCPConnectionCallLane.gitRead.rawValue: readSearchLimiterLanePayload(snapshot.gitRead),
                    MCPConnectionCallLane.fileSearch.rawValue: readSearchLimiterLanePayload(snapshot.fileSearch)
                ]
            ]
        }

        private func readSearchLimiterLanePayload(_ snapshot: AsyncLimiter.DebugSnapshot) -> [String: Any] {
            [
                "limit": snapshot.limit,
                "permits": snapshot.permits,
                "active_permit_count": snapshot.activePermitCount,
                "waiter_count": snapshot.waiterCount,
                "in_flight_count": snapshot.inFlight,
                "oldest_waiter_age_ms": Self.debugOptionalValue(snapshot.oldestWaiterAgeMilliseconds),
                "cancelled_waiter_count": snapshot.cancelledWaiterCount,
                "is_closed": snapshot.isClosed,
                "is_idle": snapshot.isIdle
            ]
        }

        private func readSearchRuntimeRootPayload(
            _ root: WorkspaceFileContextStore.ReadSearchRootDiagnosticsSnapshot,
            handledGeneration: UInt64
        ) -> [String: Any] {
            let producedGeneration = root.producedAppliedIndexGeneration
            let generationLag = producedGeneration >= handledGeneration
                ? producedGeneration - handledGeneration
                : 0
            return [
                "root_id": root.rootID.uuidString,
                "root_token": root.rootToken.uuidString,
                "root_path": root.rootPath,
                "root_kind": root.rootKind,
                "crawl_count": root.crawlCount,
                "watcher_active": root.watcherActive,
                "explicit_watcher_demand": root.explicitWatcherDemand,
                "session_worktree_owner_count": root.sessionWorktreeOwnerCount,
                "ingress": readSearchIngressPayload(root.ingress),
                "barrier": readSearchBarrierPayload(root.barrier),
                "freshness": readSearchFreshnessPayload(root.freshness),
                "invalidation": readSearchInvalidationPayload(root.invalidation),
                "projection": [
                    "produced_generation": producedGeneration,
                    "handled_generation": handledGeneration,
                    "generation_lag": generationLag
                ]
            ]
        }

        private func readSearchIngressPayload(
            _ snapshot: WorkspaceFileSystemIngressCoordinator.DebugSnapshot
        ) -> [String: Any] {
            [
                "is_open": snapshot.isOpen,
                "queued_publication_count": snapshot.queuedPublicationCount,
                "applying_publication_count": snapshot.applyingPublicationCount,
                "outstanding_publication_count": snapshot.outstandingPublicationCount,
                "waiter_count": snapshot.waiterCount,
                "accepted_service_publication_sequence": snapshot.acceptedServicePublicationSequence,
                "applied_service_publication_sequence": snapshot.appliedServicePublicationSequence,
                "accepted_applied_sequence_gap": snapshot.acceptedAppliedSequenceGap,
                "applied_watcher_watermark": snapshot.appliedWatcherWatermark,
                "oldest_outstanding_publication_age_ms": Self.debugOptionalValue(
                    snapshot.oldestOutstandingPublicationAgeMilliseconds
                )
            ]
        }

        private func readSearchBarrierPayload(
            _ snapshot: WorkspaceFileContextStore.ScopedIngressBarrierDebugSnapshot
        ) -> [String: Any] {
            let active = snapshot.active.map { active in
                [
                    "target_watcher_watermark": active.targetWatcherWatermark,
                    "target_service_publication_sequence": active.targetServicePublicationSequence,
                    "age_ms": active.ageMilliseconds
                ]
            }
            let pending = snapshot.pending.map { pending in
                [
                    "target_watcher_watermark": pending.targetWatcherWatermark,
                    "target_service_publication_sequence": pending.targetServicePublicationSequence,
                    "age_ms": pending.ageMilliseconds
                ]
            }
            let completed = snapshot.lastCompleted.map { completed in
                [
                    "token": completed.token,
                    "target_watcher_watermark": completed.targetWatcherWatermark,
                    "target_service_publication_sequence": completed.targetServicePublicationSequence,
                    "published_service_publication_sequence": completed.publishedServicePublicationSequence,
                    "applied_service_publication_sequence": completed.appliedServicePublicationSequence,
                    "applied_watcher_watermark": completed.appliedWatcherWatermark,
                    "duration_ms": completed.durationMilliseconds
                ]
            }
            return [
                "launch_count": snapshot.launchCount,
                "join_count": snapshot.joinCount,
                "successor_count": snapshot.successorCount,
                "coalesced_successor_count": snapshot.coalescedSuccessorCount,
                "completion_count": snapshot.completionCount,
                "noop_count": snapshot.noopCount,
                "total_wait_ms": snapshot.totalWaitMilliseconds,
                "max_wait_ms": snapshot.maxWaitMilliseconds,
                "active": Self.debugOptionalValue(active),
                "pending": Self.debugOptionalValue(pending),
                "last_completed": Self.debugOptionalValue(completed)
            ]
        }

        private func readSearchFreshnessPayload(
            _ snapshot: FileSystemService.FreshnessWorkDiagnosticsSnapshot
        ) -> [String: Any] {
            [
                "flush_call_count": snapshot.flushCallCount,
                "noop_flush_count": snapshot.noopFlushCount,
                "debounce_cancellation_count": snapshot.debounceCancellationCount,
                "watcher_batch_count": snapshot.watcherBatchCount,
                "watcher_batch_event_count": snapshot.watcherBatchEventCount,
                "last_watcher_batch_size": snapshot.lastWatcherBatchSize,
                "max_watcher_batch_size": snapshot.maxWatcherBatchSize
            ]
        }

        private func readSearchInvalidationPayload(
            _ snapshot: WorkspaceFileContextStore.PublicationInvalidationHistoryDebugSnapshot
        ) -> [String: Any] {
            [
                "retained_sample_limit": snapshot.retainedSampleLimit,
                "total_observed_publication_count": snapshot.totalObservedPublicationCount,
                "dropped_publication_sample_count": snapshot.droppedPublicationSampleCount,
                "returned_sample_count": snapshot.samples.count,
                "recent_publications": snapshot.samples.map(readSearchInvalidationSamplePayload)
            ]
        }

        private func readSearchInvalidationSamplePayload(
            _ sample: WorkspaceFileContextStore.PublicationInvalidationDebugSample
        ) -> [String: Any] {
            [
                "service_publication_sequence": Self.debugOptionalValue(sample.servicePublicationSequence),
                "watcher_accepted_watermark": Self.debugOptionalValue(sample.watcherAcceptedWatermark),
                "prepared_delta_count": sample.preparedDeltaCount,
                "topology_invalidation_count": sample.topologyInvalidationCount,
                "catalog_generation_advance_count": sample.catalogGenerationAdvanceCount,
                "search_catalog_cache_clear_count": sample.searchCatalogCacheClearCount,
                "path_worker_invalidation_request_count": sample.pathWorkerInvalidationRequestCount,
                "content_invalidation_count": sample.contentInvalidationCount,
                "distinct_content_key_count": sample.distinctContentKeyCount,
                "decoded_cache_invalidation_request_count": sample.decodedCacheInvalidationRequestCount,
                "codemap_invalidation_request_count": sample.codemapInvalidationRequestCount,
                "applied_index_event_yield_count": sample.appliedIndexEventYieldCount
            ]
        }

        private func debugSearchLaneTargets(
            windowID: Int?
        ) async -> [(windowID: Int, store: WorkspaceFileContextStore)] {
            await MainActor.run {
                WindowStatesManager.shared.allWindows
                    .filter { windowID == nil || $0.windowID == windowID }
                    .sorted { $0.windowID < $1.windowID }
                    .map { ($0.windowID, $0.workspaceFileContextStore) }
            }
        }

        private func debugSearchLaneSnapshots(
            _ targets: [(windowID: Int, store: WorkspaceFileContextStore)]
        ) async -> [(windowID: Int, snapshot: StoreBackedWorkspaceSearchLane.Snapshot)] {
            var entries: [(windowID: Int, snapshot: StoreBackedWorkspaceSearchLane.Snapshot)] = []
            entries.reserveCapacity(targets.count)
            for target in targets {
                await entries.append((target.windowID, target.store.searchLaneSnapshotForTesting()))
            }
            return entries
        }

        private func searchLaneAdmissionPayload(
            _ entries: [(windowID: Int, snapshot: StoreBackedWorkspaceSearchLane.Snapshot)]
        ) -> [String: Any] {
            [
                "idle": entries.allSatisfy(\.snapshot.isIdle),
                "window_count": entries.count,
                "active_count": entries.reduce(0) { $0 + $1.snapshot.activePermitCount },
                "queued_count": entries.reduce(0) { $0 + $1.snapshot.waiterCount },
                "grant_count": entries.reduce(0) { $0 + $1.snapshot.grantCount },
                "overload_count": entries.reduce(0) { $0 + $1.snapshot.overloadCount },
                "wait_expiry_count": entries.reduce(0) { $0 + $1.snapshot.waitExpiryCount },
                "queued_cancellation_count": entries.reduce(0) { $0 + $1.snapshot.queuedCancellationCount },
                "lanes": entries.map { entry in
                    [
                        "window_id": entry.windowID,
                        "configuration": [
                            "active_capacity": entry.snapshot.configuration.maxActiveLeases,
                            "max_queued": entry.snapshot.configuration.maxQueuedWaiters,
                            "max_queue_wait_ms": entry.snapshot.configuration.maxQueueWaitMilliseconds,
                            "retry_after_ms": entry.snapshot.configuration.retryAfterMilliseconds
                        ],
                        "idle": entry.snapshot.isIdle,
                        "active_count": entry.snapshot.activePermitCount,
                        "queued_count": entry.snapshot.waiterCount,
                        "grant_count": entry.snapshot.grantCount,
                        "overload_count": entry.snapshot.overloadCount,
                        "wait_expiry_count": entry.snapshot.waitExpiryCount,
                        "queued_cancellation_count": entry.snapshot.queuedCancellationCount,
                        "maximum_active_count": entry.snapshot.maximumActivePermitCount,
                        "maximum_queued_count": entry.snapshot.maximumWaiterCount
                    ]
                }
            ]
        }

        static func debugPhaseAttributionDeliveryPayloads(
            _ events: [MCPResponseDeliveryTraceEvent]
        ) -> [[String: Any]] {
            var authoritativeIDs: [PhaseAttributionDeliveryJoinKey: BoundedInvocationIDCandidates] = [:]
            for event in events where event.layer == "app_tool_handler" {
                guard let key = PhaseAttributionDeliveryJoinKey(event),
                      let appInvocationID = event.requestIdentity?.appInvocationID ?? event.invocationID
                else { continue }
                authoritativeIDs[key, default: BoundedInvocationIDCandidates()].insert(appInvocationID)
            }

            return events.map { event in
                guard let key = PhaseAttributionDeliveryJoinKey(event) else {
                    return event.phaseAttributionPayload(
                        attributionStatus: .unsupported,
                        attributionCandidateCount: 0,
                        attributionCandidateCountTruncated: false
                    )
                }
                let candidates = authoritativeIDs[key] ?? BoundedInvocationIDCandidates()
                switch candidates.resolution {
                case let .unique(appInvocationID):
                    return event.phaseAttributionPayload(
                        appInvocationID: appInvocationID,
                        attributionStatus: .joined,
                        attributionCandidateCount: candidates.countLowerBound,
                        attributionCandidateCountTruncated: candidates.isCountTruncated
                    )
                case .ambiguous:
                    return event.phaseAttributionPayload(
                        attributionStatus: .ambiguous,
                        attributionCandidateCount: candidates.countLowerBound,
                        attributionCandidateCountTruncated: candidates.isCountTruncated
                    )
                case .unsupported:
                    return event.phaseAttributionPayload(
                        attributionStatus: .unsupported,
                        attributionCandidateCount: candidates.countLowerBound,
                        attributionCandidateCountTruncated: candidates.isCountTruncated
                    )
                case .none:
                    return event.phaseAttributionPayload(
                        attributionStatus: .unattributed,
                        attributionCandidateCount: 0,
                        attributionCandidateCountTruncated: false
                    )
                }
            }
        }

        fileprivate enum PhaseAttributionStatus: String {
            case joined
            case ambiguous
            case unattributed
            case unsupported
        }

        private struct BoundedInvocationIDCandidates {
            enum Resolution {
                case none
                case unique(String)
                case ambiguous
                case unsupported
            }

            private static let retainedCandidateLimit = 8
            private var retainedValues: Set<String> = []
            private var canonicalValues: Set<String> = []
            private var hasMalformedValue = false
            private(set) var isCountTruncated = false

            var countLowerBound: Int {
                retainedValues.count + (isCountTruncated ? 1 : 0)
            }

            var resolution: Resolution {
                guard countLowerBound > 0 else { return .none }
                if hasMalformedValue {
                    return canonicalValues.isEmpty ? .unsupported : .ambiguous
                }
                guard !isCountTruncated, canonicalValues.count == 1,
                      let value = canonicalValues.first
                else { return .ambiguous }
                return .unique(value)
            }

            mutating func insert(_ rawValue: String) {
                guard let boundedValue = MCPDiagnosticBoundedString(rawValue).value else {
                    hasMalformedValue = true
                    isCountTruncated = true
                    return
                }
                let canonicalValue = UUID(uuidString: boundedValue)?.uuidString
                let distinctValue = canonicalValue ?? boundedValue
                guard !retainedValues.contains(distinctValue) else { return }
                guard retainedValues.count < Self.retainedCandidateLimit else {
                    isCountTruncated = true
                    return
                }
                retainedValues.insert(distinctValue)
                if let canonicalValue {
                    canonicalValues.insert(canonicalValue)
                } else {
                    hasMalformedValue = true
                }
            }
        }

        private enum PhaseAttributionGenerationDomain {
            case appOneBased
            case bridgeZeroBased

            init?(layer: String) {
                switch layer {
                case "app_tool_handler", "app_sdk", "app_uds_transport":
                    self = .appOneBased
                case "proxy_app_uds", "proxy_stdout":
                    self = .bridgeZeroBased
                default:
                    return nil
                }
            }

            func normalizedGeneration(_ generation: UInt64) -> UInt64? {
                switch self {
                case .appOneBased:
                    guard generation > 0 else { return nil }
                    return generation - 1
                case .bridgeZeroBased:
                    return generation
                }
            }
        }

        private struct PhaseAttributionDeliveryJoinKey: Hashable {
            let correlationConnectionID: String
            let normalizedConnectionGeneration: UInt64
            let jsonRPCRequestID: String
            let requestOrdinal: UInt64

            init?(_ event: MCPResponseDeliveryTraceEvent) {
                guard let domain = PhaseAttributionGenerationDomain(layer: event.layer),
                      let correlationConnectionID = MCPDiagnosticBoundedString(
                          event.connectionID ?? event.requestIdentity?.connectionID
                      ).value,
                      let generation = event.connectionGeneration ?? event.requestIdentity?.connectionGeneration,
                      let normalizedGeneration = domain.normalizedGeneration(generation),
                      let jsonRPCRequestID = (event.id ?? event.requestIdentity?.jsonRPCRequestID)?.boundedDiagnosticDescription,
                      let requestOrdinal = event.requestOrdinal ?? event.requestIdentity?.requestOrdinal
                else { return nil }
                self.correlationConnectionID = correlationConnectionID
                normalizedConnectionGeneration = normalizedGeneration
                self.jsonRPCRequestID = jsonRPCRequestID
                self.requestOrdinal = requestOrdinal
            }
        }

        private func debugMCPReadSearchCaptureLabel(_ raw: String) -> String? {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
            let replacement = UnicodeScalar("_")
            let scalars = trimmed.unicodeScalars.map { scalar in
                allowed.contains(scalar) ? scalar : replacement
            }
            return String(String.UnicodeScalarView(scalars.prefix(64)))
        }
    }

    actor MCPReadFileAutoSelectionProbeRegistry {
        struct Reservation {
            fileprivate let probeID: UUID
            fileprivate let token: UUID
        }

        struct Entry: @unchecked Sendable {
            let probeID: UUID
            let createdAt: Date
            let expiryMilliseconds: Int
            let windowID: Int
            let serverIdentity: ObjectIdentifier
            let target: MCPServerViewModel.DebugReadFileAutoSelectionTarget
            let baseline: MCPReadFileAutoSelectionCoordinator.DebugContextSnapshot
            let forceAuthoritative: Bool
            let releaseForceAuthoritative: @Sendable () async -> Void
        }

        static let shared = MCPReadFileAutoSelectionProbeRegistry()
        private static let capacity = 16
        private static let expirySeconds: TimeInterval = 30 * 60
        private var reservations: [UUID: UUID] = [:]
        private var entries: [UUID: Entry] = [:]
        private var expiryTasks: [UUID: Task<Void, Never>] = [:]

        func reserve(probeID: UUID, createdAt: Date = Date()) async -> Reservation? {
            await pruneExpired(now: createdAt)
            guard entries[probeID] == nil,
                  reservations[probeID] == nil,
                  entries.count + reservations.count < Self.capacity
            else { return nil }
            let reservation = Reservation(probeID: probeID, token: UUID())
            reservations[probeID] = reservation.token
            return reservation
        }

        func commit(_ reservation: Reservation, entry: Entry) -> Bool {
            guard entry.probeID == reservation.probeID,
                  reservations[reservation.probeID] == reservation.token
            else { return false }
            reservations.removeValue(forKey: reservation.probeID)
            entries[entry.probeID] = entry
            expiryTasks[entry.probeID] = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(entry.expiryMilliseconds))
                guard !Task.isCancelled else { return }
                await self?.expire(entry.probeID)
            }
            return true
        }

        func release(_ reservation: Reservation) {
            guard reservations[reservation.probeID] == reservation.token else { return }
            reservations.removeValue(forKey: reservation.probeID)
        }

        func insert(_ entry: Entry) async -> Bool {
            guard let reservation = await reserve(probeID: entry.probeID, createdAt: entry.createdAt) else {
                return false
            }
            return commit(reservation, entry: entry)
        }

        func take(_ probeID: UUID) async -> Entry? {
            await pruneExpired(now: Date())
            expiryTasks.removeValue(forKey: probeID)?.cancel()
            return entries.removeValue(forKey: probeID)
        }

        func cancel(_ probeID: UUID) async -> Entry? {
            guard let entry = await take(probeID) else { return nil }
            await entry.releaseForceAuthoritative()
            return entry
        }

        func cancel(
            serverIdentity: ObjectIdentifier,
            contextKey: MCPReadFileAutoSelectionCoordinator.ContextKey
        ) async {
            let probeIDs = entries.values.compactMap { entry in
                entry.serverIdentity == serverIdentity && entry.target.contextKey == contextKey
                    ? entry.probeID
                    : nil
            }
            for probeID in probeIDs {
                _ = await cancel(probeID)
            }
        }

        func expireForTesting(_ probeID: UUID) async {
            await expire(probeID)
        }

        func containsForTesting(_ probeID: UUID) -> Bool {
            entries[probeID] != nil
        }

        func entryCountForTesting() -> Int {
            entries.count
        }

        func reservationCountForTesting() -> Int {
            reservations.count
        }

        func resetForTesting() async {
            let retainedEntries = Array(entries.values)
            entries.removeAll()
            reservations.removeAll()
            for task in expiryTasks.values {
                task.cancel()
            }
            expiryTasks.removeAll()
            for entry in retainedEntries {
                await entry.releaseForceAuthoritative()
            }
        }

        private func expire(_ probeID: UUID) async {
            expiryTasks.removeValue(forKey: probeID)?.cancel()
            guard let entry = entries.removeValue(forKey: probeID) else { return }
            await entry.releaseForceAuthoritative()
        }

        private func pruneExpired(now: Date) async {
            let expired = entries.values.filter { entry in
                now.timeIntervalSince(entry.createdAt) * 1000 >= Double(entry.expiryMilliseconds)
            }
            for entry in expired {
                await expire(entry.probeID)
            }
        }
    }

    extension MCPToolExecutionPhaseInvocationHistory {
        var debugPayload: [String: Any] {
            [
                "tool": canonicalToolName,
                "app_connection_id": appConnectionID.uuidString,
                "correlation_connection_id": correlationConnectionID.value ?? NSNull(),
                "correlation_connection_id_omitted": correlationConnectionID.omitted,
                "correlation_connection_id_truncated": correlationConnectionID.truncated,
                "correlation_connection_id_utf8_byte_count": correlationConnectionID.originalUTF8ByteCount ?? NSNull(),
                "app_invocation_id": invocationID.uuidString,
                "dropped_event_count": droppedEventCount,
                "events": events.map(\.debugPayload)
            ]
        }
    }

    extension MCPToolExecutionPhaseHistoryEvent {
        var debugPayload: [String: Any] {
            [
                "ingestion_sequence": ingestionSequence,
                "observed_elapsed_ms": ServerNetworkManager.debugRoundedMS(observedElapsedMilliseconds),
                "kind": kind.rawValue,
                "handler_phase": handlerPhase?.rawValue ?? NSNull(),
                "handler_transition": handlerTransition?.rawValue ?? NSNull(),
                "execution_phase": executionPhase?.rawValue ?? NSNull(),
                "cancellation_requested": cancellationRequested ?? NSNull(),
                "cancellation_origin": cancellationOrigin?.rawValue ?? NSNull(),
                "terminal_outcome": terminalOutcome?.rawValue ?? NSNull()
            ]
        }
    }

    fileprivate extension MCPResponseDeliveryTraceEvent {
        func phaseAttributionPayload(
            appInvocationID: String? = nil,
            attributionStatus: ServerNetworkManager.PhaseAttributionStatus,
            attributionCandidateCount: Int,
            attributionCandidateCountTruncated: Bool
        ) -> [String: Any] {
            var result = payload
            result.removeValue(forKey: "connection_id")
            result.removeValue(forKey: "connection_id_omitted")
            result.removeValue(forKey: "connection_id_truncated")
            result.removeValue(forKey: "connection_id_utf8_byte_count")
            let correlationIdentity = MCPDiagnosticBoundedString(connectionID ?? requestIdentity?.connectionID)
            let rawInvocationIdentity = MCPDiagnosticBoundedString(requestIdentity?.appInvocationID ?? invocationID)
            let attributedInvocationIdentity = MCPDiagnosticBoundedString(appInvocationID)
            let exportedInvocationIdentity = appInvocationID == nil ? rawInvocationIdentity : attributedInvocationIdentity
            result["correlation_connection_id"] = correlationIdentity.value ?? NSNull()
            result["correlation_connection_id_omitted"] = correlationIdentity.omitted
            result["correlation_connection_id_truncated"] = correlationIdentity.truncated
            result["correlation_connection_id_utf8_byte_count"] = correlationIdentity.originalUTF8ByteCount ?? NSNull()
            result["raw_app_invocation_id"] = rawInvocationIdentity.value ?? NSNull()
            result["raw_app_invocation_id_omitted"] = rawInvocationIdentity.omitted
            result["raw_app_invocation_id_truncated"] = rawInvocationIdentity.truncated
            result["raw_app_invocation_id_utf8_byte_count"] = rawInvocationIdentity.originalUTF8ByteCount ?? NSNull()
            result["app_invocation_id"] = exportedInvocationIdentity.value ?? NSNull()
            result["app_invocation_id_omitted"] = exportedInvocationIdentity.omitted
            result["app_invocation_id_truncated"] = exportedInvocationIdentity.truncated
            result["app_invocation_id_utf8_byte_count"] = exportedInvocationIdentity.originalUTF8ByteCount ?? NSNull()
            result["attribution_status"] = attributionStatus.rawValue
            result["attribution_candidate_count"] = attributionCandidateCount
            result["attribution_candidate_count_truncated"] = attributionCandidateCountTruncated
            return result
        }
    }

    private extension ContentReadAsyncLimiter.Snapshot {
        func payload() -> [String: Any] {
            [
                "capacity": capacity,
                "max_queued_waiters": maxQueuedWaiterCount,
                "idle": isIdle,
                "active_permit_count": activePermitCount,
                "queued_waiter_count": queuedWaiterCount,
                "owner_lane_count": ownerLaneCount,
                "cancellation_count": cancellationCount,
                "grant_count": grantCount,
                "overload_count": overloadCount,
                "interactive_grant_count": interactiveGrantCount,
                "normal_grant_count": normalGrantCount,
                "bulk_grant_count": bulkGrantCount
            ]
        }
    }
#endif
