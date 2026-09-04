import Darwin
import Foundation
import MCP
@testable import RepoPromptApp
@testable import RepoPromptMCP
import RepoPromptShared
import XCTest

final class PersistentMCPResponseDeliveryTests: XCTestCase {
    func testOutstandingReplayStateOnlyCachesReplayableSingleRequests() async {
        let replayState = MCPOutstandingRequestReplayState()
        let unsafeToolCall = line(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"apply_edits","arguments":{"path":"README.md","search":"a","replace":"b"}}}"#)
        let batchedSafeRequest = line(#"[{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}]"#)
        let safeToolCall = line(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"read_file","arguments":{"path":"README.md"}}}"#)
        let safeMethodRequest = line(#"{"jsonrpc":"2.0","id":4,"method":"tools/list","params":{}}"#)
        let unsafeWorkspaceExport = line(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"workspace_context","arguments":{"op":"export","path":"context.txt"}}}"#)
        let safeWorkspaceSnapshot = line(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"workspace_context","arguments":{"op":"snapshot","include":["tokens"]}}}"#)

        await replayState.recordForwardedClientFrame(unsafeToolCall)
        await replayState.recordForwardedClientFrame(batchedSafeRequest)
        await replayState.recordForwardedClientFrame(unsafeWorkspaceExport)
        var frames = await replayState.replayFrames()
        XCTAssertEqual(frames, [])

        await replayState.recordForwardedClientFrame(safeToolCall)
        await replayState.recordForwardedClientFrame(safeMethodRequest)
        await replayState.recordForwardedClientFrame(safeWorkspaceSnapshot)
        frames = await replayState.replayFrames()
        XCTAssertEqual(frames.count, 3)
        assertJSONLineEqual(frames[0], safeToolCall)
        assertJSONLineEqual(frames[1], safeMethodRequest)
        assertJSONLineEqual(frames[2], safeWorkspaceSnapshot)

        await replayState.recordForwardedClientFrame(line(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":3}}"#))
        frames = await replayState.replayFrames()
        XCTAssertEqual(frames.count, 2)

        await replayState.recordDeliveredServerFrame(line(#"{"jsonrpc":"2.0","id":4,"result":{"tools":[]}}"#))
        await replayState.recordDeliveredServerFrame(line(#"{"jsonrpc":"2.0","id":6,"result":{"prompt_tokens":0}}"#))
        frames = await replayState.replayFrames()
        XCTAssertEqual(frames, [])
    }

    func testOutstandingReplayStateIgnoresClientResponseForAppOriginatedIDCollision() async {
        let replayState = MCPOutstandingRequestReplayState()
        let hostRequest = line(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"read_file","arguments":{"path":"README.md"}}}"#)
        let clientResponse = line(#"{"jsonrpc":"2.0","id":7,"result":{"roots":[]}}"#)

        await replayState.recordForwardedClientFrame(hostRequest)
        await replayState.recordForwardedClientFrame(clientResponse)
        let frames = await replayState.replayFrames()
        XCTAssertEqual(frames.count, 1)
        assertJSONLineEqual(frames[0], hostRequest)

        await replayState.recordDeliveredServerFrame(line(#"{"jsonrpc":"2.0","id":7,"result":{"content":[]}}"#))
        let finalFrames = await replayState.replayFrames()
        XCTAssertEqual(finalFrames, [])
    }

    func testOutstandingReplayStateUsesStrictJSONRPCIDs() async {
        let replayState = MCPOutstandingRequestReplayState()
        let hostRequest = line(#"{"jsonrpc":"2.0","id":7,"method":"tools/list","params":{}}"#)

        await replayState.recordForwardedClientFrame(line(#"{"jsonrpc":"2.0","id":7.5,"method":"tools/list","params":{}}"#))
        var frames = await replayState.replayFrames()
        XCTAssertEqual(frames, [])

        await replayState.recordForwardedClientFrame(hostRequest)
        await replayState.recordForwardedClientFrame(line(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7.5}}"#))
        frames = await replayState.replayFrames()
        XCTAssertEqual(frames.count, 1)

        await replayState.recordForwardedClientFrame(line(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7}}"#))
        frames = await replayState.replayFrames()
        XCTAssertEqual(frames, [])
    }

    #if DEBUG
        func testSameProcessToolInvocationJoinsPhaseHistoryThroughHandlerUDSBridgeAndStdout() async throws {
            let tracingDefaults = UserDefaults.standard
            let previousResponseTracing = tracingDefaults.bool(forKey: "enableMCPResponseDeliveryTrace")
            let previousPerformanceTracing = tracingDefaults.bool(forKey: "enableAgentModePerfDiagnostics")
            tracingDefaults.set(false, forKey: "enableMCPResponseDeliveryTrace")
            tracingDefaults.set(false, forKey: "enableAgentModePerfDiagnostics")
            EditFlowPerf.resetDebugCaptureForTesting()
            MCPResponseDeliveryTracer.resetDebugEvents()
            MCPToolExecutionPhaseHistoryRecorder.shared.reset()
            defer {
                tracingDefaults.set(previousResponseTracing, forKey: "enableMCPResponseDeliveryTrace")
                tracingDefaults.set(previousPerformanceTracing, forKey: "enableAgentModePerfDiagnostics")
            }

            var socketDescriptors = try makeSocketPair()
            var stdinDescriptors = try makePipe()
            var stdoutDescriptors = try makePipe()
            let stdoutReader = BoundedLineReader(descriptor: stdoutDescriptors[0])
            defer {
                closeDescriptor(&socketDescriptors[0])
                closeDescriptor(&socketDescriptors[1])
                closeDescriptor(&stdinDescriptors[0])
                closeDescriptor(&stdinDescriptors[1])
                closeDescriptor(&stdoutDescriptors[0])
                closeDescriptor(&stdoutDescriptors[1])
            }

            let appConnectionID = UUID()
            let correlationConnectionID = "phase-history-\(UUID().uuidString)"
            let clientName = "MCPToolExecutionPhaseHistoryTests"
            try await AppGlobalMCPServiceComposition.shared.ensureRegistered()
            let networkManager = ServerNetworkManager.shared
            let wasNetworkManagerRunning = await networkManager.isRunning()
            let connectionManager = try BootstrapSocketConnectionManager(
                connectionID: appConnectionID,
                sessionToken: correlationConnectionID,
                clientPid: Int(getpid()),
                observedKernelPeerPID: Int(getpid()),
                clientName: clientName,
                purpose: .unknown,
                codeMapsDisabled: true,
                connectedFD: socketDescriptors[0],
                parentManager: networkManager
            )
            socketDescriptors[0] = -1
            await networkManager.debugInstallDirectAdmissionConnectionForTesting(
                connectionID: appConnectionID,
                connection: connectionManager,
                pendingClientID: clientName
            )
            _ = await networkManager.debugInstallConnectionLimiterForTesting(connectionID: appConnectionID)
            addTeardownBlock {
                await connectionManager.stop()
                await networkManager.debugRemoveConnection(appConnectionID)
                if !wasNetworkManagerRunning {
                    await networkManager.stop()
                }
            }
            addTeardownBlock {
                _ = await networkManager.handleDebugDiagnosticsTool(
                    connectionID: appConnectionID,
                    arguments: [
                        "op": .string("mcp_read_search_capture_snapshot"),
                        "finish": .bool(true)
                    ]
                )
                EditFlowPerf.resetDebugCaptureForTesting()
                MCPResponseDeliveryTracer.resetDebugEvents()
                MCPToolExecutionPhaseHistoryRecorder.shared.reset()
            }
            try await connectionManager.start { $0.name == clientName }

            let beginResult = await networkManager.handleDebugDiagnosticsTool(
                connectionID: appConnectionID,
                arguments: [
                    "op": .string("mcp_read_search_capture_begin"),
                    "label": .string("phase-history-same-process-path")
                ]
            )
            XCTAssertEqual(try diagnosticsPayload(beginResult)["ok"] as? Bool, true)

            let ledger = JSONRPCBridgeLedger(connectionID: correlationConnectionID)
            let proxySocketFD = socketDescriptors[1]
            socketDescriptors[1] = -1
            let bridgeStdinFD = stdinDescriptors[0]
            stdinDescriptors[0] = -1
            let bridgeStdoutFD = stdoutDescriptors[1]
            stdoutDescriptors[1] = -1
            let bridgeTask = Task {
                try await BootstrapSocketProxy.runBridge(
                    socketFD: proxySocketFD,
                    stdinFD: bridgeStdinFD,
                    stdoutFD: bridgeStdoutFD,
                    identityCache: ClientIdentityCache(),
                    bridgeLedger: ledger,
                    faultRule: nil,
                    drainLogDescriptor: STDERR_FILENO
                )
            }
            addTeardownBlock {
                bridgeTask.cancel()
                _ = Darwin.shutdown(proxySocketFD, SHUT_RDWR)
                Darwin.close(bridgeStdinFD)
                Darwin.close(bridgeStdoutFD)
                _ = try? await bridgeTask.value
                Darwin.close(proxySocketFD)
            }

            try writeAll(line(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"MCPToolExecutionPhaseHistoryTests","version":"1.0"}}}"#), to: stdinDescriptors[1])
            try assertJSONRPCResponse(stdoutReader.readLine(), id: 1)
            try writeAll(line(#"{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}"#), to: stdinDescriptors[1])

            let toolRequest = line(#"{"jsonrpc":"2.0","id":41,"method":"tools/call","params":{"name":"app_settings","arguments":{"op":"list","detailed":true}}}"#)
            try writeAll(toolRequest, to: stdinDescriptors[1])
            let toolResponse = try stdoutReader.readLine()
            try assertJSONRPCResponse(toolResponse, id: 41)
            closeDescriptor(&stdinDescriptors[1])
            try await bridgeTask.value

            let snapshotResult = await networkManager.handleDebugDiagnosticsTool(
                connectionID: appConnectionID,
                arguments: [
                    "op": .string("mcp_read_search_capture_snapshot"),
                    "finish": .bool(true)
                ]
            )
            let snapshotPayload = try diagnosticsPayload(snapshotResult)
            let workCountEvidence = try XCTUnwrap(snapshotPayload["work_count_evidence"] as? [String: Any])
            XCTAssertNotNil(workCountEvidence["git"] as? [[String: Any]])
            XCTAssertNotNil(workCountEvidence["read_file"] as? [[String: Any]])
            let phaseHistories = try XCTUnwrap(snapshotPayload["phase_histories"] as? [[String: Any]])
            let phaseHistory = try XCTUnwrap(phaseHistories.first {
                $0["tool"] as? String == "app_settings"
            })
            let appInvocationID = try XCTUnwrap(phaseHistory["app_invocation_id"] as? String)
            XCTAssertEqual(phaseHistory["app_connection_id"] as? String, appConnectionID.uuidString)
            XCTAssertEqual(phaseHistory["correlation_connection_id"] as? String, correlationConnectionID)
            let phaseEvents = try XCTUnwrap(phaseHistory["events"] as? [[String: Any]])
            XCTAssertTrue(phaseEvents.contains { $0["execution_phase"] as? String == "execution_started" })
            XCTAssertTrue(phaseEvents.contains { $0["execution_phase"] as? String == "execution_handler_completed" })

            let deliveryPayloads = try XCTUnwrap(snapshotPayload["delivery_events"] as? [[String: Any]])
            let joined = deliveryPayloads.filter { $0["app_invocation_id"] as? String == appInvocationID }
            let requiredEvents = try [
                XCTUnwrap(joined.first { $0["layer"] as? String == "app_tool_handler" && $0["phase"] as? String == "handler_result_ready" }),
                XCTUnwrap(joined.first { $0["layer"] as? String == "app_uds_transport" && $0["phase"] as? String == "sdk_encode_completed" }),
                XCTUnwrap(joined.first { $0["layer"] as? String == "app_uds_transport" && $0["phase"] as? String == "transport_write_completed" }),
                XCTUnwrap(joined.first { $0["layer"] as? String == "proxy_app_uds" && $0["phase"] as? String == "socket_write_completed" }),
                XCTUnwrap(joined.first { $0["layer"] as? String == "proxy_stdout" && $0["phase"] as? String == "stdout_write_completed" })
            ]
            for payload in requiredEvents {
                XCTAssertNil(payload["connection_id"])
                XCTAssertEqual(payload["correlation_connection_id"] as? String, correlationConnectionID)
                XCTAssertEqual(payload["app_invocation_id"] as? String, appInvocationID)
                XCTAssertEqual(payload["attribution_status"] as? String, "joined")
                XCTAssertEqual(payload["attribution_candidate_count"] as? Int, 1)
            }
        }

        func testAppCaptureCoordinatorRejectsDeliveryPublicationAfterFinishBoundary() async throws {
            let networkManager = ServerNetworkManager.shared
            let beginResult = await networkManager.handleDebugDiagnosticsTool(
                connectionID: UUID(),
                arguments: [
                    "op": .string("mcp_read_search_capture_begin"),
                    "label": .string("stale-delivery-admission")
                ]
            )
            XCTAssertEqual(try diagnosticsPayload(beginResult)["ok"] as? Bool, true)
            addTeardownBlock {
                _ = await networkManager.handleDebugDiagnosticsTool(
                    connectionID: UUID(),
                    arguments: [
                        "op": .string("mcp_read_search_capture_snapshot"),
                        "finish": .bool(true)
                    ]
                )
                MCPResponseDeliveryTracer.resetDebugEvents()
            }

            let publicationEntered = DispatchSemaphore(value: 0)
            let releasePublication = DispatchSemaphore(value: 0)
            MCPDiagnosticCaptureCoordinator.setTestWillEnterSink { operation in
                guard case .deliveryPublication = operation else { return }
                publicationEntered.signal()
                releasePublication.wait()
            }
            let invocationID = UUID().uuidString
            let event = MCPResponseDeliveryTraceEvent(
                layer: "app_uds_transport",
                phase: "transport_write_completed",
                connectionID: "stale-delivery-admission",
                connectionGeneration: 1,
                direction: .serverToClient,
                id: .number(73),
                invocationID: invocationID,
                requestOrdinal: 1,
                terminalReason: "injected-test-failure"
            )
            let emissionTask = Task.detached {
                MCPResponseDeliveryTracer.emit(event, to: -1)
            }
            addTeardownBlock {
                MCPDiagnosticCaptureCoordinator.setTestWillEnterSink(nil)
                releasePublication.signal()
                await emissionTask.value
            }

            guard publicationEntered.wait(timeout: .now() + 2) == .success else {
                XCTFail("Delivery publication did not reach the coordinator boundary")
                return
            }
            let finishedResult = await networkManager.handleDebugDiagnosticsTool(
                connectionID: UUID(),
                arguments: [
                    "op": .string("mcp_read_search_capture_snapshot"),
                    "finish": .bool(true)
                ]
            )
            let finishedPayload = try diagnosticsPayload(finishedResult)
            let finishedEvents = try XCTUnwrap(finishedPayload["delivery_events"] as? [[String: Any]])
            XCTAssertFalse(finishedEvents.contains {
                $0["raw_app_invocation_id"] as? String == invocationID
            })

            releasePublication.signal()
            await emissionTask.value
            MCPDiagnosticCaptureCoordinator.setTestWillEnterSink(nil)

            let afterReleaseResult = await networkManager.handleDebugDiagnosticsTool(
                connectionID: UUID(),
                arguments: [
                    "op": .string("mcp_read_search_capture_snapshot"),
                    "finish": .bool(true)
                ]
            )
            let afterReleasePayload = try diagnosticsPayload(afterReleaseResult)
            let afterReleaseEvents = try XCTUnwrap(afterReleasePayload["delivery_events"] as? [[String: Any]])
            XCTAssertEqual(afterReleaseEvents.count, finishedEvents.count)
            XCTAssertFalse(afterReleaseEvents.contains {
                $0["raw_app_invocation_id"] as? String == invocationID
            })
        }

        func testDeliveryTraceSerializationMatrixPreservesExactDebugContract() throws {
            func emptyPayload(
                for event: MCPResponseDeliveryTraceEvent,
                layer: String,
                phase: String
            ) -> [String: Any] {
                [
                    "layer": layer,
                    "phase": phase,
                    "connection_id": NSNull(),
                    "connection_id_omitted": false,
                    "connection_id_truncated": false,
                    "connection_id_utf8_byte_count": NSNull(),
                    "connection_generation": NSNull(),
                    "direction": NSNull(),
                    "jsonrpc_request_id": NSNull(),
                    "jsonrpc_request_id_omitted": false,
                    "jsonrpc_request_id_truncated": false,
                    "jsonrpc_request_id_utf8_byte_count": NSNull(),
                    "method": NSNull(),
                    "tool": NSNull(),
                    "app_invocation_id": NSNull(),
                    "app_invocation_id_omitted": false,
                    "app_invocation_id_truncated": false,
                    "app_invocation_id_utf8_byte_count": NSNull(),
                    "lifecycle_state": NSNull(),
                    "request_ordinal": NSNull(),
                    "framed_byte_count": NSNull(),
                    "framed_sha256": NSNull(),
                    "active_request_count": NSNull(),
                    "response_in_delivery_count": NSNull(),
                    "terminal_reason": NSNull(),
                    "provider_active": NSNull(),
                    "network_scope_active": NSNull(),
                    "permit_active": NSNull(),
                    "publication_pending": NSNull(),
                    "terminal_barrier": NSNull(),
                    "monotonic_uptime_ms": event.monotonicUptimeMS
                ]
            }

            func assertContract(
                _ event: MCPResponseDeliveryTraceEvent,
                expectedPayload: [String: Any],
                expectedDescription: String,
                file: StaticString = #filePath,
                line: UInt = #line
            ) throws {
                XCTAssertEqual(
                    try canonicalJSON(event.payload),
                    try canonicalJSON(expectedPayload),
                    file: file,
                    line: line
                )
                XCTAssertEqual(event.description, expectedDescription, file: file, line: line)
            }

            let absent = MCPResponseDeliveryTraceEvent(layer: "absent", phase: "none")
            try assertContract(
                absent,
                expectedPayload: emptyPayload(for: absent, layer: "absent", phase: "none"),
                expectedDescription: "layer=absent phase=none"
            )

            let acceptedConnectionID = String(repeating: "é", count: 64)
            let acceptedInvocationID = String(repeating: "界", count: 42) + "ab"
            XCTAssertEqual(acceptedConnectionID.utf8.count, 128)
            XCTAssertEqual(acceptedInvocationID.utf8.count, 128)
            let present = MCPResponseDeliveryTraceEvent(
                layer: "present",
                phase: "complete",
                connectionID: acceptedConnectionID,
                connectionGeneration: 7,
                direction: .serverToClient,
                id: .number(42),
                method: "tools/call",
                tool: "read_file",
                invocationID: acceptedInvocationID,
                lifecycleState: "responding",
                requestOrdinal: 9,
                framedByteCount: 100,
                framedSHA256: "abc123",
                activeRequestCount: 2,
                responseInDeliveryCount: 1,
                terminalReason: "done",
                requestIdentity: MCPRequestTimelineIdentity(
                    appInvocationID: "fallback-invocation"
                ),
                providerActive: true,
                networkScopeActive: false,
                permitActive: true,
                publicationPending: false,
                terminalBarrier: true
            )
            var presentPayload = emptyPayload(for: present, layer: "present", phase: "complete")
            presentPayload["connection_id"] = acceptedConnectionID
            presentPayload["connection_id_utf8_byte_count"] = 128
            presentPayload["connection_generation"] = 7
            presentPayload["direction"] = "server_to_client"
            presentPayload["jsonrpc_request_id"] = "number:42"
            presentPayload["method"] = "tools/call"
            presentPayload["tool"] = "read_file"
            presentPayload["app_invocation_id"] = acceptedInvocationID
            presentPayload["app_invocation_id_utf8_byte_count"] = 128
            presentPayload["lifecycle_state"] = "responding"
            presentPayload["request_ordinal"] = 9
            presentPayload["framed_byte_count"] = 100
            presentPayload["framed_sha256"] = "abc123"
            presentPayload["active_request_count"] = 2
            presentPayload["response_in_delivery_count"] = 1
            presentPayload["terminal_reason"] = "done"
            presentPayload["provider_active"] = true
            presentPayload["network_scope_active"] = false
            presentPayload["permit_active"] = true
            presentPayload["publication_pending"] = false
            presentPayload["terminal_barrier"] = true
            try assertContract(
                present,
                expectedPayload: presentPayload,
                expectedDescription: "layer=present phase=complete connection_id=\(acceptedConnectionID) generation=7 direction=server_to_client id=number:42 method=tools/call tool=read_file app_invocation_id=\(acceptedInvocationID) state=responding ordinal=9 bytes=100 sha256=abc123 active=2 in_delivery=1 terminal_reason=done provider_active=true network_scope_active=false permit_active=true publication_pending=false terminal_barrier=true"
            )

            let nullID = MCPResponseDeliveryTraceEvent(layer: "null", phase: "identity", id: .null)
            var nullPayload = emptyPayload(for: nullID, layer: "null", phase: "identity")
            nullPayload["jsonrpc_request_id"] = "null"
            try assertContract(
                nullID,
                expectedPayload: nullPayload,
                expectedDescription: "layer=null phase=identity id=null"
            )

            let acceptedRequestID = String(repeating: "é", count: 60)
            let acceptedID = MCPResponseDeliveryTraceEvent(
                layer: "accepted-id",
                phase: "identity",
                id: .string(acceptedRequestID)
            )
            var acceptedIDPayload = emptyPayload(for: acceptedID, layer: "accepted-id", phase: "identity")
            acceptedIDPayload["jsonrpc_request_id"] = "string:\(acceptedRequestID)"
            acceptedIDPayload["jsonrpc_request_id_utf8_byte_count"] = 120
            try assertContract(
                acceptedID,
                expectedPayload: acceptedIDPayload,
                expectedDescription: "layer=accepted-id phase=identity id=string:\(acceptedRequestID)"
            )

            let oversizedRequestID = String(repeating: "é", count: 65)
            let oversizedID = MCPResponseDeliveryTraceEvent(
                layer: "oversized-id",
                phase: "identity",
                id: .string(oversizedRequestID)
            )
            var oversizedIDPayload = emptyPayload(for: oversizedID, layer: "oversized-id", phase: "identity")
            oversizedIDPayload["jsonrpc_request_id_omitted"] = true
            oversizedIDPayload["jsonrpc_request_id_utf8_byte_count"] = 130
            try assertContract(
                oversizedID,
                expectedPayload: oversizedIDPayload,
                expectedDescription: "layer=oversized-id phase=identity id=<omitted> id_utf8_bytes=130"
            )

            let oversizedConnectionID = String(repeating: "é", count: 65)
            let oversizedConnection = MCPResponseDeliveryTraceEvent(
                layer: "oversized-connection",
                phase: "identity",
                connectionID: oversizedConnectionID
            )
            var oversizedConnectionPayload = emptyPayload(
                for: oversizedConnection,
                layer: "oversized-connection",
                phase: "identity"
            )
            oversizedConnectionPayload["connection_id_omitted"] = true
            oversizedConnectionPayload["connection_id_utf8_byte_count"] = 130
            try assertContract(
                oversizedConnection,
                expectedPayload: oversizedConnectionPayload,
                expectedDescription: "layer=oversized-connection phase=identity connection_id=<omitted> connection_id_utf8_bytes=130"
            )

            let oversizedInvocationID = String(repeating: "界", count: 43)
            let oversizedInvocation = MCPResponseDeliveryTraceEvent(
                layer: "oversized-invocation",
                phase: "identity",
                invocationID: oversizedInvocationID
            )
            var oversizedInvocationPayload = emptyPayload(
                for: oversizedInvocation,
                layer: "oversized-invocation",
                phase: "identity"
            )
            oversizedInvocationPayload["app_invocation_id_omitted"] = true
            oversizedInvocationPayload["app_invocation_id_utf8_byte_count"] = 129
            try assertContract(
                oversizedInvocation,
                expectedPayload: oversizedInvocationPayload,
                expectedDescription: "layer=oversized-invocation phase=identity app_invocation_id=<omitted> app_invocation_id_utf8_bytes=129"
            )

            let fallbackInvocation = MCPResponseDeliveryTraceEvent(
                layer: "fallback-invocation",
                phase: "identity",
                requestIdentity: MCPRequestTimelineIdentity(appInvocationID: "fallback-only")
            )
            var fallbackPayload = emptyPayload(
                for: fallbackInvocation,
                layer: "fallback-invocation",
                phase: "identity"
            )
            fallbackPayload["app_invocation_id"] = "fallback-only"
            fallbackPayload["app_invocation_id_utf8_byte_count"] = 13
            try assertContract(
                fallbackInvocation,
                expectedPayload: fallbackPayload,
                expectedDescription: "layer=fallback-invocation phase=identity app_invocation_id=fallback-only"
            )
        }

        func testCaptureRetainsSuccessfulDeliveryEventWithoutWritingStderr() async throws {
            let tracingDefaults = UserDefaults.standard
            let previousResponseTracing = tracingDefaults.bool(forKey: "enableMCPResponseDeliveryTrace")
            let previousPerformanceTracing = tracingDefaults.bool(forKey: "enableAgentModePerfDiagnostics")
            tracingDefaults.set(false, forKey: "enableMCPResponseDeliveryTrace")
            tracingDefaults.set(false, forKey: "enableAgentModePerfDiagnostics")
            defer {
                tracingDefaults.set(previousResponseTracing, forKey: "enableMCPResponseDeliveryTrace")
                tracingDefaults.set(previousPerformanceTracing, forKey: "enableAgentModePerfDiagnostics")
            }

            let networkManager = ServerNetworkManager.shared
            let beginResult = await networkManager.handleDebugDiagnosticsTool(
                connectionID: UUID(),
                arguments: [
                    "op": .string("mcp_read_search_capture_begin"),
                    "label": .string("capture-only-delivery")
                ]
            )
            XCTAssertEqual(try diagnosticsPayload(beginResult)["ok"] as? Bool, true)
            addTeardownBlock {
                _ = await networkManager.handleDebugDiagnosticsTool(
                    connectionID: UUID(),
                    arguments: [
                        "op": .string("mcp_read_search_capture_snapshot"),
                        "finish": .bool(true)
                    ]
                )
                MCPResponseDeliveryTracer.resetDebugEvents()
            }

            var descriptors = try makePipe()
            defer {
                closeDescriptor(&descriptors[0])
                closeDescriptor(&descriptors[1])
            }
            MCPResponseDeliveryTracer.emit(
                MCPResponseDeliveryTraceEvent(
                    layer: "capture_only",
                    phase: "transport_write_completed",
                    connectionID: "capture-only",
                    connectionGeneration: 1,
                    direction: .serverToClient,
                    id: .number(1),
                    invocationID: UUID().uuidString,
                    requestOrdinal: 1
                ),
                to: descriptors[1]
            )
            XCTAssertNoReadableBytes(descriptors[0])

            let snapshotResult = await networkManager.handleDebugDiagnosticsTool(
                connectionID: UUID(),
                arguments: [
                    "op": .string("mcp_read_search_capture_snapshot"),
                    "finish": .bool(true)
                ]
            )
            let snapshotPayload = try diagnosticsPayload(snapshotResult)
            let deliveryEvents = try XCTUnwrap(snapshotPayload["delivery_events"] as? [[String: Any]])
            XCTAssertEqual(deliveryEvents.count(where: { $0["layer"] as? String == "capture_only" }), 1)
        }

        func testDeliveryDiagnosticsBoundMultibyteIdentifiersThroughRawPayloadAndExport() async throws {
            let oversizedRequestID = String(repeating: "é", count: 65)
            let oversizedConnectionID = String(repeating: "界", count: 43)
            let oversizedInvocationID = String(repeating: "🧪", count: 33)
            XCTAssertEqual(oversizedRequestID.utf8.count, 130)
            XCTAssertEqual(oversizedConnectionID.utf8.count, 129)
            XCTAssertEqual(oversizedInvocationID.utf8.count, 132)

            let oversizedEvent = MCPResponseDeliveryTraceEvent(
                layer: "privacy_oversized",
                phase: "transport_write_completed",
                connectionID: oversizedConnectionID,
                connectionGeneration: 1,
                direction: .serverToClient,
                id: .string(oversizedRequestID),
                invocationID: oversizedInvocationID,
                requestOrdinal: 1,
                terminalReason: "injected-test-failure"
            )
            let rawDescription = oversizedEvent.description
            for rawValue in [oversizedRequestID, oversizedConnectionID, oversizedInvocationID] {
                XCTAssertFalse(rawDescription.contains(rawValue))
            }
            XCTAssertTrue(rawDescription.contains("connection_id=<omitted>"))
            XCTAssertTrue(rawDescription.contains("connection_id_utf8_bytes=129"))
            XCTAssertTrue(rawDescription.contains("id=<omitted>"))
            XCTAssertTrue(rawDescription.contains("id_utf8_bytes=130"))
            XCTAssertTrue(rawDescription.contains("app_invocation_id=<omitted>"))
            XCTAssertTrue(rawDescription.contains("app_invocation_id_utf8_bytes=132"))

            let genericPayload = oversizedEvent.payload
            assertOmittedDiagnosticIdentity(genericPayload, field: "connection_id", expectedUTF8ByteCount: 129)
            assertOmittedDiagnosticIdentity(genericPayload, field: "jsonrpc_request_id", expectedUTF8ByteCount: 130)
            assertOmittedDiagnosticIdentity(genericPayload, field: "app_invocation_id", expectedUTF8ByteCount: 132)

            let numericEvent = MCPResponseDeliveryTraceEvent(
                layer: "privacy_numeric",
                phase: "transport_write_completed",
                connectionID: "privacy-numeric",
                connectionGeneration: 1,
                direction: .serverToClient,
                id: .number(42),
                invocationID: UUID().uuidString,
                requestOrdinal: 2,
                terminalReason: "injected-test-failure"
            )
            let nullEvent = MCPResponseDeliveryTraceEvent(
                layer: "privacy_null",
                phase: "transport_write_completed",
                connectionID: "privacy-null",
                connectionGeneration: 1,
                direction: .serverToClient,
                id: .null,
                invocationID: UUID().uuidString,
                requestOrdinal: 3,
                terminalReason: "injected-test-failure"
            )

            let networkManager = ServerNetworkManager.shared
            let beginResult = await networkManager.handleDebugDiagnosticsTool(
                connectionID: UUID(),
                arguments: [
                    "op": .string("mcp_read_search_capture_begin"),
                    "label": .string("bounded-delivery-identities")
                ]
            )
            XCTAssertEqual(try diagnosticsPayload(beginResult)["ok"] as? Bool, true)
            addTeardownBlock {
                _ = await networkManager.handleDebugDiagnosticsTool(
                    connectionID: UUID(),
                    arguments: [
                        "op": .string("mcp_read_search_capture_snapshot"),
                        "finish": .bool(true)
                    ]
                )
                MCPResponseDeliveryTracer.resetDebugEvents()
            }

            MCPResponseDeliveryTracer.emit(oversizedEvent, to: -1)
            MCPResponseDeliveryTracer.emit(numericEvent, to: -1)
            MCPResponseDeliveryTracer.emit(nullEvent, to: -1)
            let snapshotResult = await networkManager.handleDebugDiagnosticsTool(
                connectionID: UUID(),
                arguments: [
                    "op": .string("mcp_read_search_capture_snapshot"),
                    "finish": .bool(true)
                ]
            )
            let snapshotPayload = try diagnosticsPayload(snapshotResult)
            let exportedJSON = try String(
                decoding: JSONSerialization.data(withJSONObject: snapshotPayload, options: [.sortedKeys]),
                as: UTF8.self
            )
            for rawValue in [oversizedRequestID, oversizedConnectionID, oversizedInvocationID] {
                XCTAssertFalse(exportedJSON.contains(rawValue))
            }

            let deliveryPayloads = try XCTUnwrap(snapshotPayload["delivery_events"] as? [[String: Any]])
            let oversizedExport = try XCTUnwrap(deliveryPayloads.first {
                $0["layer"] as? String == "privacy_oversized"
            })
            assertOmittedDiagnosticIdentity(
                oversizedExport,
                field: "correlation_connection_id",
                expectedUTF8ByteCount: 129
            )
            assertOmittedDiagnosticIdentity(
                oversizedExport,
                field: "jsonrpc_request_id",
                expectedUTF8ByteCount: 130
            )
            assertOmittedDiagnosticIdentity(
                oversizedExport,
                field: "raw_app_invocation_id",
                expectedUTF8ByteCount: 132
            )
            XCTAssertTrue(oversizedExport["app_invocation_id"] is NSNull)

            let numericExport = try XCTUnwrap(deliveryPayloads.first {
                $0["layer"] as? String == "privacy_numeric"
            })
            XCTAssertEqual(numericExport["jsonrpc_request_id"] as? String, "number:42")
            XCTAssertEqual(numericExport["jsonrpc_request_id_omitted"] as? Bool, false)
            XCTAssertEqual(numericExport["jsonrpc_request_id_truncated"] as? Bool, false)

            let nullExport = try XCTUnwrap(deliveryPayloads.first {
                $0["layer"] as? String == "privacy_null"
            })
            XCTAssertEqual(nullExport["jsonrpc_request_id"] as? String, "null")
            XCTAssertEqual(nullExport["jsonrpc_request_id_omitted"] as? Bool, false)
            XCTAssertEqual(nullExport["jsonrpc_request_id_truncated"] as? Bool, false)
        }

        func testDeliveryCaptureHookLookupContentionRecordsIncompleteCaptureWithoutBlocking() async throws {
            let networkManager = ServerNetworkManager.shared
            let beginResult = await networkManager.handleDebugDiagnosticsTool(
                connectionID: UUID(),
                arguments: [
                    "op": .string("mcp_read_search_capture_begin"),
                    "label": .string("hook-lookup-contention")
                ]
            )
            XCTAssertEqual(try diagnosticsPayload(beginResult)["ok"] as? Bool, true)
            addTeardownBlock {
                _ = await networkManager.handleDebugDiagnosticsTool(
                    connectionID: UUID(),
                    arguments: [
                        "op": .string("mcp_read_search_capture_snapshot"),
                        "finish": .bool(true)
                    ]
                )
                MCPResponseDeliveryTracer.resetDebugEvents()
            }

            let replacementHookInvoked = DispatchSemaphore(value: 0)
            let replacementHooks = MCPResponseDeliveryCaptureHooks(
                isActive: {
                    replacementHookInvoked.signal()
                    return true
                },
                tryWithBoundary: { body in body() },
                recordLoss: { _ in }
            )
            let emissionCompleted = DispatchSemaphore(value: 0)
            var emissionTask: Task<Void, Never>?
            MCPResponseDeliveryCapturePublication.withInstalledHooksForTesting(replacementHooks) {
                emissionTask = Task.detached {
                    MCPResponseDeliveryTracer.emit(
                        MCPResponseDeliveryTraceEvent(
                            layer: "hook-lookup-contention",
                            phase: "transport_write_completed",
                            connectionID: "contention",
                            connectionGeneration: 1,
                            direction: .serverToClient,
                            id: .number(1),
                            invocationID: UUID().uuidString,
                            requestOrdinal: 1,
                            terminalReason: "injected-test-failure"
                        ),
                        to: -1
                    )
                    emissionCompleted.signal()
                }
                XCTAssertEqual(emissionCompleted.wait(timeout: .now() + 2), .success)
                XCTAssertEqual(replacementHookInvoked.wait(timeout: .now()), .timedOut)
            }
            await emissionTask?.value

            let snapshotResult = await networkManager.handleDebugDiagnosticsTool(
                connectionID: UUID(),
                arguments: [
                    "op": .string("mcp_read_search_capture_snapshot"),
                    "finish": .bool(true)
                ]
            )
            let snapshotPayload = try diagnosticsPayload(snapshotResult)
            let losses = try XCTUnwrap(snapshotPayload["delivery_event_losses"] as? [String: Any])
            XCTAssertEqual(losses["coordinator_boundary_contention"] as? Int, 1)
            XCTAssertEqual(snapshotPayload["incomplete_capture"] as? Bool, true)
        }

        func testHookLookupContentionBeginningBeforeFinishIsRetainedByFinishingCapture() async {
            _ = MCPDiagnosticCaptureCoordinator.finishCapture()
            MCPDiagnosticCaptureCoordinator.beginCapture()

            let lookupLockFailed = DispatchSemaphore(value: 0)
            let releaseLookup = DispatchSemaphore(value: 0)
            let captureDeactivated = DispatchSemaphore(value: 0)
            MCPResponseDeliveryCapturePublication.setTestEventSink { event in
                switch event {
                case .hookLookupLockFailed:
                    lookupLockFailed.signal()
                    releaseLookup.wait()
                case .captureDeactivated:
                    captureDeactivated.signal()
                }
            }
            defer {
                releaseLookup.signal()
                MCPResponseDeliveryCapturePublication.setTestEventSink(nil)
                _ = MCPDiagnosticCaptureCoordinator.finishCapture()
                MCPResponseDeliveryTracer.resetDebugEvents()
            }

            let replacementHookInvoked = DispatchSemaphore(value: 0)
            let replacementHooks = MCPResponseDeliveryCaptureHooks(
                isActive: {
                    replacementHookInvoked.signal()
                    return true
                },
                tryWithBoundary: { body in body() },
                recordLoss: { _ in }
            )
            let emissionCompleted = DispatchSemaphore(value: 0)
            var emissionTask: Task<Void, Never>?
            var finishTask: Task<MCPDiagnosticCaptureLossSnapshot, Never>?
            MCPResponseDeliveryCapturePublication.withInstalledHooksForTesting(replacementHooks) {
                emissionTask = Task.detached {
                    MCPResponseDeliveryTracer.emit(
                        MCPResponseDeliveryTraceEvent(
                            layer: "hook-lookup-finish-race",
                            phase: "transport_write_completed",
                            terminalReason: "injected-test-failure"
                        ),
                        to: -1
                    )
                    emissionCompleted.signal()
                }
                XCTAssertEqual(lookupLockFailed.wait(timeout: .now() + 2), .success)

                finishTask = Task.detached {
                    MCPDiagnosticCaptureCoordinator.finishCapture()
                }
                XCTAssertEqual(captureDeactivated.wait(timeout: .now() + 2), .success)
                releaseLookup.signal()
                XCTAssertEqual(emissionCompleted.wait(timeout: .now() + 2), .success)
            }
            await emissionTask?.value
            let losses = await finishTask?.value

            XCTAssertEqual(replacementHookInvoked.wait(timeout: .now()), .timedOut)
            XCTAssertEqual(losses?.coordinatorBoundaryContention, 1)
            XCTAssertEqual(losses?.incompleteCapture, true)
        }

        func testDeliveryAttributionConflictCasesFailClosedAndPreserveRawIDs() {
            let firstCanonicalID = "00000000-0000-0000-0000-000000000001"
            let secondCanonicalID = "00000000-0000-0000-0000-000000000002"
            let transportID = "00000000-0000-0000-0000-000000000003"
            let cases: [(
                label: String,
                handlerIDs: [String],
                transportID: String,
                expectedStatus: String,
                expectedCandidateCount: Int
            )] = [
                (
                    label: "canonical candidates conflict",
                    handlerIDs: [firstCanonicalID, secondCanonicalID],
                    transportID: transportID,
                    expectedStatus: "ambiguous",
                    expectedCandidateCount: 2
                ),
                (
                    label: "canonical and malformed candidates conflict",
                    handlerIDs: [firstCanonicalID, "malformed-handler-id"],
                    transportID: transportID,
                    expectedStatus: "ambiguous",
                    expectedCandidateCount: 2
                ),
                (
                    label: "malformed-only candidate is unsupported",
                    handlerIDs: ["not-a-uuid"],
                    transportID: transportID,
                    expectedStatus: "unsupported",
                    expectedCandidateCount: 1
                )
            ]

            for testCase in cases {
                XCTContext.runActivity(named: testCase.label) { _ in
                    let handlerEvents = testCase.handlerIDs.map { invocationID in
                        MCPResponseDeliveryTraceEvent(
                            layer: "app_tool_handler",
                            phase: "handler_result_ready",
                            connectionID: "attribution-conflict",
                            connectionGeneration: 2,
                            id: .number(17),
                            invocationID: invocationID,
                            requestOrdinal: 1
                        )
                    }
                    let transportEvent = MCPResponseDeliveryTraceEvent(
                        layer: "proxy_stdout",
                        phase: "stdout_write_completed",
                        connectionID: "attribution-conflict",
                        connectionGeneration: 1,
                        id: .number(17),
                        invocationID: testCase.transportID,
                        requestOrdinal: 1
                    )
                    let expectedRawIDs = testCase.handlerIDs + [testCase.transportID]
                    let payloads = ServerNetworkManager.debugPhaseAttributionDeliveryPayloads(
                        handlerEvents + [transportEvent]
                    )

                    XCTAssertEqual(payloads.count, expectedRawIDs.count)
                    XCTAssertEqual(
                        payloads.map { $0["attribution_status"] as? String },
                        Array(repeating: testCase.expectedStatus, count: expectedRawIDs.count)
                    )
                    XCTAssertEqual(
                        payloads.map { $0["attribution_candidate_count"] as? Int },
                        Array(repeating: testCase.expectedCandidateCount, count: expectedRawIDs.count)
                    )
                    XCTAssertEqual(
                        payloads.map { $0["attribution_candidate_count_truncated"] as? Bool },
                        Array(repeating: false, count: expectedRawIDs.count)
                    )
                    for (payload, rawID) in zip(payloads, expectedRawIDs) {
                        XCTAssertEqual(payload["raw_app_invocation_id"] as? String, rawID)
                        XCTAssertEqual(payload["app_invocation_id"] as? String, rawID)
                    }
                }
            }
        }
    #endif

    #if !DEBUG
        func testReleaseDeliveryTraceSerializationPreservesExactContract() throws {
            let rawConnectionID = String(repeating: "é", count: 65)
            let rawRequestID = String(repeating: "界", count: 44)
            let requestIdentity = MCPRequestTimelineIdentity(appInvocationID: "identity-invocation")
            let present = MCPResponseDeliveryTraceEvent(
                layer: "release-present",
                phase: "complete",
                connectionID: rawConnectionID,
                connectionGeneration: 7,
                direction: .clientToServer,
                id: .string(rawRequestID),
                method: "tools/call",
                tool: "read_file",
                invocationID: "direct-invocation",
                lifecycleState: "responding",
                requestOrdinal: 9,
                framedByteCount: 100,
                framedSHA256: "release-sha",
                activeRequestCount: 2,
                responseInDeliveryCount: 1,
                terminalReason: "done",
                requestIdentity: requestIdentity,
                providerActive: true,
                networkScopeActive: false,
                permitActive: true,
                publicationPending: false,
                terminalBarrier: true
            )
            let expectedPresentPayload: [String: Any] = [
                "layer": "release-present",
                "phase": "complete",
                "connection_id": rawConnectionID,
                "connection_generation": 7,
                "direction": "client_to_server",
                "jsonrpc_request_id": "string:\(rawRequestID)",
                "method": "tools/call",
                "tool": "read_file",
                "app_invocation_id": "identity-invocation",
                "lifecycle_state": "responding",
                "request_ordinal": 9,
                "framed_byte_count": 100,
                "active_request_count": 2,
                "response_in_delivery_count": 1,
                "terminal_reason": "done",
                "provider_active": true,
                "network_scope_active": false,
                "permit_active": true,
                "publication_pending": false,
                "terminal_barrier": true
            ]
            XCTAssertEqual(try canonicalJSON(present.payload), try canonicalJSON(expectedPresentPayload))
            XCTAssertFalse(present.payload.keys.contains("framed_sha256"))
            XCTAssertEqual(
                present.description,
                "layer=release-present phase=complete connection_id=\(rawConnectionID) generation=7 direction=client_to_server id=string:\(rawRequestID) method=tools/call tool=read_file invocation_id=direct-invocation state=responding ordinal=9 bytes=100 sha256=release-sha active=2 in_delivery=1 terminal_reason=done provider_active=true network_scope_active=false permit_active=true publication_pending=false terminal_barrier=true"
            )

            let fallback = MCPResponseDeliveryTraceEvent(
                layer: "release-fallback",
                phase: "identity",
                framedSHA256: "release-sha",
                requestIdentity: MCPRequestTimelineIdentity(appInvocationID: "fallback-only")
            )
            let expectedFallbackPayload: [String: Any] = [
                "layer": "release-fallback",
                "phase": "identity",
                "connection_id": NSNull(),
                "connection_generation": NSNull(),
                "direction": NSNull(),
                "jsonrpc_request_id": NSNull(),
                "method": NSNull(),
                "tool": NSNull(),
                "app_invocation_id": "fallback-only",
                "lifecycle_state": NSNull(),
                "request_ordinal": NSNull(),
                "framed_byte_count": NSNull(),
                "active_request_count": NSNull(),
                "response_in_delivery_count": NSNull(),
                "terminal_reason": NSNull(),
                "provider_active": NSNull(),
                "network_scope_active": NSNull(),
                "permit_active": NSNull(),
                "publication_pending": NSNull(),
                "terminal_barrier": NSNull()
            ]
            XCTAssertEqual(try canonicalJSON(fallback.payload), try canonicalJSON(expectedFallbackPayload))
            XCTAssertFalse(fallback.payload.keys.contains("framed_sha256"))
            XCTAssertEqual(
                fallback.description,
                "layer=release-fallback phase=identity sha256=release-sha app_invocation_id=fallback-only"
            )
        }
    #endif

    func testBoundedLineReaderReturnsCappedFirstFrameAndPreservesReadAhead() throws {
        var descriptors = try makePipe()
        defer {
            closeDescriptor(&descriptors[0])
            closeDescriptor(&descriptors[1])
        }

        let firstPayload = Data(repeating: 0x78, count: 4096)
        let firstFrame = firstPayload + Data([0x0A])
        let secondFrame = Data("second\n".utf8)
        try writeAll(firstFrame + secondFrame, to: descriptors[1])

        let reader = BoundedLineReader(descriptor: descriptors[0])
        XCTAssertEqual(try reader.readLine(maximumBytes: firstFrame.count), firstFrame)
        XCTAssertGreaterThanOrEqual(reader.readOperationCount, 2)
        let readOperationCount = reader.readOperationCount
        XCTAssertEqual(try reader.readLine(maximumBytes: secondFrame.count), secondFrame)
        XCTAssertEqual(reader.readOperationCount, readOperationCount)
    }

    func testBoundedLineReaderRejectsEOFOverrunAndMissingNewline() throws {
        var eofPipe = try makePipe()
        defer {
            closeDescriptor(&eofPipe[0])
            closeDescriptor(&eofPipe[1])
        }
        try writeAll(Data("unterminated".utf8), to: eofPipe[1])
        closeDescriptor(&eofPipe[1])
        XCTAssertThrowsError(try BoundedLineReader(descriptor: eofPipe[0]).readLine()) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .ENODATA)
        }

        var oversizedPipe = try makePipe()
        defer {
            closeDescriptor(&oversizedPipe[0])
            closeDescriptor(&oversizedPipe[1])
        }
        try writeAll(Data("123456789".utf8), to: oversizedPipe[1])
        XCTAssertThrowsError(
            try BoundedLineReader(descriptor: oversizedPipe[0]).readLine(maximumBytes: 8)
        ) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EMSGSIZE)
        }

        var deadlinePipe = try makePipe()
        defer {
            closeDescriptor(&deadlinePipe[0])
            closeDescriptor(&deadlinePipe[1])
        }
        XCTAssertThrowsError(
            try BoundedLineReader(descriptor: deadlinePipe[0]).readLine(timeoutMilliseconds: 0)
        ) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .ETIMEDOUT)
        }
    }

    func testInjectedTerminalBridgeWriteFailurePublishesNoLateResponse() async throws {
        let tracingDefaults = UserDefaults.standard
        let previousTracing = tracingDefaults.bool(forKey: "enableMCPResponseDeliveryTrace")
        tracingDefaults.set(true, forKey: "enableMCPResponseDeliveryTrace")
        MCPResponseDeliveryTracer.resetDebugEvents()
        let networkManager = ServerNetworkManager.shared
        addTeardownBlock {
            _ = await networkManager.handleDebugDiagnosticsTool(
                connectionID: UUID(),
                arguments: [
                    "op": .string("mcp_read_search_capture_snapshot"),
                    "finish": .bool(true)
                ]
            )
            UserDefaults.standard.set(previousTracing, forKey: "enableMCPResponseDeliveryTrace")
            MCPResponseDeliveryTracer.resetDebugEvents()
        }

        let beginResult = await networkManager.handleDebugDiagnosticsTool(
            connectionID: UUID(),
            arguments: [
                "op": .string("mcp_read_search_capture_begin"),
                "label": .string("same-process-terminal-write-failure")
            ]
        )
        XCTAssertEqual(try diagnosticsPayload(beginResult)["ok"] as? Bool, true)

        var socketDescriptors = try makeSocketPair()
        var stdinDescriptors = try makePipe()
        var stdoutDescriptors = try makePipe()
        defer {
            closeDescriptor(&socketDescriptors[0])
            closeDescriptor(&socketDescriptors[1])
            closeDescriptor(&stdinDescriptors[0])
            closeDescriptor(&stdinDescriptors[1])
            closeDescriptor(&stdoutDescriptors[0])
            closeDescriptor(&stdoutDescriptors[1])
        }

        let connectionID = UUID()
        let correlationConnectionID = "phase-history-failure-\(UUID().uuidString)"
        let transport = try UnixSocketMCPTransport(
            connectedFD: socketDescriptors[0],
            connectionID: connectionID,
            correlationConnectionID: correlationConnectionID,
            connectionGeneration: 1
        )
        socketDescriptors[0] = -1
        try await transport.connect()
        let request = line(#"{"jsonrpc":"2.0","id":42,"method":"tools/call","params":{"name":"read_file","arguments":{}}}"#)
        _ = MCPRequestTimelineRegistry.shared.recordAcceptedFrame(
            request,
            connectionID: connectionID.uuidString,
            correlationConnectionID: correlationConnectionID,
            connectionGeneration: 1
        )
        let identity = try XCTUnwrap(MCPRequestTimelineRegistry.shared.claimToolRequest(
            connectionID: connectionID.uuidString,
            originalToolName: "read_file"
        ))

        let ledger = JSONRPCBridgeLedger(connectionID: correlationConnectionID)
        _ = try await ledger.beginConnection()
        let preparedRequest = try await ledger.prepare(frame: request, direction: .clientToServer)
        try await ledger.commit(preparedRequest)
        let proxySocketFD = socketDescriptors[1]
        socketDescriptors[1] = -1
        let bridgeStdinFD = stdinDescriptors[0]
        stdinDescriptors[0] = -1
        let bridgeStdoutFD = stdoutDescriptors[1]
        stdoutDescriptors[1] = -1
        let bridgeTask = Task {
            try await BootstrapSocketProxy.runBridge(
                socketFD: proxySocketFD,
                stdinFD: bridgeStdinFD,
                stdoutFD: bridgeStdoutFD,
                identityCache: ClientIdentityCache(),
                bridgeLedger: ledger,
                faultRule: JSONRPCBridgeFaultRule(
                    direction: .serverToClient,
                    id: .number(42)
                ),
                drainLogDescriptor: STDERR_FILENO
            )
        }
        addTeardownBlock {
            bridgeTask.cancel()
            _ = Darwin.shutdown(proxySocketFD, SHUT_RDWR)
            Darwin.close(bridgeStdinFD)
            Darwin.close(bridgeStdoutFD)
            _ = try? await bridgeTask.value
            Darwin.close(proxySocketFD)
        }
        let invocationID = try XCTUnwrap(identity.appInvocationID)
        MCPResponseDeliveryTracer.emit(MCPResponseDeliveryTraceEvent(
            layer: "app_tool_handler",
            phase: "handler_result_ready",
            connectionID: identity.connectionID,
            connectionGeneration: identity.connectionGeneration,
            method: "tools/call",
            tool: "read_file",
            invocationID: invocationID,
            requestOrdinal: identity.requestOrdinal,
            requestIdentity: identity
        ))

        let response = line(#"{"jsonrpc":"2.0","id":42,"result":{"content":[]}}"#)
        try await transport.send(response)
        do {
            try await bridgeTask.value
            XCTFail("Expected the injected server-to-client destination write failure")
        } catch {
            XCTAssertEqual(
                error as? JSONRPCBridgeLedgerError,
                .injectedFault(.serverToClient, .number(42))
            )
        }
        XCTAssertNoReadableBytes(stdoutDescriptors[0])
        let snapshotResult = await networkManager.handleDebugDiagnosticsTool(
            connectionID: connectionID,
            arguments: [
                "op": .string("mcp_read_search_capture_snapshot"),
                "finish": .bool(true)
            ]
        )
        let snapshotPayload = try diagnosticsPayload(snapshotResult)
        XCTAssertEqual(snapshotPayload["ok"] as? Bool, true)
        let deliveryPayloads = try XCTUnwrap(snapshotPayload["delivery_events"] as? [[String: Any]])
        let canonicalInvocationID = try XCTUnwrap(UUID(uuidString: invocationID)?.uuidString)
        let transportCompleted = try XCTUnwrap(deliveryPayloads.first {
            $0["correlation_connection_id"] as? String == correlationConnectionID &&
                $0["raw_app_invocation_id"] as? String == invocationID &&
                $0["jsonrpc_request_id"] as? String == "number:42" &&
                $0["layer"] as? String == "app_uds_transport" &&
                $0["phase"] as? String == "transport_write_completed"
        })
        XCTAssertEqual(transportCompleted["raw_app_invocation_id_omitted"] as? Bool, false)
        XCTAssertEqual(transportCompleted["app_invocation_id"] as? String, canonicalInvocationID)
        XCTAssertEqual(transportCompleted["attribution_status"] as? String, "joined")
        XCTAssertEqual(transportCompleted["attribution_candidate_count"] as? Int, 1)
        XCTAssertEqual(transportCompleted["attribution_candidate_count_truncated"] as? Bool, false)
        XCTAssertFalse(deliveryPayloads.contains {
            $0["correlation_connection_id"] as? String == correlationConnectionID &&
                $0["jsonrpc_request_id"] as? String == "number:42" &&
                $0["layer"] as? String == "proxy_stdout" &&
                $0["phase"] as? String == "stdout_write_completed"
        })

        closeDescriptor(&stdinDescriptors[1])
        await transport.disconnect()
    }

    func testInitializeReplayStateReportsUnsupportedResumeReasons() async throws {
        let replayState = MCPInitializeReplayState()
        let initialPlan = await replayState.replayPlan()
        XCTAssertEqual(initialPlan, .failure(.missingInitializeFrame))

        let initializeFrame = line(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"resume-test"}}}"#)
        await replayState.recordForwardedClientFrame(initializeFrame)
        let pendingResponse = try await replayState.replayPlan().get()
        XCTAssertTrue(pendingResponse.shouldForwardInitializeResponseToHost)
        XCTAssertNil(pendingResponse.initializeResultFingerprint)

        await replayState.recordDeliveredServerFrame(line(#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25"}}"#))
        let missingInitialized = try await replayState.replayPlan().get()
        XCTAssertFalse(missingInitialized.shouldForwardInitializeResponseToHost)
        XCTAssertNotNil(missingInitialized.initializeResultFingerprint)
        XCTAssertNil(missingInitialized.initializedFrame)

        let initializedFrame = line(#"{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}"#)
        await replayState.recordForwardedClientFrame(initializedFrame)
        let plan = try await replayState.replayPlan().get()
        XCTAssertEqual(plan.initializeFrame, initializeFrame)
        XCTAssertEqual(plan.initializeRequestID, .number(1))
        XCTAssertEqual(plan.initializedFrame, initializedFrame)
        XCTAssertFalse(plan.shouldForwardInitializeResponseToHost)
    }

    private func canonicalJSON(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func makeSocketPair() throws -> [Int32] {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENFILE)
        }
        return descriptors
    }

    private func makePipe() throws -> [Int32] {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard Darwin.pipe(&descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENFILE)
        }
        return descriptors
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { bytes in
                Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    data.count - offset
                )
            }
            guard written > 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            offset += written
        }
    }

    private final class BoundedLineReader {
        private let descriptor: Int32
        private var buffered = Data()
        private(set) var readOperationCount = 0

        init(descriptor: Int32) {
            self.descriptor = descriptor
        }

        func readLine(maximumBytes: Int = 1_048_576, timeoutMilliseconds: UInt64 = 5000) throws -> Data {
            let now = DispatchTime.now().uptimeNanoseconds
            let timeoutNanoseconds = timeoutMilliseconds.multipliedReportingOverflow(by: 1_000_000)
            guard !timeoutNanoseconds.overflow,
                  now <= UInt64.max - timeoutNanoseconds.partialValue
            else { throw POSIXError(.EINVAL) }
            let deadline = now + timeoutNanoseconds.partialValue

            while true {
                if let newline = buffered.firstIndex(of: 0x0A) {
                    let frameEnd = buffered.index(after: newline)
                    let frameByteCount = buffered.distance(from: buffered.startIndex, to: frameEnd)
                    guard frameByteCount <= maximumBytes else { throw POSIXError(.EMSGSIZE) }
                    let line = Data(buffered[buffered.startIndex ..< frameEnd])
                    buffered.removeSubrange(buffered.startIndex ..< frameEnd)
                    return line
                }
                guard buffered.count < maximumBytes else { throw POSIXError(.EMSGSIZE) }

                let current = DispatchTime.now().uptimeNanoseconds
                guard current < deadline else { throw POSIXError(.ETIMEDOUT) }
                let remainingMilliseconds = max(1, (deadline - current + 999_999) / 1_000_000)
                var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let pollResult = Darwin.poll(
                    &pollDescriptor,
                    1,
                    Int32(min(remainingMilliseconds, UInt64(Int32.max)))
                )
                if pollResult < 0, errno == EINTR { continue }
                guard pollResult > 0 else {
                    throw pollResult == 0
                        ? POSIXError(.ETIMEDOUT)
                        : POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }

                var chunk = [UInt8](repeating: 0, count: 4096)
                let count = Darwin.read(descriptor, &chunk, chunk.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw count == 0
                        ? POSIXError(.ENODATA)
                        : POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                readOperationCount += 1
                buffered.append(contentsOf: chunk.prefix(count))
            }
        }
    }

    private func XCTAssertNoReadableBytes(
        _ descriptor: Int32,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let flags = fcntl(descriptor, F_GETFL)
        XCTAssertGreaterThanOrEqual(flags, 0, file: file, line: line)
        XCTAssertEqual(fcntl(descriptor, F_SETFL, flags | O_NONBLOCK), 0, file: file, line: line)
        var byte: UInt8 = 0
        let count = Darwin.read(descriptor, &byte, 1)
        XCTAssertEqual(count, -1, file: file, line: line)
        XCTAssertTrue(errno == EAGAIN || errno == EWOULDBLOCK, file: file, line: line)
    }

    private func closeDescriptor(_ descriptor: inout Int32) {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }

    private func assertJSONRPCResponse(
        _ data: Data,
        id: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            file: file,
            line: line
        )
        XCTAssertEqual(object["id"] as? Int, id, file: file, line: line)
        XCTAssertNil(object["error"], file: file, line: line)
    }

    private func diagnosticsPayload(_ result: CallTool.Result) throws -> [String: Any] {
        let text = try XCTUnwrap(result.content.compactMap { content -> String? in
            if case let .text(text, _, _) = content { return text }
            return nil
        }.first)
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func assertOmittedDiagnosticIdentity(
        _ payload: [String: Any],
        field: String,
        expectedUTF8ByteCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(payload[field] is NSNull, file: file, line: line)
        XCTAssertEqual(payload["\(field)_omitted"] as? Bool, true, file: file, line: line)
        XCTAssertEqual(payload["\(field)_truncated"] as? Bool, false, file: file, line: line)
        XCTAssertEqual(
            payload["\(field)_utf8_byte_count"] as? Int,
            expectedUTF8ByteCount,
            file: file,
            line: line
        )
    }

    private func assertJSONLineEqual(
        _ actual: Data,
        _ expected: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            let actualObject = try JSONSerialization.jsonObject(with: actual) as? NSDictionary
            let expectedObject = try JSONSerialization.jsonObject(with: expected) as? NSDictionary
            XCTAssertEqual(actualObject, expectedObject, file: file, line: line)
        } catch {
            XCTFail("Expected valid JSON lines: \(error)", file: file, line: line)
        }
    }

    private func line(_ string: String) -> Data {
        Data((string + "\n").utf8)
    }
}
