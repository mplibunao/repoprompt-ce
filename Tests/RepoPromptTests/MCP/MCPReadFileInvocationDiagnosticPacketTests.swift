#if DEBUG
    import Foundation
    import MCP
    @testable import RepoPromptApp
    import RepoPromptShared
    import XCTest

    final class MCPReadFileInvocationDiagnosticPacketTests: XCTestCase {
        override func tearDown() {
            EditFlowPerf.resetDebugCaptureForTesting()
            MCPResponseDeliveryTracer.resetDebugEvents()
            MCPToolExecutionTracer.resetDebugEvents()
            MCPToolWorkCountDiagnostics.resetForTesting()
            super.tearDown()
        }

        func testRoutingProjectionAndGitSectionsKeepMechanicalOutcomesDistinctAndPathFree() async throws {
            _ = try startedCapture(label: "routing-git-attribution")
            let connectionID = UUID()
            let cases = [
                ("ordinary", "absent", "not_applicable", "untranslated"),
                ("possible_git_artifact", "direct", "ordinary_fallthrough", "logical_to_physical"),
                ("git_artifact_target", "direct", "authorized", "alias_to_physical"),
                ("git_artifact_target", "delegated", "rejected", "blocked")
            ]
            for (ordinal, testCase) in cases.enumerated() {
                let appInvocationID = UUID()
                let identity = requestIdentity(
                    appInvocationID: appInvocationID,
                    connectionID: connectionID,
                    generation: 7,
                    ordinal: UInt64(ordinal + 1),
                    requestID: "route-\(ordinal)"
                )
                let correlation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive(
                    requestIdentity: identity,
                    toolName: "read_file"
                ))
                EditFlowPerf.lifecycleEvent(
                    EditFlowPerf.Lifecycle.MCPToolCall.received,
                    correlation: correlation,
                    EditFlowPerf.Dimensions(toolName: "read_file")
                )
                EditFlowPerf.lifecycleEvent(
                    EditFlowPerf.Lifecycle.ReadFile.lookupProjectionResolved,
                    correlation: correlation,
                    EditFlowPerf.Dimensions(
                        usesWorktreeProjection: true,
                        rootCount: 2,
                        bindingFingerprintToken: "binding_fingerprint:\(String(repeating: "a", count: 64))",
                        hydrationState: "hydrated",
                        projectionSource: ordinal.isMultiple(of: 2) ? "cache_hit" : "newly_materialized",
                        lifetimeCurrentBefore: true,
                        lifetimeCurrentAfter: true,
                        visibleRootFingerprintToken: "visible_root_fingerprint:\(String(repeating: "b", count: 64))",
                        visibleRootFingerprintTokenAfter: "visible_root_fingerprint:\(String(repeating: "c", count: 64))"
                    )
                )
                EditFlowPerf.lifecycleEvent(
                    EditFlowPerf.Lifecycle.ReadFile.pathClassified,
                    correlation: correlation,
                    EditFlowPerf.Dimensions(
                        rootCount: testCase.3 == "blocked" ? 0 : 1,
                        inputShape: ordinal == 0 ? "absolute" : "explicit_root",
                        translationRoute: testCase.3,
                        rootScopeKind: "validated_session_bound",
                        physicalRootToken: "physical_root:\(String(repeating: "d", count: 64))"
                    )
                )
                EditFlowPerf.lifecycleEvent(
                    EditFlowPerf.Lifecycle.ReadFile.gitPreflightBegan,
                    correlation: correlation,
                    EditFlowPerf.Dimensions(
                        gitClassification: "ordinary",
                        gitCapability: "absent",
                        gitPreflightStatus: "open"
                    )
                )
                EditFlowPerf.lifecycleEvent(
                    EditFlowPerf.Lifecycle.ReadFile.gitPreflightEnded,
                    correlation: correlation,
                    EditFlowPerf.Dimensions(
                        outcome: testCase.2 == "authorized" ? "authorized_requested_entry" : "no_requested_match",
                        gitClassification: testCase.0,
                        gitCapability: testCase.1,
                        gitPreflightStatus: testCase.2,
                        candidateCount: 1,
                        examinedCount: 1
                    )
                )

                let response = try await packetResponse(appInvocationID: appInvocationID)
                let packet = try XCTUnwrap(response["packet"] as? [String: Any])
                let routing = try XCTUnwrap(packet["routing_projection"] as? [String: Any])
                let routingEntries = try XCTUnwrap(routing["entries"] as? [[String: Any]])
                XCTAssertEqual(routingEntries.last?["translation_route"] as? String, testCase.3)
                let git = try XCTUnwrap(packet["git_artifact"] as? [String: Any])
                let gitEntries = try XCTUnwrap(git["entries"] as? [[String: Any]])
                XCTAssertEqual(gitEntries.last?["git_classification"] as? String, testCase.0)
                XCTAssertEqual(gitEntries.last?["git_capability"] as? String, testCase.1)
                XCTAssertEqual(gitEntries.last?["git_preflight_status"] as? String, testCase.2)
            }

            let serialized = try JSONSerialization.data(withJSONObject: EditFlowPerf.debugCaptureSnapshot(finish: false).payload())
            let text = String(decoding: serialized, as: UTF8.self)
            XCTAssertFalse(text.contains("/Users/"))
            XCTAssertFalse(text.contains("Secret.swift"))
        }

        func testDedicatedRouteAndGitEventsDoNotManufactureLifecycleTruncation() async throws {
            _ = try startedCapture(label: "dedicated-attribution-is-not-lifecycle-loss")
            let appInvocationID = UUID()
            let identity = requestIdentity(
                appInvocationID: appInvocationID,
                connectionID: UUID(),
                generation: 1,
                ordinal: 1,
                requestID: "dedicated-attribution"
            )
            let correlation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive(
                requestIdentity: identity,
                toolName: "read_file"
            ))
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.MCPToolCall.received,
                correlation: correlation,
                EditFlowPerf.Dimensions(toolName: "read_file")
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFile.lookupProjectionResolved,
                correlation: correlation,
                EditFlowPerf.Dimensions(
                    hydrationState: "unhydrated",
                    projectionSource: "fail_closed"
                )
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFile.gitPreflightBegan,
                correlation: correlation,
                EditFlowPerf.Dimensions(
                    gitClassification: "ordinary",
                    gitCapability: "absent",
                    gitPreflightStatus: "open"
                )
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFile.gitPreflightEnded,
                correlation: correlation,
                EditFlowPerf.Dimensions(
                    outcome: "no_requested_match",
                    gitClassification: "ordinary",
                    gitCapability: "absent",
                    gitPreflightStatus: "not_applicable"
                )
            )

            let response = try await packetResponse(appInvocationID: appInvocationID)
            let packet = try XCTUnwrap(response["packet"] as? [String: Any])
            let routing = try XCTUnwrap(packet["routing_projection"] as? [String: Any])
            let git = try XCTUnwrap(packet["git_artifact"] as? [String: Any])
            let lifecycle = try XCTUnwrap(packet["lifecycle"] as? [String: Any])

            XCTAssertEqual(routing["state"] as? String, "observed")
            XCTAssertEqual(routing["retained_count"] as? Int, 1)
            let routingEntries = try XCTUnwrap(routing["entries"] as? [[String: Any]])
            XCTAssertEqual(routingEntries.first?["lifetime_current_before"] as? String, "not_checked")
            XCTAssertEqual(routingEntries.first?["lifetime_current_after"] as? String, "not_checked")
            XCTAssertEqual(git["state"] as? String, "observed")
            XCTAssertEqual(git["retained_count"] as? Int, 2)
            XCTAssertEqual(lifecycle["omitted_count"] as? Int, 0)
            XCTAssertEqual(lifecycle["truncated"] as? Bool, false)
            XCTAssertEqual(packet["dropped_event_count"] as? Int, 0)
            XCTAssertNotEqual(packet["packet_state"] as? String, "truncated")
        }

        func testTerminalWatchdogWithMissingInnerEvidenceReportsExactPartialSummary() async throws {
            _ = try startedCapture(label: "terminal-missing-inner")
            let appInvocationID = UUID()
            let connectionID = UUID()
            let identity = requestIdentity(
                appInvocationID: appInvocationID,
                connectionID: connectionID,
                generation: 1,
                ordinal: 1,
                requestID: "terminal-missing-inner"
            )
            try recordReceived(identity)
            let correlation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive(
                requestIdentity: identity,
                toolName: "read_file"
            ))
            EditFlowPerf.lifecycleEvent(
                "ReadFile.SettlementTransition",
                correlation: correlation,
                EditFlowPerf.Dimensions(runPurpose: "execution_deadline_cancellation_boundary")
            )
            let captureIdentity = try XCTUnwrap(EditFlowPerf.debugCaptureIdentity(toolName: "read_file"))
            MCPToolExecutionTracer.emit(
                Self.makeTraceEvent(
                    appInvocationID: appInvocationID,
                    connectionID: connectionID,
                    requestIdentity: identity,
                    phase: .deadlineExpired,
                    freeFormCanary: "ignored",
                    cancellationOrigin: .watchdogDeadline,
                    cancellationOutcome: "cancellation"
                ),
                captureIdentity: captureIdentity
            )

            let response = try await packetResponse(appInvocationID: appInvocationID)
            let packet = try XCTUnwrap(response["packet"] as? [String: Any])
            XCTAssertEqual(packet["packet_state"] as? String, "partial")
            XCTAssertEqual(packet["watchdog_terminal_observed"] as? Bool, true)
            XCTAssertEqual(packet["required_evidence_complete"] as? Bool, false)
            XCTAssertEqual(packet["open_inner_stages_at_watchdog_terminal"] as? [String], [])
            XCTAssertTrue(packet["longest_closed_inner_stage"] is NSNull)
            let missing = try XCTUnwrap(packet["missing_required_evidence"] as? [String])
            XCTAssertTrue(missing.contains("freshness_authority_ingress:missing"), "\(missing)")
            XCTAssertTrue(missing.contains("exact_resolution:missing"), "\(missing)")
            XCTAssertTrue(missing.contains("interactive_load:missing"), "\(missing)")
            XCTAssertFalse(missing.contains("watchdog_terminal_boundary:missing"), "\(missing)")
        }

        func testLaterFreshnessEndDoesNotEraseOpenAtWatchdogTerminal() async throws {
            _ = try startedCapture(label: "terminal-open-inner")
            let appInvocationID = UUID()
            let connectionID = UUID()
            let identity = requestIdentity(
                appInvocationID: appInvocationID,
                connectionID: connectionID,
                generation: 1,
                ordinal: 1,
                requestID: "terminal-open-inner"
            )
            try recordReceived(identity)
            let correlation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive(
                requestIdentity: identity,
                toolName: "read_file"
            ))
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFile.explicitFreshnessBegan,
                correlation: correlation
            )
            EditFlowPerf.lifecycleEvent(
                "ReadFile.SettlementTransition",
                correlation: correlation,
                EditFlowPerf.Dimensions(runPurpose: "execution_deadline_cancellation_boundary")
            )
            let captureIdentity = try XCTUnwrap(EditFlowPerf.debugCaptureIdentity(toolName: "read_file"))
            MCPToolExecutionTracer.emit(
                Self.makeTraceEvent(
                    appInvocationID: appInvocationID,
                    connectionID: connectionID,
                    requestIdentity: identity,
                    phase: .deadlineExpired,
                    freeFormCanary: "ignored",
                    cancellationOrigin: .watchdogDeadline,
                    cancellationOutcome: "cancellation"
                ),
                captureIdentity: captureIdentity
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFile.explicitFreshnessEnded,
                correlation: correlation,
                EditFlowPerf.Dimensions(outcome: "outer_cancellation", rootCount: 0)
            )

            let response = try await packetResponse(appInvocationID: appInvocationID)
            let packet = try XCTUnwrap(response["packet"] as? [String: Any])
            XCTAssertEqual(packet["packet_state"] as? String, "partial")
            XCTAssertEqual(packet["watchdog_terminal_observed"] as? Bool, true)
            XCTAssertEqual(packet["required_evidence_complete"] as? Bool, false)
            XCTAssertEqual(
                packet["open_inner_stages_at_watchdog_terminal"] as? [String],
                ["freshness_authority_ingress:ReadFile.ExplicitFreshness"]
            )
            XCTAssertTrue(packet["longest_closed_inner_stage"] is NSNull)
            let freshness = try XCTUnwrap(packet["freshness_authority_ingress"] as? [String: Any])
            XCTAssertEqual(freshness["open_span_count"] as? Int, 0)
            XCTAssertEqual(freshness["terminal_integrity"] as? String, "balanced")
            let freshnessEntries = try XCTUnwrap(freshness["entries"] as? [[String: Any]])
            XCTAssertEqual(freshnessEntries.count, 2, "The post-deadline terminal must remain in packet history.")
            let missing = try XCTUnwrap(packet["missing_required_evidence"] as? [String])
            XCTAssertTrue(
                missing.contains("freshness_authority_ingress:open_at_watchdog_terminal"),
                "\(missing)"
            )
            XCTAssertFalse(missing.contains("freshness_authority_ingress:open"), "\(missing)")
        }

        func testDuplicatePreciseDeadlineBoundariesSuppressAmbiguousPointInTimeSummary() async throws {
            _ = try startedCapture(label: "duplicate-precise-deadline-boundaries")
            let appInvocationID = UUID()
            let connectionID = UUID()
            let identity = requestIdentity(
                appInvocationID: appInvocationID,
                connectionID: connectionID,
                generation: 1,
                ordinal: 1,
                requestID: "duplicate-precise-deadline-boundaries"
            )
            try recordReceived(identity)
            let correlation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive(
                requestIdentity: identity,
                toolName: "read_file"
            ))
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFile.explicitFreshnessBegan,
                correlation: correlation
            )
            EditFlowPerf.lifecycleEvent(
                "ReadFile.SettlementTransition",
                correlation: correlation,
                EditFlowPerf.Dimensions(runPurpose: "execution_deadline_cancellation_boundary")
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFile.explicitFreshnessEnded,
                correlation: correlation,
                EditFlowPerf.Dimensions(outcome: "outer_cancellation", rootCount: 0)
            )
            EditFlowPerf.lifecycleEvent(
                "ReadFile.SettlementTransition",
                correlation: correlation,
                EditFlowPerf.Dimensions(runPurpose: "execution_deadline_cancellation_boundary")
            )
            let captureIdentity = try XCTUnwrap(EditFlowPerf.debugCaptureIdentity(toolName: "read_file"))
            MCPToolExecutionTracer.emit(
                Self.makeTraceEvent(
                    appInvocationID: appInvocationID,
                    connectionID: connectionID,
                    requestIdentity: identity,
                    phase: .deadlineExpired,
                    freeFormCanary: "ignored",
                    cancellationOrigin: .watchdogDeadline,
                    cancellationOutcome: "cancellation"
                ),
                captureIdentity: captureIdentity
            )

            let response = try await packetResponse(appInvocationID: appInvocationID)
            let packet = try XCTUnwrap(response["packet"] as? [String: Any])
            XCTAssertEqual(packet["open_inner_stages_at_watchdog_terminal"] as? [String], [])
            XCTAssertTrue(packet["longest_closed_inner_stage"] is NSNull)
            let missing = try XCTUnwrap(packet["missing_required_evidence"] as? [String])
            XCTAssertTrue(missing.contains("watchdog_terminal_boundary:ambiguous"), "\(missing)")
            XCTAssertFalse(missing.contains("watchdog_terminal_boundary:missing"), "\(missing)")
            let settlement = try XCTUnwrap(packet["settlement"] as? [String: Any])
            let settlementEntries = try XCTUnwrap(settlement["entries"] as? [[String: Any]])
            XCTAssertEqual(
                settlementEntries.count { $0["purpose"] as? String == "execution_deadline_cancellation_boundary" },
                2
            )
            let freshness = try XCTUnwrap(packet["freshness_authority_ingress"] as? [String: Any])
            XCTAssertEqual((freshness["entries"] as? [[String: Any]])?.count, 2)
        }

        func testPreciseDeadlineBoundaryContradictedByNonCancelledGraceSuppressesSummary() async throws {
            _ = try startedCapture(label: "precise-boundary-non-cancelled-grace")
            let appInvocationID = UUID()
            let connectionID = UUID()
            let identity = requestIdentity(
                appInvocationID: appInvocationID,
                connectionID: connectionID,
                generation: 1,
                ordinal: 1,
                requestID: "precise-boundary-non-cancelled-grace"
            )
            try recordReceived(identity)
            let correlation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive(
                requestIdentity: identity,
                toolName: "read_file"
            ))
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFile.explicitFreshnessBegan,
                correlation: correlation
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFile.explicitFreshnessEnded,
                correlation: correlation,
                EditFlowPerf.Dimensions(outcome: "success", rootCount: 0)
            )
            EditFlowPerf.lifecycleEvent(
                "ReadFile.SettlementTransition",
                correlation: correlation,
                EditFlowPerf.Dimensions(runPurpose: "execution_deadline_cancellation_boundary")
            )
            let captureIdentity = try XCTUnwrap(EditFlowPerf.debugCaptureIdentity(toolName: "read_file"))
            MCPToolExecutionTracer.emit(
                Self.makeTraceEvent(
                    appInvocationID: appInvocationID,
                    connectionID: connectionID,
                    requestIdentity: identity,
                    phase: .deadlineExpired,
                    freeFormCanary: "ignored"
                ),
                captureIdentity: captureIdentity
            )
            MCPToolExecutionTracer.emit(
                Self.makeTraceEvent(
                    appInvocationID: appInvocationID,
                    connectionID: connectionID,
                    requestIdentity: identity,
                    phase: .settledDuringGrace,
                    freeFormCanary: "ignored",
                    cancellationRequested: false,
                    cancellationOutcome: "success",
                    graceOutcome: "late_completion"
                ),
                captureIdentity: captureIdentity
            )

            let response = try await packetResponse(appInvocationID: appInvocationID)
            let packet = try XCTUnwrap(response["packet"] as? [String: Any])
            XCTAssertEqual(packet["open_inner_stages_at_watchdog_terminal"] as? [String], [])
            XCTAssertTrue(packet["longest_closed_inner_stage"] is NSNull)
            let missing = try XCTUnwrap(packet["missing_required_evidence"] as? [String])
            XCTAssertTrue(missing.contains("watchdog_terminal_boundary:ambiguous"), "\(missing)")
            XCTAssertFalse(missing.contains("watchdog_terminal_boundary:missing"), "\(missing)")
            let settlement = try XCTUnwrap(packet["settlement"] as? [String: Any])
            XCTAssertEqual((settlement["entries"] as? [[String: Any]])?.count, 1)
            let execution = try XCTUnwrap(packet["execution_trace"] as? [String: Any])
            XCTAssertEqual((execution["entries"] as? [[String: Any]])?.count, 2)
            let freshness = try XCTUnwrap(packet["freshness_authority_ingress"] as? [String: Any])
            XCTAssertEqual((freshness["entries"] as? [[String: Any]])?.count, 2)
        }

        func testPreciseDeadlineBoundarySuppressesSummariesForEachSelectedEvidenceLoss() throws {
            let cases: [(label: String, evidence: TruncatedDeadlineEvidenceSection, section: String)] = [
                ("freshness evidence truncated", .freshness, "freshness_authority_ingress"),
                ("exact-resolution evidence truncated", .exactResolution, "exact_resolution"),
                ("interactive-load evidence truncated", .interactive, "interactive_load"),
                ("settlement evidence truncated", .settlement, "settlement"),
                ("lifecycle evidence truncated", .lifecycle, "lifecycle"),
                ("execution evidence truncated", .execution, "execution_trace")
            ]

            for testCase in cases {
                let packet = try preciseBoundaryPacket(truncating: testCase.evidence)
                assertDeadlineSummarySuppressedBySelectedLoss(
                    packet,
                    section: testCase.section,
                    label: testCase.label
                )
                EditFlowPerf.resetDebugCaptureForTesting()
                MCPToolExecutionTracer.resetDebugEvents()
            }
        }

        func testLostCancellationBoundaryDoesNotInferDeadlineStateFromLaterMarker() async throws {
            _ = try startedCapture(label: "lost-cancellation-boundary")
            let appInvocationID = UUID()
            let connectionID = UUID()
            let identity = requestIdentity(
                appInvocationID: appInvocationID,
                connectionID: connectionID,
                generation: 1,
                ordinal: 1,
                requestID: "lost-cancellation-boundary"
            )
            try recordReceived(identity)
            let correlation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive(
                requestIdentity: identity,
                toolName: "read_file"
            ))
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFile.explicitFreshnessBegan,
                correlation: correlation
            )
            let captureIdentity = try XCTUnwrap(EditFlowPerf.debugCaptureIdentity(toolName: "read_file"))
            MCPToolExecutionTracer.emit(
                Self.makeTraceEvent(
                    appInvocationID: appInvocationID,
                    connectionID: connectionID,
                    requestIdentity: identity,
                    phase: .deadlineExpired,
                    freeFormCanary: "ignored"
                ),
                captureIdentity: captureIdentity
            )
            MCPToolExecutionTracer.emit(
                Self.makeTraceEvent(
                    appInvocationID: appInvocationID,
                    connectionID: connectionID,
                    requestIdentity: identity,
                    phase: .cancellationRequested,
                    freeFormCanary: "ignored",
                    cancellationRequested: true,
                    cancellationOrigin: .watchdogDeadline,
                    cancellationOutcome: "cancellation"
                ),
                captureIdentity: captureIdentity
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFile.explicitFreshnessEnded,
                correlation: correlation,
                EditFlowPerf.Dimensions(outcome: "outer_cancellation", rootCount: 0)
            )
            EditFlowPerf.lifecycleEvent(
                "ReadFile.SettlementTransition",
                correlation: correlation,
                EditFlowPerf.Dimensions(runPurpose: "execution_deadline_expired", outcome: "observed")
            )

            let response = try await packetResponse(appInvocationID: appInvocationID)
            let packet = try XCTUnwrap(response["packet"] as? [String: Any])
            XCTAssertEqual(packet["watchdog_terminal_observed"] as? Bool, true)
            XCTAssertEqual(packet["required_evidence_complete"] as? Bool, false)
            XCTAssertEqual(packet["open_inner_stages_at_watchdog_terminal"] as? [String], [])
            XCTAssertTrue(packet["longest_closed_inner_stage"] is NSNull)
            let missing = try XCTUnwrap(packet["missing_required_evidence"] as? [String])
            XCTAssertTrue(missing.contains("watchdog_terminal_boundary:missing"), "\(missing)")
            let freshness = try XCTUnwrap(packet["freshness_authority_ingress"] as? [String: Any])
            let freshnessEntries = try XCTUnwrap(freshness["entries"] as? [[String: Any]])
            XCTAssertEqual(freshnessEntries.count, 2, "The later inner terminal must remain in full history.")
            let settlement = try XCTUnwrap(packet["settlement"] as? [String: Any])
            let settlementEntries = try XCTUnwrap(settlement["entries"] as? [[String: Any]])
            XCTAssertTrue(settlementEntries.contains {
                $0["purpose"] as? String == "execution_deadline_expired"
            }, "The later deadline marker must remain in full history.")
        }

        func testNonCancelledDeadlineCompletionRetainsLaterMarkerFallback() async throws {
            _ = try startedCapture(label: "non-cancelled-deadline-fallback")
            let appInvocationID = UUID()
            let connectionID = UUID()
            let identity = requestIdentity(
                appInvocationID: appInvocationID,
                connectionID: connectionID,
                generation: 1,
                ordinal: 1,
                requestID: "non-cancelled-deadline-fallback"
            )
            try recordReceived(identity)
            let correlation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive(
                requestIdentity: identity,
                toolName: "read_file"
            ))
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFile.explicitFreshnessBegan,
                correlation: correlation
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFile.explicitFreshnessEnded,
                correlation: correlation,
                EditFlowPerf.Dimensions(outcome: "success", rootCount: 1)
            )
            EditFlowPerf.lifecycleEvent(
                "ReadFile.SettlementTransition",
                correlation: correlation,
                EditFlowPerf.Dimensions(runPurpose: "execution_deadline_expired", outcome: "observed")
            )
            let captureIdentity = try XCTUnwrap(EditFlowPerf.debugCaptureIdentity(toolName: "read_file"))
            MCPToolExecutionTracer.emit(
                Self.makeTraceEvent(
                    appInvocationID: appInvocationID,
                    connectionID: connectionID,
                    requestIdentity: identity,
                    phase: .deadlineExpired,
                    freeFormCanary: "ignored"
                ),
                captureIdentity: captureIdentity
            )
            MCPToolExecutionTracer.emit(
                Self.makeTraceEvent(
                    appInvocationID: appInvocationID,
                    connectionID: connectionID,
                    requestIdentity: identity,
                    phase: .settledDuringGrace,
                    freeFormCanary: "ignored",
                    cancellationRequested: false,
                    cancellationOutcome: "success",
                    graceOutcome: "late_completion"
                ),
                captureIdentity: captureIdentity
            )

            let response = try await packetResponse(appInvocationID: appInvocationID)
            let packet = try XCTUnwrap(response["packet"] as? [String: Any])
            XCTAssertEqual(packet["watchdog_terminal_observed"] as? Bool, true)
            XCTAssertEqual(packet["open_inner_stages_at_watchdog_terminal"] as? [String], [])
            let longest = try XCTUnwrap(packet["longest_closed_inner_stage"] as? [String: Any])
            XCTAssertEqual(longest["section"] as? String, "freshness_authority_ingress")
            XCTAssertEqual(
                longest["stage"] as? String,
                "freshness_authority_ingress:ReadFile.ExplicitFreshness"
            )
            let missing = try XCTUnwrap(packet["missing_required_evidence"] as? [String])
            XCTAssertFalse(missing.contains("watchdog_terminal_boundary:missing"), "\(missing)")
        }

        func testDroppedExecutionEvidenceSuppressesLaterDeadlineFallback() throws {
            _ = try startedCapture(label: "dropped-execution-fallback")
            let appInvocationID = UUID()
            let connectionID = UUID()
            let identity = requestIdentity(
                appInvocationID: appInvocationID,
                connectionID: connectionID,
                generation: 1,
                ordinal: 1,
                requestID: "dropped-execution-fallback"
            )
            try recordReceived(identity)
            let correlation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive(
                requestIdentity: identity,
                toolName: "read_file"
            ))
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFile.explicitFreshnessBegan,
                correlation: correlation
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFile.explicitFreshnessEnded,
                correlation: correlation,
                EditFlowPerf.Dimensions(outcome: "success", rootCount: 1)
            )
            EditFlowPerf.lifecycleEvent(
                "ReadFile.SettlementTransition",
                correlation: correlation,
                EditFlowPerf.Dimensions(runPurpose: "execution_deadline_expired", outcome: "observed")
            )
            let captureIdentity = try XCTUnwrap(EditFlowPerf.debugCaptureIdentity(toolName: "read_file"))
            MCPToolExecutionTracer.emit(
                Self.makeTraceEvent(
                    appInvocationID: appInvocationID,
                    connectionID: connectionID,
                    requestIdentity: identity,
                    phase: .deadlineExpired,
                    freeFormCanary: "ignored"
                ),
                captureIdentity: captureIdentity
            )
            MCPToolExecutionTracer.emit(
                Self.makeTraceEvent(
                    appInvocationID: appInvocationID,
                    connectionID: connectionID,
                    requestIdentity: identity,
                    phase: .settledDuringGrace,
                    freeFormCanary: "ignored",
                    cancellationRequested: false,
                    cancellationOutcome: "success",
                    graceOutcome: "late_completion"
                ),
                captureIdentity: captureIdentity
            )

            let capture = EditFlowPerf.debugCaptureSnapshot(finish: false)
            let captureID = try XCTUnwrap(capture.captureID)
            let retainedTrace = MCPToolExecutionTracer.debugEventSnapshot(captureID)
            let lossyTrace = MCPToolExecutionTracer.DebugEventSnapshot(
                captureID: retainedTrace.captureID,
                retainedCaptureID: retainedTrace.retainedCaptureID,
                maxEventCount: retainedTrace.maxEventCount,
                retainedEventCount: retainedTrace.retainedEventCount,
                droppedEventCount: 1,
                events: retainedTrace.events
            )
            let packet = try MCPReadFileInvocationDiagnosticPacketAssembler.packet(
                appInvocationID: appInvocationID,
                capture: capture,
                trace: lossyTrace,
                work: MCPToolWorkCountDiagnostics.debugReadFileSnapshot(captureID: captureID),
                runtimeIdentity: Self.completeRuntimeIdentityValue()
            )
            XCTAssertTrue(packet.executionTrace.truncated == false)
            XCTAssertEqual(packet.executionTrace.captureWideOmittedCount, 1)
            XCTAssertTrue(packet.openInnerStagesAtWatchdogTerminal.isEmpty)
            XCTAssertNil(packet.longestClosedInnerStage)
            XCTAssertTrue(packet.missingRequiredEvidence.contains("watchdog_terminal_boundary:missing"))
            XCTAssertFalse(packet.requiredEvidenceComplete)
        }

        func testMixedNonCancelledSettlementAndCancellationSuppressesLaterDeadlineFallback() async throws {
            _ = try startedCapture(label: "mixed-cancellation-fallback")
            let appInvocationID = UUID()
            let connectionID = UUID()
            let identity = requestIdentity(
                appInvocationID: appInvocationID,
                connectionID: connectionID,
                generation: 1,
                ordinal: 1,
                requestID: "mixed-cancellation-fallback"
            )
            try recordReceived(identity)
            let correlation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive(
                requestIdentity: identity,
                toolName: "read_file"
            ))
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFile.explicitFreshnessBegan,
                correlation: correlation
            )
            let captureIdentity = try XCTUnwrap(EditFlowPerf.debugCaptureIdentity(toolName: "read_file"))
            MCPToolExecutionTracer.emit(
                Self.makeTraceEvent(
                    appInvocationID: appInvocationID,
                    connectionID: connectionID,
                    requestIdentity: identity,
                    phase: .deadlineExpired,
                    freeFormCanary: "ignored"
                ),
                captureIdentity: captureIdentity
            )
            MCPToolExecutionTracer.emit(
                Self.makeTraceEvent(
                    appInvocationID: appInvocationID,
                    connectionID: connectionID,
                    requestIdentity: identity,
                    phase: .settledDuringGrace,
                    freeFormCanary: "ignored",
                    cancellationRequested: false,
                    cancellationOutcome: "success",
                    graceOutcome: "late_completion"
                ),
                captureIdentity: captureIdentity
            )
            MCPToolExecutionTracer.emit(
                Self.makeTraceEvent(
                    appInvocationID: appInvocationID,
                    connectionID: connectionID,
                    requestIdentity: identity,
                    phase: .cancellationRequested,
                    freeFormCanary: "ignored",
                    cancellationRequested: true,
                    cancellationOrigin: .watchdogDeadline,
                    cancellationOutcome: "cancellation"
                ),
                captureIdentity: captureIdentity
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFile.explicitFreshnessEnded,
                correlation: correlation,
                EditFlowPerf.Dimensions(outcome: "outer_cancellation", rootCount: 0)
            )
            EditFlowPerf.lifecycleEvent(
                "ReadFile.SettlementTransition",
                correlation: correlation,
                EditFlowPerf.Dimensions(runPurpose: "execution_deadline_expired", outcome: "observed")
            )

            let response = try await packetResponse(appInvocationID: appInvocationID)
            let packet = try XCTUnwrap(response["packet"] as? [String: Any])
            XCTAssertEqual(packet["open_inner_stages_at_watchdog_terminal"] as? [String], [])
            XCTAssertTrue(packet["longest_closed_inner_stage"] is NSNull)
            XCTAssertEqual(packet["required_evidence_complete"] as? Bool, false)
            let missing = try XCTUnwrap(packet["missing_required_evidence"] as? [String])
            XCTAssertTrue(missing.contains("watchdog_terminal_boundary:missing"), "\(missing)")
        }

        func testDuplicateNonCancelledGraceTerminalsSuppressLaterDeadlineFallback() async throws {
            let fixture = try closedFreshnessFallbackFixture(label: "duplicate-grace-terminals")
            MCPToolExecutionTracer.emit(
                Self.makeTraceEvent(
                    appInvocationID: fixture.appInvocationID,
                    connectionID: fixture.connectionID,
                    requestIdentity: fixture.identity,
                    phase: .deadlineExpired,
                    freeFormCanary: "ignored"
                ),
                captureIdentity: fixture.captureIdentity
            )
            for outcome in ["success", "error"] {
                MCPToolExecutionTracer.emit(
                    Self.makeTraceEvent(
                        appInvocationID: fixture.appInvocationID,
                        connectionID: fixture.connectionID,
                        requestIdentity: fixture.identity,
                        phase: .settledDuringGrace,
                        freeFormCanary: "ignored",
                        cancellationRequested: false,
                        cancellationOutcome: outcome,
                        graceOutcome: "late_completion"
                    ),
                    captureIdentity: fixture.captureIdentity
                )
            }

            let response = try await packetResponse(appInvocationID: fixture.appInvocationID)
            let packet = try XCTUnwrap(response["packet"] as? [String: Any])
            XCTAssertEqual(packet["open_inner_stages_at_watchdog_terminal"] as? [String], [])
            XCTAssertTrue(packet["longest_closed_inner_stage"] is NSNull)
            XCTAssertEqual(packet["required_evidence_complete"] as? Bool, false)
            let missing = try XCTUnwrap(packet["missing_required_evidence"] as? [String])
            XCTAssertTrue(missing.contains("watchdog_terminal_boundary:missing"), "\(missing)")
            let execution = try XCTUnwrap(packet["execution_trace"] as? [String: Any])
            XCTAssertEqual(execution["retained_count"] as? Int, 3)
        }

        func testLifecycleCaptureLossSuppressesLaterDeadlineFallback() throws {
            let fixture = try closedFreshnessFallbackFixture(label: "lifecycle-loss-fallback")
            MCPToolExecutionTracer.emit(
                Self.makeTraceEvent(
                    appInvocationID: fixture.appInvocationID,
                    connectionID: fixture.connectionID,
                    requestIdentity: fixture.identity,
                    phase: .deadlineExpired,
                    freeFormCanary: "ignored"
                ),
                captureIdentity: fixture.captureIdentity
            )
            MCPToolExecutionTracer.emit(
                Self.makeTraceEvent(
                    appInvocationID: fixture.appInvocationID,
                    connectionID: fixture.connectionID,
                    requestIdentity: fixture.identity,
                    phase: .settledDuringGrace,
                    freeFormCanary: "ignored",
                    cancellationRequested: false,
                    cancellationOutcome: "success",
                    graceOutcome: "late_completion"
                ),
                captureIdentity: fixture.captureIdentity
            )

            let initialCapture = EditFlowPerf.debugCaptureSnapshot(finish: false)
            for _ in 0 ... initialCapture.maxLifecycleEvents {
                EditFlowPerf.lifecycleEvent(
                    EditFlowPerf.Lifecycle.MCPToolCall.received,
                    correlation: fixture.correlation,
                    EditFlowPerf.Dimensions(toolName: "read_file")
                )
            }
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFile.explicitFreshnessBegan,
                correlation: fixture.correlation
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFile.explicitFreshnessEnded,
                correlation: fixture.correlation,
                EditFlowPerf.Dimensions(outcome: "success", rootCount: 1)
            )
            EditFlowPerf.lifecycleEvent(
                "ReadFile.SettlementTransition",
                correlation: fixture.correlation,
                EditFlowPerf.Dimensions(runPurpose: "execution_deadline_expired", outcome: "observed")
            )
            let lossyCapture = EditFlowPerf.debugCaptureSnapshot(finish: false)
            let captureID = try XCTUnwrap(lossyCapture.captureID)
            XCTAssertGreaterThan(lossyCapture.droppedLifecycleEventCount, 0)
            let packet = try MCPReadFileInvocationDiagnosticPacketAssembler.packet(
                appInvocationID: fixture.appInvocationID,
                capture: lossyCapture,
                trace: MCPToolExecutionTracer.debugEventSnapshot(captureID),
                work: MCPToolWorkCountDiagnostics.debugReadFileSnapshot(captureID: captureID),
                runtimeIdentity: Self.completeRuntimeIdentityValue()
            )
            XCTAssertEqual(packet.executionTrace.retainedCount, 2)
            XCTAssertTrue(packet.openInnerStagesAtWatchdogTerminal.isEmpty)
            XCTAssertNil(packet.longestClosedInnerStage)
            XCTAssertTrue(packet.missingRequiredEvidence.contains("watchdog_terminal_boundary:missing"))
            XCTAssertFalse(packet.requiredEvidenceComplete)
        }

        func testOutOfOrderNonCancelledGraceTerminalSuppressesLaterDeadlineFallback() async throws {
            let fixture = try closedFreshnessFallbackFixture(label: "out-of-order-grace-terminal")
            MCPToolExecutionTracer.emit(
                Self.makeTraceEvent(
                    appInvocationID: fixture.appInvocationID,
                    connectionID: fixture.connectionID,
                    requestIdentity: fixture.identity,
                    phase: .settledDuringGrace,
                    freeFormCanary: "ignored",
                    cancellationRequested: false,
                    cancellationOutcome: "success",
                    graceOutcome: "late_completion"
                ),
                captureIdentity: fixture.captureIdentity
            )
            MCPToolExecutionTracer.emit(
                Self.makeTraceEvent(
                    appInvocationID: fixture.appInvocationID,
                    connectionID: fixture.connectionID,
                    requestIdentity: fixture.identity,
                    phase: .deadlineExpired,
                    freeFormCanary: "ignored"
                ),
                captureIdentity: fixture.captureIdentity
            )

            let response = try await packetResponse(appInvocationID: fixture.appInvocationID)
            let packet = try XCTUnwrap(response["packet"] as? [String: Any])
            XCTAssertTrue(packet["longest_closed_inner_stage"] is NSNull)
            let missing = try XCTUnwrap(packet["missing_required_evidence"] as? [String])
            XCTAssertTrue(missing.contains("watchdog_terminal_boundary:missing"), "\(missing)")
        }

        func testInvalidNonCancelledGraceTerminalSuppressesLaterDeadlineFallback() async throws {
            let fixture = try closedFreshnessFallbackFixture(label: "invalid-grace-terminal")
            MCPToolExecutionTracer.emit(
                Self.makeTraceEvent(
                    appInvocationID: fixture.appInvocationID,
                    connectionID: fixture.connectionID,
                    requestIdentity: fixture.identity,
                    phase: .deadlineExpired,
                    freeFormCanary: "ignored"
                ),
                captureIdentity: fixture.captureIdentity
            )
            MCPToolExecutionTracer.emit(
                Self.makeTraceEvent(
                    appInvocationID: fixture.appInvocationID,
                    connectionID: fixture.connectionID,
                    requestIdentity: fixture.identity,
                    phase: .settledDuringGrace,
                    freeFormCanary: "ignored",
                    cancellationRequested: false,
                    cancellationOutcome: "success",
                    graceOutcome: "settled"
                ),
                captureIdentity: fixture.captureIdentity
            )

            let response = try await packetResponse(appInvocationID: fixture.appInvocationID)
            let packet = try XCTUnwrap(response["packet"] as? [String: Any])
            XCTAssertTrue(packet["longest_closed_inner_stage"] is NSNull)
            let missing = try XCTUnwrap(packet["missing_required_evidence"] as? [String])
            XCTAssertTrue(missing.contains("watchdog_terminal_boundary:missing"), "\(missing)")
        }

        func testExplicitMaterializationLateRootTokenPairsWithTokenlessBegin() throws {
            _ = try startedCapture(label: "explicit-materialization-pairing")
            let appInvocationID = UUID()
            let connectionID = UUID()
            let identity = requestIdentity(
                appInvocationID: appInvocationID,
                connectionID: connectionID,
                generation: 1,
                ordinal: 1,
                requestID: "explicit-materialization-pairing"
            )
            try recordReceived(identity)
            let correlation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive(
                requestIdentity: identity,
                toolName: "read_file"
            ))
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFile.explicitFreshnessBegan,
                correlation: correlation
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFile.explicitFreshnessEnded,
                correlation: correlation,
                EditFlowPerf.Dimensions(outcome: "success", rootCount: 1)
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.WorkspaceExactResolution.checkpoint,
                correlation: correlation,
                EditFlowPerf.Dimensions(runPurpose: "explicitMaterialization", status: "materializationBegan")
            )
            let materializedRootToken = UUID().uuidString
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.WorkspaceExactResolution.checkpoint,
                correlation: correlation,
                EditFlowPerf.Dimensions(
                    runPurpose: "explicitMaterialization",
                    status: "materializationEnded",
                    outcome: "materialized",
                    rootToken: materializedRootToken
                )
            )
            let interactiveRootToken = UUID().uuidString
            EditFlowPerf.lifecycleEvent(
                "ReadFile.InteractiveStage",
                correlation: correlation,
                EditFlowPerf.Dimensions(
                    runPurpose: "attempt",
                    status: "began",
                    rootToken: interactiveRootToken,
                    serialPosition: 0
                )
            )
            EditFlowPerf.lifecycleEvent(
                "ReadFile.InteractiveStage",
                correlation: correlation,
                EditFlowPerf.Dimensions(
                    runPurpose: "attempt",
                    status: "ended",
                    outcome: "completed",
                    rootToken: interactiveRootToken,
                    serialPosition: 0
                )
            )
            EditFlowPerf.lifecycleEvent(
                "ReadFile.SettlementTransition",
                correlation: correlation,
                EditFlowPerf.Dimensions(
                    runPurpose: MCPToolExecutionTraceEvent.Phase.handlerCompleted.rawValue,
                    status: "settled",
                    outcome: "success"
                )
            )
            let captureIdentity = try XCTUnwrap(EditFlowPerf.debugCaptureIdentity(toolName: "read_file"))
            MCPToolExecutionTracer.emit(
                Self.makeTraceEvent(
                    appInvocationID: appInvocationID,
                    connectionID: connectionID,
                    requestIdentity: identity,
                    phase: .handlerCompleted,
                    freeFormCanary: "ignored"
                ),
                captureIdentity: captureIdentity
            )

            let capture = EditFlowPerf.debugCaptureSnapshot(finish: false)
            let captureID = try XCTUnwrap(capture.captureID)
            let packet = try MCPReadFileInvocationDiagnosticPacketAssembler.packet(
                appInvocationID: appInvocationID,
                capture: capture,
                trace: MCPToolExecutionTracer.debugEventSnapshot(captureID),
                work: MCPToolWorkCountDiagnostics.debugReadFileSnapshot(captureID: captureID),
                runtimeIdentity: Self.completeRuntimeIdentityValue()
            )
            XCTAssertEqual(packet.exactResolution.state, "observed")
            XCTAssertEqual(packet.exactResolution.openSpanCount, 0)
            XCTAssertEqual(packet.exactResolution.terminalIntegrity, "balanced")
            XCTAssertEqual(packet.exactResolution.retainedCount, 2)
            XCTAssertEqual(packet.exactResolution.entries.last?.dimensions["rootToken"], materializedRootToken)
            XCTAssertEqual(packet.packetState, .complete)
            XCTAssertTrue(packet.requiredEvidenceComplete)
            XCTAssertEqual(packet.missingRequiredEvidence, [])
        }

        func testFreshnessCancellationOutcomeUsesWatchdogOriginInsteadOfGenericCancellation() async throws {
            _ = try startedCapture(label: "cancellation-provenance")
            let captureIdentity = try XCTUnwrap(EditFlowPerf.debugCaptureIdentity(toolName: "read_file"))
            let connectionID = UUID()
            let cases: [(MCPToolExecutionCancellationOrigin?, String, String)] = [
                (.watchdogDeadline, "other_cancellation", "outer_cancellation"),
                (.requestCancellation, "other_cancellation", "other_cancellation"),
                (nil, "inner_timeout", "inner_timeout")
            ]
            for (ordinal, testCase) in cases.enumerated() {
                let appInvocationID = UUID()
                let identity = requestIdentity(
                    appInvocationID: appInvocationID,
                    connectionID: connectionID,
                    generation: 1,
                    ordinal: UInt64(ordinal + 1),
                    requestID: "cancellation-\(ordinal)"
                )
                try recordReceived(identity)
                let correlation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive(
                    requestIdentity: identity,
                    toolName: "read_file"
                ))
                EditFlowPerf.lifecycleEvent(
                    EditFlowPerf.Lifecycle.ReadFile.explicitFreshnessBegan,
                    correlation: correlation
                )
                EditFlowPerf.lifecycleEvent(
                    EditFlowPerf.Lifecycle.ReadFile.explicitFreshnessEnded,
                    correlation: correlation,
                    EditFlowPerf.Dimensions(outcome: testCase.1, rootCount: 0)
                )
                MCPToolExecutionTracer.emit(
                    Self.makeTraceEvent(
                        appInvocationID: appInvocationID,
                        connectionID: connectionID,
                        requestIdentity: identity,
                        phase: .handlerCompleted,
                        freeFormCanary: "ignored",
                        cancellationOrigin: testCase.0,
                        cancellationOutcome: "cancellation"
                    ),
                    captureIdentity: captureIdentity
                )

                let response = try await packetResponse(appInvocationID: appInvocationID)
                let packet = try XCTUnwrap(response["packet"] as? [String: Any])
                let freshness = try XCTUnwrap(packet["freshness_authority_ingress"] as? [String: Any])
                let exact = try XCTUnwrap(packet["exact_resolution"] as? [String: Any])
                let interactive = try XCTUnwrap(packet["interactive_load"] as? [String: Any])
                let entries = try XCTUnwrap(freshness["entries"] as? [[String: Any]])
                let longest = try XCTUnwrap(packet["longest_closed_inner_stage"] as? [String: Any])
                XCTAssertEqual(exact["state"] as? String, "not_entered")
                XCTAssertEqual(interactive["state"] as? String, "not_entered")
                XCTAssertEqual(entries.last?["outcome"] as? String, testCase.2)
                XCTAssertEqual(longest["section"] as? String, "freshness_authority_ingress")
                XCTAssertEqual(longest["stage"] as? String, "freshness_authority_ingress:ReadFile.ExplicitFreshness")
                XCTAssertNotNil(longest["duration_ms"] as? Double)
            }
        }

        func testBusyCaptureHandlerReturnsTokenWithoutOperatorLabelAnywhere() async throws {
            let manager = ServerNetworkManager.shared
            let rawLabel = "RFD02AllowedRawLabel7D19C4"
            let first = await manager.handleDebugDiagnosticsTool(
                connectionID: UUID(),
                arguments: [
                    "op": .string("mcp_read_search_capture_begin"),
                    "label": .string(rawLabel)
                ]
            )
            XCTAssertEqual(try payload(first)["ok"] as? Bool, true)

            let busy = await manager.handleDebugDiagnosticsTool(
                connectionID: UUID(),
                arguments: [
                    "op": .string("mcp_read_search_capture_begin"),
                    "label": .string("SecondAllowedLabel")
                ]
            )
            let serialized = try payload(busy)
            XCTAssertEqual(serialized["code"] as? String, "capture_busy")
            XCTAssertEqual(serialized["error"] as? String, "A read/search latency capture is already active.")
            let capture = try XCTUnwrap(serialized["capture"] as? [String: Any])
            XCTAssertTrue((capture["capture_label_token"] as? String)?.hasPrefix("capture_label:") == true)
            XCTAssertFalse(payloadContains(rawLabel, in: serialized))
        }

        func testPacketEndpointsRejectAllCaptureWithoutSerializingUnrelatedEvidence() async throws {
            let manager = ServerNetworkManager.shared
            let rawLabel = "AllCapturePrivacyCanary91B7"
            switch EditFlowPerf.beginDebugCapture(
                label: rawLabel,
                maxSamples: 100,
                expiryMilliseconds: 120_000,
                toolFilter: .all,
                prepare: Self.prepareCaptureStores
            ) {
            case .started:
                break
            case .busy:
                return XCTFail("Expected a fresh all-tools capture.")
            }

            let unrelatedInvocationID = UUID()
            let requestCanary = "/Users/example/private/Unrelated.swift|all-capture-canary-91B7"
            let identity = requestIdentity(
                appInvocationID: unrelatedInvocationID,
                connectionID: UUID(),
                generation: 7,
                ordinal: 23,
                requestID: requestCanary
            )
            let correlation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive(
                requestIdentity: identity,
                toolName: "file_search"
            ))
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.MCPToolCall.received,
                correlation: correlation,
                EditFlowPerf.Dimensions(toolName: "file_search", outcome: requestCanary)
            )

            let list = try await payload(manager.handleDebugDiagnosticsTool(
                connectionID: UUID(),
                arguments: ["op": .string("list_read_file_invocations")]
            ))
            let packet = try await payload(manager.handleDebugDiagnosticsTool(
                connectionID: UUID(),
                arguments: [
                    "op": .string("read_file_invocation_packet"),
                    "app_invocation_id": .string(unrelatedInvocationID.uuidString)
                ]
            ))

            for result in [list, packet] {
                XCTAssertEqual(result["code"] as? String, "capture_incompatible")
                XCTAssertEqual(
                    result["error"] as? String,
                    "The selected capture is not compatible with read-file invocation diagnostics."
                )
                for forbidden in [rawLabel, unrelatedInvocationID.uuidString, requestCanary, "Unrelated.swift"] {
                    XCTAssertFalse(payloadContains(forbidden, in: result), forbidden)
                }
            }
        }

        func testHandlersListInvocationAndReturnWhitelistOnlyExplicitPacket() async throws {
            let manager = ServerNetworkManager.shared
            let rawLabel = "PacketPrivacyLabel8F21"
            _ = await manager.handleDebugDiagnosticsTool(
                connectionID: UUID(),
                arguments: [
                    "op": .string("mcp_read_search_capture_begin"),
                    "label": .string(rawLabel),
                    "expiry_ms": .int(120_000),
                    "tool_filter": .string("read_file")
                ]
            )
            let captureIdentity = try XCTUnwrap(EditFlowPerf.debugCaptureIdentity(toolName: "read_file"))
            let appInvocationID = UUID()
            let connectionID = UUID()
            let requestCanary = "/Users/example/private/Secret.swift|argument-canary-8F21"
            let freeFormCanary = "free_form_error_canary_8F21"
            let identity = requestIdentity(
                appInvocationID: appInvocationID,
                connectionID: connectionID,
                generation: 4,
                ordinal: 17,
                requestID: requestCanary
            )

            try await MCPRequestTimelineContext.$current.withValue(identity) {
                let correlation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive(
                    requestIdentity: identity,
                    toolName: "read_file"
                ))
                for event in [
                    EditFlowPerf.Lifecycle.MCPToolCall.received,
                    EditFlowPerf.Lifecycle.ReadFile.providerEntered,
                    EditFlowPerf.Lifecycle.ReadFile.providerResultReady
                ] {
                    EditFlowPerf.lifecycleEvent(
                        event,
                        correlation: correlation,
                        EditFlowPerf.Dimensions(outcome: freeFormCanary)
                    )
                }
                for event: StaticString in [
                    EditFlowPerf.Lifecycle.ReadFile.pathClassified,
                    EditFlowPerf.Lifecycle.ReadFile.gitPreflightEnded,
                    "ReadFile.FreshnessRootSnapshot",
                    EditFlowPerf.Lifecycle.WorkspaceExactResolution.checkpoint,
                    "ReadFile.InteractiveStage",
                    "ReadFile.SettlementTransition"
                ] {
                    EditFlowPerf.lifecycleEvent(
                        event,
                        correlation: correlation,
                        EditFlowPerf.Dimensions(
                            runPurpose: freeFormCanary,
                            status: freeFormCanary,
                            outcome: requestCanary,
                            inputShape: freeFormCanary,
                            translationRoute: requestCanary,
                            bindingFingerprintToken: requestCanary,
                            gitClassification: freeFormCanary,
                            gitCapability: requestCanary,
                            gitPreflightStatus: freeFormCanary
                        )
                    )
                }
                try await MCPToolWorkCountDiagnostics.withReadFileInvocation {
                    MCPToolWorkCountDiagnostics.recordReadFileDiskRead(bytes: 41, decodeMicroseconds: 7)
                    MCPToolWorkCountDiagnostics.recordReadFileResult(
                        returnedBytes: 19,
                        returnedLines: 2,
                        cacheHit: false
                    )
                }
            }
            MCPToolExecutionTracer.emit(
                Self.makeTraceEvent(
                    appInvocationID: appInvocationID,
                    connectionID: connectionID,
                    requestIdentity: identity,
                    phase: .handlerCompleted,
                    freeFormCanary: freeFormCanary
                ),
                captureIdentity: captureIdentity
            )

            let listed = try await payload(manager.handleDebugDiagnosticsTool(
                connectionID: UUID(),
                arguments: ["op": .string("list_read_file_invocations")]
            ))
            let invocations = try XCTUnwrap(listed["invocations"] as? [String: Any])
            let rows = try XCTUnwrap(invocations["entries"] as? [[String: Any]])
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows.first?["app_invocation_id"] as? String, appInvocationID.uuidString)
            XCTAssertEqual(rows.first?["request_ordinal"] as? UInt64, 17)
            XCTAssertEqual(rows.first?["terminal_state"] as? String, "handler_completed")
            XCTAssertEqual(invocations["omitted_count"] as? Int, 0)
            XCTAssertEqual(invocations["truncated"] as? Bool, false)

            let response = try await payload(manager.handleDebugDiagnosticsTool(
                connectionID: UUID(),
                arguments: [
                    "op": .string("read_file_invocation_packet"),
                    "app_invocation_id": .string(appInvocationID.uuidString),
                    "finish_capture": .bool(true)
                ]
            ))
            XCTAssertEqual(response["ok"] as? Bool, true)
            XCTAssertEqual(response["capture_finished"] as? Bool, true)
            let packet = try XCTUnwrap(response["packet"] as? [String: Any])
            XCTAssertTrue(["partial", "complete"].contains(packet["packet_state"] as? String))
            XCTAssertEqual(packet["capture_label_token"] as? String, captureIdentityToken(from: packet))
            assertEveryPacketSectionReportsBounds(packet)
            for forbidden in [rawLabel, requestCanary, "/Users/example/private/Secret.swift", freeFormCanary] {
                XCTAssertFalse(payloadContains(forbidden, in: response), forbidden)
            }
            let settlement = try XCTUnwrap(packet["settlement"] as? [String: Any])
            let settlementEntries = try XCTUnwrap(settlement["entries"] as? [[String: Any]])
            for forbiddenKey in [
                "root_path", "path", "content", "error", "arguments", "selection",
                "credential", "repoRoot", "worktreePath", "worktreeName", "branch"
            ] {
                XCTAssertFalse(payloadContainsKey(forbiddenKey, in: packet), forbiddenKey)
            }
            for entry in settlementEntries {
                XCTAssertNil(entry["provider_active"])
                XCTAssertNil(entry["permit_active"])
            }

            let finishedList = try await payload(manager.handleDebugDiagnosticsTool(
                connectionID: UUID(),
                arguments: ["op": .string("list_read_file_invocations")]
            ))
            XCTAssertEqual((finishedList["capture"] as? [String: Any])?["capture_state"] as? String, "finished")
            XCTAssertEqual(
                ((finishedList["invocations"] as? [String: Any])?["entries"] as? [[String: Any]])?.count,
                1
            )
        }

        func testPacketSelectionFailsClosedForMalformedMissingAndConflictingInvocation() async throws {
            let manager = ServerNetworkManager.shared
            _ = try startedCapture(label: "selection-fail-closed")

            let malformed = try await payload(manager.handleDebugDiagnosticsTool(
                connectionID: UUID(),
                arguments: [
                    "op": .string("read_file_invocation_packet"),
                    "app_invocation_id": .string("not-a-uuid")
                ]
            ))
            XCTAssertEqual(malformed["code"] as? String, "invalid_params")

            let missing = try await payload(manager.handleDebugDiagnosticsTool(
                connectionID: UUID(),
                arguments: [
                    "op": .string("read_file_invocation_packet"),
                    "app_invocation_id": .string(UUID().uuidString),
                    "finish_capture": .bool(true)
                ]
            ))
            XCTAssertEqual(missing["code"] as? String, "invocation_not_found")
            XCTAssertNotNil((missing["capture"] as? [String: Any])?["capture_id"])
            XCTAssertTrue(EditFlowPerf.isDebugCaptureActive)

            let appInvocationID = UUID()
            for (generation, connectionID) in [(UInt64(1), UUID()), (UInt64(2), UUID())] {
                let identity = requestIdentity(
                    appInvocationID: appInvocationID,
                    connectionID: connectionID,
                    generation: generation,
                    ordinal: 9,
                    requestID: "request-\(generation)"
                )
                let correlation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive(
                    requestIdentity: identity,
                    toolName: "read_file"
                ))
                EditFlowPerf.lifecycleEvent(
                    EditFlowPerf.Lifecycle.MCPToolCall.received,
                    correlation: correlation,
                    EditFlowPerf.Dimensions(toolName: "read_file")
                )
            }

            let inconsistent = try await payload(manager.handleDebugDiagnosticsTool(
                connectionID: UUID(),
                arguments: [
                    "op": .string("read_file_invocation_packet"),
                    "app_invocation_id": .string(appInvocationID.uuidString)
                ]
            ))
            XCTAssertEqual(inconsistent["code"] as? String, "inconsistent_identity")
            XCTAssertFalse(payloadContains("request-1", in: inconsistent))
            XCTAssertFalse(payloadContains("request-2", in: inconsistent))
        }

        func testWorkCountRingReportsCaptureWideLossWithoutInventingSelectedOmission() async throws {
            _ = try startedCapture(label: "bounded-work-counts")
            let appInvocationID = UUID()
            let identity = requestIdentity(
                appInvocationID: appInvocationID,
                connectionID: UUID(),
                generation: 1,
                ordinal: 1,
                requestID: "bounded-request"
            )
            let correlation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive(
                requestIdentity: identity,
                toolName: "read_file"
            ))
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.MCPToolCall.received,
                correlation: correlation,
                EditFlowPerf.Dimensions(toolName: "read_file")
            )

            for ordinal in 0 ..< 65 {
                try await MCPRequestTimelineContext.$current.withValue(identity) {
                    try await MCPToolWorkCountDiagnostics.withReadFileInvocation {
                        MCPToolWorkCountDiagnostics.recordReadFileResult(
                            returnedBytes: ordinal,
                            returnedLines: 1,
                            cacheHit: true
                        )
                    }
                }
            }

            let capture = EditFlowPerf.debugCaptureSnapshot(finish: false)
            let captureID = try XCTUnwrap(capture.captureID)
            let packet = try MCPReadFileInvocationDiagnosticPacketAssembler.packet(
                appInvocationID: appInvocationID,
                capture: capture,
                trace: MCPToolExecutionTracer.debugEventSnapshot(captureID),
                work: MCPToolWorkCountDiagnostics.debugReadFileSnapshot(captureID: captureID),
                runtimeIdentity: Self.completeRuntimeIdentityValue()
            )
            XCTAssertEqual(packet.packetState, .partial)
            XCTAssertEqual(packet.workCounts.retainedCount, 64)
            XCTAssertEqual(packet.workCounts.omittedCount, 0)
            XCTAssertFalse(packet.workCounts.truncated)
            XCTAssertEqual(packet.workCounts.captureWideOmittedCount, 1)
            XCTAssertEqual(packet.workCounts.captureWideLossImpact, "unknown")
            XCTAssertEqual(packet.selectedInvocationLossAttribution, "unknown")
            XCTAssertEqual(packet.truncationScope, "none")
        }

        func testUnrelatedOverflowKeepsSelectedOmissionZeroAndReportsCaptureWideUnknownImpact() async throws {
            _ = try startedCapture(label: "unrelated-overflow")
            let selectedInvocationID = UUID()
            let selectedIdentity = requestIdentity(
                appInvocationID: selectedInvocationID,
                connectionID: UUID(),
                generation: 1,
                ordinal: 1,
                requestID: "selected-request"
            )
            let selectedCorrelation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive(
                requestIdentity: selectedIdentity,
                toolName: "read_file"
            ))
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.MCPToolCall.received,
                correlation: selectedCorrelation,
                EditFlowPerf.Dimensions(toolName: "read_file")
            )

            let unrelatedIdentity = requestIdentity(
                appInvocationID: UUID(),
                connectionID: UUID(),
                generation: 1,
                ordinal: 2,
                requestID: "unrelated-request"
            )
            for _ in 0 ..< 65 {
                try await appendWorkCount(identity: unrelatedIdentity)
            }
            try await appendWorkCount(identity: selectedIdentity)

            let capture = EditFlowPerf.debugCaptureSnapshot(finish: false)
            let captureID = try XCTUnwrap(capture.captureID)
            let trace = MCPToolExecutionTracer.debugEventSnapshot(captureID)
            let work = MCPToolWorkCountDiagnostics.debugReadFileSnapshot(captureID: captureID)
            let packet = try MCPReadFileInvocationDiagnosticPacketAssembler.packet(
                appInvocationID: selectedInvocationID,
                capture: capture,
                trace: trace,
                work: work,
                runtimeIdentity: Self.completeRuntimeIdentityValue()
            )
            XCTAssertEqual(packet.workCounts.retainedCount, 1)
            XCTAssertEqual(packet.workCounts.omittedCount, 0)
            XCTAssertFalse(packet.workCounts.truncated)
            XCTAssertEqual(packet.workCounts.captureWideOmittedCount, 2)
            XCTAssertEqual(packet.workCounts.captureWideLossImpact, "unknown")
            XCTAssertEqual(packet.packetState, .partial)

            let list = MCPReadFileInvocationDiagnosticPacketAssembler.invocationList(
                capture: capture,
                trace: trace,
                work: work,
                limit: 64
            )
            XCTAssertEqual(list.omittedCount, 0)
            XCTAssertFalse(list.truncated)
            XCTAssertEqual(list.captureWideOmittedCount, 2)
            XCTAssertEqual(list.captureWideLossImpact, "unknown")
        }

        func testTraceInvocationMismatchIsExcludedAndFailsSelectedPacketClosed() async throws {
            _ = try startedCapture(label: "invocation-mismatch")
            let appInvocationID = UUID()
            let envelopeInvocationID = UUID()
            let connectionID = UUID()
            let identity = requestIdentity(
                appInvocationID: appInvocationID,
                connectionID: connectionID,
                generation: 1,
                ordinal: 1,
                requestID: "identity-request"
            )
            try recordReceived(identity)
            let captureIdentity = try XCTUnwrap(EditFlowPerf.debugCaptureIdentity(toolName: "read_file"))
            MCPToolExecutionTracer.emit(
                Self.makeTraceEvent(
                    appInvocationID: envelopeInvocationID,
                    connectionID: connectionID,
                    requestIdentity: identity,
                    phase: .handlerCompleted,
                    freeFormCanary: "ignored"
                ),
                captureIdentity: captureIdentity
            )

            let response = try await packetResponse(appInvocationID: appInvocationID)
            XCTAssertEqual(response["code"] as? String, "inconsistent_identity")
            XCTAssertFalse(payloadContains(envelopeInvocationID.uuidString, in: response))
            let list = try await invocationListResponse()
            let invocations = try XCTUnwrap(list["invocations"] as? [String: Any])
            XCTAssertEqual(invocations["identity_state"] as? String, "partial")
            XCTAssertEqual(invocations["inconsistent_identity_count"] as? Int, 1)
        }

        func testTraceConnectionMismatchIsExcludedAndFailsSelectedPacketClosed() async throws {
            _ = try startedCapture(label: "connection-mismatch")
            let appInvocationID = UUID()
            let identityConnectionID = UUID()
            let envelopeConnectionID = UUID()
            let identity = requestIdentity(
                appInvocationID: appInvocationID,
                connectionID: identityConnectionID,
                generation: 1,
                ordinal: 1,
                requestID: "identity-request"
            )
            try recordReceived(identity)
            let captureIdentity = try XCTUnwrap(EditFlowPerf.debugCaptureIdentity(toolName: "read_file"))
            MCPToolExecutionTracer.emit(
                Self.makeTraceEvent(
                    appInvocationID: appInvocationID,
                    connectionID: envelopeConnectionID,
                    requestIdentity: identity,
                    phase: .handlerCompleted,
                    freeFormCanary: "ignored"
                ),
                captureIdentity: captureIdentity
            )

            let response = try await packetResponse(appInvocationID: appInvocationID)
            XCTAssertEqual(response["code"] as? String, "inconsistent_identity")
            XCTAssertFalse(payloadContains(envelopeConnectionID.uuidString, in: response))
        }

        func testMalformedPresentTraceIdentityNeverFallsBackOrLeaksRawValue() async throws {
            _ = try startedCapture(label: "malformed-identity")
            let appInvocationID = UUID()
            let connectionID = UUID()
            let validIdentity = requestIdentity(
                appInvocationID: appInvocationID,
                connectionID: connectionID,
                generation: 1,
                ordinal: 1,
                requestID: "valid-request"
            )
            try recordReceived(validIdentity)
            let malformedCanary = "private-identity-canary-4C82"
            let malformedIdentity = MCPRequestTimelineIdentity(
                jsonRPCRequestID: .string("raw-request-canary-4C82"),
                connectionID: malformedCanary,
                connectionGeneration: 1,
                appInvocationID: appInvocationID.uuidString,
                requestOrdinal: 1
            )
            let captureIdentity = try XCTUnwrap(EditFlowPerf.debugCaptureIdentity(toolName: "read_file"))
            MCPToolExecutionTracer.emit(
                Self.makeTraceEvent(
                    appInvocationID: appInvocationID,
                    connectionID: connectionID,
                    requestIdentity: malformedIdentity,
                    phase: .handlerCompleted,
                    freeFormCanary: "ignored"
                ),
                captureIdentity: captureIdentity
            )

            let response = try await packetResponse(appInvocationID: appInvocationID)
            XCTAssertEqual(response["code"] as? String, "malformed_identity")
            XCTAssertFalse(payloadContains(malformedCanary, in: response))
            XCTAssertFalse(payloadContains("raw-request-canary-4C82", in: response))
            let list = try await invocationListResponse()
            let invocations = try XCTUnwrap(list["invocations"] as? [String: Any])
            XCTAssertEqual(invocations["malformed_identity_count"] as? Int, 1)
            XCTAssertEqual(invocations["identity_state"] as? String, "partial")
            XCTAssertFalse(payloadContains(malformedCanary, in: list))
            XCTAssertFalse(payloadContains("raw-request-canary-4C82", in: list))
        }

        func testMalformedTraceAppIdentityFailsEnvelopeInvocationClosedWithoutFallbackRow() async throws {
            _ = try startedCapture(label: "malformed-trace-app-identity")
            let appInvocationID = UUID()
            let connectionID = UUID()
            let validIdentity = requestIdentity(
                appInvocationID: appInvocationID,
                connectionID: connectionID,
                generation: 1,
                ordinal: 1,
                requestID: "valid-request"
            )
            try recordReceived(validIdentity)

            let malformedAppIDCanary = "malformed-app-id-canary-7F31"
            let rawRequestCanary = "raw-request-canary-7F31"
            let malformedIdentity = MCPRequestTimelineIdentity(
                jsonRPCRequestID: .string(rawRequestCanary),
                connectionID: connectionID.uuidString,
                connectionGeneration: 1,
                appInvocationID: malformedAppIDCanary,
                requestOrdinal: 1
            )
            let captureIdentity = try XCTUnwrap(EditFlowPerf.debugCaptureIdentity(toolName: "read_file"))
            MCPToolExecutionTracer.emit(
                Self.makeTraceEvent(
                    appInvocationID: appInvocationID,
                    connectionID: connectionID,
                    requestIdentity: malformedIdentity,
                    phase: .handlerCompleted,
                    freeFormCanary: "ignored"
                ),
                captureIdentity: captureIdentity
            )

            let list = try await invocationListResponse()
            let invocations = try XCTUnwrap(list["invocations"] as? [String: Any])
            let rows = try XCTUnwrap(invocations["entries"] as? [[String: Any]])
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows.first?["app_invocation_id"] as? String, appInvocationID.uuidString)
            XCTAssertEqual(invocations["malformed_identity_count"] as? Int, 1)
            XCTAssertFalse(payloadContains(malformedAppIDCanary, in: list))
            XCTAssertFalse(payloadContains(rawRequestCanary, in: list))

            let response = try await packetResponse(appInvocationID: appInvocationID)
            XCTAssertEqual(response["code"] as? String, "malformed_identity")
            XCTAssertFalse(payloadContains(malformedAppIDCanary, in: response))
            XCTAssertFalse(payloadContains(rawRequestCanary, in: response))
        }

        func testTraceWithoutRequestIdentityUsesEnvelopeIdentity() throws {
            _ = try startedCapture(label: "envelope-identity")
            let appInvocationID = UUID()
            let captureIdentity = try XCTUnwrap(EditFlowPerf.debugCaptureIdentity(toolName: "read_file"))
            MCPToolExecutionTracer.emit(
                Self.makeTraceEvent(
                    appInvocationID: appInvocationID,
                    connectionID: UUID(),
                    requestIdentity: nil,
                    phase: .handlerCompleted,
                    freeFormCanary: "ignored"
                ),
                captureIdentity: captureIdentity
            )
            let capture = EditFlowPerf.debugCaptureSnapshot(finish: false)
            let captureID = try XCTUnwrap(capture.captureID)
            let list = MCPReadFileInvocationDiagnosticPacketAssembler.invocationList(
                capture: capture,
                trace: MCPToolExecutionTracer.debugEventSnapshot(captureID),
                work: MCPToolWorkCountDiagnostics.debugReadFileSnapshot(captureID: captureID),
                limit: 64
            )
            XCTAssertEqual(list.entries.map(\.appInvocationID), [appInvocationID])
            XCTAssertEqual(list.inconsistentIdentityCount, 0)
            XCTAssertEqual(list.malformedIdentityCount, 0)
        }

        func testCaptureActivationRetainsAdmissionQueuedAfterDependentPreparation() throws {
            let preparationEntered = DispatchSemaphore(value: 0)
            let releasePreparation = DispatchSemaphore(value: 0)
            let admissionContended = DispatchSemaphore(value: 0)
            let workers = DispatchGroup()
            let identityBox = LockedBox<EditFlowPerf.DebugCaptureIdentity>()
            let beginSnapshotBox = LockedBox<EditFlowPerf.DebugCaptureSnapshot>()
            let gateTimeout: DispatchTimeInterval = .seconds(5)
            let gateDeadline = DispatchTime.now() + gateTimeout
            EditFlowPerf.setDebugCaptureLockContentionHookForTesting {
                admissionContended.signal()
            }
            defer {
                releasePreparation.signal()
                XCTAssertEqual(workers.wait(timeout: .now() + gateTimeout), .success)
                EditFlowPerf.setDebugCaptureLockContentionHookForTesting(nil)
            }

            workers.enter()
            DispatchQueue.global().async {
                defer { workers.leave() }
                let result = EditFlowPerf.beginDebugCapture(
                    label: "activation-admission",
                    maxSamples: 100,
                    expiryMilliseconds: 120_000,
                    toolFilter: .readFile,
                    prepare: { captureIdentity in
                        Self.prepareCaptureStores(captureIdentity)
                        identityBox.store(captureIdentity)
                        preparationEntered.signal()
                        _ = releasePreparation.wait(timeout: gateDeadline)
                    }
                )
                if case let .started(snapshot) = result {
                    beginSnapshotBox.store(snapshot)
                }
            }
            XCTAssertEqual(preparationEntered.wait(timeout: gateDeadline), .success)
            let captureIdentity = try XCTUnwrap(identityBox.load())

            workers.enter()
            DispatchQueue.global().async {
                defer { workers.leave() }
                MCPToolExecutionTracer.emit(
                    Self.makeTraceEvent(
                        appInvocationID: UUID(),
                        connectionID: UUID(),
                        requestIdentity: nil,
                        phase: .handlerCompleted,
                        freeFormCanary: "ignored"
                    ),
                    captureIdentity: captureIdentity
                )
            }
            XCTAssertEqual(admissionContended.wait(timeout: gateDeadline), .success)
            releasePreparation.signal()
            XCTAssertEqual(workers.wait(timeout: gateDeadline), .success)
            XCTAssertEqual(beginSnapshotBox.load()?.captureID, captureIdentity.captureID)
            let trace = MCPToolExecutionTracer.debugEventSnapshot(captureIdentity.captureID)
            XCTAssertEqual(trace.retainedCaptureID, captureIdentity.captureID)
            XCTAssertEqual(trace.retainedEventCount, 1)
            XCTAssertEqual(trace.droppedEventCount, 0)
        }

        func testInvocationListAssemblyKeepsReplacementOutsideStableCaptureView() throws {
            let prior = try startedCapture(label: "list-prior")
            let priorCaptureID = try XCTUnwrap(prior.captureID)
            let appInvocationID = UUID()
            try recordReceived(requestIdentity(
                appInvocationID: appInvocationID,
                connectionID: UUID(),
                generation: 1,
                ordinal: 1,
                requestID: "list-prior-request"
            ))

            let accessEntered = DispatchSemaphore(value: 0)
            let releaseAccess = DispatchSemaphore(value: 0)
            let replacementContended = DispatchSemaphore(value: 0)
            let workers = DispatchGroup()
            let listBox = LockedBox<MCPReadFileInvocationDiagnosticList>()
            let replacementIDBox = LockedBox<UUID>()
            let gateTimeout: DispatchTimeInterval = .seconds(5)
            let gateDeadline = DispatchTime.now() + gateTimeout
            EditFlowPerf.setDebugCaptureLockContentionHookForTesting {
                replacementContended.signal()
            }
            defer {
                releaseAccess.signal()
                XCTAssertEqual(workers.wait(timeout: .now() + gateTimeout), .success)
                EditFlowPerf.setDebugCaptureLockContentionHookForTesting(nil)
            }

            workers.enter()
            DispatchQueue.global().async {
                defer { workers.leave() }
                _ = EditFlowPerf.withDebugCaptureSnapshot { snapshot in
                    accessEntered.signal()
                    _ = releaseAccess.wait(timeout: gateDeadline)
                    guard let captureID = snapshot.captureID else {
                        return Result<MCPReadFileInvocationDiagnosticList, PacketTestError>.failure(.captureMismatch)
                    }
                    let trace = MCPToolExecutionTracer.debugEventSnapshot(captureID)
                    let work = MCPToolWorkCountDiagnostics.debugReadFileSnapshot(captureID: captureID)
                    guard trace.retainedCaptureID == captureID,
                          work.retainedCaptureID == captureID
                    else {
                        return .failure(.captureMismatch)
                    }
                    let list = MCPReadFileInvocationDiagnosticPacketAssembler.invocationList(
                        capture: snapshot,
                        trace: trace,
                        work: work,
                        limit: 64
                    )
                    listBox.store(list)
                    return .success(list)
                }
            }
            XCTAssertEqual(accessEntered.wait(timeout: gateDeadline), .success)

            workers.enter()
            DispatchQueue.global().async {
                defer { workers.leave() }
                _ = EditFlowPerf.debugCaptureSnapshot(finish: true)
                if case let .started(snapshot) = EditFlowPerf.beginDebugCapture(
                    label: "list-replacement",
                    maxSamples: 100,
                    expiryMilliseconds: 120_000,
                    toolFilter: .readFile,
                    prepare: Self.prepareCaptureStores
                ) {
                    replacementIDBox.store(snapshot.captureID)
                }
            }
            XCTAssertEqual(replacementContended.wait(timeout: gateDeadline), .success)
            releaseAccess.signal()
            XCTAssertEqual(workers.wait(timeout: gateDeadline), .success)
            XCTAssertEqual(listBox.load()?.captureID, priorCaptureID)
            XCTAssertEqual(listBox.load()?.entries.map(\.appInvocationID), [appInvocationID])
            let replacementID = try XCTUnwrap(replacementIDBox.load())
            XCTAssertNotEqual(replacementID, priorCaptureID)
            XCTAssertEqual(EditFlowPerf.debugCaptureIdentity(toolName: "read_file")?.captureID, replacementID)
        }

        func testSuccessfulPacketAssemblyFinishesOnlyPriorCaptureBeforeReplacementBegins() throws {
            let prior = try startedCapture(label: "packet-prior")
            let priorCaptureID = try XCTUnwrap(prior.captureID)
            let appInvocationID = UUID()
            try recordReceived(requestIdentity(
                appInvocationID: appInvocationID,
                connectionID: UUID(),
                generation: 1,
                ordinal: 1,
                requestID: "packet-prior-request"
            ))

            let accessEntered = DispatchSemaphore(value: 0)
            let releaseAccess = DispatchSemaphore(value: 0)
            let replacementContended = DispatchSemaphore(value: 0)
            let workers = DispatchGroup()
            let packetBox = LockedBox<MCPReadFileInvocationDiagnosticPacket>()
            let replacementIDBox = LockedBox<UUID>()
            let gateTimeout: DispatchTimeInterval = .seconds(5)
            let gateDeadline = DispatchTime.now() + gateTimeout
            EditFlowPerf.setDebugCaptureLockContentionHookForTesting {
                replacementContended.signal()
            }
            defer {
                releaseAccess.signal()
                XCTAssertEqual(workers.wait(timeout: .now() + gateTimeout), .success)
                EditFlowPerf.setDebugCaptureLockContentionHookForTesting(nil)
            }

            workers.enter()
            DispatchQueue.global().async {
                defer { workers.leave() }
                _ = EditFlowPerf.withDebugCaptureSnapshot(finishOnSuccess: true) { snapshot in
                    accessEntered.signal()
                    _ = releaseAccess.wait(timeout: gateDeadline)
                    guard let captureID = snapshot.captureID else {
                        return Result<MCPReadFileInvocationDiagnosticPacket, PacketTestError>.failure(.captureMismatch)
                    }
                    let trace = MCPToolExecutionTracer.debugEventSnapshot(captureID)
                    let work = MCPToolWorkCountDiagnostics.debugReadFileSnapshot(captureID: captureID)
                    guard trace.retainedCaptureID == captureID,
                          work.retainedCaptureID == captureID,
                          let packet = try? MCPReadFileInvocationDiagnosticPacketAssembler.packet(
                              appInvocationID: appInvocationID,
                              capture: snapshot,
                              trace: trace,
                              work: work,
                              runtimeIdentity: Self.completeRuntimeIdentityValue()
                          )
                    else {
                        return .failure(.captureMismatch)
                    }
                    packetBox.store(packet)
                    return .success(packet)
                }
            }
            XCTAssertEqual(accessEntered.wait(timeout: gateDeadline), .success)

            workers.enter()
            DispatchQueue.global().async {
                defer { workers.leave() }
                _ = EditFlowPerf.debugCaptureSnapshot(finish: true)
                if case let .started(snapshot) = EditFlowPerf.beginDebugCapture(
                    label: "packet-replacement",
                    maxSamples: 100,
                    expiryMilliseconds: 120_000,
                    toolFilter: .readFile,
                    prepare: Self.prepareCaptureStores
                ) {
                    replacementIDBox.store(snapshot.captureID)
                }
            }
            XCTAssertEqual(replacementContended.wait(timeout: gateDeadline), .success)
            releaseAccess.signal()
            XCTAssertEqual(workers.wait(timeout: gateDeadline), .success)
            XCTAssertEqual(packetBox.load()?.captureID, priorCaptureID)
            let replacementID = try XCTUnwrap(replacementIDBox.load())
            XCTAssertNotEqual(replacementID, priorCaptureID)
            XCTAssertEqual(EditFlowPerf.debugCaptureIdentity(toolName: "read_file")?.captureID, replacementID)
        }

        func testBusyCaptureBeginPreservesActiveCaptureEvidence() async throws {
            _ = try startedCapture(label: "busy-preserves-evidence")
            let activeIdentity = try XCTUnwrap(EditFlowPerf.debugCaptureIdentity(toolName: "read_file"))
            let appInvocationID = UUID()
            let identity = requestIdentity(
                appInvocationID: appInvocationID,
                connectionID: UUID(),
                generation: 1,
                ordinal: 1,
                requestID: "active-request"
            )
            let connectionID = try XCTUnwrap(identity.connectionID.flatMap(UUID.init(uuidString:)))
            MCPToolExecutionTracer.emit(
                Self.makeTraceEvent(
                    appInvocationID: appInvocationID,
                    connectionID: connectionID,
                    requestIdentity: identity,
                    phase: .handlerCompleted,
                    freeFormCanary: "ignored"
                ),
                captureIdentity: activeIdentity
            )
            try await appendWorkCount(identity: identity)

            let busy = try await payload(ServerNetworkManager.shared.handleDebugDiagnosticsTool(
                connectionID: UUID(),
                arguments: [
                    "op": .string("mcp_read_search_capture_begin"),
                    "label": .string("replacement")
                ]
            ))
            XCTAssertEqual(busy["code"] as? String, "capture_busy")
            XCTAssertEqual(EditFlowPerf.debugCaptureIdentity(toolName: "read_file"), activeIdentity)
            let trace = MCPToolExecutionTracer.debugEventSnapshot(activeIdentity.captureID)
            let work = MCPToolWorkCountDiagnostics.debugReadFileSnapshot(captureID: activeIdentity.captureID)
            XCTAssertEqual(trace.retainedCaptureID, activeIdentity.captureID)
            XCTAssertEqual(trace.retainedEventCount, 1)
            XCTAssertEqual(work.retainedCaptureID, activeIdentity.captureID)
            XCTAssertEqual(work.retainedEntryCount, 1)
        }

        func testWorkCountCompletionAfterCaptureCloseCannotPopulateReplacementCapture() async throws {
            _ = try startedCapture(label: "work-prior")
            let priorIdentity = try XCTUnwrap(EditFlowPerf.debugCaptureIdentity(toolName: "read_file"))
            let request = requestIdentity(
                appInvocationID: UUID(),
                connectionID: UUID(),
                generation: 1,
                ordinal: 1,
                requestID: "late-work"
            )
            let entered = AsyncGate()
            let release = AsyncGate()
            let task = Task {
                try await MCPRequestTimelineContext.$current.withValue(request) {
                    try await MCPToolWorkCountDiagnostics.withReadFileInvocation {
                        await entered.open()
                        await release.wait()
                    }
                }
            }
            await entered.wait()
            _ = EditFlowPerf.debugCaptureSnapshot(finish: true)
            _ = try startedCapture(label: "work-replacement")
            let replacementIdentity = try XCTUnwrap(EditFlowPerf.debugCaptureIdentity(toolName: "read_file"))
            await release.open()
            _ = try await task.value

            let prior = MCPToolWorkCountDiagnostics.debugReadFileSnapshot(captureID: priorIdentity.captureID)
            XCTAssertEqual(prior.retainedEntryCount, 0)
            XCTAssertEqual(prior.droppedEntryCount, 1)
            let replacement = MCPToolWorkCountDiagnostics.debugReadFileSnapshot(
                captureID: replacementIdentity.captureID
            )
            XCTAssertEqual(replacement.retainedEntryCount, 0)
            XCTAssertEqual(replacement.droppedEntryCount, 0)
        }

        private func startedCapture(
            label: String,
            maxSamples: Int = 100
        ) throws -> EditFlowPerf.DebugCaptureSnapshot {
            switch EditFlowPerf.beginDebugCapture(
                label: label,
                maxSamples: maxSamples,
                expiryMilliseconds: 120_000,
                toolFilter: .readFile,
                prepare: Self.prepareCaptureStores
            ) {
            case let .started(snapshot):
                return snapshot
            case .busy:
                XCTFail("Expected a fresh read-file diagnostic capture.")
                throw PacketTestError.captureBusy
            }
        }

        private func requestIdentity(
            appInvocationID: UUID,
            connectionID: UUID,
            generation: UInt64,
            ordinal: UInt64,
            requestID: String
        ) -> MCPRequestTimelineIdentity {
            MCPRequestTimelineIdentity(
                jsonRPCRequestID: .string(requestID),
                connectionID: connectionID.uuidString,
                connectionGeneration: generation,
                appInvocationID: appInvocationID.uuidString,
                requestOrdinal: ordinal
            )
        }

        private func recordReceived(_ identity: MCPRequestTimelineIdentity) throws {
            let correlation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive(
                requestIdentity: identity,
                toolName: "read_file"
            ))
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.MCPToolCall.received,
                correlation: correlation,
                EditFlowPerf.Dimensions(toolName: "read_file")
            )
        }

        private func appendWorkCount(identity: MCPRequestTimelineIdentity) async throws {
            try await MCPRequestTimelineContext.$current.withValue(identity) {
                try await MCPToolWorkCountDiagnostics.withReadFileInvocation {
                    MCPToolWorkCountDiagnostics.recordReadFileResult(
                        returnedBytes: 1,
                        returnedLines: 1,
                        cacheHit: true
                    )
                }
            }
        }

        private func packetResponse(appInvocationID: UUID) async throws -> [String: Any] {
            try await payload(ServerNetworkManager.shared.handleDebugDiagnosticsTool(
                connectionID: UUID(),
                arguments: [
                    "op": .string("read_file_invocation_packet"),
                    "app_invocation_id": .string(appInvocationID.uuidString)
                ]
            ))
        }

        private func invocationListResponse() async throws -> [String: Any] {
            try await payload(ServerNetworkManager.shared.handleDebugDiagnosticsTool(
                connectionID: UUID(),
                arguments: ["op": .string("list_read_file_invocations")]
            ))
        }

        private enum TruncatedDeadlineEvidenceSection {
            case freshness
            case exactResolution
            case interactive
            case settlement
            case lifecycle
            case execution
        }

        private func preciseBoundaryPacket(
            truncating section: TruncatedDeadlineEvidenceSection
        ) throws -> MCPReadFileInvocationDiagnosticPacket {
            _ = try startedCapture(label: "precise-boundary-truncated-\(section)", maxSamples: 1000)
            let appInvocationID = UUID()
            let connectionID = UUID()
            let identity = requestIdentity(
                appInvocationID: appInvocationID,
                connectionID: connectionID,
                generation: 1,
                ordinal: 1,
                requestID: "precise-boundary-truncated-\(section)"
            )
            try recordReceived(identity)
            let correlation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive(
                requestIdentity: identity,
                toolName: "read_file"
            ))
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFile.explicitFreshnessBegan,
                correlation: correlation
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFile.explicitFreshnessEnded,
                correlation: correlation,
                EditFlowPerf.Dimensions(outcome: "success", rootCount: 1)
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.WorkspaceExactResolution.checkpoint,
                correlation: correlation,
                EditFlowPerf.Dimensions(runPurpose: "explicitMaterialization", status: "materializationBegan")
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.WorkspaceExactResolution.checkpoint,
                correlation: correlation,
                EditFlowPerf.Dimensions(
                    runPurpose: "explicitMaterialization",
                    status: "materializationEnded",
                    outcome: "materialized",
                    rootToken: UUID().uuidString
                )
            )
            let interactiveRootToken = UUID().uuidString
            EditFlowPerf.lifecycleEvent(
                "ReadFile.InteractiveStage",
                correlation: correlation,
                EditFlowPerf.Dimensions(
                    runPurpose: "attempt",
                    status: "began",
                    rootToken: interactiveRootToken,
                    serialPosition: 0
                )
            )
            EditFlowPerf.lifecycleEvent(
                "ReadFile.InteractiveStage",
                correlation: correlation,
                EditFlowPerf.Dimensions(
                    runPurpose: "attempt",
                    status: "ended",
                    outcome: "completed",
                    rootToken: interactiveRootToken,
                    serialPosition: 0
                )
            )

            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFile.providerResultReady,
                correlation: correlation
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFile.explicitFreshnessBegan,
                correlation: correlation
            )
            EditFlowPerf.lifecycleEvent(
                "ReadFile.SettlementTransition",
                correlation: correlation,
                EditFlowPerf.Dimensions(runPurpose: "execution_deadline_cancellation_boundary")
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFile.explicitFreshnessEnded,
                correlation: correlation,
                EditFlowPerf.Dimensions(outcome: "outer_cancellation", rootCount: 0)
            )
            EditFlowPerf.lifecycleEvent(
                "ReadFile.SettlementTransition",
                correlation: correlation,
                EditFlowPerf.Dimensions(runPurpose: "execution_deadline_expired", outcome: "observed")
            )

            switch section {
            case .freshness:
                for _ in 0 ... 128 {
                    EditFlowPerf.lifecycleEvent("ReadFile.FreshnessRootSnapshot", correlation: correlation)
                }
            case .exactResolution:
                for _ in 0 ... 512 {
                    EditFlowPerf.lifecycleEvent(
                        EditFlowPerf.Lifecycle.WorkspaceExactResolution.checkpoint,
                        correlation: correlation
                    )
                }
            case .interactive:
                for _ in 0 ... 256 {
                    EditFlowPerf.lifecycleEvent("ReadFile.InteractiveStage", correlation: correlation)
                }
            case .settlement:
                for _ in 0 ... 64 {
                    EditFlowPerf.lifecycleEvent(
                        "ReadFile.SettlementTransition",
                        correlation: correlation,
                        EditFlowPerf.Dimensions(runPurpose: "execution_started", outcome: "observed")
                    )
                }
            case .lifecycle:
                for _ in 0 ... 512 {
                    EditFlowPerf.lifecycleEvent(
                        EditFlowPerf.Lifecycle.ReadFile.providerEntered,
                        correlation: correlation
                    )
                }
            case .execution:
                break
            }
            let captureIdentity = try XCTUnwrap(EditFlowPerf.debugCaptureIdentity(toolName: "read_file"))
            MCPToolExecutionTracer.emit(
                Self.makeTraceEvent(
                    appInvocationID: appInvocationID,
                    connectionID: connectionID,
                    requestIdentity: identity,
                    phase: .deadlineExpired,
                    freeFormCanary: "ignored",
                    cancellationOrigin: .watchdogDeadline,
                    cancellationOutcome: "cancellation"
                ),
                captureIdentity: captureIdentity
            )
            if case .execution = section {
                for _ in 0 ..< 64 {
                    MCPToolExecutionTracer.emit(
                        Self.makeTraceEvent(
                            appInvocationID: appInvocationID,
                            connectionID: connectionID,
                            requestIdentity: identity,
                            phase: .handlerPhaseTransition,
                            freeFormCanary: "ignored"
                        ),
                        captureIdentity: captureIdentity
                    )
                }
            }

            let capture = EditFlowPerf.debugCaptureSnapshot(finish: false)
            let captureID = try XCTUnwrap(capture.captureID)
            return try MCPReadFileInvocationDiagnosticPacketAssembler.packet(
                appInvocationID: appInvocationID,
                capture: capture,
                trace: MCPToolExecutionTracer.debugEventSnapshot(captureID),
                work: MCPToolWorkCountDiagnostics.debugReadFileSnapshot(captureID: captureID),
                runtimeIdentity: Self.completeRuntimeIdentityValue()
            )
        }

        private func assertDeadlineSummarySuppressedBySelectedLoss(
            _ packet: MCPReadFileInvocationDiagnosticPacket,
            section: String,
            label: String,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            let truncated = switch section {
            case "freshness_authority_ingress": packet.freshnessAuthorityIngress.truncated
            case "exact_resolution": packet.exactResolution.truncated
            case "interactive_load": packet.interactiveLoad.truncated
            case "settlement": packet.settlement.truncated
            case "lifecycle": packet.lifecycle.truncated
            case "execution_trace": packet.executionTrace.truncated
            default: false
            }
            XCTAssertTrue(truncated, label, file: file, line: line)
            XCTAssertTrue(packet.watchdogTerminalObserved, label, file: file, line: line)
            XCTAssertTrue(packet.openInnerStagesAtWatchdogTerminal.isEmpty, label, file: file, line: line)
            XCTAssertNil(packet.longestClosedInnerStage, label, file: file, line: line)
            XCTAssertFalse(packet.requiredEvidenceComplete, label, file: file, line: line)
            XCTAssertTrue(packet.missingRequiredEvidence.contains("\(section):truncated"), label, file: file, line: line)
            XCTAssertFalse(
                packet.missingRequiredEvidence.contains("watchdog_terminal_boundary:missing"),
                "The retained precise boundary must remain distinguished from selected evidence loss.",
                file: file,
                line: line
            )
            let boundary = packet.settlement.entries.first {
                $0.dimensions["purpose"] == "execution_deadline_cancellation_boundary"
            }
            let boundaryOrdinal = boundary?.ordinal
            XCTAssertNotNil(boundaryOrdinal, label, file: file, line: line)
            XCTAssertTrue(packet.settlement.entries.contains { entry in
                entry.dimensions["purpose"] == "execution_deadline_expired"
                    && boundaryOrdinal.map { entry.ordinal > $0 } == true
            }, label, file: file, line: line)
            XCTAssertTrue(packet.freshnessAuthorityIngress.entries.contains { entry in
                entry.kind == "ReadFile.ExplicitFreshnessEnded"
                    && boundaryOrdinal.map { entry.ordinal > $0 } == true
            }, label, file: file, line: line)
        }

        private func closedFreshnessFallbackFixture(
            label: String
        ) throws -> (
            appInvocationID: UUID,
            connectionID: UUID,
            identity: MCPRequestTimelineIdentity,
            correlation: EditFlowPerf.LifecycleCorrelation,
            captureIdentity: EditFlowPerf.DebugCaptureIdentity
        ) {
            _ = try startedCapture(label: label)
            let appInvocationID = UUID()
            let connectionID = UUID()
            let identity = requestIdentity(
                appInvocationID: appInvocationID,
                connectionID: connectionID,
                generation: 1,
                ordinal: 1,
                requestID: label
            )
            try recordReceived(identity)
            let correlation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive(
                requestIdentity: identity,
                toolName: "read_file"
            ))
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFile.explicitFreshnessBegan,
                correlation: correlation
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFile.explicitFreshnessEnded,
                correlation: correlation,
                EditFlowPerf.Dimensions(outcome: "success", rootCount: 1)
            )
            EditFlowPerf.lifecycleEvent(
                "ReadFile.SettlementTransition",
                correlation: correlation,
                EditFlowPerf.Dimensions(runPurpose: "execution_deadline_expired", outcome: "observed")
            )
            return try (
                appInvocationID,
                connectionID,
                identity,
                correlation,
                XCTUnwrap(EditFlowPerf.debugCaptureIdentity(toolName: "read_file"))
            )
        }

        private static func makeTraceEvent(
            appInvocationID: UUID,
            connectionID: UUID,
            requestIdentity: MCPRequestTimelineIdentity?,
            phase: MCPToolExecutionTraceEvent.Phase,
            freeFormCanary: String,
            cancellationRequested: Bool = false,
            cancellationOrigin: MCPToolExecutionCancellationOrigin? = nil,
            cancellationOutcome: String? = nil,
            graceOutcome: String? = nil
        ) -> MCPToolExecutionTraceEvent {
            MCPToolExecutionTraceEvent(
                toolName: "read_file",
                operationIdentity: MCPDomainToolCatalog.operationIdentity(for: "read_file", input: .missing),
                connectionID: connectionID,
                invocationID: appInvocationID,
                runID: nil,
                requestIdentity: requestIdentity,
                contractKind: .bounded,
                executionDeadlineSeconds: 30,
                cleanupGraceSeconds: 5,
                cleanupDisposition: .detachAndSettle,
                phase: phase,
                elapsedMilliseconds: 12.5,
                cancellationRequested: cancellationRequested,
                cancellationOutcome: cancellationOutcome ?? freeFormCanary,
                cancellationOrigin: cancellationOrigin,
                settlement: freeFormCanary,
                graceOutcome: graceOutcome ?? freeFormCanary,
                escalationReason: freeFormCanary,
                handlerPhase: nil,
                handlerPhaseAgeMilliseconds: nil
            )
        }

        private static func completeRuntimeIdentityValue() -> MCPReadFileDiagnosticRuntimeIdentity {
            MCPReadFileDiagnosticRuntimeIdentity(
                bundleIdentifier: "com.example.RepoPrompt.debug",
                marketingVersion: "1.2.3",
                buildNumber: "456",
                machOUUID: UUID(),
                executableSHA256: String(repeating: "a", count: 64),
                sourceBaseCommit: String(repeating: "b", count: 40),
                sourceTreeDirty: true,
                diagnosticPatchPresent: true,
                diagnosticPatchDigest: String(repeating: "c", count: 64),
                processStartID: UUID()
            )
        }

        private func payload(_ result: CallTool.Result) throws -> [String: Any] {
            let text = result.content.compactMap { content -> String? in
                if case let .text(text, _, _) = content { return text }
                return nil
            }.joined()
            let data = try XCTUnwrap(text.data(using: .utf8))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        private func assertEveryPacketSectionReportsBounds(
            _ packet: [String: Any],
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            XCTAssertEqual(packet["dropped_event_scope"] as? String, "capture_wide", file: file, line: line)
            XCTAssertNotNil(packet["selected_invocation_loss_attribution"], file: file, line: line)
            XCTAssertNotNil(packet["truncation_scope"], file: file, line: line)
            for key in ["invocation", "runtime_identity", "lifecycle", "execution_trace", "work_counts"] {
                guard let section = packet[key] as? [String: Any] else {
                    return XCTFail("Missing packet section \(key)", file: file, line: line)
                }
                XCTAssertNotNil(section["state"], key, file: file, line: line)
                XCTAssertNotNil(section["truncated"], key, file: file, line: line)
                XCTAssertNotNil(section["omitted_count"], key, file: file, line: line)
                if ["lifecycle", "execution_trace", "work_counts"].contains(key) {
                    XCTAssertNotNil(section["capture_wide_omitted_count"], key, file: file, line: line)
                    XCTAssertNotNil(section["capture_wide_loss_impact"], key, file: file, line: line)
                }
            }
        }

        private func captureIdentityToken(from packet: [String: Any]) -> String? {
            let token = packet["capture_label_token"] as? String
            return token?.hasPrefix("capture_label:") == true ? token : nil
        }

        private func payloadContains(_ needle: String, in value: Any) -> Bool {
            if let string = value as? String {
                return string.contains(needle)
            }
            if let dictionary = value as? [String: Any] {
                return dictionary.contains { key, nested in
                    key.contains(needle) || payloadContains(needle, in: nested)
                }
            }
            if let array = value as? [Any] {
                return array.contains { payloadContains(needle, in: $0) }
            }
            return false
        }

        private func payloadContainsKey(_ needle: String, in value: Any) -> Bool {
            if let dictionary = value as? [String: Any] {
                return dictionary.contains { key, nested in
                    key == needle || payloadContainsKey(needle, in: nested)
                }
            }
            if let array = value as? [Any] {
                return array.contains { payloadContainsKey(needle, in: $0) }
            }
            return false
        }

        private enum PacketTestError: Error {
            case captureBusy
            case captureMismatch
        }

        private static func prepareCaptureStores(_ captureIdentity: EditFlowPerf.DebugCaptureIdentity) {
            MCPResponseDeliveryTracer.prepareDebugCapture(captureIdentity.captureID)
            MCPToolExecutionTracer.prepareDebugCapture(captureIdentity)
            MCPToolWorkCountDiagnostics.prepareDebugCapture(captureIdentity)
        }

        private actor AsyncGate {
            private var openState = false
            private var waiters: [CheckedContinuation<Void, Never>] = []

            func wait() async {
                guard !openState else { return }
                await withCheckedContinuation { continuation in
                    waiters.append(continuation)
                }
            }

            func open() {
                guard !openState else { return }
                openState = true
                let current = waiters
                waiters.removeAll()
                current.forEach { $0.resume() }
            }
        }

        private final class LockedBox<Value>: @unchecked Sendable {
            private let lock = NSLock()
            private var value: Value?

            func store(_ value: Value?) {
                lock.withLock {
                    self.value = value
                }
            }

            func load() -> Value? {
                lock.withLock { value }
            }
        }
    }
#endif
