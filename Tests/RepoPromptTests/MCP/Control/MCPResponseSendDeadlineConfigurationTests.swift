import Darwin
import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptShared
import XCTest

@MainActor
final class MCPResponseSendDeadlineConfigurationTests: XCTestCase {
    func testCEPinsReviewedSwiftSDKResponseDeliveryCommit() throws {
        let root = try RepoRoot.url()
        let manifest = try String(
            contentsOf: root.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(manifest.contains(
            #"revision: "85dec2fc7a27252bc33dc7728be6af6b3bd398c0""#
        ))

        let resolvedData = try Data(contentsOf: root.appendingPathComponent("Package.resolved"))
        let resolved = try XCTUnwrap(JSONSerialization.jsonObject(with: resolvedData) as? [String: Any])
        let pins = try XCTUnwrap(resolved["pins"] as? [[String: Any]])
        let sdk = try XCTUnwrap(pins.first { $0["identity"] as? String == "swift-sdk" })
        let state = try XCTUnwrap(sdk["state"] as? [String: Any])
        XCTAssertEqual(
            state["revision"] as? String,
            "85dec2fc7a27252bc33dc7728be6af6b3bd398c0"
        )
        XCTAssertNil(state["branch"])
    }

    func testBootstrapServerAndTransportsUseCentralResponseDeliveryPolicy() throws {
        XCTAssertEqual(MCPTimeoutPolicy.responseSendDeadlineSeconds, 30)
        XCTAssertEqual(MCPTimeoutPolicy.transportWriteStallTimeoutSeconds, 30)
        XCTAssertEqual(
            MCPTimeoutPolicy.responseSendDeadlineSeconds,
            MCPTimeoutPolicy.boundedToolExecutionDeadlineSeconds
        )
        XCTAssertEqual(
            MCPTimeoutPolicy.transportWriteStallTimeoutSeconds,
            TimeInterval(MCPTimeoutPolicy.responseSendDeadlineSeconds)
        )

        let root = try RepoRoot.url()
        let server = try source(
            root: root,
            path: "Sources/RepoPrompt/Infrastructure/MCP/BootstrapSocketConnectionManager.swift"
        )
        XCTAssertTrue(server.contains("responseSendTimeout: MCPTimeoutPolicy.responseSendDeadline"))

        let appTransport = try source(
            root: root,
            path: "Sources/RepoPrompt/Infrastructure/MCP/UnixSocketMCPTransport.swift"
        )
        XCTAssertTrue(appTransport.contains(
            "writeStallTimeout: TimeInterval = MCPTimeoutPolicy.transportWriteStallTimeoutSeconds"
        ))
        XCTAssertTrue(appTransport.contains(
            "firstCloseSnapshot?.cause.rawValue ?? \"app_uds_send_failed\""
        ))

        let cliTransport = try source(
            root: root,
            path: "Sources/RepoPromptMCP/Transports/BootstrapSocketMCPTransport.swift"
        )
        XCTAssertTrue(cliTransport.contains(
            "writeStallTimeout: TimeInterval = MCPTimeoutPolicy.transportWriteStallTimeoutSeconds"
        ))

        let cliWriter = try source(
            root: root,
            path: "Sources/RepoPromptMCP/Transports/NonBlockingFDWriter.swift"
        )
        XCTAssertTrue(cliWriter.contains(
            "stallTimeout: TimeInterval = MCPTimeoutPolicy.transportWriteStallTimeoutSeconds"
        ))
    }

    func testExportTraceCorrelatesProviderFormattingPublicationAndTransportWrite() async throws {
        #if DEBUG
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(
                    lease: lease,
                    domainRuntime: AppDomainRuntimeComposition.shared.runtime
                )
                let manager = fixture.networkManager
                let endpoint = try fixture.endpointA()
                let executionRecorder = MCPExecutionTraceRecorder()
                let traceDefaults = UserDefaults.standard
                let traceKey = "enableMCPResponseDeliveryTrace"
                let priorTraceValue = traceDefaults.object(forKey: traceKey)
                try await Self.prepareProtectedExportFixture(fixture, endpoint: endpoint)
                traceDefaults.set(true, forKey: traceKey)
                MCPResponseDeliveryTracer.resetDebugEvents()
                MCPToolExecutionTracer.setTestSink { executionRecorder.append($0) }
                await manager.debugSetResolvedToolOperationOverride(toolName: "workspace_context") {
                    .object(["ok": .bool(true)])
                }

                do {
                    _ = try await endpoint.callTool(
                        name: "workspace_context",
                        arguments: [
                            "op": "export",
                            "path": fixture.contextA.rootURL
                                .appendingPathComponent("export-trace-content-sentinel")
                                .path,
                            "operation_id": "export-trace-correlation-\(UUID().uuidString)",
                            "_rawJSON": true
                        ]
                    )

                    let executionEvents = executionRecorder.snapshot().filter {
                        $0.toolName == "workspace_context"
                    }
                    let provider = try XCTUnwrap(executionEvents.first { $0.phase == .handlerCompleted })
                    let requestIdentity = try XCTUnwrap(provider.requestIdentity)
                    XCTAssertEqual(
                        requestIdentity.appInvocationID.flatMap(UUID.init(uuidString:)),
                        provider.invocationID
                    )
                    XCTAssertNotNil(requestIdentity.connectionID)

                    let phaseEvents = executionEvents.filter { $0.phase == .handlerPhaseTransition }
                    XCTAssertEqual(
                        phaseEvents.map { $0.handlerPhase?.phase },
                        [
                            .promptExportFormatting,
                            .promptExportFormatting,
                            .promptExportPublication,
                            .promptExportPublication
                        ]
                    )
                    XCTAssertEqual(
                        phaseEvents.map { $0.handlerPhase?.transition },
                        [.started, .completed, .started, .completed]
                    )
                    XCTAssertTrue(phaseEvents.allSatisfy {
                        $0.invocationID == provider.invocationID
                            && $0.requestIdentity == requestIdentity
                            && $0.toolName == "workspace_context"
                    })
                    XCTAssertFalse(phaseEvents.contains {
                        $0.description.contains("export-trace-content-sentinel")
                    })

                    let deliveryEvents = MCPResponseDeliveryTracer.debugEventSnapshot()
                    for phase in [
                        "handler_result_ready",
                        "sdk_encode_completed",
                        "transport_write_started",
                        "transport_write_completed"
                    ] {
                        let event = try XCTUnwrap(deliveryEvents.first {
                            $0.phase == phase
                                && $0.requestIdentity?.jsonRPCRequestID == requestIdentity.jsonRPCRequestID
                                && $0.requestIdentity?.connectionID == requestIdentity.connectionID
                                && $0.requestIdentity?.requestOrdinal == requestIdentity.requestOrdinal
                        })
                        XCTAssertEqual(
                            event.requestIdentity?.appInvocationID.flatMap(UUID.init(uuidString:)),
                            provider.invocationID
                        )
                        if phase == "handler_result_ready" {
                            XCTAssertEqual(event.tool, "workspace_context")
                        }
                    }

                    MCPToolExecutionTracer.setTestSink(nil)
                    MCPResponseDeliveryTracer.resetDebugEvents()
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: "workspace_context",
                        operation: nil
                    )
                    await manager.debugSetDomainPeerIdentityForTesting(
                        connectionID: endpoint.connectionID,
                        identity: nil
                    )
                    if let priorTraceValue {
                        traceDefaults.set(priorTraceValue, forKey: traceKey)
                    } else {
                        traceDefaults.removeObject(forKey: traceKey)
                    }
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    MCPToolExecutionTracer.setTestSink(nil)
                    MCPResponseDeliveryTracer.resetDebugEvents()
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: "workspace_context",
                        operation: nil
                    )
                    await manager.debugSetDomainPeerIdentityForTesting(
                        connectionID: endpoint.connectionID,
                        identity: nil
                    )
                    if let priorTraceValue {
                        traceDefaults.set(priorTraceValue, forKey: traceKey)
                    } else {
                        traceDefaults.removeObject(forKey: traceKey)
                    }
                    await fixture.cleanup()
                    throw error
                }
            }
        #else
            throw XCTSkip("Correlated tracer capture requires a DEBUG build")
        #endif
    }

    func testExportTraceRetainsStartedPhaseWhenPublicationAuthorityIsLost() async throws {
        #if DEBUG
            for lossBoundary in ["formatting", "publication"] {
                try await MCPSharedServerTestLease.shared.withLease { lease in
                    let fixture = try await PersistentMCPTestFixture.make(
                        lease: lease,
                        domainRuntime: AppDomainRuntimeComposition.shared.runtime
                    )
                    let manager = fixture.networkManager
                    let endpoint = try fixture.endpointA()
                    let executionRecorder = MCPExecutionTraceRecorder()
                    try await Self.prepareProtectedExportFixture(fixture, endpoint: endpoint)
                    MCPToolExecutionTracer.setTestSink { executionRecorder.append($0) }
                    await manager.debugSetResolvedToolOperationOverride(toolName: "workspace_context") {
                        .object(["ok": .bool(true)])
                    }
                    if lossBoundary == "formatting" {
                        await manager.debugSetBeforeToolResultFormattingForTesting { connectionID, toolName in
                            guard connectionID == endpoint.connectionID,
                                  toolName == "workspace_context"
                            else { return }
                            await AppDomainRuntimeComposition.shared.unregister(fixture.contextA.catalogService)
                        }
                    } else {
                        await manager.debugSetBeforeToolCompletionObserversForTesting { connectionID, toolName in
                            guard connectionID == endpoint.connectionID,
                                  toolName == "workspace_context"
                            else { return }
                            await AppDomainRuntimeComposition.shared.unregister(fixture.contextA.catalogService)
                        }
                    }

                    do {
                        _ = try? await endpoint.callTool(
                            name: "workspace_context",
                            arguments: [
                                "op": "export",
                                "path": fixture.contextA.rootURL
                                    .appendingPathComponent("export-trace-authority-loss")
                                    .path,
                                "operation_id": "export-trace-authority-loss-\(UUID().uuidString)",
                                "_rawJSON": true
                            ]
                        )

                        let transitions = executionRecorder.snapshot().filter {
                            $0.toolName == "workspace_context"
                                && $0.phase == .handlerPhaseTransition
                        }
                        if lossBoundary == "formatting" {
                            XCTAssertEqual(
                                transitions.compactMap(\.handlerPhase),
                                [MCPToolExecutionHandlerPhaseSnapshot(
                                    phase: .promptExportFormatting,
                                    transition: .started,
                                    elapsedMilliseconds: transitions.first?.handlerPhase?.elapsedMilliseconds ?? 0
                                )]
                            )
                        } else {
                            let publicationTransitions = transitions.compactMap(\.handlerPhase).filter {
                                $0.phase == .promptExportPublication
                            }
                            XCTAssertEqual(publicationTransitions.map(\.transition), [.started])
                            XCTAssertEqual(
                                transitions.compactMap(\.handlerPhase).filter {
                                    $0.phase == .promptExportFormatting
                                }.map(\.transition),
                                [.started, .completed]
                            )
                        }

                        MCPToolExecutionTracer.setTestSink(nil)
                        await manager.debugSetBeforeToolResultFormattingForTesting(nil)
                        await manager.debugSetBeforeToolCompletionObserversForTesting(nil)
                        await manager.debugSetResolvedToolOperationOverride(
                            toolName: "workspace_context",
                            operation: nil
                        )
                        await manager.debugSetDomainPeerIdentityForTesting(
                            connectionID: endpoint.connectionID,
                            identity: nil
                        )
                        await fixture.cleanup()
                    } catch {
                        MCPToolExecutionTracer.setTestSink(nil)
                        await manager.debugSetBeforeToolResultFormattingForTesting(nil)
                        await manager.debugSetBeforeToolCompletionObserversForTesting(nil)
                        await manager.debugSetResolvedToolOperationOverride(
                            toolName: "workspace_context",
                            operation: nil
                        )
                        await manager.debugSetDomainPeerIdentityForTesting(
                            connectionID: endpoint.connectionID,
                            identity: nil
                        )
                        await fixture.cleanup()
                        throw error
                    }
                }
            }
        #else
            throw XCTSkip("Publication-authority tracer capture requires a DEBUG build")
        #endif
    }

    func testUnixSocketWriteFailuresTracePreciseTerminalReasons() async throws {
        #if DEBUG
            try await Self.assertWriteStallTrace()
            try await Self.assertWriteHangupTrace()
            try await Self.assertWriteFailureTrace()
        #else
            throw XCTSkip("Deterministic socketpair transport diagnostics require a DEBUG build")
        #endif
    }

    func testTransportWriteTracePreservesResponseDeliveryTrackerBehavior() async throws {
        #if DEBUG
            let descriptors = try Self.makeSocketPair()
            defer { Self.closeIfOpen(descriptors[1]) }
            let transport = try UnixSocketMCPTransport(connectedFD: descriptors[0])
            try await transport.connect()
            let receiveStream = await transport.receive()
            let requestJSON = #"{"jsonrpc":"2.0","id":71,"method":"tools/list"}"#
            var request = Data(requestJSON.utf8)
            request.append(0x0A)
            try Self.writeAll(request, to: descriptors[1])
            var iterator = receiveStream.makeAsyncIterator()
            _ = try await iterator.next()

            let pending = await transport.responseDeliverySnapshot()
            XCTAssertEqual(pending.pendingRequestCount, 1)
            try await transport.send(Data(#"{"jsonrpc":"2.0","id":71,"result":{}}"#.utf8))
            let delivered = await transport.responseDeliverySnapshot()
            XCTAssertEqual(delivered.pendingRequestCount, 0)
            XCTAssertTrue(delivered.acceptedRequestsFullyResponded)
            await transport.disconnect()
        #else
            throw XCTSkip("Transport delivery snapshots require a DEBUG build")
        #endif
    }

    #if DEBUG
        private static func prepareProtectedExportFixture(
            _ fixture: PersistentMCPTestFixture,
            endpoint: PersistentMCPTestEndpoint
        ) async throws {
            let context = fixture.contextA
            let workspace = try XCTUnwrap(
                context.window.workspaceManager.workspaces.first { $0.id == context.workspaceID }
            )
            let client = DomainWorkspaceAuthorityClient(
                store: AppDomainRuntimeComposition.shared.runtime.workspaceStore,
                windowID: context.window.windowID
            )
            _ = try await client.registerForRead(
                workspace,
                fileURL: context.rootURL.appendingPathComponent("fixture.repoprompt-workspace")
            )
            await fixture.networkManager.debugSetDomainPeerIdentityForTesting(
                connectionID: endpoint.connectionID,
                identity: .verified(
                    processID: Int(getpid()),
                    fingerprint: "test:verified:export-delivery-trace"
                )
            )
            await context.window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "MCPResponseSendDeadlineConfigurationTests"
            )
            context.window.promptManager.loadComposeTabsFromWorkspace(
                workspace,
                syncPromptText: true
            )
            _ = try await endpoint.callTool(
                name: "bind_context",
                arguments: ["op": "bind", "context_id": context.tabID.uuidString]
            )
            await context.window.mcpServer.domainRoutingPublishTask?.value
        }

        private static func assertWriteStallTrace() async throws {
            MCPResponseDeliveryTracer.resetDebugEvents()
            var descriptors = try makeSocketPair()
            defer { closeIfOpen(descriptors[1]) }
            var sendBuffer: Int32 = 4096
            XCTAssertEqual(
                setsockopt(
                    descriptors[0],
                    SOL_SOCKET,
                    SO_SNDBUF,
                    &sendBuffer,
                    socklen_t(MemoryLayout<Int32>.size)
                ),
                0
            )
            let transport = try UnixSocketMCPTransport(
                connectedFD: descriptors[0],
                writeStallTimeout: 0.02,
                writePollIntervalMilliseconds: 1
            )
            descriptors[0] = -1
            try await transport.connect()

            do {
                try await transport.send(Data(repeating: 0x61, count: 2 * 1024 * 1024))
                XCTFail("Expected a socket write stall")
            } catch {
                // Expected: the terminal trace is asserted below.
            }

            try await assertTerminalWriteTrace(.writeStall, transport: transport)
        }

        private static func assertWriteHangupTrace() async throws {
            MCPResponseDeliveryTracer.resetDebugEvents()
            var descriptors = try makeSocketPair()
            var peerFD = descriptors[1]
            defer {
                closeIfOpen(descriptors[0])
                closeIfOpen(peerFD)
            }
            let transport = try UnixSocketMCPTransport(connectedFD: descriptors[0])
            descriptors[0] = -1
            await transport.debugHoldReaderTerminalCallback()
            try await transport.connect()
            closeIfOpen(peerFD)
            peerFD = -1
            let readerObservedClose = await waitUntil {
                let snapshot = await transport.debugCleanupSnapshot()
                return snapshot.pendingTerminalCallbackCount == 1
            }
            XCTAssertTrue(readerObservedClose)

            do {
                try await transport.send(Data("peer-close-write".utf8))
                XCTFail("Expected a peer write hangup")
            } catch {
                // Expected: the terminal trace is asserted below.
            }

            try await assertTerminalWriteTrace(.writeHangup, transport: transport)
            await transport.debugReleaseReaderTerminalCallbacks()
        }

        private static func assertWriteFailureTrace() async throws {
            MCPResponseDeliveryTracer.resetDebugEvents()
            var descriptors = try makeSocketPair(type: SOCK_DGRAM)
            defer {
                closeIfOpen(descriptors[0])
                closeIfOpen(descriptors[1])
            }
            let transport = try UnixSocketMCPTransport(connectedFD: descriptors[0])
            descriptors[0] = -1
            try await transport.connect()

            do {
                try await transport.send(Data(repeating: 0x62, count: 2 * 1024 * 1024))
                XCTFail("Expected a transport write failure")
            } catch {
                // Expected: the terminal trace is asserted below.
            }

            try await assertTerminalWriteTrace(.writeFailure, transport: transport)
        }

        private static func assertTerminalWriteTrace(
            _ expectedCause: MCPTransportTerminalCause,
            transport: UnixSocketMCPTransport
        ) async throws {
            let closeSnapshot = await transport.closeSnapshot()
            let close = try XCTUnwrap(closeSnapshot)
            XCTAssertEqual(close.cause, expectedCause)
            let failure = try XCTUnwrap(
                MCPResponseDeliveryTracer.debugEventSnapshot().last {
                    $0.phase == "transport_write_failed"
                }
            )
            XCTAssertEqual(failure.terminalReason, expectedCause.rawValue)
        }

        private static func makeSocketPair(type: Int32 = SOCK_STREAM) throws -> [Int32] {
            var descriptors = [Int32](repeating: -1, count: 2)
            guard Darwin.socketpair(AF_UNIX, type, 0, &descriptors) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return descriptors
        }

        private static func closeIfOpen(_ descriptor: Int32) {
            guard descriptor >= 0 else { return }
            _ = Darwin.close(descriptor)
        }

        private static func writeAll(_ data: Data, to descriptor: Int32) throws {
            var offset = 0
            while offset < data.count {
                let written = data.withUnsafeBytes { bytes in
                    Darwin.write(
                        descriptor,
                        bytes.baseAddress?.advanced(by: offset),
                        data.count - offset
                    )
                }
                guard written > 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                offset += written
            }
        }

        private static func waitUntil(
            timeout: Duration = .seconds(1),
            condition: @escaping @Sendable () async -> Bool
        ) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline {
                if await condition() { return true }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return await condition()
        }
    #endif

    private func source(root: URL, path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}

#if DEBUG
    private final class MCPExecutionTraceRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [MCPToolExecutionTraceEvent] = []

        func append(_ event: MCPToolExecutionTraceEvent) {
            lock.lock()
            events.append(event)
            lock.unlock()
        }

        func snapshot() -> [MCPToolExecutionTraceEvent] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }
    }

#endif
