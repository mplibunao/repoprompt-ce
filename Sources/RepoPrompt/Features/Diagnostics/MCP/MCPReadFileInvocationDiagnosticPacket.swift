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
        let watchdogTerminalObserved: Bool
        let openInnerStagesAtWatchdogTerminal: [String]
        let longestClosedInnerStage: InnerStageSummary?
        let requiredEvidenceComplete: Bool
        let invocation: InvocationSection
        let runtimeIdentity: RuntimeIdentitySection
        let routingProjection: AttributionSection
        let gitArtifact: AttributionSection
        let freshnessAuthorityIngress: AttributionSection
        let exactResolution: AttributionSection
        let interactiveLoad: AttributionSection
        let settlement: AttributionSection
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
                "watchdog_terminal_observed": watchdogTerminalObserved,
                "open_inner_stages_at_watchdog_terminal": openInnerStagesAtWatchdogTerminal,
                "longest_closed_inner_stage": Self.optional(longestClosedInnerStage?.payload),
                "required_evidence_complete": requiredEvidenceComplete,
                "invocation": invocation.payload,
                "runtime_identity": runtimeIdentity.payload,
                "routing_projection": routingProjection.payload,
                "git_artifact": gitArtifact.payload,
                "freshness_authority_ingress": freshnessAuthorityIngress.payload,
                "exact_resolution": exactResolution.payload,
                "interactive_load": interactiveLoad.payload,
                "settlement": settlement.payload,
                "lifecycle": lifecycle.payload,
                "execution_trace": executionTrace.payload,
                "work_counts": workCounts.payload
            ]
        }

        struct InnerStageSummary {
            let section: String
            let stage: String
            let durationMilliseconds: Double

            var payload: [String: Any] {
                [
                    "section": section,
                    "stage": stage,
                    "duration_ms": MCPReadFileInvocationDiagnosticPacket.roundedMS(durationMilliseconds)
                ]
            }
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

        struct AttributionEntry {
            let ordinal: UInt64
            let offsetMilliseconds: Double
            let kind: String
            let dimensions: [String: String]

            var payload: [String: Any] {
                var result: [String: Any] = [
                    "ordinal": ordinal,
                    "offset_ms": MCPReadFileInvocationDiagnosticPacket.roundedMS(offsetMilliseconds),
                    "kind": kind
                ]
                for key in Self.allowedKeys(for: kind) {
                    let value: Any = if let dimension = dimensions[key] {
                        dimension
                    } else if kind == "ReadFile.LookupProjectionResolved",
                              Self.lifetimeTruthKeys.contains(key)
                    {
                        "not_checked"
                    } else {
                        NSNull()
                    }
                    result[Self.payloadKey(for: key)] = value
                }
                return result
            }

            private static let lifetimeTruthKeys: Set<String> = [
                "lifetimeCurrentBefore", "lifetimeCurrentAfter"
            ]

            static func allowedKeys(for eventName: String) -> [String] {
                switch eventName {
                case "ReadFile.DomainRouteResolved":
                    ["windowID", "workspaceID", "tabID", "agentSessionID", "runID", "bindingKind", "requestedRunValidated"]
                case "ReadFile.LookupProjectionResolved":
                    [
                        "rootCount", "bindingFingerprintToken", "hydrationState", "projectionSource",
                        "usesWorktreeProjection", "lifetimeCurrentBefore", "lifetimeCurrentAfter",
                        "visibleRootFingerprintToken", "visibleRootFingerprintTokenAfter", "agentSessionID"
                    ]
                case "ReadFile.PathClassified":
                    [
                        "inputShape", "translationRoute", "rootScopeKind", "rootCount",
                        "logicalRootToken", "physicalRootToken", "bindingFingerprintToken",
                        "usesWorktreeProjection", "ownershipGeneration", "rootLifetimeID"
                    ]
                case "ReadFile.GitPreflightBegan", "ReadFile.GitPreflightEnded":
                    ["gitClassification", "gitCapability", "gitPreflightStatus", "candidateCount", "examinedCount", "outcome"]
                case "ReadFile.GitCandidateResolved":
                    ["outcome", "serialPosition", "candidateKind", "rejectionReason"]
                case "ReadFile.ExplicitFreshnessBegan", "ReadFile.ExplicitFreshnessEnded":
                    ["rootCount", "pendingRawEventCount", "outcome"]
                case "ReadFile.FreshnessRootSnapshot":
                    [
                        "purpose", "status", "outcome", "rootToken", "serialPosition", "activeCount",
                        "workerCount", "queueDepth", "taskCount", "waiterCount", "pendingRawEventCount",
                        "ingressSequence", "barrierSequence", "observerToken", "durationMicroseconds",
                        "providerActive", "permitActive", "publicationPending"
                    ]
                case "ReadFile.SeededAuthorityWaitBegan", "ReadFile.SeededAuthorityWaitEnded":
                    ["purpose", "outcome", "rootToken"]
                case "ReadFile.IngressBarrierBegan", "ReadFile.IngressBarrierEnded":
                    ["outcome", "rootToken", "ingressSequence", "observerToken"]
                case "WorkspaceExactResolution.Checkpoint":
                    ["purpose", "status", "outcome", "rootToken", "serialPosition"]
                case "ReadFile.InteractiveStage":
                    [
                        "purpose", "status", "outcome", "rootToken", "serialPosition",
                        "bindingFingerprintToken", "visibleRootFingerprintToken", "fileBytes", "cacheHit"
                    ]
                case "ReadFile.SettlementTransition":
                    [
                        "purpose", "status", "outcome", "windowID", "activeCount", "workerCount",
                        "errorCount", "durationMicroseconds", "blocksAdmission", "isReleased"
                    ]
                default:
                    []
                }
            }

            private static func payloadKey(for dimensionKey: String) -> String {
                var scalars: [Character] = []
                for character in dimensionKey {
                    if character.isUppercase {
                        scalars.append("_")
                        scalars.append(Character(character.lowercased()))
                    } else {
                        scalars.append(character)
                    }
                }
                return String(scalars)
            }
        }

        struct AttributionSection {
            let state: String
            let retainedCount: Int
            let omittedCount: Int
            let truncated: Bool
            let openSpanCount: Int
            let terminalIntegrity: String
            let entries: [AttributionEntry]

            var payload: [String: Any] {
                [
                    "state": state,
                    "retained_count": retainedCount,
                    "omitted_count": omittedCount,
                    "truncated": truncated,
                    "open_span_count": openSpanCount,
                    "terminal_integrity": terminalIntegrity,
                    "entries": entries.map(\.payload)
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
            let cancellationOutcome: String?
            let cancellationOrigin: String?
            let settlement: String?
            let graceOutcome: String?
            let escalationReason: String?
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
                    "cancellation_outcome": MCPReadFileInvocationDiagnosticPacket.optional(cancellationOutcome),
                    "cancellation_origin": MCPReadFileInvocationDiagnosticPacket.optional(cancellationOrigin),
                    "settlement": MCPReadFileInvocationDiagnosticPacket.optional(settlement),
                    "grace_outcome": MCPReadFileInvocationDiagnosticPacket.optional(graceOutcome),
                    "escalation_reason": MCPReadFileInvocationDiagnosticPacket.optional(escalationReason),
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

    private struct DeadlineSummaryDecision {
        enum BoundaryStatus {
            case available
            case missing
            case ambiguous
        }

        let watchdogTerminalObserved: Bool
        let retainedBoundaryStatus: BoundaryStatus
        let analysisBoundaryOrdinal: UInt64?
        let evidenceCompleteForAnalysis: Bool

        static func classify(
            executionEntries: [MCPReadFileInvocationDiagnosticPacket.ExecutionTraceEntry],
            settlementEntries: [MCPReadFileInvocationDiagnosticPacket.AttributionEntry],
            evidenceCompleteForAnalysis: Bool
        ) -> DeadlineSummaryDecision {
            let watchdogTerminalObserved = executionEntries.contains {
                $0.phase == MCPToolExecutionTraceEvent.Phase.deadlineExpired.rawValue
            }
            let operationCancellationObserved = executionEntries.contains {
                $0.phase == MCPToolExecutionTraceEvent.Phase.cancellationRequested.rawValue
                    || $0.cancellationRequested == true
                    || $0.cancellationOrigin != nil
            }
            let deadlineEntries = executionEntries.filter {
                $0.phase == MCPToolExecutionTraceEvent.Phase.deadlineExpired.rawValue
            }
            let graceTerminalEntries = executionEntries.filter {
                $0.phase == MCPToolExecutionTraceEvent.Phase.settledDuringGrace.rawValue
            }
            let nonCancelledGraceTerminalObserved = graceTerminalEntries.contains {
                $0.cancellationRequested == false
            }
            let orderedNonCancelledGraceTerminalObserved = if deadlineEntries.count == 1,
                                                              graceTerminalEntries.count == 1
            {
                graceTerminalEntries[0].sequence > deadlineEntries[0].sequence
                    && graceTerminalEntries[0].cancellationRequested == false
                    && graceTerminalEntries[0].cancellationOutcome != nil
                    && graceTerminalEntries[0].graceOutcome == "late_completion"
            } else {
                false
            }
            let preciseBoundaries = settlementEntries.filter {
                $0.dimensions["purpose"] == "execution_deadline_cancellation_boundary"
            }
            let preciseBoundaryAmbiguous = preciseBoundaries.count > 1
                || (!preciseBoundaries.isEmpty && nonCancelledGraceTerminalObserved)
            let preciseBoundaryOrdinal = preciseBoundaries.count == 1
                && !preciseBoundaryAmbiguous
                ? preciseBoundaries[0].ordinal
                : nil
            let laterFallbackAuthorized = evidenceCompleteForAnalysis
                && orderedNonCancelledGraceTerminalObserved
                && !operationCancellationObserved
            let laterFallbackOrdinal = !preciseBoundaryAmbiguous
                && laterFallbackAuthorized
                ? settlementEntries.first(where: {
                    $0.dimensions["purpose"] == MCPToolExecutionTraceEvent.Phase.deadlineExpired.rawValue
                })?.ordinal
                : nil
            let retainedBoundaryStatus: BoundaryStatus = if preciseBoundaryAmbiguous {
                .ambiguous
            } else if preciseBoundaryOrdinal != nil || laterFallbackOrdinal != nil {
                .available
            } else {
                .missing
            }
            let retainedBoundaryOrdinal = preciseBoundaryOrdinal ?? laterFallbackOrdinal
            let analysisBoundaryOrdinal = watchdogTerminalObserved && evidenceCompleteForAnalysis
                ? retainedBoundaryOrdinal
                : nil

            return DeadlineSummaryDecision(
                watchdogTerminalObserved: watchdogTerminalObserved,
                retainedBoundaryStatus: retainedBoundaryStatus,
                analysisBoundaryOrdinal: analysisBoundaryOrdinal,
                evidenceCompleteForAnalysis: evidenceCompleteForAnalysis
            )
        }
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

            let freshnessCancellationOutcome = trace.events.contains {
                matches(appInvocationID, event: $0.event)
                    && $0.event.cancellationOrigin == .watchdogDeadline
            } ? "outer_cancellation" : "other_cancellation"
            let routingProjection = attributionSection(
                appInvocationID: appInvocationID,
                capture: capture,
                eventNames: routeProjectionEventNames,
                limit: 64,
                captureActive: capture.active
            )
            let gitArtifact = attributionSection(
                appInvocationID: appInvocationID,
                capture: capture,
                eventNames: gitEventNames,
                limit: 128,
                captureActive: capture.active
            )
            let capturedFreshnessAuthorityIngress = attributionSection(
                appInvocationID: appInvocationID,
                capture: capture,
                eventNames: freshnessAuthorityIngressEventNames,
                limit: 128,
                captureActive: capture.active,
                freshnessCancellationOutcome: freshnessCancellationOutcome
            )
            let capturedExactResolution = attributionSection(
                appInvocationID: appInvocationID,
                capture: capture,
                eventNames: exactResolutionEventNames,
                limit: 512,
                captureActive: capture.active
            )
            let capturedInteractiveLoad = attributionSection(
                appInvocationID: appInvocationID,
                capture: capture,
                eventNames: interactiveEventNames,
                limit: 256,
                captureActive: capture.active
            )
            let gitAuthorizedArtifact = gitArtifact.entries.contains {
                $0.dimensions["gitPreflightStatus"] == "authorized"
                    || $0.dimensions["outcome"] == "authorized_requested_entry"
            }
            let ordinaryReadStoppedAtFreshness = capturedFreshnessAuthorityIngress.entries.contains {
                guard $0.kind == "ReadFile.ExplicitFreshnessEnded",
                      let outcome = $0.dimensions["outcome"]
                else { return false }
                return outcome != "success"
            }
            let freshnessAuthorityIngress = gitAuthorizedArtifact
                ? sectionStateIfMissing(capturedFreshnessAuthorityIngress, state: "not_applicable")
                : capturedFreshnessAuthorityIngress
            let exactResolution = if gitAuthorizedArtifact {
                sectionStateIfMissing(capturedExactResolution, state: "not_applicable")
            } else if ordinaryReadStoppedAtFreshness {
                sectionStateIfMissing(capturedExactResolution, state: "not_entered")
            } else {
                capturedExactResolution
            }
            let interactiveLoad = if gitAuthorizedArtifact {
                sectionStateIfMissing(capturedInteractiveLoad, state: "not_applicable")
            } else if ordinaryReadStoppedAtFreshness {
                sectionStateIfMissing(capturedInteractiveLoad, state: "not_entered")
            } else {
                capturedInteractiveLoad
            }
            let settlement = attributionSection(
                appInvocationID: appInvocationID,
                capture: capture,
                eventNames: settlementEventNames,
                limit: 64,
                captureActive: capture.active
            )
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

            let innerSections = [
                (name: "freshness_authority_ingress", entries: freshnessAuthorityIngress.entries),
                (name: "exact_resolution", entries: exactResolution.entries),
                (name: "interactive_load", entries: interactiveLoad.entries)
            ]
            let relevantSelectedEvidenceComplete = !freshnessAuthorityIngress.truncated
                && !exactResolution.truncated
                && !interactiveLoad.truncated
                && !settlement.truncated
                && !lifecycle.truncated
                && !execution.truncated
                && execution.omittedCount == 0
            let deadlineSummaryEvidenceComplete = relevantSelectedEvidenceComplete
                && !captureWideLoss.hasAny
            let deadlineDecision = DeadlineSummaryDecision.classify(
                executionEntries: execution.entries,
                settlementEntries: settlement.entries,
                evidenceCompleteForAnalysis: deadlineSummaryEvidenceComplete
            )
            // Settlement transitions and inner stages share the capture lifecycle ordinal authority.
            // Slice only the summary analysis so later grace/detached terminals remain in full history.
            let innerAnalyses = innerSections.map { section in
                let entries = if deadlineDecision.watchdogTerminalObserved {
                    section.entries.filter { entry in
                        deadlineDecision.analysisBoundaryOrdinal.map { entry.ordinal <= $0 } ?? false
                    }
                } else {
                    section.entries
                }
                return innerSpanAnalysis(section: section.name, entries: entries)
            }
            let openInnerStagesAtWatchdogTerminal = deadlineDecision.watchdogTerminalObserved
                && deadlineDecision.analysisBoundaryOrdinal != nil
                ? innerAnalyses.flatMap(\.openStages).sorted()
                : []
            let longestClosedInnerStage = deadlineDecision.watchdogTerminalObserved
                && deadlineDecision.analysisBoundaryOrdinal == nil
                ? nil
                : innerAnalyses.flatMap(\.closedStages).sorted {
                    if $0.durationMilliseconds == $1.durationMilliseconds {
                        return $0.stage < $1.stage
                    }
                    return $0.durationMilliseconds > $1.durationMilliseconds
                }.first

            var missingRequiredEvidence: [String] = []
            if !invocationComplete { missingRequiredEvidence.append("invocation_identity") }
            if !runtimeComplete { missingRequiredEvidence.append("runtime_identity") }
            if lifecycle.entries.isEmpty { missingRequiredEvidence.append("lifecycle") }
            if lifecycle.truncated { missingRequiredEvidence.append("lifecycle:truncated") }
            if execution.entries.isEmpty { missingRequiredEvidence.append("execution_trace") }
            if execution.truncated { missingRequiredEvidence.append("execution_trace:truncated") }
            if execution.terminalState == "open"
                || execution.terminalState == "capture_closed_before_terminal"
            {
                missingRequiredEvidence.append("execution_terminal")
            }
            for (name, section) in [
                ("freshness_authority_ingress", freshnessAuthorityIngress),
                ("exact_resolution", exactResolution),
                ("interactive_load", interactiveLoad),
                ("settlement", settlement)
            ] {
                let stateComplete = ["observed", "not_entered", "not_applicable"].contains(section.state)
                if section.truncated {
                    missingRequiredEvidence.append("\(name):truncated")
                }
                if section.terminalIntegrity != "balanced" {
                    missingRequiredEvidence.append("\(name):\(section.terminalIntegrity)")
                } else if !stateComplete {
                    missingRequiredEvidence.append("\(name):\(section.state)")
                }
            }
            if deadlineDecision.watchdogTerminalObserved {
                switch deadlineDecision.retainedBoundaryStatus {
                case .ambiguous:
                    missingRequiredEvidence.append("watchdog_terminal_boundary:ambiguous")
                case .missing:
                    missingRequiredEvidence.append("watchdog_terminal_boundary:missing")
                case .available:
                    let openSections = Set(innerAnalyses.compactMap { analysis in
                        analysis.openStages.isEmpty ? nil : analysis.section
                    })
                    missingRequiredEvidence.append(contentsOf: openSections.sorted().map {
                        "\($0):open_at_watchdog_terminal"
                    })
                }
            }

            let selectedInvocationTruncated = routingProjection.truncated
                || gitArtifact.truncated
                || freshnessAuthorityIngress.truncated
                || exactResolution.truncated
                || interactiveLoad.truncated
                || settlement.truncated
                || lifecycle.truncated
                || execution.truncated
                || workCounts.truncated
            let requiredEvidenceComplete = missingRequiredEvidence.isEmpty
                && !captureWideLoss.hasAny
                && !selectedInvocationTruncated
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
                watchdogTerminalObserved: deadlineDecision.watchdogTerminalObserved,
                openInnerStagesAtWatchdogTerminal: openInnerStagesAtWatchdogTerminal,
                longestClosedInnerStage: longestClosedInnerStage,
                requiredEvidenceComplete: requiredEvidenceComplete,
                invocation: invocation,
                runtimeIdentity: runtime,
                routingProjection: routingProjection,
                gitArtifact: gitArtifact,
                freshnessAuthorityIngress: freshnessAuthorityIngress,
                exactResolution: exactResolution,
                interactiveLoad: interactiveLoad,
                settlement: settlement,
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

        private static let routeProjectionEventNames: Set<String> = [
            "ReadFile.DomainRouteResolved",
            "ReadFile.LookupProjectionResolved",
            "ReadFile.PathClassified"
        ]

        private static let gitEventNames: Set<String> = [
            "ReadFile.GitPreflightBegan",
            "ReadFile.GitCandidateResolved",
            "ReadFile.GitPreflightEnded"
        ]

        private static let freshnessAuthorityIngressEventNames: Set<String> = [
            "ReadFile.ExplicitFreshnessBegan",
            "ReadFile.ExplicitFreshnessEnded",
            "ReadFile.FreshnessRootSnapshot",
            "ReadFile.SeededAuthorityWaitBegan",
            "ReadFile.SeededAuthorityWaitEnded",
            "ReadFile.IngressBarrierBegan",
            "ReadFile.IngressBarrierEnded"
        ]

        private static let exactResolutionEventNames: Set<String> = [
            "WorkspaceExactResolution.Checkpoint"
        ]

        private static let interactiveEventNames: Set<String> = [
            "ReadFile.InteractiveStage"
        ]

        private static let settlementEventNames: Set<String> = [
            "ReadFile.SettlementTransition"
        ]

        private static func attributionSection(
            appInvocationID: UUID,
            capture: EditFlowPerf.DebugCaptureSnapshot,
            eventNames: Set<String>,
            limit: Int,
            captureActive: Bool,
            freshnessCancellationOutcome: String? = nil
        ) -> MCPReadFileInvocationDiagnosticPacket.AttributionSection {
            let selected = capture.lifecycleEvents.filter {
                eventNames.contains($0.eventName)
                    && $0.requestIdentity?.appInvocationID.flatMap(UUID.init(uuidString:)) == appInvocationID
            }
            let entries = selected.prefix(limit).map { event in
                MCPReadFileInvocationDiagnosticPacket.AttributionEntry(
                    ordinal: event.ordinal,
                    offsetMilliseconds: event.offsetMS,
                    kind: event.eventName,
                    dimensions: sanitizedDimensionMap(
                        event.sanitizedDimensions,
                        eventName: event.eventName,
                        freshnessCancellationOutcome: freshnessCancellationOutcome
                    )
                )
            }
            let omitted = max(0, selected.count - entries.count)
            let balance = spanBalance(entries: entries, captureActive: captureActive)
            let state: String = if entries.isEmpty {
                "missing"
            } else if omitted > 0 {
                "truncated"
            } else if balance.integrity != "balanced", balance.openCount == 0 {
                "missing"
            } else if balance.openCount > 0 {
                captureActive ? "open" : "capture_closed_before_terminal"
            } else {
                "observed"
            }
            return MCPReadFileInvocationDiagnosticPacket.AttributionSection(
                state: state,
                retainedCount: entries.count,
                omittedCount: omitted,
                truncated: omitted > 0,
                openSpanCount: balance.openCount,
                terminalIntegrity: balance.integrity,
                entries: entries
            )
        }

        private static func sectionStateIfMissing(
            _ section: MCPReadFileInvocationDiagnosticPacket.AttributionSection,
            state: String
        ) -> MCPReadFileInvocationDiagnosticPacket.AttributionSection {
            guard section.state == "missing" else { return section }
            return MCPReadFileInvocationDiagnosticPacket.AttributionSection(
                state: state,
                retainedCount: section.retainedCount,
                omittedCount: section.omittedCount,
                truncated: section.truncated,
                openSpanCount: section.openSpanCount,
                terminalIntegrity: section.terminalIntegrity,
                entries: section.entries
            )
        }

        private static func spanBalance(
            entries: [MCPReadFileInvocationDiagnosticPacket.AttributionEntry],
            captureActive: Bool
        ) -> (openCount: Int, integrity: String) {
            var openByKey: [String: Int] = [:]
            var closedKeys: Set<String> = []
            var orphanTerminal = false
            var duplicateTerminal = false
            var duplicateBegin = false
            for entry in entries.sorted(by: { $0.ordinal < $1.ordinal }) {
                guard let transition = spanTransition(entry) else { continue }
                switch transition.kind {
                case .began:
                    if openByKey[transition.key, default: 0] > 0 {
                        duplicateBegin = true
                    }
                    openByKey[transition.key, default: 0] += 1
                case .ended:
                    guard openByKey[transition.key, default: 0] > 0 else {
                        if closedKeys.contains(transition.key) {
                            duplicateTerminal = true
                        } else {
                            orphanTerminal = true
                        }
                        continue
                    }
                    openByKey[transition.key, default: 0] -= 1
                    closedKeys.insert(transition.key)
                }
            }
            let openCount = openByKey.values.reduce(0, +)
            let integrity: String = if orphanTerminal {
                "orphan_terminal"
            } else if duplicateTerminal {
                "duplicate_terminal"
            } else if duplicateBegin {
                "duplicate_begin"
            } else if openCount > 0 {
                captureActive ? "open" : "capture_closed_before_terminal"
            } else {
                "balanced"
            }
            return (openCount, integrity)
        }

        private struct InnerSpanAnalysis {
            let section: String
            let openStages: [String]
            let closedStages: [MCPReadFileInvocationDiagnosticPacket.InnerStageSummary]
        }

        private static func innerSpanAnalysis(
            section: String,
            entries: [MCPReadFileInvocationDiagnosticPacket.AttributionEntry]
        ) -> InnerSpanAnalysis {
            var openByKey: [String: [MCPReadFileInvocationDiagnosticPacket.AttributionEntry]] = [:]
            var closed: [MCPReadFileInvocationDiagnosticPacket.InnerStageSummary] = []
            for entry in entries.sorted(by: { $0.ordinal < $1.ordinal }) {
                guard let transition = spanTransition(entry) else { continue }
                switch transition.kind {
                case .began:
                    openByKey[transition.key, default: []].append(entry)
                case .ended:
                    guard var began = openByKey[transition.key], !began.isEmpty else { continue }
                    let start = began.removeFirst()
                    openByKey[transition.key] = began
                    closed.append(MCPReadFileInvocationDiagnosticPacket.InnerStageSummary(
                        section: section,
                        stage: innerStageName(section: section, entry: start),
                        durationMilliseconds: max(0, entry.offsetMilliseconds - start.offsetMilliseconds)
                    ))
                }
            }
            let open = openByKey.values.flatMap(\.self).map {
                innerStageName(section: section, entry: $0)
            }.sorted()
            return InnerSpanAnalysis(section: section, openStages: open, closedStages: closed)
        }

        private static func innerStageName(
            section: String,
            entry: MCPReadFileInvocationDiagnosticPacket.AttributionEntry
        ) -> String {
            let event = removingTransitionSuffix(entry.kind)
            let purpose = entry.dimensions["purpose"]
            let status = entry.dimensions["status"].map(removingTransitionSuffix)
            return [section, event, purpose, status]
                .compactMap { value in value?.isEmpty == false ? value : nil }
                .joined(separator: ":")
        }

        private enum SpanTransitionKind {
            case began
            case ended
        }

        private static func spanTransition(
            _ entry: MCPReadFileInvocationDiagnosticPacket.AttributionEntry
        ) -> (kind: SpanTransitionKind, key: String)? {
            let status = entry.dimensions["status"] ?? ""
            let eventTransition = transitionSuffix(entry.kind)
            let statusTransition = transitionSuffix(status)
            guard let transition = statusTransition ?? eventTransition else { return nil }
            let eventBase = removingTransitionSuffix(entry.kind)
            let statusBase = removingTransitionSuffix(status)
            let stableRootToken = eventBase == "WorkspaceExactResolution.Checkpoint"
                ? ""
                : entry.dimensions["rootToken"] ?? ""
            let key = [
                eventBase,
                statusBase,
                entry.dimensions["purpose"] ?? "",
                stableRootToken,
                entry.dimensions["serialPosition"] ?? ""
            ].joined(separator: "|")
            return (transition, key)
        }

        private static func transitionSuffix(_ value: String) -> SpanTransitionKind? {
            if value == "began" || value.hasSuffix("Began") { return .began }
            if value == "ended" || value.hasSuffix("Ended") { return .ended }
            return nil
        }

        private static func removingTransitionSuffix(_ value: String) -> String {
            if value == "began" || value == "ended" { return "" }
            if value.hasSuffix("Began") { return String(value.dropLast("Began".count)) }
            if value.hasSuffix("Ended") { return String(value.dropLast("Ended".count)) }
            return value
        }

        private static func sanitizedDimensionMap(
            _ serialized: String,
            eventName: String,
            freshnessCancellationOutcome: String?
        ) -> [String: String] {
            var result: [String: String] = [:]
            for component in serialized.split(separator: " ") {
                guard let separator = component.firstIndex(of: "=") else { continue }
                let key = String(component[..<separator])
                var value = String(component[component.index(after: separator)...])
                guard !key.isEmpty, !value.isEmpty else { continue }
                if eventName == "ReadFile.ExplicitFreshnessEnded",
                   key == "outcome",
                   value == "other_cancellation",
                   let freshnessCancellationOutcome
                {
                    value = freshnessCancellationOutcome
                }
                guard result[key] == nil,
                      let safeValue = safeAttributionDimension(
                          eventName: eventName,
                          key: key,
                          value: value
                      )
                else { continue }
                result[key] = safeValue
            }
            return result
        }

        private static func safeAttributionDimension(
            eventName: String,
            key: String,
            value: String
        ) -> String? {
            let allowedKeys = Set(MCPReadFileInvocationDiagnosticPacket.AttributionEntry.allowedKeys(for: eventName))
            guard allowedKeys.contains(key) else { return nil }
            switch key {
            case "rootCount", "ownershipGeneration", "windowID", "candidateCount", "examinedCount",
                 "serialPosition", "activeCount", "workerCount", "errorCount", "queueDepth", "taskCount",
                 "waiterCount", "pendingRawEventCount", "ingressSequence", "barrierSequence",
                 "observerToken", "durationMicroseconds", "fileBytes":
                return UInt64(value) == nil && Int64(value) == nil ? nil : value
            case "usesWorktreeProjection", "lifetimeCurrentBefore", "lifetimeCurrentAfter",
                 "requestedRunValidated", "cacheHit", "providerActive", "permitActive", "publicationPending",
                 "blocksAdmission", "isReleased":
                return value == "true" || value == "false" ? value : nil
            case "workspaceID", "tabID", "agentSessionID", "runID", "rootLifetimeID", "rootToken":
                return UUID(uuidString: value) == nil ? nil : value
            case "logicalRootToken", "physicalRootToken", "bindingFingerprintToken",
                 "visibleRootFingerprintToken", "visibleRootFingerprintTokenAfter":
                return isCaptureToken(value) ? value : nil
            default:
                guard let allowed = allowedAttributionValues(eventName: eventName, key: key),
                      allowed.contains(value)
                else { return nil }
                return value
            }
        }

        private static func isCaptureToken(_ value: String) -> Bool {
            let components = value.split(separator: ":", omittingEmptySubsequences: false)
            guard components.count == 2,
                  [
                      "logical_root", "physical_root", "binding_fingerprint",
                      "visible_root_fingerprint", "cache_key", "file_system_fingerprint"
                  ].contains(String(components[0])),
                  components[1].count == 64
            else { return false }
            return components[1].allSatisfy { "0123456789abcdef".contains($0) }
        }

        private static func allowedAttributionValues(eventName: String, key: String) -> Set<String>? {
            switch (eventName, key) {
            case ("ReadFile.DomainRouteResolved", "bindingKind"):
                ["explicit", "app_presentation", "run_scoped"]
            case ("ReadFile.LookupProjectionResolved", "hydrationState"):
                ["not_applicable", "hydrated", "unhydrated", "unavailable"]
            case ("ReadFile.LookupProjectionResolved", "projectionSource"):
                ["fail_closed", "frozen_context", "cache_hit", "newly_materialized"]
            case ("ReadFile.PathClassified", "inputShape"):
                ["absolute", "explicit_root", "bare_relative"]
            case ("ReadFile.PathClassified", "translationRoute"):
                ["unchanged_physical", "logical_to_physical", "alias_to_physical", "single_binding_relative", "untranslated", "blocked"]
            case ("ReadFile.PathClassified", "rootScopeKind"):
                ["visible_workspace", "visible_workspace_plus_git_data", "all_loaded", "all_loaded_excluding_git_data", "session_bound", "validated_session_bound"]
            case let (event, "gitClassification") where gitEventNames.contains(event):
                ["syntactic_git", "not_evaluated", "git_artifact_target", "possible_git_artifact", "ordinary"]
            case let (event, "gitCapability") where gitEventNames.contains(event):
                ["not_evaluated", "absent", "direct", "delegated"]
            case let (event, "gitPreflightStatus") where gitEventNames.contains(event):
                ["open", "failed", "cancelled", "rejected", "not_applicable", "ordinary_fallthrough", "authorized"]
            case ("ReadFile.GitCandidateResolved", "outcome"):
                ["authorized", "rejected"]
            case ("ReadFile.GitCandidateResolved", "candidateKind"):
                ["map", "patch", "unknown"]
            case ("ReadFile.GitCandidateResolved", "rejectionReason"):
                [
                    "invalid_absolute_path", "outside_workspace_git_data", "capability_root_unavailable",
                    "not_cataloged", "unsupported_artifact_path", "manifest_not_cataloged",
                    "manifest_unreadable", "manifest_invalid", "manifest_identity_mismatch", "tab_mismatch",
                    "legacy_tab_not_allowed", "repository_provenance_missing", "checkout_provenance_mismatch",
                    "unlisted_patch", "content_unreadable", "not_in_delegated_selection",
                    "delegation_consumer_mismatch", "delegation_workspace_mismatch",
                    "legacy_artifact_not_delegable", "delegation_binding_mismatch"
                ]
            case ("ReadFile.GitPreflightEnded", "outcome"):
                ["not_evaluated", "rejected_target", "no_requested_match", "authorized_requested_entry"]
            case ("ReadFile.ExplicitFreshnessEnded", "outcome"):
                ["success", "inner_timeout", "outer_cancellation", "other_cancellation", "error"]
            case ("ReadFile.FreshnessRootSnapshot", "purpose"):
                ["explicit_freshness_pre", "explicit_freshness_post", "explicit_ingress", "interactive_pre", "interactive_post"]
            case ("ReadFile.FreshnessRootSnapshot", "status"):
                ["before", "after"]
            case ("ReadFile.FreshnessRootSnapshot", "outcome"):
                ["no_fence", "reconciliation_failed", "blocked_reconciling", "queryable"]
            case let (event, "purpose") where event == "ReadFile.SeededAuthorityWaitBegan" || event == "ReadFile.SeededAuthorityWaitEnded":
                ["explicit_freshness_pre", "explicit_freshness_post", "interactive_pre", "interactive_post"]
            case ("ReadFile.SeededAuthorityWaitEnded", "outcome"):
                ["completed", "cancelled", "failed_unavailable", "failed_other"]
            case ("ReadFile.IngressBarrierEnded", "outcome"):
                [
                    "cancelled_or_unavailable", "no_op", "joined", "joined_cancelled", "joined_completed",
                    "coalesced_successor", "coalesced_successor_cancelled", "coalesced_successor_completed",
                    "successor", "successor_cancelled", "successor_completed", "launched",
                    "launched_cancelled", "launched_completed"
                ]
            case ("WorkspaceExactResolution.Checkpoint", "purpose"):
                ["qualifiedTargetValidation", "bareRelativeNamespaceClassification", "canonicalCompaction", "explicitMaterialization"]
            case ("WorkspaceExactResolution.Checkpoint", "status"):
                [
                    "bindingProbeBegan", "bindingProbeEnded", "catalogValidationBegan", "catalogValidationEnded",
                    "eligibilityBegan", "eligibilityEnded", "missingFilePruneBegan", "missingFilePruneEnded",
                    "materializationBegan", "materializationEnded", "candidateEligibilityBegan",
                    "candidateEligibilityEnded", "candidateMissingFilePruneBegan",
                    "candidateMissingFilePruneEnded", "managedRegistrationBegan", "managedRegistrationEnded",
                    "codemapRootFenceBegan", "codemapRootFenceEnded", "codemapCleanupFlightsBegan",
                    "codemapCleanupFlightsEnded"
                ]
            case ("WorkspaceExactResolution.Checkpoint", "outcome"):
                [
                    "unavailable", "missing", "current", "catalogCurrent", "eligible", "ignored",
                    "missingOrDirectory", "ineligible", "completed", "error", "noCandidate", "blocked",
                    "ambiguous", "materialized", "cancelled", "acquired"
                ]
            case ("ReadFile.InteractiveStage", "purpose"):
                ["attempt", "fingerprint", "catalog_revalidation", "cache_snapshot", "content_load", "off_actor_preparation", "record_revalidation"]
            case ("ReadFile.InteractiveStage", "status"):
                ["began", "ended"]
            case ("ReadFile.InteractiveStage", "outcome"):
                [
                    "completed", "cancelled", "missing", "failed_other", "stale", "current", "hit",
                    "miss_loaded", "no_content", "scheduler_error", "fingerprint_changed",
                    "cancelled_fingerprint", "missing_fingerprint", "failed_fingerprint",
                    "retry_record_changed", "failed_record_changed", "retry_no_content", "failed_no_content",
                    "cancelled_cache_or_load", "failed_scheduler", "retry_fingerprint_changed",
                    "failed_fingerprint_changed", "missing_content"
                ]
            case ("ReadFile.SettlementTransition", "purpose"):
                [
                    "admission", "busy_admission", "execution_exit", "execution_contract_selected",
                    "execution_started", "execution_handler_completed", "execution_handler_phase_transition",
                    "execution_deadline_cancellation_boundary", "execution_deadline_expired",
                    "execution_cancellation_requested", "execution_settled_during_grace",
                    "execution_cleanup_grace_expired", "execution_detached_for_settlement",
                    "execution_detached_settled", "recovery_released", "connection_force_disconnect_requested"
                ]
            case ("ReadFile.SettlementTransition", "status"):
                ["reserved", "detaching", "detaching_success", "detaching_cancellation", "detaching_error", "detached", "abandoned", "force_disconnecting", "settled"]
            case ("ReadFile.SettlementTransition", "outcome"):
                [
                    "admitted", "detached", "abandoned", "settling", "released_provider_limit", "released",
                    "retained", "already_settled", "unavailable", "success", "cancellation", "error",
                    "observed", "late_completion", "expired", "settled"
                ]
            default:
                nil
            }
        }

        private static func lifecycleSection(
            appInvocationID: UUID,
            capture: EditFlowPerf.DebugCaptureSnapshot,
            captureWideLoss: CaptureWideLoss
        ) -> MCPReadFileInvocationDiagnosticPacket.LifecycleSection {
            let selected = capture.lifecycleEvents.filter {
                $0.requestIdentity?.appInvocationID.flatMap(UUID.init(uuidString:)) == appInvocationID
            }
            let genericSelected = selected.filter {
                !routeProjectionEventNames.contains($0.eventName)
                    && !gitEventNames.contains($0.eventName)
                    && !freshnessAuthorityIngressEventNames.contains($0.eventName)
                    && !exactResolutionEventNames.contains($0.eventName)
                    && !interactiveEventNames.contains($0.eventName)
                    && !settlementEventNames.contains($0.eventName)
            }
            let recognized = genericSelected.compactMap { event -> MCPReadFileInvocationDiagnosticPacket.LifecycleEntry? in
                guard let kind = lifecycleKind(event.eventName) else { return nil }
                return MCPReadFileInvocationDiagnosticPacket.LifecycleEntry(
                    ordinal: event.ordinal,
                    offsetMilliseconds: event.offsetMS,
                    kind: kind
                )
            }
            .sorted { $0.ordinal < $1.ordinal }
            let entries = Array(recognized.prefix(lifecycleLimit))
            let unrecognizedCount = max(0, genericSelected.count - recognized.count)
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
                    cancellationOutcome: safeTraceValue(
                        event.cancellationOutcome,
                        allowed: ["success", "cancellation", "error"]
                    ),
                    cancellationOrigin: event.cancellationOrigin?.rawValue,
                    settlement: safeTraceValue(event.settlement, allowed: ["detached"]),
                    graceOutcome: safeTraceValue(
                        event.graceOutcome,
                        allowed: ["settled", "late_completion", "expired"]
                    ),
                    escalationReason: safeTraceValue(
                        event.escalationReason,
                        allowed: [
                            "handler_ignored_cancellation",
                            "detach_disposition_handler_ignored_cancellation"
                        ]
                    ),
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

        private static func safeTraceValue(_ value: String?, allowed: Set<String>) -> String? {
            guard let value, allowed.contains(value) else { return nil }
            return value
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
