#if DEBUG
    import Foundation
    import RepoPromptShared

    struct MCPReadFileInvocationDiagnosticPacket {
        enum PacketState: String {
            case complete
            case partial
            case truncated
        }

        let schemaVersion: Int
        let captureID: UUID
        let captureLabelToken: String?
        let captureState: EditFlowPerf.DebugCaptureState
        let packetState: PacketState
        let capturedAtMilliseconds: Int64
        let captureAgeMilliseconds: Int64?
        let droppedEventCount: Int
        let droppedEventScope: String
        let selectedInvocationLossAttribution: String
        let truncationScope: String
        let missingRequiredEvidence: [String]
        let invocation: InvocationSection
        let runtimeIdentity: RuntimeIdentitySection
        let lifecycle: LifecycleSection
        let executionTrace: ExecutionTraceSection
        let workCounts: WorkCountSection

        var payload: [String: Any] {
            [
                "schema_version": schemaVersion,
                "capture_id": captureID.uuidString,
                "capture_label_token": Self.optional(captureLabelToken),
                "capture_state": captureState.rawValue,
                "packet_state": packetState.rawValue,
                "captured_at_ms": capturedAtMilliseconds,
                "capture_age_ms": Self.optional(captureAgeMilliseconds),
                "dropped_event_count": droppedEventCount,
                "dropped_event_scope": droppedEventScope,
                "selected_invocation_loss_attribution": selectedInvocationLossAttribution,
                "truncation_scope": truncationScope,
                "missing_required_evidence": missingRequiredEvidence,
                "invocation": invocation.payload,
                "runtime_identity": runtimeIdentity.payload,
                "lifecycle": lifecycle.payload,
                "execution_trace": executionTrace.payload,
                "work_counts": workCounts.payload
            ]
        }

        struct InvocationSection {
            let state: String
            let appInvocationID: UUID
            let connectionID: UUID?
            let connectionGeneration: UInt64?
            let requestOrdinal: UInt64?
            let jsonRPCRequestKind: String?
            let jsonRPCRequestToken: String?

            var payload: [String: Any] {
                [
                    "state": state,
                    "truncated": false,
                    "omitted_count": 0,
                    "app_invocation_id": appInvocationID.uuidString,
                    "connection_id": MCPReadFileInvocationDiagnosticPacket.optional(connectionID?.uuidString),
                    "connection_generation": MCPReadFileInvocationDiagnosticPacket.optional(connectionGeneration),
                    "request_ordinal": MCPReadFileInvocationDiagnosticPacket.optional(requestOrdinal),
                    "jsonrpc_request_kind": MCPReadFileInvocationDiagnosticPacket.optional(jsonRPCRequestKind),
                    "jsonrpc_request_token": MCPReadFileInvocationDiagnosticPacket.optional(jsonRPCRequestToken)
                ]
            }
        }

        struct RuntimeIdentitySection {
            let state: String
            let identity: MCPReadFileDiagnosticRuntimeIdentity

            var payload: [String: Any] {
                [
                    "state": state,
                    "truncated": false,
                    "omitted_count": 0,
                    "bundle_identifier": MCPReadFileInvocationDiagnosticPacket.optional(identity.bundleIdentifier),
                    "marketing_version": MCPReadFileInvocationDiagnosticPacket.optional(identity.marketingVersion),
                    "build_number": MCPReadFileInvocationDiagnosticPacket.optional(identity.buildNumber),
                    "mach_o_uuid": MCPReadFileInvocationDiagnosticPacket.optional(identity.machOUUID?.uuidString),
                    "executable_sha256": MCPReadFileInvocationDiagnosticPacket.optional(identity.executableSHA256),
                    "source_base_commit": MCPReadFileInvocationDiagnosticPacket.optional(identity.sourceBaseCommit),
                    "source_tree_dirty": MCPReadFileInvocationDiagnosticPacket.optional(identity.sourceTreeDirty),
                    "diagnostic_patch_present": MCPReadFileInvocationDiagnosticPacket.optional(identity.diagnosticPatchPresent),
                    "diagnostic_patch_digest": MCPReadFileInvocationDiagnosticPacket.optional(identity.diagnosticPatchDigest),
                    "process_start_id": identity.processStartID.uuidString
                ]
            }
        }

        struct LifecycleEntry {
            let ordinal: UInt64
            let offsetMilliseconds: Double
            let kind: String

            var payload: [String: Any] {
                [
                    "ordinal": ordinal,
                    "offset_ms": MCPReadFileInvocationDiagnosticPacket.roundedMS(offsetMilliseconds),
                    "kind": kind
                ]
            }
        }

        struct LifecycleSection {
            let state: String
            let retainedCount: Int
            let omittedCount: Int
            let truncated: Bool
            let captureWideOmittedCount: Int
            let captureWideLossImpact: String
            let entries: [LifecycleEntry]

            var payload: [String: Any] {
                [
                    "state": state,
                    "retained_count": retainedCount,
                    "omitted_count": omittedCount,
                    "truncated": truncated,
                    "capture_wide_omitted_count": captureWideOmittedCount,
                    "capture_wide_loss_impact": captureWideLossImpact,
                    "entries": entries.map(\.payload)
                ]
            }
        }

        struct ExecutionTraceEntry {
            let sequence: UInt64
            let phase: String
            let elapsedMilliseconds: Double
            let contractKind: String
            let executionDeadlineMilliseconds: Double?
            let cleanupGraceMilliseconds: Double?
            let cleanupDisposition: String?
            let cancellationRequested: Bool?
            let cancellationOrigin: String?
            let handlerPhase: String?
            let handlerPhaseTransition: String?
            let handlerPhaseElapsedMilliseconds: Double?
            let handlerPhaseAgeMilliseconds: Double?

            var payload: [String: Any] {
                [
                    "sequence": sequence,
                    "phase": phase,
                    "elapsed_ms": MCPReadFileInvocationDiagnosticPacket.roundedMS(elapsedMilliseconds),
                    "contract_kind": contractKind,
                    "execution_deadline_ms": MCPReadFileInvocationDiagnosticPacket.optional(
                        executionDeadlineMilliseconds.map(MCPReadFileInvocationDiagnosticPacket.roundedMS)
                    ),
                    "cleanup_grace_ms": MCPReadFileInvocationDiagnosticPacket.optional(
                        cleanupGraceMilliseconds.map(MCPReadFileInvocationDiagnosticPacket.roundedMS)
                    ),
                    "cleanup_disposition": MCPReadFileInvocationDiagnosticPacket.optional(cleanupDisposition),
                    "cancellation_requested": MCPReadFileInvocationDiagnosticPacket.optional(cancellationRequested),
                    "cancellation_origin": MCPReadFileInvocationDiagnosticPacket.optional(cancellationOrigin),
                    "handler_phase": MCPReadFileInvocationDiagnosticPacket.optional(handlerPhase),
                    "handler_phase_transition": MCPReadFileInvocationDiagnosticPacket.optional(handlerPhaseTransition),
                    "handler_phase_elapsed_ms": MCPReadFileInvocationDiagnosticPacket.optional(
                        handlerPhaseElapsedMilliseconds.map(MCPReadFileInvocationDiagnosticPacket.roundedMS)
                    ),
                    "handler_phase_age_ms": MCPReadFileInvocationDiagnosticPacket.optional(
                        handlerPhaseAgeMilliseconds.map(MCPReadFileInvocationDiagnosticPacket.roundedMS)
                    )
                ]
            }
        }

        struct ExecutionTraceSection {
            let state: String
            let retainedCount: Int
            let omittedCount: Int
            let truncated: Bool
            let captureWideOmittedCount: Int
            let captureWideLossImpact: String
            let terminalState: String
            let entries: [ExecutionTraceEntry]

            var payload: [String: Any] {
                [
                    "state": state,
                    "retained_count": retainedCount,
                    "omitted_count": omittedCount,
                    "truncated": truncated,
                    "capture_wide_omitted_count": captureWideOmittedCount,
                    "capture_wide_loss_impact": captureWideLossImpact,
                    "terminal_state": terminalState,
                    "entries": entries.map(\.payload)
                ]
            }
        }

        struct WorkCountEntry {
            let sequence: UInt64
            let source: String
            let readBytes: Int
            let returnedBytes: Int
            let returnedLines: Int
            let decodeMicroseconds: Int
            let cacheHit: Bool
            let outcome: String

            var payload: [String: Any] {
                [
                    "sequence": sequence,
                    "source": source,
                    "read_bytes": readBytes,
                    "returned_bytes": returnedBytes,
                    "returned_lines": returnedLines,
                    "decode_us": decodeMicroseconds,
                    "cache_hit": cacheHit,
                    "outcome": outcome
                ]
            }
        }

        struct WorkCountSection {
            let state: String
            let retainedCount: Int
            let omittedCount: Int
            let truncated: Bool
            let captureWideOmittedCount: Int
            let captureWideLossImpact: String
            let entries: [WorkCountEntry]

            var payload: [String: Any] {
                [
                    "state": state,
                    "retained_count": retainedCount,
                    "omitted_count": omittedCount,
                    "truncated": truncated,
                    "capture_wide_omitted_count": captureWideOmittedCount,
                    "capture_wide_loss_impact": captureWideLossImpact,
                    "entries": entries.map(\.payload)
                ]
            }
        }

        private static func optional(_ value: (some Any)?) -> Any {
            value ?? NSNull()
        }

        private static func roundedMS(_ value: Double) -> Double {
            (value * 1000).rounded() / 1000
        }
    }

    struct MCPReadFileInvocationDiagnosticList {
        struct Entry {
            let appInvocationID: UUID
            let connectionGeneration: UInt64?
            let requestOrdinal: UInt64?
            let providerEntryOffsetMilliseconds: Double?
            let terminalState: String

            var payload: [String: Any] {
                [
                    "app_invocation_id": appInvocationID.uuidString,
                    "connection_generation": connectionGeneration ?? NSNull(),
                    "request_ordinal": requestOrdinal ?? NSNull(),
                    "provider_entry_offset_ms": providerEntryOffsetMilliseconds
                        .map { ($0 * 1000).rounded() / 1000 } ?? NSNull(),
                    "terminal_state": terminalState
                ]
            }
        }

        let captureID: UUID
        let captureState: EditFlowPerf.DebugCaptureState
        let limit: Int
        let retainedCount: Int
        let omittedCount: Int
        let truncated: Bool
        let identityState: String
        let malformedIdentityCount: Int
        let inconsistentIdentityCount: Int
        let captureWideOmittedCount: Int
        let captureWideLossImpact: String
        let truncationScope: String
        let entries: [Entry]

        var payload: [String: Any] {
            [
                "capture": [
                    "capture_id": captureID.uuidString,
                    "capture_state": captureState.rawValue
                ],
                "invocations": [
                    "state": entries.isEmpty ? "missing" : "observed",
                    "limit": limit,
                    "retained_count": retainedCount,
                    "omitted_count": omittedCount,
                    "truncated": truncated,
                    "identity_state": identityState,
                    "malformed_identity_count": malformedIdentityCount,
                    "inconsistent_identity_count": inconsistentIdentityCount,
                    "capture_wide_omitted_count": captureWideOmittedCount,
                    "capture_wide_loss_impact": captureWideLossImpact,
                    "truncation_scope": truncationScope,
                    "entries": entries.map(\.payload)
                ]
            ]
        }
    }

    enum MCPReadFileInvocationDiagnosticPacketAssemblyError: Error, Equatable {
        case invocationNotFound
        case ambiguousInvocation
        case inconsistentIdentity
        case malformedIdentity
    }

    enum MCPReadFileInvocationDiagnosticPacketAssembler {
        private static let lifecycleLimit = 512
        private static let executionTraceLimit = 64
        private static let workCountLimit = 64

        static func invocationList(
            capture: EditFlowPerf.DebugCaptureSnapshot,
            trace: MCPToolExecutionTracer.DebugEventSnapshot,
            work: MCPToolWorkCountDiagnostics.DebugReadFileSnapshot,
            limit: Int
        ) -> MCPReadFileInvocationDiagnosticList {
            guard let captureID = capture.captureID else {
                preconditionFailure("A diagnostic invocation list requires a retained capture identity.")
            }
            let captureWideLoss = CaptureWideLoss(capture: capture, trace: trace, work: work)
            let identityAnalysis = identityAnalysis(capture: capture, trace: trace, work: work)
            let candidates = identityAnalysis.candidates
            let sorted = candidates.sorted {
                switch ($0.requestOrdinal, $1.requestOrdinal) {
                case let (lhs?, rhs?) where lhs != rhs:
                    lhs < rhs
                case (nil, _?):
                    false
                case (_?, nil):
                    true
                default:
                    $0.appInvocationID.uuidString < $1.appInvocationID.uuidString
                }
            }
            let bounded = Array(sorted.prefix(limit))
            let sourceOmitted = max(0, sorted.count - bounded.count)
            let entries = bounded.map { candidate in
                MCPReadFileInvocationDiagnosticList.Entry(
                    appInvocationID: candidate.appInvocationID,
                    connectionGeneration: candidate.connectionGeneration,
                    requestOrdinal: candidate.requestOrdinal,
                    providerEntryOffsetMilliseconds: providerEntryOffset(
                        appInvocationID: candidate.appInvocationID,
                        lifecycleEvents: capture.lifecycleEvents
                    ),
                    terminalState: terminalState(
                        appInvocationID: candidate.appInvocationID,
                        lifecycleEvents: capture.lifecycleEvents,
                        traceEvents: trace.events,
                        captureActive: capture.active
                    )
                )
            }
            let omitted = [
                sourceOmitted,
                identityAnalysis.malformedCount,
                identityAnalysis.inconsistentCount
            ].reduce(0, saturatedSum)
            return MCPReadFileInvocationDiagnosticList(
                captureID: captureID,
                captureState: capture.captureState,
                limit: limit,
                retainedCount: entries.count,
                omittedCount: omitted,
                truncated: omitted > 0,
                identityState: identityAnalysis.hasIdentityIssue
                    ? "partial"
                    : (entries.isEmpty ? "missing" : "observed"),
                malformedIdentityCount: identityAnalysis.malformedCount,
                inconsistentIdentityCount: identityAnalysis.inconsistentCount,
                captureWideOmittedCount: captureWideLoss.totalCount,
                captureWideLossImpact: captureWideLoss.hasAny ? "unknown" : "none",
                truncationScope: omitted > 0 ? "invocation_list" : "none",
                entries: entries
            )
        }

        static func packet(
            appInvocationID: UUID,
            capture: EditFlowPerf.DebugCaptureSnapshot,
            trace: MCPToolExecutionTracer.DebugEventSnapshot,
            work: MCPToolWorkCountDiagnostics.DebugReadFileSnapshot,
            runtimeIdentity: MCPReadFileDiagnosticRuntimeIdentity,
            capturedAt: Date = Date()
        ) throws -> MCPReadFileInvocationDiagnosticPacket {
            guard let captureID = capture.captureID else {
                preconditionFailure("A diagnostic packet requires a retained capture identity.")
            }
            let captureWideLoss = CaptureWideLoss(capture: capture, trace: trace, work: work)
            let identityAnalysis = identityAnalysis(capture: capture, trace: trace, work: work)
            if identityAnalysis.inconsistentAppInvocationIDs.contains(appInvocationID) {
                throw MCPReadFileInvocationDiagnosticPacketAssemblyError.inconsistentIdentity
            }
            if identityAnalysis.malformedAppInvocationIDs.contains(appInvocationID) {
                throw MCPReadFileInvocationDiagnosticPacketAssemblyError.malformedIdentity
            }
            let matchingCandidates = identityAnalysis.candidates
                .filter { $0.appInvocationID == appInvocationID }
            guard !matchingCandidates.isEmpty else {
                throw MCPReadFileInvocationDiagnosticPacketAssemblyError.invocationNotFound
            }
            guard matchingCandidates.count == 1, let candidate = matchingCandidates.first else {
                throw MCPReadFileInvocationDiagnosticPacketAssemblyError.ambiguousInvocation
            }

            let lifecycle = lifecycleSection(
                appInvocationID: appInvocationID,
                capture: capture,
                captureWideLoss: captureWideLoss
            )
            let execution = executionSection(
                appInvocationID: appInvocationID,
                captureActive: capture.active,
                trace: trace,
                captureWideLoss: captureWideLoss
            )
            let workCounts = workCountSection(
                appInvocationID: appInvocationID,
                work: work,
                captureWideLoss: captureWideLoss
            )
            let invocationComplete = candidate.connectionID != nil
                && candidate.connectionGeneration != nil
                && candidate.requestOrdinal != nil
                && candidate.jsonRPCRequestKind != nil
                && candidate.jsonRPCRequestToken != nil
            let invocation = MCPReadFileInvocationDiagnosticPacket.InvocationSection(
                state: invocationComplete ? "observed" : "missing",
                appInvocationID: candidate.appInvocationID,
                connectionID: candidate.connectionID,
                connectionGeneration: candidate.connectionGeneration,
                requestOrdinal: candidate.requestOrdinal,
                jsonRPCRequestKind: candidate.jsonRPCRequestKind,
                jsonRPCRequestToken: candidate.jsonRPCRequestToken
            )
            let runtimeComplete = runtimeIdentity.bundleIdentifier != nil
                && runtimeIdentity.marketingVersion != nil
                && runtimeIdentity.buildNumber != nil
                && runtimeIdentity.machOUUID != nil
                && runtimeIdentity.executableSHA256 != nil
                && runtimeIdentity.sourceBaseCommit != nil
                && runtimeIdentity.sourceTreeDirty != nil
                && runtimeIdentity.diagnosticPatchPresent != nil
                && (runtimeIdentity.diagnosticPatchPresent != true || runtimeIdentity.diagnosticPatchDigest != nil)
            let runtime = MCPReadFileInvocationDiagnosticPacket.RuntimeIdentitySection(
                state: runtimeComplete ? "observed" : "missing",
                identity: runtimeIdentity
            )

            var missingRequiredEvidence: [String] = []
            if !invocationComplete { missingRequiredEvidence.append("invocation_identity") }
            if !runtimeComplete { missingRequiredEvidence.append("runtime_identity") }
            if lifecycle.entries.isEmpty { missingRequiredEvidence.append("lifecycle") }
            if execution.entries.isEmpty { missingRequiredEvidence.append("execution_trace") }
            if execution.terminalState == "open"
                || execution.terminalState == "capture_closed_before_terminal"
            {
                missingRequiredEvidence.append("execution_terminal")
            }

            let selectedInvocationTruncated = lifecycle.truncated || execution.truncated || workCounts.truncated
            let packetState: MCPReadFileInvocationDiagnosticPacket.PacketState = if selectedInvocationTruncated {
                .truncated
            } else if missingRequiredEvidence.isEmpty, !captureWideLoss.hasAny {
                .complete
            } else {
                .partial
            }
            let capturedAtMilliseconds = Int64((capturedAt.timeIntervalSince1970 * 1000).rounded())
            let captureAgeMilliseconds = capture.startedAt.map {
                Int64(max(0, (capturedAt.timeIntervalSince($0) * 1000).rounded()))
            }

            return MCPReadFileInvocationDiagnosticPacket(
                schemaVersion: 1,
                captureID: captureID,
                captureLabelToken: capture.captureLabelToken,
                captureState: capture.captureState,
                packetState: packetState,
                capturedAtMilliseconds: capturedAtMilliseconds,
                captureAgeMilliseconds: captureAgeMilliseconds,
                droppedEventCount: captureWideLoss.totalCount,
                droppedEventScope: "capture_wide",
                selectedInvocationLossAttribution: captureWideLoss.hasAny
                    ? "unknown"
                    : (selectedInvocationTruncated ? "observed" : "none"),
                truncationScope: selectedInvocationTruncated ? "selected_invocation" : "none",
                missingRequiredEvidence: missingRequiredEvidence,
                invocation: invocation,
                runtimeIdentity: runtime,
                lifecycle: lifecycle,
                executionTrace: execution,
                workCounts: workCounts
            )
        }

        private struct IdentityCandidate {
            let appInvocationID: UUID
            var connectionID: UUID?
            var connectionGeneration: UInt64?
            var requestOrdinal: UInt64?
            var jsonRPCRequestKind: String?
            var jsonRPCRequestToken: String?

            func isCompatible(with other: IdentityCandidate) -> Bool {
                Self.compatible(connectionID, other.connectionID)
                    && Self.compatible(connectionGeneration, other.connectionGeneration)
                    && Self.compatible(requestOrdinal, other.requestOrdinal)
                    && Self.compatible(jsonRPCRequestKind, other.jsonRPCRequestKind)
                    && Self.compatible(jsonRPCRequestToken, other.jsonRPCRequestToken)
            }

            mutating func merge(_ other: IdentityCandidate) {
                connectionID = connectionID ?? other.connectionID
                connectionGeneration = connectionGeneration ?? other.connectionGeneration
                requestOrdinal = requestOrdinal ?? other.requestOrdinal
                jsonRPCRequestKind = jsonRPCRequestKind ?? other.jsonRPCRequestKind
                jsonRPCRequestToken = jsonRPCRequestToken ?? other.jsonRPCRequestToken
            }

            private static func compatible<T: Equatable>(_ lhs: T?, _ rhs: T?) -> Bool {
                lhs == nil || rhs == nil || lhs == rhs
            }
        }

        private struct IdentityAnalysis {
            var candidates: [IdentityCandidate] = []
            var malformedCount = 0
            var inconsistentCount = 0
            var malformedAppInvocationIDs: Set<UUID> = []
            var inconsistentAppInvocationIDs: Set<UUID> = []

            var hasIdentityIssue: Bool {
                malformedCount > 0 || inconsistentCount > 0
            }
        }

        private struct CaptureWideLoss {
            let lifecycleSectionCount: Int
            let executionSectionCount: Int
            let workSectionCount: Int
            let totalCount: Int

            init(
                capture: EditFlowPerf.DebugCaptureSnapshot,
                trace: MCPToolExecutionTracer.DebugEventSnapshot,
                work: MCPToolWorkCountDiagnostics.DebugReadFileSnapshot
            ) {
                lifecycleSectionCount = MCPReadFileInvocationDiagnosticPacketAssembler.saturatedSum(
                    capture.droppedLifecycleEventCount,
                    capture.droppedClosedEpochEventCount
                )
                executionSectionCount = trace.droppedEventCount
                workSectionCount = work.droppedEntryCount
                totalCount = [
                    capture.droppedSampleCount,
                    lifecycleSectionCount,
                    executionSectionCount,
                    workSectionCount
                ].reduce(0, MCPReadFileInvocationDiagnosticPacketAssembler.saturatedSum)
            }

            var hasAny: Bool {
                totalCount > 0
            }
        }

        private enum IdentityCandidateResult {
            case absent
            case valid(IdentityCandidate)
            case malformed(UUID?)
        }

        private enum TraceIdentityValidationResult {
            case valid(IdentityCandidate)
            case malformed(Set<UUID>)
            case inconsistent(Set<UUID>)
        }

        private static func identityAnalysis(
            capture: EditFlowPerf.DebugCaptureSnapshot,
            trace: MCPToolExecutionTracer.DebugEventSnapshot,
            work: MCPToolWorkCountDiagnostics.DebugReadFileSnapshot
        ) -> IdentityAnalysis {
            var analysis = IdentityAnalysis()
            for event in capture.lifecycleEvents {
                record(
                    candidateResult(
                        from: event.requestIdentity,
                        kind: event.jsonRPCRequestKind,
                        token: event.jsonRPCRequestToken
                    ),
                    in: &analysis
                )
            }
            for captured in trace.events {
                let event = captured.event
                switch traceIdentityValidation(event) {
                case let .valid(candidate):
                    merge(candidate, in: &analysis)
                case let .malformed(affectedAppInvocationIDs):
                    analysis.malformedCount = incremented(analysis.malformedCount)
                    analysis.malformedAppInvocationIDs.formUnion(affectedAppInvocationIDs)
                case let .inconsistent(affectedAppInvocationIDs):
                    analysis.inconsistentCount = incremented(analysis.inconsistentCount)
                    analysis.inconsistentAppInvocationIDs.formUnion(affectedAppInvocationIDs)
                }
            }
            for entry in work.entries {
                record(candidateResult(from: entry.snapshot.requestIdentity), in: &analysis)
            }
            return analysis
        }

        private static func record(
            _ result: IdentityCandidateResult,
            in analysis: inout IdentityAnalysis
        ) {
            switch result {
            case .absent:
                break
            case let .valid(candidate):
                merge(candidate, in: &analysis)
            case let .malformed(appInvocationID):
                analysis.malformedCount = incremented(analysis.malformedCount)
                if let appInvocationID {
                    analysis.malformedAppInvocationIDs.insert(appInvocationID)
                }
            }
        }

        private static func merge(
            _ observation: IdentityCandidate,
            in analysis: inout IdentityAnalysis
        ) {
            guard let index = analysis.candidates.firstIndex(where: {
                $0.appInvocationID == observation.appInvocationID
            }) else {
                analysis.candidates.append(observation)
                return
            }
            guard analysis.candidates[index].isCompatible(with: observation) else {
                analysis.inconsistentCount = incremented(analysis.inconsistentCount)
                analysis.inconsistentAppInvocationIDs.insert(observation.appInvocationID)
                return
            }
            analysis.candidates[index].merge(observation)
        }

        private static func candidateResult(
            from identity: MCPRequestTimelineIdentity?,
            kind: String? = nil,
            token: String? = nil
        ) -> IdentityCandidateResult {
            guard let identity else { return .absent }
            guard let rawAppInvocationID = identity.appInvocationID,
                  let appInvocationID = UUID(uuidString: rawAppInvocationID)
            else { return .malformed(nil) }
            let connectionID: UUID?
            if let rawConnectionID = identity.connectionID {
                guard let parsedConnectionID = UUID(uuidString: rawConnectionID) else {
                    return .malformed(appInvocationID)
                }
                connectionID = parsedConnectionID
            } else {
                connectionID = nil
            }
            return .valid(IdentityCandidate(
                appInvocationID: appInvocationID,
                connectionID: connectionID,
                connectionGeneration: identity.connectionGeneration,
                requestOrdinal: identity.requestOrdinal,
                jsonRPCRequestKind: kind,
                jsonRPCRequestToken: token
            ))
        }

        private static func lifecycleSection(
            appInvocationID: UUID,
            capture: EditFlowPerf.DebugCaptureSnapshot,
            captureWideLoss: CaptureWideLoss
        ) -> MCPReadFileInvocationDiagnosticPacket.LifecycleSection {
            let selected = capture.lifecycleEvents.filter {
                $0.requestIdentity?.appInvocationID.flatMap(UUID.init(uuidString:)) == appInvocationID
            }
            let recognized = selected.compactMap { event -> MCPReadFileInvocationDiagnosticPacket.LifecycleEntry? in
                guard let kind = lifecycleKind(event.eventName) else { return nil }
                return MCPReadFileInvocationDiagnosticPacket.LifecycleEntry(
                    ordinal: event.ordinal,
                    offsetMilliseconds: event.offsetMS,
                    kind: kind
                )
            }
            .sorted { $0.ordinal < $1.ordinal }
            let entries = Array(recognized.prefix(lifecycleLimit))
            let unrecognizedCount = max(0, selected.count - recognized.count)
            let omitted = [
                unrecognizedCount,
                max(0, recognized.count - entries.count)
            ].reduce(0, saturatedSum)
            let terminal = entries.contains { $0.kind == "read_file_provider_result_ready" }
                || entries.contains { $0.kind == "tool_call_handler_result_ready" }
            let selectedState = if entries.isEmpty {
                "missing"
            } else if terminal {
                "observed"
            } else if capture.active {
                "open"
            } else {
                "capture_closed_before_terminal"
            }
            return MCPReadFileInvocationDiagnosticPacket.LifecycleSection(
                state: captureWideLoss.lifecycleSectionCount > 0 ? "partial" : selectedState,
                retainedCount: entries.count,
                omittedCount: omitted,
                truncated: omitted > 0,
                captureWideOmittedCount: captureWideLoss.lifecycleSectionCount,
                captureWideLossImpact: captureWideLoss.lifecycleSectionCount > 0 ? "unknown" : "none",
                entries: entries
            )
        }

        private static func executionSection(
            appInvocationID: UUID,
            captureActive: Bool,
            trace: MCPToolExecutionTracer.DebugEventSnapshot,
            captureWideLoss: CaptureWideLoss
        ) -> MCPReadFileInvocationDiagnosticPacket.ExecutionTraceSection {
            let selected = trace.events.filter { matches(appInvocationID, event: $0.event) }
                .sorted { $0.sequence < $1.sequence }
            let bounded = Array(selected.prefix(executionTraceLimit))
            let entries = bounded.map { captured in
                let event = captured.event
                return MCPReadFileInvocationDiagnosticPacket.ExecutionTraceEntry(
                    sequence: captured.sequence,
                    phase: event.phase.rawValue,
                    elapsedMilliseconds: event.elapsedMilliseconds,
                    contractKind: event.contractKind.rawValue,
                    executionDeadlineMilliseconds: event.executionDeadlineSeconds.map { $0 * 1000 },
                    cleanupGraceMilliseconds: event.cleanupGraceSeconds.map { $0 * 1000 },
                    cleanupDisposition: event.cleanupDisposition?.rawValue,
                    cancellationRequested: event.cancellationRequested,
                    cancellationOrigin: event.cancellationOrigin?.rawValue,
                    handlerPhase: event.handlerPhase?.phase.rawValue,
                    handlerPhaseTransition: event.handlerPhase?.transition.rawValue,
                    handlerPhaseElapsedMilliseconds: event.handlerPhase?.elapsedMilliseconds,
                    handlerPhaseAgeMilliseconds: event.handlerPhaseAgeMilliseconds
                )
            }
            let omitted = max(0, selected.count - entries.count)
            let terminal = terminalState(
                appInvocationID: appInvocationID,
                lifecycleEvents: [],
                traceEvents: selected,
                captureActive: captureActive
            )
            let selectedState = if entries.isEmpty {
                "missing"
            } else if terminal == "open" {
                "open"
            } else if terminal == "capture_closed_before_terminal" {
                "capture_closed_before_terminal"
            } else {
                "observed"
            }
            return MCPReadFileInvocationDiagnosticPacket.ExecutionTraceSection(
                state: captureWideLoss.executionSectionCount > 0 ? "partial" : selectedState,
                retainedCount: entries.count,
                omittedCount: omitted,
                truncated: omitted > 0,
                captureWideOmittedCount: captureWideLoss.executionSectionCount,
                captureWideLossImpact: captureWideLoss.executionSectionCount > 0 ? "unknown" : "none",
                terminalState: terminal,
                entries: entries
            )
        }

        private static func workCountSection(
            appInvocationID: UUID,
            work: MCPToolWorkCountDiagnostics.DebugReadFileSnapshot,
            captureWideLoss: CaptureWideLoss
        ) -> MCPReadFileInvocationDiagnosticPacket.WorkCountSection {
            let selected = work.entries.filter {
                $0.snapshot.requestIdentity?.appInvocationID.flatMap(UUID.init(uuidString:)) == appInvocationID
            }
            .sorted { $0.sequence < $1.sequence }
            let bounded = Array(selected.prefix(workCountLimit))
            let entries = bounded.map { captured in
                let snapshot = captured.snapshot
                return MCPReadFileInvocationDiagnosticPacket.WorkCountEntry(
                    sequence: captured.sequence,
                    source: safeReadSource(snapshot.source),
                    readBytes: snapshot.readBytes,
                    returnedBytes: snapshot.returnedBytes,
                    returnedLines: snapshot.returnedLines,
                    decodeMicroseconds: snapshot.decodeMicroseconds,
                    cacheHit: snapshot.cacheHit,
                    outcome: safeReadOutcome(snapshot.outcome)
                )
            }
            let omitted = max(0, selected.count - entries.count)
            return MCPReadFileInvocationDiagnosticPacket.WorkCountSection(
                state: captureWideLoss.workSectionCount > 0 ? "partial" : (entries.isEmpty ? "missing" : "observed"),
                retainedCount: entries.count,
                omittedCount: omitted,
                truncated: omitted > 0,
                captureWideOmittedCount: captureWideLoss.workSectionCount,
                captureWideLossImpact: captureWideLoss.workSectionCount > 0 ? "unknown" : "none",
                entries: entries
            )
        }

        private static func matches(_ appInvocationID: UUID, event: MCPToolExecutionTraceEvent) -> Bool {
            guard case let .valid(candidate) = traceIdentityValidation(event) else { return false }
            return candidate.appInvocationID == appInvocationID
        }

        private static func traceIdentityValidation(
            _ event: MCPToolExecutionTraceEvent
        ) -> TraceIdentityValidationResult {
            switch candidateResult(from: event.requestIdentity) {
            case .absent:
                return .valid(IdentityCandidate(
                    appInvocationID: event.invocationID,
                    connectionID: event.connectionID,
                    connectionGeneration: nil,
                    requestOrdinal: nil,
                    jsonRPCRequestKind: nil,
                    jsonRPCRequestToken: nil
                ))
            case let .valid(candidate):
                guard candidate.appInvocationID == event.invocationID,
                      candidate.connectionID == nil || candidate.connectionID == event.connectionID
                else {
                    return .inconsistent([candidate.appInvocationID, event.invocationID])
                }
                var joinedCandidate = candidate
                joinedCandidate.connectionID = joinedCandidate.connectionID ?? event.connectionID
                return .valid(joinedCandidate)
            case let .malformed(appInvocationID):
                var affectedAppInvocationIDs: Set<UUID> = [event.invocationID]
                if let appInvocationID {
                    affectedAppInvocationIDs.insert(appInvocationID)
                }
                return .malformed(affectedAppInvocationIDs)
            }
        }

        private static func providerEntryOffset(
            appInvocationID: UUID,
            lifecycleEvents: [EditFlowPerf.DebugCaptureLifecycleEvent]
        ) -> Double? {
            lifecycleEvents.first { event in
                guard event.eventName == "ReadFile.ProviderEntered",
                      case let .valid(candidate) = candidateResult(from: event.requestIdentity)
                else { return false }
                return candidate.appInvocationID == appInvocationID
            }?.offsetMS
        }

        private static func terminalState(
            appInvocationID: UUID,
            lifecycleEvents: [EditFlowPerf.DebugCaptureLifecycleEvent],
            traceEvents: [MCPToolExecutionTracer.DebugCapturedEvent],
            captureActive: Bool
        ) -> String {
            let phases = Set(traceEvents.filter { matches(appInvocationID, event: $0.event) }.map(\.event.phase))
            if phases.contains(.connectionForceDisconnectRequested) { return "force_disconnect_requested" }
            if phases.contains(.detachedSettled) { return "detached_settled" }
            if phases.contains(.detachedForSettlement) { return "detached" }
            if phases.contains(.settledDuringGrace) { return "settled_during_grace" }
            if phases.contains(.deadlineExpired) { return "deadline_expired" }
            if phases.contains(.handlerCompleted) { return "handler_completed" }
            let hasProviderResult = lifecycleEvents.contains {
                ($0.eventName == "ReadFile.ProviderResultReady" || $0.eventName == "MCP.ToolCall.HandlerResultReady")
                    && $0.requestIdentity?.appInvocationID.flatMap(UUID.init(uuidString:)) == appInvocationID
            }
            if hasProviderResult { return "provider_result_ready" }
            return captureActive ? "open" : "capture_closed_before_terminal"
        }

        private static func lifecycleKind(_ eventName: String) -> String? {
            switch eventName {
            case "MCP.ToolCall.Received": "tool_call_received"
            case "MCP.ToolCall.RoutingSnapshotCompleted": "tool_call_routing_snapshot_completed"
            case "MCP.ToolCall.LimiterWaitBegan": "tool_call_limiter_wait_began"
            case "MCP.ToolCall.LimiterAcquired": "tool_call_limiter_acquired"
            case "MCP.ToolCall.PermitQueued": "tool_call_permit_queued"
            case "MCP.ToolCall.PermitAcquired": "tool_call_permit_acquired"
            case "MCP.ToolCall.PermitReleased": "tool_call_permit_released"
            case "MCP.ToolCall.ResolvedProviderBegan": "tool_call_resolved_provider_began"
            case "MCP.ToolCall.ResolvedProviderEnded": "tool_call_resolved_provider_ended"
            case "MCP.ToolCall.HandlerResultReady": "tool_call_handler_result_ready"
            case "MCP.RunTool.ProviderBegan": "run_tool_provider_began"
            case "MCP.RunTool.ProviderEnded": "run_tool_provider_ended"
            case "MCP.RunTool.Return": "run_tool_returned"
            case "ReadFile.ProviderEntered": "read_file_provider_entered"
            case "ReadFile.ExplicitFreshnessBegan": "read_file_explicit_freshness_began"
            case "ReadFile.ExplicitFreshnessEnded": "read_file_explicit_freshness_ended"
            case "ReadFile.ExactCatalogLookupResolved": "read_file_exact_catalog_lookup_resolved"
            case "ReadFile.ExactCatalogShortcutResolved": "read_file_exact_catalog_shortcut_resolved"
            case "ReadFile.FolderResolutionReturned": "read_file_folder_resolution_returned"
            case "ReadFile.ReadableServiceResolutionReturned": "read_file_service_resolution_returned"
            case "ReadFile.ContentLoadBegan": "read_file_content_load_began"
            case "ReadFile.ContentLoadEnded": "read_file_content_load_ended"
            case "ReadFile.StoreReadContentEntered": "read_file_store_content_entered"
            case "ReadFile.StoreReadContentReturned": "read_file_store_content_returned"
            case "ReadFile.ProviderResultReady": "read_file_provider_result_ready"
            case "WorkspaceExactResolution.Checkpoint": "workspace_exact_resolution_checkpoint"
            case "FileSystem.ContentLoadEntered": "file_system_content_load_entered"
            case "FileSystem.ContentReadRequestPrepared": "file_system_content_read_request_prepared"
            case "FileSystem.ContentReadOffActorScheduled": "file_system_content_read_off_actor_scheduled"
            case "FileSystem.ContentReadWorkerReturned": "file_system_content_read_worker_returned"
            case "FileSystem.ContentLoadReturned": "file_system_content_load_returned"
            case "FileSystem.ContentReadWorkerPermitWaitBegan": "file_system_content_permit_wait_began"
            case "FileSystem.ContentReadWorkerPermitAcquired": "file_system_content_permit_acquired"
            case "FileSystem.ContentReadWorkerPermitCancelled": "file_system_content_permit_cancelled"
            case "FileSystem.ContentReadWorkerOverloaded": "file_system_content_overloaded"
            default: nil
            }
        }

        private static func safeReadSource(_ source: String) -> String {
            switch source {
            case "disk", "external_disk", "interactive_cache", "unknown": source
            default: "unknown"
            }
        }

        private static func safeReadOutcome(_ outcome: String) -> String {
            switch outcome {
            case "success", "cancelled", "error": outcome
            default: "error"
            }
        }

        private static func saturatedSum(_ lhs: Int, _ rhs: Int) -> Int {
            let (sum, overflow) = lhs.addingReportingOverflow(rhs)
            return overflow ? Int.max : sum
        }

        private static func incremented(_ value: Int) -> Int {
            value == Int.max ? value : value + 1
        }
    }
#endif
