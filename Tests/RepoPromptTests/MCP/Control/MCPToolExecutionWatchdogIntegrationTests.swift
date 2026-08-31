import Foundation
import JSONSchema
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptShared
import XCTest

#if DEBUG
    @MainActor
    final class MCPToolExecutionWatchdogIntegrationTests: XCTestCase {
        func testPromptExportDeadlineEqualityPreservesAppliedAuthorityForBothPublicTools() async throws {
            for toolName in ["prompt", "workspace_context"] {
                let operationID = "applied-equality-\(toolName)-\(UUID().uuidString)"
                try await MCPSharedServerTestLease.shared.withLease { lease in
                    let fixture = try await PersistentMCPTestFixture.make(
                        lease: lease,
                        domainRuntime: AppDomainRuntimeComposition.shared.runtime
                    )
                    let manager = fixture.networkManager
                    let endpoint = try fixture.endpointA()
                    let clock = ExecutionWatchdogManualClock()
                    let preWriteGate = MCPExecutionIgnoringCancellationGate()
                    let schedulingGate = ExecutionWatchdogSchedulingGate(blocking: .operationCompleted)
                    let exportURL = fixture.contextA.rootURL.appendingPathComponent("\(toolName)-\(operationID).md")
                    var responseTask: Task<PersistentMCPTestRPCResponse, Error>?

                    await manager.debugSetToolExecutionWatchdogEnvironment(clock.environment(
                        eventDidProduce: { await schedulingGate.eventDidProduce($0) },
                        beforeEventConsumption: { await schedulingGate.beforeEventConsumption($0) }
                    ))
                    MCPAppPhysicalCapabilityAdapters.setPromptExportPhaseHookForTesting { phase in
                        guard phase == .beforeDurableWrite else { return }
                        await preWriteGate.enterAndWait()
                    }
                    do {
                        try await Self.prepareProtectedExportFixture(fixture, endpoint: endpoint)
                        let activeResponseTask = Task {
                            try await endpoint.callTool(
                                name: toolName,
                                arguments: [
                                    "op": "export",
                                    "path": exportURL.path,
                                    "operation_id": operationID,
                                    "_rawJSON": true
                                ]
                            )
                        }
                        responseTask = activeResponseTask
                        try await clock.waitForSleeperCount(1)
                        try await preWriteGate.waitUntilEntered(count: 1)
                        try await clock.advanceWithoutWakingSleepers(
                            by: MCPTimeoutPolicy.promptExportExecutionDeadline
                        )
                        await preWriteGate.release()
                        await schedulingGate.waitUntilConsumptionPaused()
                        try await clock.advanceNext(expected: MCPTimeoutPolicy.promptExportExecutionDeadline)
                        await schedulingGate.waitUntilProduced(.deadlineExpired)
                        await schedulingGate.open()

                        let response = try await activeResponseTask.value
                        let payload = try Self.toolResultObject(response)
                        responseTask = nil
                        XCTAssertEqual(payload["code"] as? String, "tool_execution_timeout")
                        XCTAssertEqual(payload["settlement"] as? String, "success")
                        XCTAssertEqual(payload["mutation_state"] as? String, "applied")
                        XCTAssertEqual(payload["retryable"] as? Bool, false)
                        XCTAssertEqual(payload["operation_id"] as? String, operationID)
                        XCTAssertEqual(payload["tool"] as? String, toolName)
                        XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.path))
                        let record = try await Self.journalRecord(operationID: operationID)
                        XCTAssertEqual(record.toolName, toolName)
                        XCTAssertEqual(record.status.rawValue, DomainMutationJournalStatus.applied.rawValue)

                        MCPAppPhysicalCapabilityAdapters.setPromptExportPhaseHookForTesting(nil)
                        await manager.debugSetDomainPeerIdentityForTesting(
                            connectionID: endpoint.connectionID,
                            identity: nil
                        )
                        await manager.debugResetToolExecutionWatchdogEnvironment()
                        await fixture.cleanup()
                        try await fixture.assertCleanedUp()
                    } catch {
                        await preWriteGate.release()
                        await schedulingGate.open()
                        responseTask?.cancel()
                        if let responseTask { _ = try? await responseTask.value }
                        MCPAppPhysicalCapabilityAdapters.setPromptExportPhaseHookForTesting(nil)
                        await manager.debugSetDomainPeerIdentityForTesting(
                            connectionID: endpoint.connectionID,
                            identity: nil
                        )
                        await manager.debugResetToolExecutionWatchdogEnvironment()
                        await fixture.cleanup()
                        throw error
                    }
                }
            }
        }

        func testPromptExportWatchdogPreservesPreAndPostCommitTruth() async throws {
            for (toolName, postCommit) in ["prompt", "workspace_context"].flatMap({ toolName in
                [false, true].map { (toolName, $0) }
            }) {
                try await MCPSharedServerTestLease.shared.withLease { lease in
                    let fixture = try await PersistentMCPTestFixture.make(
                        lease: lease,
                        domainRuntime: AppDomainRuntimeComposition.shared.runtime
                    )
                    let manager = fixture.networkManager
                    let endpoint = try fixture.endpointA()
                    let clock = ExecutionWatchdogManualClock()
                    let phaseGate = MCPExecutionIgnoringCancellationGate()
                    let label = "\(toolName)-\(postCommit ? "post-commit" : "pre-commit")"
                    let operationID = "\(label)-\(UUID().uuidString)"
                    let exportURL = fixture.contextA.rootURL.appendingPathComponent("\(operationID).md")
                    var responseTask: Task<PersistentMCPTestRPCResponse, Error>?

                    await manager.debugSetToolExecutionWatchdogEnvironment(clock.environment)
                    MCPAppPhysicalCapabilityAdapters.setPromptExportPhaseHookForTesting { phase in
                        guard phase == (postCommit ? .afterDurableWrite : .beforeDurableWrite) else { return }
                        await phaseGate.enterAndWait()
                    }
                    do {
                        try await Self.prepareProtectedExportFixture(fixture, endpoint: endpoint)
                        let activeResponseTask = Task {
                            try await endpoint.callTool(
                                name: toolName,
                                arguments: [
                                    "op": "export",
                                    "path": exportURL.path,
                                    "operation_id": operationID,
                                    "_rawJSON": true
                                ]
                            )
                        }
                        responseTask = activeResponseTask
                        try await clock.waitForSleeperCount(1)
                        try await phaseGate.waitUntilEntered(count: 1)
                        XCTAssertEqual(FileManager.default.fileExists(atPath: exportURL.path), postCommit)
                        try await clock.advanceNext(expected: MCPTimeoutPolicy.promptExportExecutionDeadline)
                        await phaseGate.release()

                        let response = try await activeResponseTask.value
                        let payload = try Self.toolResultObject(response)
                        responseTask = nil
                        XCTAssertEqual(payload["code"] as? String, "tool_execution_timeout")
                        XCTAssertEqual(payload["settlement"] as? String, postCommit ? "error" : "cancellation")
                        XCTAssertEqual(
                            payload["mutation_state"] as? String,
                            postCommit ? "indeterminate_after_commit" : "not_applied"
                        )
                        XCTAssertEqual(payload["retryable"] as? Bool, !postCommit)
                        XCTAssertEqual(payload["operation_id"] as? String, operationID)
                        XCTAssertEqual(payload["tool"] as? String, toolName)
                        XCTAssertEqual(FileManager.default.fileExists(atPath: exportURL.path), postCommit)
                        let record = try await Self.journalRecord(operationID: operationID)
                        XCTAssertEqual(
                            record.status.rawValue,
                            postCommit
                                ? DomainMutationJournalStatus.indeterminateAfterCommit.rawValue
                                : DomainMutationJournalStatus.cancelledBeforeCommit.rawValue
                        )

                        MCPAppPhysicalCapabilityAdapters.setPromptExportPhaseHookForTesting(nil)
                        await manager.debugSetDomainPeerIdentityForTesting(
                            connectionID: endpoint.connectionID,
                            identity: nil
                        )
                        await manager.debugResetToolExecutionWatchdogEnvironment()
                        await fixture.cleanup()
                        try await fixture.assertCleanedUp()
                    } catch {
                        await phaseGate.release()
                        responseTask?.cancel()
                        if let responseTask { _ = try? await responseTask.value }
                        MCPAppPhysicalCapabilityAdapters.setPromptExportPhaseHookForTesting(nil)
                        await manager.debugSetDomainPeerIdentityForTesting(
                            connectionID: endpoint.connectionID,
                            identity: nil
                        )
                        await manager.debugResetToolExecutionWatchdogEnvironment()
                        await fixture.cleanup()
                        throw error
                    }
                }
            }
        }

        func testPromptExportCleanupUnresponsiveRetainsEventualJournalTruth() async throws {
            for toolName in ["prompt", "workspace_context"] {
                try await MCPSharedServerTestLease.shared.withLease { lease in
                    let fixture = try await PersistentMCPTestFixture.make(
                        lease: lease,
                        domainRuntime: AppDomainRuntimeComposition.shared.runtime
                    )
                    let manager = fixture.networkManager
                    let endpoint = try fixture.endpointA()
                    let clock = ExecutionWatchdogManualClock()
                    let afterWriteGate = MCPExecutionIgnoringCancellationGate()
                    let operationID = "cleanup-unresponsive-\(toolName)-\(UUID().uuidString)"
                    let exportURL = fixture.contextA.rootURL.appendingPathComponent("\(operationID).md")
                    var responseTask: Task<PersistentMCPTestRPCResponse, Error>?

                    await manager.debugSetToolExecutionWatchdogEnvironment(clock.environment)
                    MCPAppPhysicalCapabilityAdapters.setPromptExportPhaseHookForTesting { phase in
                        guard phase == .afterDurableWrite else { return }
                        await afterWriteGate.enterAndWait()
                    }
                    do {
                        try await Self.prepareProtectedExportFixture(fixture, endpoint: endpoint)
                        let activeResponseTask = Task {
                            try await endpoint.callTool(
                                name: toolName,
                                arguments: [
                                    "op": "export",
                                    "path": exportURL.path,
                                    "operation_id": operationID,
                                    "_rawJSON": true
                                ]
                            )
                        }
                        responseTask = activeResponseTask
                        try await clock.waitForSleeperCount(1)
                        try await afterWriteGate.waitUntilEntered(count: 1)
                        XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.path))
                        try await clock.advanceNext(expected: MCPTimeoutPolicy.promptExportExecutionDeadline)
                        try await clock.waitForSleeperCount(1)
                        try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolCancellationCleanupGrace)
                        await Self.assertSocketClosed(activeResponseTask)
                        responseTask = nil
                        let isTerminal = await manager.debugIsExecutionWatchdogTerminal(
                            connectionID: endpoint.connectionID
                        )
                        XCTAssertTrue(isTerminal)

                        await afterWriteGate.release()
                        let settled = await Self.waitUntil {
                            guard let record = try? await Self.journalRecord(operationID: operationID) else { return false }
                            return record.status.rawValue == DomainMutationJournalStatus.indeterminateAfterCommit.rawValue
                        }
                        XCTAssertTrue(settled)
                        let record = try await Self.journalRecord(operationID: operationID)
                        XCTAssertEqual(
                            record.status.rawValue,
                            DomainMutationJournalStatus.indeterminateAfterCommit.rawValue
                        )
                        XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.path))

                        MCPAppPhysicalCapabilityAdapters.setPromptExportPhaseHookForTesting(nil)
                        await manager.debugSetDomainPeerIdentityForTesting(
                            connectionID: endpoint.connectionID,
                            identity: nil
                        )
                        await manager.debugResetToolExecutionWatchdogEnvironment()
                        await fixture.cleanup()
                    } catch {
                        await afterWriteGate.release()
                        responseTask?.cancel()
                        if let responseTask { _ = try? await responseTask.value }
                        MCPAppPhysicalCapabilityAdapters.setPromptExportPhaseHookForTesting(nil)
                        await manager.debugSetDomainPeerIdentityForTesting(
                            connectionID: endpoint.connectionID,
                            identity: nil
                        )
                        await manager.debugResetToolExecutionWatchdogEnvironment()
                        await fixture.cleanup()
                        throw error
                    }
                }
            }
        }

        func testLateCompletionTraceDoesNotClaimCancellationWasRequested() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let recorder = MCPExecutionTraceRecorder()
                let clock = ExecutionWatchdogManualClock()
                let operationGate = MCPExecutionIgnoringCancellationGate()
                let schedulingGate = ExecutionWatchdogSchedulingGate(blocking: .operationCompleted)
                let manager = fixture.networkManager
                let endpoint = try fixture.endpointA()
                var responseTask: Task<PersistentMCPTestRPCResponse, Error>?

                MCPToolExecutionTracer.setTestSink { recorder.append($0) }
                await manager.debugSetToolExecutionWatchdogEnvironment(clock.environment(
                    eventDidProduce: { await schedulingGate.eventDidProduce($0) },
                    beforeEventConsumption: { await schedulingGate.beforeEventConsumption($0) }
                ))
                await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.readFile) {
                    await operationGate.enterAndWait()
                    return .object(["late": .bool(true)])
                }

                do {
                    let activeResponseTask = Task {
                        try await endpoint.callTool(
                            name: MCPWindowToolName.readFile,
                            arguments: [
                                "path": fixture.contextA.fileURL.path,
                                "context_id": fixture.contextA.tabID.uuidString
                            ]
                        )
                    }
                    responseTask = activeResponseTask
                    try await clock.waitForSleeperCount(1)
                    try await clock.advanceWithoutWakingSleepers(
                        by: MCPTimeoutPolicy.boundedToolExecutionDeadline + .nanoseconds(1)
                    )
                    await operationGate.release()
                    await schedulingGate.waitUntilConsumptionPaused()
                    try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolExecutionDeadline)
                    await schedulingGate.waitUntilProduced(.deadlineExpired)
                    await schedulingGate.open()

                    let response = try await activeResponseTask.value
                    responseTask = nil
                    let text = try Self.toolResultText(response)
                    XCTAssertTrue(text.contains("tool_execution_timeout"), text)

                    let events = recorder.snapshot().filter {
                        $0.connectionID == endpoint.connectionID
                            && $0.toolName == MCPWindowToolName.readFile
                    }
                    XCTAssertEqual(events.count(where: { $0.phase == .deadlineExpired }), 1)
                    XCTAssertFalse(events.contains { $0.phase == .cancellationRequested })
                    let settled = try XCTUnwrap(events.first { $0.phase == .settledDuringGrace })
                    XCTAssertEqual(settled.cancellationRequested, false)
                    XCTAssertNil(settled.cancellationOrigin)
                    XCTAssertEqual(settled.cancellationOutcome, MCPToolExecutionSettlement.success.rawValue)
                    XCTAssertEqual(settled.graceOutcome, "late_completion")
                    let sleeperCount = await clock.sleeperCount()
                    let pendingSchedulingTasks = await schedulingGate.pendingTaskCount()
                    XCTAssertEqual(sleeperCount, 0)
                    XCTAssertEqual(pendingSchedulingTasks, 0)

                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPWindowToolName.readFile,
                        operation: nil
                    )
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    await operationGate.release()
                    await schedulingGate.open()
                    responseTask?.cancel()
                    if let responseTask {
                        _ = try? await responseTask.value
                    }
                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPWindowToolName.readFile,
                        operation: nil
                    )
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testBoundedFileToolsEmitHandlerCompletionAndConnectionRemainsUsable() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let recorder = MCPExecutionTraceRecorder()
                MCPToolExecutionTracer.setTestSink { recorder.append($0) }
                do {
                    let endpoint = try fixture.endpointA()
                    let context = fixture.contextA
                    _ = try await endpoint.callTool(
                        name: MCPWindowToolName.getCodeStructure,
                        arguments: [
                            "paths": [context.fileURL.path],
                            "context_id": context.tabID.uuidString
                        ]
                    )
                    _ = try await endpoint.callTool(
                        name: MCPWindowToolName.readFile,
                        arguments: [
                            "path": context.fileURL.path,
                            "context_id": context.tabID.uuidString
                        ]
                    )
                    _ = try await endpoint.callTool(
                        name: MCPWindowToolName.search,
                        arguments: [
                            "pattern": "distinct_mcp_connection_shared_search_token",
                            "mode": "content",
                            "context_id": context.tabID.uuidString
                        ]
                    )

                    let events = recorder.snapshot().filter { $0.connectionID == endpoint.connectionID }
                    for toolName in [
                        MCPWindowToolName.getCodeStructure,
                        MCPWindowToolName.readFile,
                        MCPWindowToolName.search
                    ] {
                        XCTAssertTrue(events.contains {
                            $0.toolName == toolName && $0.phase == .handlerCompleted
                        }, "Missing handler-completed trace for \(toolName): \(events)")
                    }

                    _ = try await endpoint.client.request(method: "tools/list", params: [:])
                    let isTerminal = await fixture.networkManager.debugIsExecutionWatchdogTerminal(connectionID: endpoint.connectionID)
                    XCTAssertFalse(isTerminal)
                    MCPToolExecutionTracer.setTestSink(nil)
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    MCPToolExecutionTracer.setTestSink(nil)
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testQualifiedReadBypassesBlockedPeerCompactionAndLeavesSameWindowSettlementUsable() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let endpoint = try fixture.endpointA()
                let store = fixture.contextA.window.workspaceFileContextStore
                let peerRootURL = fixture.rootURL.appendingPathComponent("qualified-read-peer", isDirectory: true)
                try FileManager.default.createDirectory(at: peerRootURL, withIntermediateDirectories: true)
                try "peer\n".write(
                    to: peerRootURL.appendingPathComponent("Peer.swift"),
                    atomically: true,
                    encoding: .utf8
                )
                let peerRoot = try await store.loadRoot(path: peerRootURL.path)
                let namespace = await WorkspaceExactFileNamespace.identity(
                    roots: store.rootRefs(scope: .visibleWorkspace)
                )
                let peerSerialPosition = try XCTUnwrap(namespace.rootBindings.firstIndex {
                    $0.lookupRoot.id == peerRoot.id
                })
                let peerGate = TestReleaseFence(name: "qualified provider peer compaction")
                let completion = MCPQualifiedReadCompletionProbe()
                var responseTask: Task<PersistentMCPTestRPCResponse, Error>?

                await store.setExactFileCandidateProbeGateForTesting(
                    purpose: .canonicalCompaction,
                    rootID: peerRoot.id,
                    serialPosition: peerSerialPosition
                ) {
                    await peerGate.enterAndWaitIgnoringCancellationUntilRelease()
                }

                do {
                    let activeResponseTask = Task {
                        let response = try await endpoint.callTool(
                            name: MCPWindowToolName.readFile,
                            arguments: [
                                "path": fixture.contextA.fileURL.path,
                                "context_id": fixture.contextA.tabID.uuidString
                            ]
                        )
                        await completion.markCompleted()
                        return response
                    }
                    responseTask = activeResponseTask

                    let firstObservationArrived = await Self.waitUntil {
                        let completed = await completion.isCompleted()
                        return completed || peerGate.hasEntered
                    }
                    let readCompletedBeforeRelease = await completion.isCompleted()
                    let peerGateEnteredBeforeRelease = peerGate.hasEntered
                    peerGate.release()
                    XCTAssertTrue(firstObservationArrived)
                    XCTAssertTrue(readCompletedBeforeRelease)
                    XCTAssertFalse(peerGateEnteredBeforeRelease)

                    let firstResponse = try await activeResponseTask.value
                    responseTask = nil
                    let firstText = try Self.toolResultText(firstResponse)
                    XCTAssertTrue(firstText.contains(fixture.contextA.sentinel), firstText)

                    let secondResponse = try await endpoint.callTool(
                        name: MCPWindowToolName.readFile,
                        arguments: [
                            "path": fixture.contextA.fileURL.path,
                            "context_id": fixture.contextA.tabID.uuidString
                        ]
                    )
                    let secondText = try Self.toolResultText(secondResponse)
                    XCTAssertTrue(secondText.contains(fixture.contextA.sentinel), secondText)
                    XCTAssertFalse(secondText.contains("tool_execution_structure_settlement_busy"), secondText)

                    await store.clearExactFileCandidateProbeGateForTesting()
                    await store.unloadRoot(id: peerRoot.id)
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    peerGate.release()
                    responseTask?.cancel()
                    if let responseTask {
                        _ = try? await responseTask.value
                    }
                    await store.clearExactFileCandidateProbeGateForTesting()
                    await store.unloadRoot(id: peerRoot.id)
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testHistoryPartialResultLeavesPersistentConnectionUsable() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let recorder = MCPExecutionTraceRecorder()
                let manager = fixture.networkManager
                let endpoint = try fixture.endpointA()

                let applicationSupportRoot = FileManager.default.temporaryDirectory
                    .appendingPathComponent("HistoryPersistentBudget-\(UUID().uuidString)", isDirectory: true)
                let workspaceDirectories = (0 ... 5000).map { index in
                    applicationSupportRoot
                        .appendingPathComponent("Workspaces", isDirectory: true)
                        .appendingPathComponent("Workspace-Synthetic-\(index)", isDirectory: true)
                }
                let scanner = HistorySessionScanner(
                    applicationSupportRoot: applicationSupportRoot,
                    workspaceDirectoryProvider: { _ in workspaceDirectories }
                )
                let runtime = MCPAppToolBinder(windowID: 42) { name, _, arguments, implementation in
                    try await implementation(
                        MCPAppToolInvocation(toolName: name, windowID: 42),
                        arguments
                    )
                }
                let provider = MCPHistoryToolProvider(runtime: runtime, scannerFactory: { scanner })

                MCPToolExecutionTracer.setTestSink { recorder.append($0) }
                await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.history) {
                    try await provider.execute(args: ["op": "list_sessions"])
                }

                do {
                    let response = try await endpoint.callTool(
                        name: MCPWindowToolName.history,
                        arguments: [
                            "op": "list_sessions",
                            "context_id": fixture.contextA.tabID.uuidString
                        ]
                    )
                    let text = try Self.toolResultText(response)
                    XCTAssertTrue(text.contains("History Sessions ⚠️"), text)
                    XCTAssertTrue(text.contains("workspace_count"), text)
                    XCTAssertTrue(text.contains("5000/5000 workspaces"), text)

                    _ = try await endpoint.client.request(method: "tools/list", params: [:])
                    let isTerminal = await manager.debugIsExecutionWatchdogTerminal(
                        connectionID: endpoint.connectionID
                    )
                    XCTAssertFalse(isTerminal)
                    XCTAssertTrue(recorder.snapshot().contains {
                        $0.connectionID == endpoint.connectionID
                            && $0.toolName == MCPWindowToolName.history
                            && $0.phase == .handlerCompleted
                    })

                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPWindowToolName.history,
                        operation: nil
                    )
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPWindowToolName.history,
                        operation: nil
                    )
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testSameWindowExclusiveResourceReleasesBeforeCompletionObserverTail() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let manager = fixture.networkManager
                let firstEndpoint = try fixture.endpointA()
                let secondEndpoint = try fixture.endpointARead()
                let providerProbe = MCPPostProviderAdmissionProbe()
                let observerTailGate = MCPExecutionIgnoringCancellationGate()
                var firstTask: Task<PersistentMCPTestRPCResponse, Error>?
                var secondTask: Task<PersistentMCPTestRPCResponse, Error>?

                await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.manageSelection) {
                    await providerProbe.record(connectionID: ServerNetworkManager.currentConnectionID)
                }
                await manager.debugSetBeforeToolCompletionObserversForTesting { connectionID, toolName in
                    guard connectionID == firstEndpoint.connectionID,
                          toolName == MCPWindowToolName.manageSelection
                    else { return }
                    await observerTailGate.enterAndWait()
                }

                do {
                    let arguments: [String: Any] = [
                        "op": "get",
                        "context_id": fixture.contextA.tabID.uuidString,
                        "_rawJSON": true
                    ]
                    let blockedFirst = Task {
                        try await firstEndpoint.callTool(
                            name: MCPWindowToolName.manageSelection,
                            arguments: arguments
                        )
                    }
                    firstTask = blockedFirst
                    try await observerTailGate.waitUntilEntered(count: 1)
                    try await providerProbe.waitUntilEntered(connectionID: firstEndpoint.connectionID)

                    let firstLimiter = await manager.connectionLimiterSnapshotForTesting(
                        connectionID: firstEndpoint.connectionID,
                        lane: .ordinary
                    )
                    XCTAssertEqual(firstLimiter?.activePermitCount, 1)

                    let competingSecond = Task {
                        try await secondEndpoint.callTool(
                            name: MCPWindowToolName.manageSelection,
                            arguments: arguments
                        )
                    }
                    secondTask = competingSecond
                    try await providerProbe.waitUntilEntered(connectionID: secondEndpoint.connectionID)
                    _ = try await competingSecond.value
                    secondTask = nil

                    await observerTailGate.release()
                    _ = try await blockedFirst.value
                    firstTask = nil

                    await manager.debugSetBeforeToolCompletionObserversForTesting(nil)
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPWindowToolName.manageSelection,
                        operation: nil
                    )
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    await observerTailGate.release()
                    firstTask?.cancel()
                    secondTask?.cancel()
                    if let firstTask { _ = try? await firstTask.value }
                    if let secondTask { _ = try? await secondTask.value }
                    await manager.debugSetBeforeToolCompletionObserversForTesting(nil)
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPWindowToolName.manageSelection,
                        operation: nil
                    )
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testSameWindowFileReadResourcesReleaseBeforeFormattingTail() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let manager = fixture.networkManager
                let firstEndpoint = try fixture.endpointA()
                let secondEndpoint = try fixture.endpointARead()
                let thirdEndpoint = try fixture.endpointAQueuedSearch()
                let providerProbe = MCPPostProviderAdmissionProbe()
                let formattingTailGate = MCPExecutionIgnoringCancellationGate()
                let blockedConnectionIDs = Set([firstEndpoint.connectionID, secondEndpoint.connectionID])
                var tasks: [Task<PersistentMCPTestRPCResponse, Error>] = []

                await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.readFile) {
                    await providerProbe.record(connectionID: ServerNetworkManager.currentConnectionID)
                }
                await manager.debugSetBeforeToolResultFormattingForTesting { connectionID, toolName in
                    guard blockedConnectionIDs.contains(connectionID),
                          toolName == MCPWindowToolName.readFile
                    else { return }
                    await formattingTailGate.enterAndWait()
                }

                do {
                    let arguments: [String: Any] = [
                        "path": fixture.contextA.fileURL.path,
                        "context_id": fixture.contextA.tabID.uuidString,
                        "_rawJSON": true
                    ]
                    let first = Task {
                        try await firstEndpoint.callTool(
                            name: MCPWindowToolName.readFile,
                            arguments: arguments
                        )
                    }
                    let second = Task {
                        try await secondEndpoint.callTool(
                            name: MCPWindowToolName.readFile,
                            arguments: arguments
                        )
                    }
                    tasks = [first, second]
                    try await formattingTailGate.waitUntilEntered(count: 2)
                    try await providerProbe.waitUntilEntered(connectionID: firstEndpoint.connectionID)
                    try await providerProbe.waitUntilEntered(connectionID: secondEndpoint.connectionID)

                    for endpoint in [firstEndpoint, secondEndpoint] {
                        let limiter = await manager.connectionLimiterSnapshotForTesting(
                            connectionID: endpoint.connectionID,
                            lane: .fileRead
                        )
                        XCTAssertEqual(limiter?.activePermitCount, 1)
                    }

                    let third = Task {
                        try await thirdEndpoint.callTool(
                            name: MCPWindowToolName.readFile,
                            arguments: arguments
                        )
                    }
                    tasks.append(third)
                    try await providerProbe.waitUntilEntered(connectionID: thirdEndpoint.connectionID)
                    _ = try await third.value
                    tasks.removeLast()

                    await formattingTailGate.release()
                    _ = try await first.value
                    _ = try await second.value
                    tasks.removeAll()

                    await manager.debugSetBeforeToolResultFormattingForTesting(nil)
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPWindowToolName.readFile,
                        operation: nil
                    )
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    await formattingTailGate.release()
                    tasks.forEach { $0.cancel() }
                    for task in tasks {
                        _ = try? await task.value
                    }
                    await manager.debugSetBeforeToolResultFormattingForTesting(nil)
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPWindowToolName.readFile,
                        operation: nil
                    )
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testAppWideExclusiveResourceReleasesBeforeFormattingTail() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let manager = fixture.networkManager
                let firstEndpoint = try fixture.endpointA()
                let secondEndpoint = try fixture.endpointB()
                let providerProbe = MCPPostProviderAdmissionProbe()
                let formattingTailGate = MCPExecutionIgnoringCancellationGate()
                var appSettingsScope: MCPAppSettingsServiceScope?
                var firstTask: Task<PersistentMCPTestRPCResponse, Error>?
                var secondTask: Task<PersistentMCPTestRPCResponse, Error>?

                await manager.debugSetResolvedToolOperationOverride(toolName: MCPGlobalToolName.appSettings) {
                    await providerProbe.record(connectionID: ServerNetworkManager.currentConnectionID)
                }
                await manager.debugSetBeforeToolResultFormattingForTesting { connectionID, toolName in
                    guard connectionID == firstEndpoint.connectionID,
                          toolName == MCPGlobalToolName.appSettings
                    else { return }
                    await formattingTailGate.enterAndWait()
                }

                do {
                    let installedScope = try await MCPAppSettingsServiceScope.install()
                    appSettingsScope = installedScope
                    let arguments: [String: Any] = [
                        "op": "get",
                        "key": "ui.appearance_mode",
                        "_rawJSON": true
                    ]
                    let blockedFirst = Task {
                        try await firstEndpoint.callTool(
                            name: MCPGlobalToolName.appSettings,
                            arguments: arguments
                        )
                    }
                    firstTask = blockedFirst
                    try await formattingTailGate.waitUntilEntered(count: 1)
                    try await providerProbe.waitUntilEntered(connectionID: firstEndpoint.connectionID)

                    let firstLimiter = await manager.connectionLimiterSnapshotForTesting(
                        connectionID: firstEndpoint.connectionID,
                        lane: .ordinary
                    )
                    XCTAssertEqual(firstLimiter?.activePermitCount, 1)

                    let competingSecond = Task {
                        try await secondEndpoint.callTool(
                            name: MCPGlobalToolName.appSettings,
                            arguments: arguments
                        )
                    }
                    secondTask = competingSecond
                    try await providerProbe.waitUntilEntered(connectionID: secondEndpoint.connectionID)
                    _ = try await competingSecond.value
                    secondTask = nil

                    await formattingTailGate.release()
                    _ = try await blockedFirst.value
                    firstTask = nil

                    await manager.debugSetBeforeToolResultFormattingForTesting(nil)
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPGlobalToolName.appSettings,
                        operation: nil
                    )
                    await installedScope.restore()
                    await installedScope.assertRestored()
                    appSettingsScope = nil
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    await formattingTailGate.release()
                    firstTask?.cancel()
                    secondTask?.cancel()
                    if let firstTask { _ = try? await firstTask.value }
                    if let secondTask { _ = try? await secondTask.value }
                    await manager.debugSetBeforeToolResultFormattingForTesting(nil)
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPGlobalToolName.appSettings,
                        operation: nil
                    )
                    if let appSettingsScope {
                        await appSettingsScope.restore()
                        await appSettingsScope.assertRestored()
                    }
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testManageSelectionAndFileActionsReportReplyConstructionPhase() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let recorder = MCPExecutionTraceRecorder()
                let createdFileURL = fixture.contextA.fileURL
                    .deletingLastPathComponent()
                    .appendingPathComponent("watchdog-phase-\(UUID().uuidString).txt")
                MCPToolExecutionTracer.setTestSink { recorder.append($0) }
                do {
                    let endpoint = try fixture.endpointA()
                    _ = try await endpoint.callTool(
                        name: MCPWindowToolName.manageSelection,
                        arguments: [
                            "op": "get",
                            "context_id": fixture.contextA.tabID.uuidString
                        ]
                    )
                    _ = try await endpoint.callTool(
                        name: MCPWindowToolName.fileActions,
                        arguments: [
                            "action": "create",
                            "path": createdFileURL.path,
                            "content": "watchdog phase fixture\n",
                            "context_id": fixture.contextA.tabID.uuidString
                        ]
                    )

                    let events = recorder.snapshot().filter { $0.connectionID == endpoint.connectionID }
                    let selectionCompleted = try XCTUnwrap(events.last {
                        $0.toolName == MCPWindowToolName.manageSelection && $0.phase == .handlerCompleted
                    })
                    XCTAssertEqual(selectionCompleted.handlerPhase?.phase, .manageSelectionReplyConstruction)
                    XCTAssertEqual(selectionCompleted.handlerPhase?.transition, .completed)

                    let fileActionCompleted = try XCTUnwrap(events.last {
                        $0.toolName == MCPWindowToolName.fileActions && $0.phase == .handlerCompleted
                    })
                    XCTAssertEqual(fileActionCompleted.handlerPhase?.phase, .fileActionsReplyConstruction)
                    XCTAssertEqual(fileActionCompleted.handlerPhase?.transition, .completed)

                    MCPToolExecutionTracer.setTestSink(nil)
                    try? FileManager.default.removeItem(at: createdFileURL)
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    MCPToolExecutionTracer.setTestSink(nil)
                    try? FileManager.default.removeItem(at: createdFileURL)
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testAskUserLifecycleExemptionDoesNotInstallExecutionWatchdog() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let clock = ExecutionWatchdogManualClock()
                let operationGate = MCPExecutionIgnoringCancellationGate()
                let recorder = MCPExecutionTraceRecorder()
                let manager = fixture.networkManager
                let clientName = "ask-user-execution-contract-\(UUID().uuidString)"
                var endpoint: PersistentMCPTestEndpoint?

                MCPToolExecutionTracer.setTestSink { recorder.append($0) }
                await manager.debugSetToolExecutionWatchdogEnvironment(clock.environment)
                await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.askUser) {
                    await operationGate.enterAndWait()
                    return .object(["timed_out": .bool(false)])
                }
                await manager.installClientConnectionPolicy(
                    for: clientName,
                    windowID: fixture.contextA.window.windowID,
                    restrictedTools: [],
                    tabID: fixture.contextA.tabID,
                    runID: UUID(),
                    additionalTools: [MCPWindowToolName.askUser],
                    purpose: .agentModeRun
                )

                do {
                    let createdEndpoint = try await PersistentMCPTestEndpoint.make(
                        label: "ask-user-exemption",
                        networkManager: manager,
                        clientName: clientName,
                        requiredToolNames: [MCPWindowToolName.askUser]
                    )
                    endpoint = createdEndpoint
                    let responseTask = Task {
                        try await createdEndpoint.callTool(
                            name: MCPWindowToolName.askUser,
                            arguments: [
                                "questions": [[
                                    "id": "scope",
                                    "question": "Which scope?"
                                ]],
                                "timeout_seconds": 900
                            ]
                        )
                    }

                    try await operationGate.waitUntilEntered(count: 1)
                    for _ in 0 ..< 10 {
                        await Task.yield()
                    }
                    let sleeperCount = await clock.sleeperCount()
                    XCTAssertEqual(sleeperCount, 0)

                    let selected = recorder.snapshot().first {
                        $0.connectionID == createdEndpoint.connectionID
                            && $0.toolName == MCPWindowToolName.askUser
                            && $0.phase == .contractSelected
                    }
                    XCTAssertEqual(selected?.contractKind, .interactiveCancellable)
                    XCTAssertNil(selected?.executionDeadlineSeconds)
                    XCTAssertFalse(recorder.snapshot().contains {
                        $0.connectionID == createdEndpoint.connectionID
                            && $0.toolName == MCPWindowToolName.askUser
                            && $0.phase == .deadlineExpired
                    })

                    await operationGate.release()
                    _ = try await responseTask.value

                    await Self.cleanupEndpoint(createdEndpoint, manager: manager)
                    endpoint = nil
                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.askUser, operation: nil)
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    await operationGate.release()
                    if let endpoint {
                        await Self.cleanupEndpoint(endpoint, manager: manager)
                    }
                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.askUser, operation: nil)
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testLongRunningFileSearchSurvivesFormerWatchdogAndHonorsCallerCancellation() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let clock = ExecutionWatchdogManualClock()
                let survivalGate = MCPExecutionIgnoringCancellationGate()
                let cancellationGate = MCPExecutionCooperativeCancellationGate()
                let recorder = MCPExecutionTraceRecorder()
                let manager = fixture.networkManager
                let endpoint = try fixture.endpointA()

                MCPToolExecutionTracer.setTestSink { recorder.append($0) }
                await manager.debugSetToolExecutionWatchdogEnvironment(clock.environment)
                await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.search) {
                    await survivalGate.enterAndWait()
                    return .object(["phase": .string("survived-former-watchdog")])
                }

                var survivalTask: Task<PersistentMCPTestRPCResponse, Error>?
                var cancellationTask: Task<PersistentMCPTestRPCResponse, Error>?
                do {
                    let activeSurvivalTask = Task {
                        try await endpoint.callTool(
                            name: MCPWindowToolName.search,
                            arguments: [
                                "pattern": PersistentMCPTestFixture.sharedSearchToken,
                                "mode": "content",
                                "context_id": fixture.contextA.tabID.uuidString
                            ]
                        )
                    }
                    survivalTask = activeSurvivalTask
                    try await survivalGate.waitUntilEntered(count: 1)
                    let survivalSleeperCount = await clock.sleeperCount()
                    XCTAssertEqual(survivalSleeperCount, 0)
                    let formerWatchdogWindow = MCPTimeoutPolicy.boundedToolExecutionDeadline
                        + MCPTimeoutPolicy.boundedToolCancellationCleanupGrace
                        + .seconds(1)
                    try await clock.advanceWithoutSleepers(by: formerWatchdogWindow)
                    for _ in 0 ..< 20 {
                        await Task.yield()
                    }
                    let survivalInFlight = await manager.hasInFlightCalls(for: endpoint.connectionID)
                    let survivalTerminal = await manager.debugIsExecutionWatchdogTerminal(connectionID: endpoint.connectionID)
                    XCTAssertTrue(survivalInFlight)
                    XCTAssertFalse(survivalTerminal)
                    let survivalViable = await endpoint.connectionManager.isViableForRetention()
                    XCTAssertTrue(survivalViable)
                    let survivalEvents = recorder.snapshot().filter {
                        $0.connectionID == endpoint.connectionID && $0.toolName == MCPWindowToolName.search
                    }
                    let selected = try XCTUnwrap(survivalEvents.first { $0.phase == .contractSelected })
                    XCTAssertEqual(selected.contractKind, .longSynchronousCancellable)
                    XCTAssertNil(selected.executionDeadlineSeconds)
                    XCTAssertNil(selected.cleanupGraceSeconds)
                    XCTAssertFalse(survivalEvents.contains { $0.phase == .deadlineExpired })
                    XCTAssertFalse(survivalEvents.contains { $0.phase == .connectionForceDisconnectRequested })

                    await survivalGate.release()
                    _ = try await activeSurvivalTask.value

                    await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.search) {
                        try await cancellationGate.enterAndWait()
                        return .object(["phase": .string("unexpected-completion")])
                    }
                    let cancellationRequestID = endpoint.client.nextRequestIDForTesting()
                    let activeCancellationTask = Task {
                        try await endpoint.callTool(
                            name: MCPWindowToolName.search,
                            arguments: [
                                "pattern": PersistentMCPTestFixture.sharedSearchToken,
                                "mode": "content",
                                "context_id": fixture.contextA.tabID.uuidString
                            ]
                        )
                    }
                    cancellationTask = activeCancellationTask
                    try await cancellationGate.waitUntilEntered()
                    let cancellationSleeperCount = await clock.sleeperCount()
                    XCTAssertEqual(cancellationSleeperCount, 0)
                    try endpoint.client.sendNotification(
                        method: "notifications/cancelled",
                        params: ["requestId": cancellationRequestID]
                    )
                    try await cancellationGate.waitUntilCancellationObserved()
                    let observedCancellationCount = await cancellationGate.observedCancellationCount()
                    XCTAssertEqual(observedCancellationCount, 1)
                    let cancellationResponse = try await activeCancellationTask.value
                    let cancellationText = try Self.toolResultText(cancellationResponse)
                    XCTAssertFalse(cancellationText.contains("tool_execution_timeout"), cancellationText)
                    XCTAssertFalse(cancellationText.contains("tool_execution_cleanup_unresponsive"), cancellationText)

                    let events = recorder.snapshot().filter {
                        $0.connectionID == endpoint.connectionID && $0.toolName == MCPWindowToolName.search
                    }
                    XCTAssertEqual(events.count(where: { $0.phase == .contractSelected }), 2)
                    XCTAssertTrue(events.filter { $0.phase == .contractSelected }.allSatisfy {
                        $0.contractKind == .longSynchronousCancellable
                            && $0.executionDeadlineSeconds == nil
                            && $0.cleanupGraceSeconds == nil
                    })
                    XCTAssertFalse(events.contains { $0.phase == .deadlineExpired })
                    XCTAssertFalse(events.contains { $0.phase == .cleanupGraceExpired })
                    XCTAssertFalse(events.contains { $0.phase == .connectionForceDisconnectRequested })
                    let cancellationTerminal = await manager.debugIsExecutionWatchdogTerminal(connectionID: endpoint.connectionID)
                    XCTAssertFalse(cancellationTerminal)

                    await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.search, operation: nil)
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    MCPToolExecutionTracer.setTestSink(nil)

                    _ = try await endpoint.callTool(
                        name: MCPWindowToolName.search,
                        arguments: [
                            "pattern": PersistentMCPTestFixture.sharedSearchToken,
                            "mode": "content",
                            "context_id": fixture.contextA.tabID.uuidString
                        ]
                    )
                    _ = try await endpoint.callTool(
                        name: MCPWindowToolName.readFile,
                        arguments: [
                            "path": fixture.contextA.fileURL.path,
                            "context_id": fixture.contextA.tabID.uuidString
                        ]
                    )
                    _ = try await endpoint.client.request(method: "tools/list", params: [:])
                    let finalInFlight = await manager.hasInFlightCalls(for: endpoint.connectionID)
                    XCTAssertFalse(finalInFlight)
                    let limiter = await manager.connectionLimiterSnapshotForTesting(connectionID: endpoint.connectionID)
                    XCTAssertEqual(limiter?.permits, 1)
                    XCTAssertEqual(limiter?.waiterCount, 0)
                    XCTAssertEqual(limiter?.inFlight, 0)

                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    await survivalGate.release()
                    await cancellationGate.cancelForCleanup()
                    survivalTask?.cancel()
                    cancellationTask?.cancel()
                    if let survivalTask {
                        _ = try? await survivalTask.value
                    }
                    if let cancellationTask {
                        _ = try? await cancellationTask.value
                    }
                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.search, operation: nil)
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testInactiveReadFileCaptureSkipsSettlementDiagnosticSnapshotEnumeration() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let manager = fixture.networkManager
                EditFlowPerf.resetDebugCaptureForTesting()
                let before = await manager.debugCodeStructureSettlementDiagnosticSnapshotCountForTesting()

                do {
                    let response = try await fixture.endpointA().callTool(
                        name: MCPWindowToolName.readFile,
                        arguments: [
                            "path": fixture.contextA.fileURL.path,
                            "context_id": fixture.contextA.tabID.uuidString
                        ]
                    )
                    let after = await manager.debugCodeStructureSettlementDiagnosticSnapshotCountForTesting()

                    XCTAssertTrue(try Self.toolResultText(response).contains(fixture.contextA.sentinel))
                    XCTAssertEqual(after, before)
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testReadFileFilteredCaptureRetainsLifecycleFromRealDispatch() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                EditFlowPerf.resetDebugCaptureForTesting()
                defer { EditFlowPerf.resetDebugCaptureForTesting() }
                switch EditFlowPerf.beginDebugCapture(
                    label: "read-file-real-dispatch",
                    maxSamples: 200,
                    expiryMilliseconds: 120_000,
                    toolFilter: .readFile,
                    prepare: { captureIdentity in
                        MCPResponseDeliveryTracer.prepareDebugCapture(captureIdentity.captureID)
                        MCPToolExecutionTracer.prepareDebugCapture(captureIdentity)
                        MCPToolWorkCountDiagnostics.prepareDebugCapture(captureIdentity)
                    }
                ) {
                case .started:
                    break
                case .busy:
                    await fixture.cleanup()
                    return XCTFail("Read-file capture should start")
                }

                do {
                    let endpoint = try fixture.endpointA()
                    _ = try await endpoint.callTool(
                        name: MCPWindowToolName.readFile,
                        arguments: [
                            "path": fixture.contextA.fileURL.path,
                            "context_id": fixture.contextA.tabID.uuidString
                        ]
                    )
                    let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
                    let readCorrelationID = try XCTUnwrap(snapshot.lifecycleEvents.first {
                        $0.eventName == "MCP.ToolCall.Received"
                    }?.correlationID)
                    let readEvents = snapshot.lifecycleEvents.filter {
                        $0.correlationID == readCorrelationID
                    }
                    let observedEvents = readEvents.map(\.eventName).joined(separator: ",")
                    XCTAssertTrue(
                        readEvents.contains { $0.eventName == "ReadFile.ProviderEntered" },
                        observedEvents
                    )
                    XCTAssertTrue(
                        readEvents.contains { $0.eventName == "ReadFile.PathClassified" },
                        observedEvents
                    )
                    XCTAssertTrue(
                        readEvents.contains { $0.eventName == "ReadFile.GitPreflightEnded" },
                        observedEvents
                    )
                    XCTAssertTrue(
                        readEvents.contains { $0.eventName == "ReadFile.ProviderResultReady" },
                        observedEvents
                    )
                    XCTAssertTrue(readEvents.allSatisfy {
                        !$0.sanitizedDimensions.contains(fixture.contextA.fileURL.path)
                    })
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testGitPreflightEarlyTabResolutionFailureDoesNotClaimOrdinaryFallthrough() async throws {
            let window = WindowState()
            let connectionID = UUID()
            let pathCanary = "_git_data/private-path-canary-7D19C4.patch"
            let errorCanary = "private-error-canary-7D19C4"
            EditFlowPerf.resetDebugCaptureForTesting()
            defer { EditFlowPerf.resetDebugCaptureForTesting() }
            guard case .started = EditFlowPerf.beginDebugCapture(
                label: "git-preflight-unresolved-context",
                maxSamples: 64,
                toolFilter: .readFile
            ) else {
                return XCTFail("Read-file capture should start")
            }
            let requestIdentity = MCPRequestTimelineIdentity(
                jsonRPCRequestID: .string("git-preflight-unresolved"),
                connectionID: connectionID.uuidString,
                connectionGeneration: 1,
                appInvocationID: UUID().uuidString,
                requestOrdinal: 1
            )
            let correlation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive(
                requestIdentity: requestIdentity,
                toolName: "read_file"
            ))
            let metadata = MCPServerViewModel.RequestMetadata(
                connectionID: connectionID,
                clientName: errorCanary,
                windowID: Int.max,
                runPurpose: .agentModeRun
            )

            let reply = try await EditFlowPerf.$currentLifecycleCorrelation.withValue(correlation) {
                try await window.mcpServer.readSelectedAuthorizedGitArtifactForTesting(
                    requestedPath: pathCanary,
                    translatedLookupPath: pathCanary,
                    metadata: metadata
                )
            }
            XCTAssertNil(reply)

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            let ended = try XCTUnwrap(snapshot.lifecycleEvents.last {
                $0.eventName == "ReadFile.GitPreflightEnded"
            })
            XCTAssertTrue(ended.sanitizedDimensions.contains("gitClassification=syntactic_git"))
            XCTAssertTrue(ended.sanitizedDimensions.contains("gitCapability=not_evaluated"))
            XCTAssertTrue(ended.sanitizedDimensions.contains("gitPreflightStatus=failed"))
            XCTAssertTrue(ended.sanitizedDimensions.contains("outcome=not_evaluated"))
            XCTAssertFalse(ended.sanitizedDimensions.contains("gitClassification=ordinary"))
            XCTAssertFalse(ended.sanitizedDimensions.contains("outcome=no_requested_match"))
            XCTAssertFalse(ended.sanitizedDimensions.contains(pathCanary))
            XCTAssertFalse(ended.sanitizedDimensions.contains(errorCanary))
        }

        func testBoundedWindowAndGlobalDispatchBranchesReturnOneTimeoutAndKeepConnectionUsable() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let recorder = MCPExecutionTraceRecorder()
                let manager = fixture.networkManager
                let cases: [(
                    label: String,
                    toolName: String,
                    arguments: [String: Any]
                )] = [
                    (
                        label: "window-scoped read_file",
                        toolName: MCPWindowToolName.readFile,
                        arguments: [
                            "path": fixture.contextA.fileURL.path,
                            "context_id": fixture.contextA.tabID.uuidString
                        ]
                    ),
                    (
                        label: "global app_settings",
                        toolName: MCPGlobalToolName.appSettings,
                        arguments: [
                            "op": "get",
                            "key": "ui.appearance_mode"
                        ]
                    )
                ]
                var appSettingsScope: MCPAppSettingsServiceScope?
                var activeToolName: String?
                var activeGate: MCPExecutionCooperativeCancellationGate?
                var activeResponseTask: Task<PersistentMCPTestRPCResponse, Error>?

                MCPToolExecutionTracer.setTestSink { recorder.append($0) }
                do {
                    let installedAppSettingsScope = try await MCPAppSettingsServiceScope.install()
                    appSettingsScope = installedAppSettingsScope
                    let endpoint = try fixture.endpointA()
                    for testCase in cases {
                        let clock = ExecutionWatchdogManualClock()
                        let cooperativeGate = MCPExecutionCooperativeCancellationGate()
                        activeToolName = testCase.toolName
                        activeGate = cooperativeGate
                        await manager.debugSetToolExecutionWatchdogEnvironment(clock.environment)
                        await manager.debugSetResolvedToolOperationOverride(toolName: testCase.toolName) {
                            try await cooperativeGate.enterAndWait()
                            return .null
                        }

                        let responseTask = Task {
                            try await endpoint.callTool(
                                name: testCase.toolName,
                                arguments: testCase.arguments
                            )
                        }
                        activeResponseTask = responseTask
                        try await clock.waitForSleeperCount(1)
                        let sleeperCount = await clock.sleeperCount()
                        XCTAssertEqual(sleeperCount, 1, testCase.label)
                        try await cooperativeGate.waitUntilEntered()
                        try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolExecutionDeadline)

                        let response = try await responseTask.value
                        activeResponseTask = nil
                        let cancellationCount = await cooperativeGate.observedCancellationCount()
                        XCTAssertEqual(cancellationCount, 1, testCase.label)
                        let text = try Self.toolResultText(response)
                        XCTAssertEqual(
                            text.components(separatedBy: "tool_execution_timeout").count - 1,
                            1,
                            "\(testCase.label): \(text)"
                        )
                        let isTerminal = await manager.debugIsExecutionWatchdogTerminal(connectionID: endpoint.connectionID)
                        XCTAssertFalse(isTerminal, testCase.label)

                        let events = recorder.snapshot().filter {
                            $0.connectionID == endpoint.connectionID && $0.toolName == testCase.toolName
                        }
                        XCTAssertEqual(events.count(where: { $0.phase == .contractSelected }), 1, testCase.label)
                        XCTAssertEqual(events.count(where: { $0.phase == .deadlineExpired }), 1, testCase.label)
                        let selected = try XCTUnwrap(
                            events.first { $0.phase == .contractSelected },
                            testCase.label
                        )
                        XCTAssertEqual(selected.contractKind, .bounded, testCase.label)
                        XCTAssertEqual(
                            selected.executionDeadlineSeconds,
                            Double(MCPTimeoutPolicy.boundedToolExecutionDeadlineSeconds),
                            testCase.label
                        )

                        await manager.debugSetResolvedToolOperationOverride(toolName: testCase.toolName, operation: nil)
                        await manager.debugResetToolExecutionWatchdogEnvironment()
                        activeToolName = nil
                        activeGate = nil
                    }

                    MCPToolExecutionTracer.setTestSink(nil)
                    let appSettingsResponse = try await endpoint.callTool(
                        name: MCPGlobalToolName.appSettings,
                        arguments: [
                            "op": "get",
                            "key": "ui.appearance_mode",
                            "_rawJSON": true
                        ]
                    )
                    let appSettingsPayload = try Self.toolResultObject(appSettingsResponse)
                    XCTAssertEqual(appSettingsPayload["op"] as? String, "get")
                    XCTAssertEqual(appSettingsPayload["status"] as? String, "ok")
                    XCTAssertEqual((appSettingsPayload["count"] as? NSNumber)?.intValue, 1)
                    let appSettingsValues = try XCTUnwrap(appSettingsPayload["values"] as? [String: Any])
                    XCTAssertNotNil(appSettingsValues["ui.appearance_mode"])

                    _ = try await endpoint.client.request(method: "tools/list", params: [:])
                    let readFileResponse = try await endpoint.callTool(
                        name: MCPWindowToolName.readFile,
                        arguments: [
                            "path": fixture.contextA.fileURL.path,
                            "context_id": fixture.contextA.tabID.uuidString
                        ]
                    )
                    let readFileText = try Self.toolResultText(readFileResponse)
                    XCTAssertTrue(readFileText.contains(fixture.contextA.sentinel), readFileText)
                    let finalInFlight = await manager.hasInFlightCalls(for: endpoint.connectionID)
                    XCTAssertFalse(finalInFlight)
                    let limiter = await manager.connectionLimiterSnapshotForTesting(connectionID: endpoint.connectionID)
                    XCTAssertEqual(limiter?.permits, 1)
                    XCTAssertEqual(limiter?.waiterCount, 0)
                    XCTAssertEqual(limiter?.inFlight, 0)

                    await installedAppSettingsScope.restore()
                    await installedAppSettingsScope.assertRestored()
                    appSettingsScope = nil
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    await activeGate?.cancelForCleanup()
                    activeResponseTask?.cancel()
                    if let activeResponseTask {
                        _ = try? await activeResponseTask.value
                    }
                    MCPToolExecutionTracer.setTestSink(nil)
                    if let activeToolName {
                        await manager.debugSetResolvedToolOperationOverride(toolName: activeToolName, operation: nil)
                    }
                    for testCase in cases {
                        await manager.debugSetResolvedToolOperationOverride(toolName: testCase.toolName, operation: nil)
                    }
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    if let appSettingsScope {
                        await appSettingsScope.restore()
                        await appSettingsScope.assertRestored()
                    }
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testManageWorkspacesSwitchTimeoutReleasesPermitAndKeepsConnectionUsable() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let clock = ExecutionWatchdogManualClock()
                let operationGate = MCPExecutionCooperativeCancellationGate()
                let recorder = MCPExecutionTraceRecorder()
                let manager = fixture.networkManager
                let clientName = "manage-workspaces-cooperative-\(UUID().uuidString)"
                var endpoint: PersistentMCPTestEndpoint?
                var responseTask: Task<PersistentMCPTestRPCResponse, Error>?

                MCPToolExecutionTracer.setTestSink { recorder.append($0) }
                await manager.installClientConnectionPolicy(
                    for: clientName,
                    windowID: fixture.contextA.window.windowID,
                    restrictedTools: [],
                    tabID: fixture.contextA.tabID,
                    runID: UUID(),
                    additionalTools: [MCPGlobalToolName.manageWorkspaces],
                    purpose: .agentModeRun
                )
                await manager.debugSetToolExecutionWatchdogEnvironment(clock.environment)
                await manager.debugSetResolvedToolOperationOverride(toolName: MCPGlobalToolName.manageWorkspaces) {
                    try await operationGate.enterAndWait()
                    return .null
                }

                do {
                    let createdEndpoint = try await PersistentMCPTestEndpoint.make(
                        label: "manage-workspaces-cooperative",
                        networkManager: manager,
                        clientName: clientName,
                        requiredToolNames: [MCPGlobalToolName.manageWorkspaces]
                    )
                    endpoint = createdEndpoint
                    let activeResponseTask = Task {
                        try await createdEndpoint.callTool(
                            name: MCPGlobalToolName.manageWorkspaces,
                            arguments: [
                                "action": "switch",
                                "workspace": fixture.contextA.workspaceID.uuidString,
                                "window_id": fixture.contextA.window.windowID
                            ]
                        )
                    }
                    responseTask = activeResponseTask
                    try await clock.waitForSleeperCount(1)
                    try await operationGate.waitUntilEntered()
                    try await clock.advanceNext(expected: MCPTimeoutPolicy.workspaceSwitchToolExecutionDeadline)

                    let response = try await activeResponseTask.value
                    responseTask = nil
                    let cancellationCount = await operationGate.observedCancellationCount()
                    XCTAssertEqual(cancellationCount, 1)
                    let text = try Self.toolResultText(response)
                    XCTAssertEqual(text.components(separatedBy: "tool_execution_timeout").count - 1, 1, text)
                    XCTAssertTrue(text.contains("120-second execution contract"), text)

                    let events = recorder.snapshot().filter {
                        $0.connectionID == createdEndpoint.connectionID
                            && $0.toolName == MCPGlobalToolName.manageWorkspaces
                    }
                    let selected = try XCTUnwrap(events.first { $0.phase == .contractSelected })
                    XCTAssertEqual(selected.contractKind, .bounded)
                    XCTAssertEqual(
                        selected.executionDeadlineSeconds,
                        Double(MCPTimeoutPolicy.workspaceSwitchToolExecutionDeadlineSeconds)
                    )
                    XCTAssertEqual(
                        selected.cleanupGraceSeconds,
                        Double(MCPTimeoutPolicy.boundedToolCancellationCleanupGraceSeconds)
                    )
                    XCTAssertEqual(events.count(where: { $0.phase == .deadlineExpired }), 1)
                    let isTerminal = await manager.debugIsExecutionWatchdogTerminal(
                        connectionID: createdEndpoint.connectionID
                    )
                    XCTAssertFalse(isTerminal)

                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPGlobalToolName.manageWorkspaces,
                        operation: nil
                    )
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    MCPToolExecutionTracer.setTestSink(nil)

                    let listResponse = try await createdEndpoint.callTool(
                        name: MCPGlobalToolName.manageWorkspaces,
                        arguments: ["action": "list"]
                    )
                    let listText = try Self.toolResultText(listResponse)
                    XCTAssertFalse(listText.contains("tool_execution_timeout"), listText)
                    _ = try await createdEndpoint.client.request(method: "tools/list", params: [:])
                    let limiter = await manager.connectionLimiterSnapshotForTesting(
                        connectionID: createdEndpoint.connectionID
                    )
                    XCTAssertEqual(limiter?.permits, 1)
                    XCTAssertEqual(limiter?.waiterCount, 0)
                    XCTAssertEqual(limiter?.inFlight, 0)

                    await Self.cleanupEndpoint(createdEndpoint, manager: manager)
                    endpoint = nil
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    await operationGate.cancelForCleanup()
                    responseTask?.cancel()
                    if let responseTask {
                        _ = try? await responseTask.value
                    }
                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPGlobalToolName.manageWorkspaces,
                        operation: nil
                    )
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    if let endpoint {
                        await Self.cleanupEndpoint(endpoint, manager: manager)
                    }
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testManageWorkspacesCreateDeleteAndListSelectExactContracts() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let recorder = MCPExecutionTraceRecorder()
                let manager = fixture.networkManager
                let clientName = "manage-workspaces-classification-\(UUID().uuidString)"
                let cases: [(label: String, arguments: [String: Any], isBounded: Bool)] = [
                    ("create default", ["action": "create"], true),
                    ("create true", ["action": "create", "switch_to_created": true], true),
                    ("create false", ["action": "create", "switch_to_created": false], false),
                    ("delete close", ["action": "delete", "close_window": true], true),
                    ("delete default", ["action": "delete"], false),
                    ("delete no close", ["action": "delete", "close_window": false], false),
                    ("list", ["action": "list"], false)
                ]
                var endpoint: PersistentMCPTestEndpoint?
                var activeGate: MCPExecutionIgnoringCancellationGate?
                var activeResponseTask: Task<PersistentMCPTestRPCResponse, Error>?

                MCPToolExecutionTracer.setTestSink { recorder.append($0) }
                await manager.installClientConnectionPolicy(
                    for: clientName,
                    windowID: fixture.contextA.window.windowID,
                    restrictedTools: [],
                    tabID: fixture.contextA.tabID,
                    runID: UUID(),
                    additionalTools: [MCPGlobalToolName.manageWorkspaces],
                    purpose: .agentModeRun
                )
                do {
                    let createdEndpoint = try await PersistentMCPTestEndpoint.make(
                        label: "manage-workspaces-classification",
                        networkManager: manager,
                        clientName: clientName,
                        requiredToolNames: [MCPGlobalToolName.manageWorkspaces]
                    )
                    endpoint = createdEndpoint
                    for (index, testCase) in cases.enumerated() {
                        let clock = ExecutionWatchdogManualClock()
                        let operationGate = MCPExecutionIgnoringCancellationGate()
                        activeGate = operationGate
                        let label = testCase.label
                        await manager.debugSetToolExecutionWatchdogEnvironment(clock.environment)
                        await manager.debugSetResolvedToolOperationOverride(toolName: MCPGlobalToolName.manageWorkspaces) {
                            await operationGate.enterAndWait()
                            return .object([
                                "action": .string(label),
                                "status": .string("ok")
                            ])
                        }

                        var arguments = testCase.arguments
                        arguments["window_id"] = fixture.contextA.window.windowID
                        let responseTask = Task {
                            try await createdEndpoint.callTool(
                                name: MCPGlobalToolName.manageWorkspaces,
                                arguments: arguments
                            )
                        }
                        activeResponseTask = responseTask
                        try await operationGate.waitUntilEntered(count: 1)
                        if testCase.isBounded {
                            try await clock.waitForSleeperCount(1)
                        } else {
                            for _ in 0 ..< 20 {
                                await Task.yield()
                            }
                            let sleeperCount = await clock.sleeperCount()
                            XCTAssertEqual(sleeperCount, 0, testCase.label)
                        }

                        let selectedEvents = recorder.snapshot().filter {
                            $0.connectionID == createdEndpoint.connectionID
                                && $0.toolName == MCPGlobalToolName.manageWorkspaces
                                && $0.phase == .contractSelected
                        }
                        XCTAssertEqual(selectedEvents.count, index + 1, testCase.label)
                        let selected = try XCTUnwrap(selectedEvents.last, testCase.label)
                        XCTAssertEqual(
                            selected.contractKind,
                            testCase.isBounded ? .bounded : .workspaceLifecycleCancellable,
                            testCase.label
                        )
                        XCTAssertEqual(
                            selected.executionDeadlineSeconds,
                            testCase.isBounded
                                ? Double(MCPTimeoutPolicy.workspaceSwitchToolExecutionDeadlineSeconds)
                                : nil,
                            testCase.label
                        )

                        await operationGate.release()
                        _ = try await responseTask.value
                        activeResponseTask = nil
                        activeGate = nil
                        await manager.debugSetResolvedToolOperationOverride(
                            toolName: MCPGlobalToolName.manageWorkspaces,
                            operation: nil
                        )
                        await manager.debugResetToolExecutionWatchdogEnvironment()
                    }

                    MCPToolExecutionTracer.setTestSink(nil)
                    let terminal = await manager.debugIsExecutionWatchdogTerminal(
                        connectionID: createdEndpoint.connectionID
                    )
                    XCTAssertFalse(terminal)
                    await Self.cleanupEndpoint(createdEndpoint, manager: manager)
                    endpoint = nil
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    await activeGate?.release()
                    activeResponseTask?.cancel()
                    if let activeResponseTask {
                        _ = try? await activeResponseTask.value
                    }
                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPGlobalToolName.manageWorkspaces,
                        operation: nil
                    )
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    if let endpoint {
                        await Self.cleanupEndpoint(endpoint, manager: manager)
                    }
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testUncooperativeManageWorkspacesSwitchForceDisconnectsAndBlocksQueuedProviderEntry() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let clock = ExecutionWatchdogManualClock()
                let operationGate = MCPExecutionIgnoringCancellationGate()
                let recorder = MCPExecutionTraceRecorder()
                let manager = fixture.networkManager
                let clientName = "manage-workspaces-uncooperative-\(UUID().uuidString)"
                var endpoint: PersistentMCPTestEndpoint?

                MCPToolExecutionTracer.setTestSink { recorder.append($0) }
                await manager.installClientConnectionPolicy(
                    for: clientName,
                    windowID: fixture.contextA.window.windowID,
                    restrictedTools: [],
                    tabID: fixture.contextA.tabID,
                    runID: UUID(),
                    additionalTools: [MCPGlobalToolName.manageWorkspaces],
                    purpose: .agentModeRun
                )
                await manager.debugSetToolExecutionWatchdogEnvironment(clock.environment)
                await manager.debugSetResolvedToolOperationOverride(toolName: MCPGlobalToolName.manageWorkspaces) {
                    await operationGate.enterAndWait()
                    return .null
                }

                do {
                    let createdEndpoint = try await PersistentMCPTestEndpoint.make(
                        label: "manage-workspaces-uncooperative",
                        networkManager: manager,
                        clientName: clientName,
                        requiredToolNames: [MCPGlobalToolName.manageWorkspaces]
                    )
                    endpoint = createdEndpoint
                    let first = Task {
                        try await createdEndpoint.callTool(
                            name: MCPGlobalToolName.manageWorkspaces,
                            arguments: [
                                "action": "switch",
                                "workspace": fixture.contextA.workspaceID.uuidString,
                                "window_id": fixture.contextA.window.windowID
                            ]
                        )
                    }
                    try await clock.waitForSleeperCount(1)
                    try await operationGate.waitUntilEntered(count: 1)

                    let queued = Task {
                        try await createdEndpoint.callTool(
                            name: MCPGlobalToolName.manageWorkspaces,
                            arguments: [
                                "action": "list",
                                "window_id": fixture.contextA.window.windowID
                            ]
                        )
                    }
                    for _ in 0 ..< 1000 {
                        let waiterCount = await manager.connectionLimiterSnapshotForTesting(
                            connectionID: createdEndpoint.connectionID
                        )?.waiterCount
                        if waiterCount == 1 { break }
                        await Task.yield()
                    }
                    let queuedLimiter = await manager.connectionLimiterSnapshotForTesting(
                        connectionID: createdEndpoint.connectionID
                    )
                    XCTAssertEqual(queuedLimiter?.waiterCount, 1)

                    try await clock.advanceNext(expected: MCPTimeoutPolicy.workspaceSwitchToolExecutionDeadline)
                    try await clock.waitForSleeperCount(1)
                    try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolCancellationCleanupGrace)

                    await Self.assertSocketClosed(first)
                    await Self.assertSocketClosed(queued)
                    let enteredCount = await operationGate.enteredCount()
                    let isTerminal = await manager.debugIsExecutionWatchdogTerminal(
                        connectionID: createdEndpoint.connectionID
                    )
                    XCTAssertEqual(enteredCount, 1)
                    XCTAssertTrue(isTerminal)

                    let events = recorder.snapshot().filter {
                        $0.connectionID == createdEndpoint.connectionID
                            && $0.toolName == MCPGlobalToolName.manageWorkspaces
                    }
                    let selected = try XCTUnwrap(events.first { $0.phase == .contractSelected })
                    XCTAssertEqual(
                        selected.executionDeadlineSeconds,
                        Double(MCPTimeoutPolicy.workspaceSwitchToolExecutionDeadlineSeconds)
                    )
                    XCTAssertFalse(events.contains { $0.phase == .handlerCompleted })
                    XCTAssertTrue(events.contains { $0.phase == .cleanupGraceExpired })
                    XCTAssertTrue(events.contains { $0.phase == .connectionForceDisconnectRequested })

                    await operationGate.release()
                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPGlobalToolName.manageWorkspaces,
                        operation: nil
                    )
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    await Self.cleanupEndpoint(createdEndpoint, manager: manager)
                    endpoint = nil
                    await fixture.cleanup()
                } catch {
                    await operationGate.release()
                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPGlobalToolName.manageWorkspaces,
                        operation: nil
                    )
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    if let endpoint {
                        await Self.cleanupEndpoint(endpoint, manager: manager)
                    }
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testRealManageSelectionDrainTimeoutSettlesDuringGraceAndKeepsQueuedCallUsable() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let clock = ExecutionWatchdogManualClock()
                let gate = MCPExecutionIgnoringCancellationGate()
                let recorder = MCPExecutionTraceRecorder()
                let manager = fixture.networkManager
                let server = fixture.contextA.window.mcpServer
                var endpoint: PersistentMCPTestEndpoint?
                var manageTask: Task<PersistentMCPTestRPCResponse, Error>?
                var queuedReadTask: Task<PersistentMCPTestRPCResponse, Error>?

                MCPToolExecutionTracer.setTestSink { recorder.append($0) }
                server.setReadFileAutoSelectionCanonicalApplyGateForTesting {
                    await gate.enterAndWait()
                }
                do {
                    let clientName = "real-manage-selection-watchdog-\(UUID().uuidString)"
                    await manager.installClientConnectionPolicy(
                        for: clientName,
                        windowID: fixture.contextA.window.windowID,
                        restrictedTools: [],
                        tabID: fixture.contextA.tabID,
                        runID: UUID(),
                        additionalTools: [],
                        purpose: .agentModeRun
                    )
                    let createdEndpoint = try await PersistentMCPTestEndpoint.make(
                        label: "real-manage-selection-watchdog",
                        networkManager: manager,
                        clientName: clientName,
                        requiredToolNames: [
                            MCPWindowToolName.readFile,
                            MCPWindowToolName.manageSelection
                        ]
                    )
                    endpoint = createdEndpoint
                    let readTask = Task {
                        try await createdEndpoint.callTool(
                            name: MCPWindowToolName.readFile,
                            arguments: ["path": fixture.contextA.fileURL.path]
                        )
                    }
                    try await gate.waitUntilEntered(count: 1)
                    _ = try await readTask.value

                    await manager.debugSetToolExecutionWatchdogEnvironment(clock.environment)
                    let activeManageTask = Task {
                        try await createdEndpoint.callTool(
                            name: MCPWindowToolName.manageSelection,
                            arguments: ["op": "get"]
                        )
                    }
                    manageTask = activeManageTask
                    try await clock.waitForSleeperCount(1)
                    let waiterRegistered = await Self.waitUntil {
                        server.readFileAutoSelectionDiagnosticsSnapshot().canonicalWaiterCount == 1
                    }
                    XCTAssertTrue(waiterRegistered)

                    let activeQueuedReadTask = Task {
                        try await createdEndpoint.callTool(
                            name: MCPWindowToolName.readFile,
                            arguments: ["path": fixture.contextA.fileURL.path]
                        )
                    }
                    queuedReadTask = activeQueuedReadTask
                    let queuedReadResponse = try await activeQueuedReadTask.value
                    queuedReadTask = nil
                    let queuedReadText = try Self.toolResultText(queuedReadResponse)
                    XCTAssertTrue(queuedReadText.contains(fixture.contextA.sentinel), queuedReadText)

                    try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolExecutionDeadline)
                    let timeoutResponse = try await activeManageTask.value
                    manageTask = nil
                    let timeoutText = try Self.toolResultText(timeoutResponse)
                    XCTAssertEqual(timeoutText.components(separatedBy: "tool_execution_timeout").count - 1, 1, timeoutText)
                    XCTAssertEqual(server.readFileAutoSelectionDiagnosticsSnapshot().canonicalWaiterCount, 0)
                    XCTAssertEqual(server.readFileAutoSelectionDiagnosticsSnapshot().canonicalWorkerCount, 1)

                    let isTerminal = await manager.debugIsExecutionWatchdogTerminal(connectionID: createdEndpoint.connectionID)
                    XCTAssertFalse(isTerminal)
                    let events = recorder.snapshot().filter {
                        $0.connectionID == createdEndpoint.connectionID
                            && $0.toolName == MCPWindowToolName.manageSelection
                    }
                    XCTAssertTrue(events.contains { $0.phase == .deadlineExpired })
                    XCTAssertFalse(events.contains { $0.phase == .cleanupGraceExpired })
                    XCTAssertFalse(events.contains { $0.phase == .connectionForceDisconnectRequested })

                    await gate.release()
                    server.setReadFileAutoSelectionCanonicalApplyGateForTesting(nil)
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    _ = try await createdEndpoint.callTool(
                        name: MCPWindowToolName.manageSelection,
                        arguments: ["op": "get"]
                    )
                    _ = try await createdEndpoint.client.request(method: "tools/list", params: [:])

                    MCPToolExecutionTracer.setTestSink(nil)
                    await Self.cleanupEndpoint(createdEndpoint, manager: manager)
                    endpoint = nil
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    manageTask?.cancel()
                    queuedReadTask?.cancel()
                    await gate.release()
                    server.setReadFileAutoSelectionCanonicalApplyGateForTesting(nil)
                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    if let manageTask { _ = try? await manageTask.value }
                    if let queuedReadTask { _ = try? await queuedReadTask.value }
                    if let endpoint { await Self.cleanupEndpoint(endpoint, manager: manager) }
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testRealFileActionTimeoutDetachesIOReconcilesCatalogAndKeepsQueuedCallUsable() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let clock = ExecutionWatchdogManualClock()
                let mutationIOFence = TestBlockingFence(name: "file_actions blocking mutation I/O")
                let recorder = MCPExecutionTraceRecorder()
                let manager = fixture.networkManager
                let store = fixture.contextA.window.workspaceFileContextStore
                try await store.startWatchingRoot(id: fixture.contextA.rootID)
                let loadedService = await store.fileSystemServiceForTesting(rootID: fixture.contextA.rootID)
                let service = try XCTUnwrap(loadedService)
                let createdRelativePath = "Pending/CreatedAfterWatchdog.swift"
                let createdURL = fixture.contextA.rootURL.appendingPathComponent(createdRelativePath)
                let createdContent = String(
                    repeating: "struct CreatedAfterWatchdogPayload {}\n",
                    count: 8192
                )
                var fileActionTask: Task<PersistentMCPTestRPCResponse, Error>?
                var queuedReadTask: Task<PersistentMCPTestRPCResponse, Error>?
                let initialMonitorCompletionCount = await service.mutationMonitorCompletionCountForTesting()

                MCPToolExecutionTracer.setTestSink { recorder.append($0) }
                await service.setMutationIOWillExecuteHandlerForTesting { operation in
                    guard operation == .create else { return }
                    mutationIOFence.enterAndWait()
                }
                do {
                    let endpoint = try fixture.endpointA()
                    try await Self.activateWorkspace(for: fixture.contextA)
                    _ = try await endpoint.callTool(
                        name: "bind_context",
                        arguments: [
                            "op": "bind",
                            "context_id": fixture.contextA.tabID.uuidString
                        ]
                    )
                    await manager.debugSetToolExecutionWatchdogEnvironment(clock.environment)
                    let activeFileActionTask = Task {
                        try await endpoint.callTool(
                            name: MCPWindowToolName.fileActions,
                            arguments: [
                                "action": "create",
                                "path": createdURL.path,
                                "content": createdContent,
                                "if_exists": "overwrite"
                            ]
                        )
                    }
                    fileActionTask = activeFileActionTask
                    try await clock.waitForSleeperCount(1)
                    let mutationIOEntered = await Task.detached {
                        mutationIOFence.waitUntilEntered()
                    }.value
                    XCTAssertTrue(mutationIOEntered)
                    let waiterRegistered = await Self.waitUntil {
                        let waiters = await service.pendingMutationWaiterCountForTesting()
                        let mutations = await service.pendingInFlightMutationCountForTesting()
                        return waiters == 1 && mutations == 1
                    }
                    XCTAssertTrue(waiterRegistered)

                    let activeQueuedReadTask = Task {
                        try await endpoint.callTool(
                            name: MCPWindowToolName.readFile,
                            arguments: ["path": fixture.contextA.fileURL.path]
                        )
                    }
                    queuedReadTask = activeQueuedReadTask
                    let queuedReadResponse = try await activeQueuedReadTask.value
                    queuedReadTask = nil
                    let queuedReadText = try Self.toolResultText(queuedReadResponse)
                    XCTAssertTrue(queuedReadText.contains(fixture.contextA.sentinel), queuedReadText)

                    try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolExecutionDeadline)
                    let timeoutResponse = try await activeFileActionTask.value
                    fileActionTask = nil
                    let timeoutText = try Self.toolResultText(timeoutResponse)
                    XCTAssertEqual(timeoutText.components(separatedBy: "tool_execution_timeout").count - 1, 1, timeoutText)
                    let pendingWaiters = await service.pendingMutationWaiterCountForTesting()
                    XCTAssertEqual(pendingWaiters, 0)
                    let pendingMutations = await service.pendingInFlightMutationCountForTesting()
                    XCTAssertEqual(pendingMutations, 1)
                    XCTAssertFalse(FileManager.default.fileExists(atPath: createdURL.path))

                    do {
                        try await service.moveItemToTrash(atRelativePath: "Pending")
                        XCTFail("Expected an ancestor mutation to conflict with the detached create")
                    } catch FileSystemError.mutationInProgress {
                        // Expected: parent and descendant paths share conservative mutation authority.
                    }

                    let conflictingResponse = try await endpoint.callTool(
                        name: MCPWindowToolName.fileActions,
                        arguments: [
                            "action": "create",
                            "path": createdURL.path,
                            "content": "conflicting replay",
                            "if_exists": "overwrite"
                        ]
                    )
                    let conflictingText = try Self.toolResultText(conflictingResponse)
                    XCTAssertTrue(conflictingText.contains("conflicting filesystem mutation"), conflictingText)
                    XCTAssertFalse(conflictingText.contains("retryable"), conflictingText)

                    await service.setMutationIOWillExecuteHandlerForTesting(nil)
                    let unrelatedURL = fixture.contextA.rootURL.appendingPathComponent("UnrelatedWhilePending.swift")
                    let unrelatedResponse = try await endpoint.callTool(
                        name: MCPWindowToolName.fileActions,
                        arguments: [
                            "action": "create",
                            "path": unrelatedURL.path,
                            "content": SwiftFixtureSource.emptyStruct("UnrelatedWhilePending")
                        ]
                    )
                    let unrelatedText = try Self.toolResultText(unrelatedResponse)
                    XCTAssertTrue(unrelatedText.contains("## File Action ✅"), unrelatedText)
                    XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedURL.path))
                    let completionsAfterUnrelated = await service.mutationMonitorCompletionCountForTesting()
                    XCTAssertEqual(completionsAfterUnrelated, initialMonitorCompletionCount + 1)
                    let pendingAfterUnrelated = await service.pendingInFlightMutationCountForTesting()
                    XCTAssertEqual(pendingAfterUnrelated, 1)

                    let isTerminal = await manager.debugIsExecutionWatchdogTerminal(connectionID: endpoint.connectionID)
                    XCTAssertFalse(isTerminal)
                    let events = recorder.snapshot().filter {
                        $0.connectionID == endpoint.connectionID
                            && $0.toolName == MCPWindowToolName.fileActions
                    }
                    XCTAssertTrue(events.contains { $0.phase == .deadlineExpired })
                    XCTAssertFalse(events.contains { $0.phase == .cleanupGraceExpired })
                    XCTAssertFalse(events.contains { $0.phase == .connectionForceDisconnectRequested })

                    // Prove the persistent transport is usable after cancellation settlement while
                    // the detached mutation worker is still blocked and owns eventual reconciliation.
                    _ = try await endpoint.client.request(method: "tools/list", params: [:])

                    mutationIOFence.release()
                    let reconciled = await Self.waitUntil {
                        let mutations = await service.pendingInFlightMutationCountForTesting()
                        let monitorCompletions = await service.mutationMonitorCompletionCountForTesting()
                        guard FileManager.default.fileExists(atPath: createdURL.path),
                              mutations == 0,
                              monitorCompletions == initialMonitorCompletionCount + 2
                        else { return false }
                        return await store.file(
                            rootID: fixture.contextA.rootID,
                            relativePath: createdRelativePath
                        ) != nil
                    }
                    XCTAssertTrue(reconciled)
                    XCTAssertEqual(try String(contentsOf: createdURL, encoding: .utf8), createdContent)
                    let finalWaiters = await service.pendingMutationWaiterCountForTesting()
                    XCTAssertEqual(finalWaiters, 0)

                    await service.setMutationIOWillExecuteHandlerForTesting(nil)
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    _ = try await endpoint.client.request(method: "tools/list", params: [:])
                    MCPToolExecutionTracer.setTestSink(nil)
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    fileActionTask?.cancel()
                    queuedReadTask?.cancel()
                    mutationIOFence.release()
                    await service.setMutationIOWillExecuteHandlerForTesting(nil)
                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    if let fileActionTask { _ = try? await fileActionTask.value }
                    if let queuedReadTask { _ = try? await queuedReadTask.value }
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testUncooperativeFileActionPreMutationWorkDetachesWithoutClosingTransport() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let clock = ExecutionWatchdogManualClock()
                let gate = MCPExecutionIgnoringCancellationGate()
                let recorder = MCPExecutionTraceRecorder()
                let manager = fixture.networkManager
                var fileActionTask: Task<PersistentMCPTestRPCResponse, Error>?

                MCPToolExecutionTracer.setTestSink { recorder.append($0) }
                await manager.debugSetToolExecutionWatchdogEnvironment(clock.environment)
                await manager.debugSetResolvedToolOperationOverride(
                    toolName: MCPWindowToolName.fileActions
                ) {
                    await MCPToolExecutionHandlerPhaseContext.report(.fileActionsMutationIO)
                    await gate.enterAndWait()
                    return .null
                }

                do {
                    let endpoint = try fixture.endpointA()
                    try await Self.activateWorkspace(for: fixture.contextA)
                    _ = try await endpoint.callTool(
                        name: "bind_context",
                        arguments: [
                            "op": "bind",
                            "context_id": fixture.contextA.tabID.uuidString
                        ]
                    )
                    let activeFileActionTask = Task {
                        try await endpoint.callTool(
                            name: MCPWindowToolName.fileActions,
                            arguments: [
                                "action": "create",
                                "path": fixture.contextA.rootURL
                                    .appendingPathComponent("PreMutationDetached.swift")
                                    .path,
                                "content": String(repeating: "0123456789abcdef", count: 512),
                                "if_exists": "overwrite",
                                "_rawJSON": true
                            ]
                        )
                    }
                    fileActionTask = activeFileActionTask
                    try await clock.waitForSleeperCount(1)
                    try await gate.waitUntilEntered(count: 1)

                    try await clock.advanceNext(
                        expected: MCPTimeoutPolicy.boundedToolExecutionDeadline
                    )
                    try await clock.waitForSleeperCount(1)
                    try await clock.advanceNext(
                        expected: MCPTimeoutPolicy.boundedToolCancellationCleanupGrace
                    )

                    let timeoutPayload = try await Self.toolResultObject(
                        activeFileActionTask.value
                    )
                    fileActionTask = nil
                    XCTAssertEqual(timeoutPayload["code"] as? String, "tool_execution_timeout")
                    XCTAssertEqual(timeoutPayload["settlement"] as? String, "detached")
                    XCTAssertEqual(timeoutPayload["retryable"] as? Bool, false)
                    XCTAssertTrue(
                        (timeoutPayload["error"] as? String)?
                            .contains("Inspect the filesystem") == true
                    )
                    let connectionIsTerminal = await manager.debugIsExecutionWatchdogTerminal(
                        connectionID: endpoint.connectionID
                    )
                    XCTAssertFalse(connectionIsTerminal)

                    let treeResponse = try await endpoint.callTool(
                        name: MCPWindowToolName.getFileTree,
                        arguments: [
                            "path": fixture.contextA.rootURL.path,
                            "max_depth": 1,
                            "context_id": fixture.contextA.tabID.uuidString
                        ]
                    )
                    let treeText = try Self.toolResultText(treeResponse)
                    XCTAssertFalse(treeText.contains("tool_execution_timeout"), treeText)
                    XCTAssertFalse(treeText.contains("settlement_busy"), treeText)
                    _ = try await endpoint.client.request(method: "tools/list", params: [:])

                    let events = recorder.snapshot().filter {
                        $0.connectionID == endpoint.connectionID
                            && $0.toolName == MCPWindowToolName.fileActions
                    }
                    XCTAssertTrue(events.contains { $0.phase == .deadlineExpired })
                    XCTAssertTrue(events.contains {
                        $0.phase == .cleanupGraceExpired
                            && $0.cleanupDisposition == .detachAndSettle
                    })
                    XCTAssertTrue(events.contains { $0.phase == .detachedForSettlement })
                    XCTAssertFalse(events.contains {
                        $0.phase == .connectionForceDisconnectRequested
                    })

                    await gate.release()
                    let detachedSettled = await Self.waitUntil {
                        recorder.snapshot().contains {
                            $0.connectionID == endpoint.connectionID
                                && $0.toolName == MCPWindowToolName.fileActions
                                && $0.phase == .detachedSettled
                        }
                    }
                    XCTAssertTrue(detachedSettled)

                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPWindowToolName.fileActions,
                        operation: nil
                    )
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    fileActionTask?.cancel()
                    await gate.release()
                    if let fileActionTask {
                        _ = try? await fileActionTask.value
                    }
                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPWindowToolName.fileActions,
                        operation: nil
                    )
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testRealFileActionOverwriteTimeoutDetachesIOReconcilesCatalogAndKeepsQueuedCallUsable() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let clock = ExecutionWatchdogManualClock()
                let gate = MCPExecutionIgnoringCancellationGate()
                let recorder = MCPExecutionTraceRecorder()
                let manager = fixture.networkManager
                let store = fixture.contextA.window.workspaceFileContextStore
                let relativePath = "OverwriteAfterWatchdog.swift"
                let fileURL = fixture.contextA.rootURL.appendingPathComponent(relativePath)
                _ = try await store.createFile(
                    rootID: fixture.contextA.rootID,
                    relativePath: relativePath,
                    content: "old"
                )
                try await store.startWatchingRoot(id: fixture.contextA.rootID)
                let loadedService = await store.fileSystemServiceForTesting(rootID: fixture.contextA.rootID)
                let service = try XCTUnwrap(loadedService)
                var fileActionTask: Task<PersistentMCPTestRPCResponse, Error>?
                var queuedReadTask: Task<PersistentMCPTestRPCResponse, Error>?

                MCPToolExecutionTracer.setTestSink { recorder.append($0) }
                await service.setMutationIOWillBeginHandlerForTesting { operation in
                    guard operation == .edit else { return }
                    await gate.enterAndWait()
                }
                do {
                    let endpoint = try fixture.endpointA()
                    try await Self.activateWorkspace(for: fixture.contextA)
                    _ = try await endpoint.callTool(
                        name: "bind_context",
                        arguments: [
                            "op": "bind",
                            "context_id": fixture.contextA.tabID.uuidString
                        ]
                    )
                    await manager.debugSetToolExecutionWatchdogEnvironment(clock.environment)
                    let activeFileActionTask = Task {
                        try await endpoint.callTool(
                            name: MCPWindowToolName.fileActions,
                            arguments: [
                                "action": "create",
                                "path": fileURL.path,
                                "content": "new",
                                "if_exists": "overwrite"
                            ]
                        )
                    }
                    fileActionTask = activeFileActionTask
                    try await clock.waitForSleeperCount(1)
                    try await gate.waitUntilEntered(count: 1)

                    let activeQueuedReadTask = Task {
                        try await endpoint.callTool(
                            name: MCPWindowToolName.readFile,
                            arguments: ["path": fixture.contextA.fileURL.path]
                        )
                    }
                    queuedReadTask = activeQueuedReadTask
                    let queuedReadResponse = try await activeQueuedReadTask.value
                    queuedReadTask = nil
                    let queuedReadText = try Self.toolResultText(queuedReadResponse)
                    XCTAssertTrue(queuedReadText.contains(fixture.contextA.sentinel), queuedReadText)

                    try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolExecutionDeadline)
                    let timeoutResponse = try await activeFileActionTask.value
                    fileActionTask = nil
                    let timeoutText = try Self.toolResultText(timeoutResponse)
                    XCTAssertEqual(timeoutText.components(separatedBy: "tool_execution_timeout").count - 1, 1, timeoutText)
                    let pendingWaiters = await service.pendingMutationWaiterCountForTesting()
                    XCTAssertEqual(pendingWaiters, 0)
                    XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "old")

                    let isTerminal = await manager.debugIsExecutionWatchdogTerminal(connectionID: endpoint.connectionID)
                    XCTAssertFalse(isTerminal)
                    let events = recorder.snapshot().filter {
                        $0.connectionID == endpoint.connectionID
                            && $0.toolName == MCPWindowToolName.fileActions
                    }
                    XCTAssertTrue(events.contains { $0.phase == .deadlineExpired })
                    XCTAssertFalse(events.contains { $0.phase == .cleanupGraceExpired })
                    XCTAssertFalse(events.contains { $0.phase == .connectionForceDisconnectRequested })

                    await gate.release()
                    let reconciled = await Self.waitUntil {
                        guard (try? String(contentsOf: fileURL, encoding: .utf8)) == "new" else { return false }
                        return await (try? store.readContent(
                            rootID: fixture.contextA.rootID,
                            relativePath: relativePath
                        )) == "new"
                    }
                    XCTAssertTrue(reconciled)
                    let finalWaiters = await service.pendingMutationWaiterCountForTesting()
                    XCTAssertEqual(finalWaiters, 0)

                    await service.setMutationIOWillBeginHandlerForTesting(nil)
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    _ = try await endpoint.client.request(method: "tools/list", params: [:])
                    MCPToolExecutionTracer.setTestSink(nil)
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    fileActionTask?.cancel()
                    queuedReadTask?.cancel()
                    await gate.release()
                    await service.setMutationIOWillBeginHandlerForTesting(nil)
                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    if let fileActionTask { _ = try? await fileActionTask.value }
                    if let queuedReadTask { _ = try? await queuedReadTask.value }
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testReadAutoSelectionThenImmediateManageSelectionAddAndGetPreservesCanonicalOwnership() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let gate = MCPExecutionIgnoringCancellationGate()
                let server = fixture.contextA.window.mcpServer
                let store = fixture.contextA.window.workspaceFileContextStore
                let manager = fixture.networkManager
                let secondRelativePath = "Sources/ImmediateOwnership.swift"
                let secondURL = fixture.contextA.rootURL.appendingPathComponent(secondRelativePath)
                var endpoint: PersistentMCPTestEndpoint?
                _ = try await store.createFile(
                    rootID: fixture.contextA.rootID,
                    relativePath: secondRelativePath,
                    content: SwiftFixtureSource.emptyStruct("ImmediateOwnership")
                )
                server.setReadFileAutoSelectionCanonicalApplyGateForTesting {
                    await gate.enterAndWait()
                }
                do {
                    let clientName = "selection-ownership-\(UUID().uuidString)"
                    let runID = UUID()
                    await manager.installClientConnectionPolicy(
                        for: clientName,
                        windowID: fixture.contextA.window.windowID,
                        restrictedTools: [],
                        tabID: fixture.contextA.tabID,
                        runID: runID,
                        additionalTools: [],
                        purpose: .agentModeRun
                    )
                    let createdEndpoint = try await PersistentMCPTestEndpoint.make(
                        label: "selection-ownership",
                        networkManager: manager,
                        clientName: clientName,
                        requiredToolNames: [
                            MCPWindowToolName.readFile,
                            MCPWindowToolName.manageSelection
                        ]
                    )
                    endpoint = createdEndpoint
                    try await fixture.registerDomainWorkspace(fixture.contextA)
                    try await Self.activateWorkspace(for: fixture.contextA)
                    let bindResponse = try await createdEndpoint.callTool(
                        name: "bind_context",
                        arguments: ["op": "bind", "context_id": fixture.contextA.tabID.uuidString]
                    )
                    XCTAssertFalse(bindResponse.rawJSON.contains("\"isError\":true"), bindResponse.rawJSON)
                    await manager.setRunPurpose(.agentModeRun, for: createdEndpoint.connectionID)
                    await manager.debugSeedConnectionRunRouting(
                        connectionID: createdEndpoint.connectionID,
                        runID: runID,
                        purpose: .agentModeRun,
                        windowID: fixture.contextA.window.windowID
                    )
                    let registration = try await AppDomainRuntimeComposition.shared.runtime
                        .routingCoordinator.currentRegistration(connectionID: createdEndpoint.connectionID)
                    let routingOutcome = await AppDomainRuntimeComposition.shared.runtime.routingCoordinator.bind(
                        connection: registration,
                        binding: .runScoped(
                            runID: runID,
                            context: .init(
                                workspaceID: fixture.contextA.workspaceID,
                                contextID: fixture.contextA.tabID
                            )
                        ),
                        operationID: UUID()
                    )
                    XCTAssertTrue(
                        routingOutcome.disposition == .applied || routingOutcome.disposition == .unchanged,
                        routingOutcome.diagnostic ?? "Domain run routing was not established"
                    )
                    let clearResponse = try await createdEndpoint.callTool(
                        name: MCPWindowToolName.manageSelection,
                        arguments: ["op": "clear"]
                    )
                    XCTAssertFalse(clearResponse.rawJSON.contains("\"isError\":true"), clearResponse.rawJSON)
                    let readTask = Task {
                        try await createdEndpoint.callTool(
                            name: MCPWindowToolName.readFile,
                            arguments: ["path": fixture.contextA.fileURL.path]
                        )
                    }
                    try await gate.waitUntilEntered(count: 1)
                    let readResponse = try await readTask.value
                    XCTAssertFalse(readResponse.rawJSON.contains("\"isError\":true"), readResponse.rawJSON)

                    let addTask = Task {
                        try await createdEndpoint.callTool(
                            name: MCPWindowToolName.manageSelection,
                            arguments: [
                                "op": "add",
                                "paths": [secondURL.path],
                                "view": "files"
                            ]
                        )
                    }
                    let waiterRegistered = await Self.waitUntil {
                        server.readFileAutoSelectionDiagnosticsSnapshot().canonicalWaiterCount == 1
                    }
                    XCTAssertTrue(waiterRegistered)
                    await gate.release()
                    server.setReadFileAutoSelectionCanonicalApplyGateForTesting(nil)
                    let addResponse = try await addTask.value
                    XCTAssertFalse(addResponse.rawJSON.contains("\"isError\":true"), addResponse.rawJSON)

                    let getResponse = try await createdEndpoint.callTool(
                        name: MCPWindowToolName.manageSelection,
                        arguments: [
                            "op": "get",
                            "view": "files"
                        ]
                    )
                    let getText = try Self.toolResultText(getResponse)
                    XCTAssertTrue(getText.contains(fixture.contextA.fileURL.lastPathComponent), getText)
                    XCTAssertTrue(getText.contains(secondURL.lastPathComponent), getText)

                    let canonical = try XCTUnwrap(
                        server.tabContextByConnectionID[createdEndpoint.connectionID]?.selection
                    )
                    XCTAssertEqual(
                        Set(canonical.selectedPaths),
                        Set([fixture.contextA.fileURL.path, secondURL.path])
                    )
                    let mirrored = try XCTUnwrap(
                        fixture.contextA.window.workspaceManager.composeTab(with: fixture.contextA.tabID)?.selection
                    )
                    XCTAssertEqual(Set(mirrored.selectedPaths), Set(canonical.selectedPaths))

                    await Self.cleanupEndpoint(createdEndpoint, manager: manager)
                    endpoint = nil
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    await gate.release()
                    server.setReadFileAutoSelectionCanonicalApplyGateForTesting(nil)
                    if let endpoint { await Self.cleanupEndpoint(endpoint, manager: manager) }
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testWindowIDInjectionPrecedenceForDeclaredSchemas() throws {
            let manager = ServerNetworkManager.shared
            let schema = try Value(
                JSONSchema.object(
                    properties: [
                        "marker": .string(description: "Scenario marker."),
                        "window_id": .integer(description: "Effective public window identifier.")
                    ],
                    required: ["marker"]
                )
            )
            let routingWindowID = 43
            let explicitWindowID = 44

            let injected = manager.debugInjectWindowIDIfNeeded(
                schema: schema,
                routingWindowID: routingWindowID,
                args: ["marker": .string("injected")]
            )
            XCTAssertEqual(injected["marker"], .string("injected"))
            XCTAssertEqual(injected["window_id"], .int(routingWindowID))

            let explicit = manager.debugInjectWindowIDIfNeeded(
                schema: schema,
                routingWindowID: routingWindowID,
                args: [
                    "marker": .string("explicit"),
                    "window_id": .int(explicitWindowID)
                ]
            )
            XCTAssertEqual(explicit["marker"], .string("explicit"))
            XCTAssertEqual(explicit["window_id"], .int(explicitWindowID))
        }

        func testReadFileCancellationCloseAfterDeadlineBoundarySuppressesSummaryWhenLifecycleTruncated() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let clock = ExecutionWatchdogManualClock()
                let cancellationGate = MCPExecutionCooperativeCancellationGate()
                let cancellationClosed = MCPQualifiedReadCompletionProbe()
                let manager = fixture.networkManager
                EditFlowPerf.resetDebugCaptureForTesting()
                let captureID: UUID
                switch EditFlowPerf.beginDebugCapture(
                    label: "read-file-deadline-boundary",
                    maxSamples: 200,
                    expiryMilliseconds: 120_000,
                    toolFilter: .readFile,
                    prepare: { captureIdentity in
                        MCPToolExecutionTracer.prepareDebugCapture(captureIdentity)
                        MCPToolWorkCountDiagnostics.prepareDebugCapture(captureIdentity)
                    }
                ) {
                case let .started(snapshot):
                    captureID = try XCTUnwrap(snapshot.captureID)
                case .busy:
                    await fixture.cleanup()
                    return XCTFail("Read-file watchdog capture should start")
                }
                await manager.debugSetToolExecutionWatchdogEnvironment(clock.environment(
                    beforeCleanupGraceTaskRegistration: {
                        _ = try? await AsyncTestWait.waitUntil(
                            "read-file inner span closed after cancellation",
                            timeout: 10
                        ) {
                            await cancellationClosed.isCompleted()
                        }
                    }
                ))
                await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.readFile) {
                    let correlation = EditFlowPerf.currentLifecycleCorrelation
                    EditFlowPerf.lifecycleEvent(
                        EditFlowPerf.Lifecycle.ReadFile.explicitFreshnessBegan,
                        correlation: correlation
                    )
                    do {
                        try await cancellationGate.enterAndWait()
                        return .null
                    } catch {
                        EditFlowPerf.lifecycleEvent(
                            EditFlowPerf.Lifecycle.ReadFile.explicitFreshnessEnded,
                            correlation: correlation,
                            EditFlowPerf.Dimensions(outcome: "outer_cancellation", rootCount: 0)
                        )
                        await cancellationClosed.markCompleted()
                        throw error
                    }
                }
                do {
                    let endpoint = try fixture.endpointA()
                    let fixtureTimelineGeneration = UInt64.max
                    defer {
                        MCPRequestTimelineRegistry.shared.removeConnection(
                            connectionID: endpoint.connectionID.uuidString,
                            connectionGeneration: fixtureTimelineGeneration
                        )
                    }
                    let timelineFrame = try JSONSerialization.data(withJSONObject: [
                        "jsonrpc": "2.0",
                        "id": "read-file-deadline-boundary",
                        "method": "tools/call",
                        "params": [
                            "name": MCPWindowToolName.readFile,
                            "arguments": [:]
                        ]
                    ])
                    _ = MCPRequestTimelineRegistry.shared.recordAcceptedFrame(
                        timelineFrame,
                        connectionID: endpoint.connectionID.uuidString,
                        correlationConnectionID: endpoint.connectionID.uuidString,
                        connectionGeneration: fixtureTimelineGeneration
                    )
                    let responseTask = Task {
                        try await endpoint.callTool(
                            name: MCPWindowToolName.readFile,
                            arguments: [
                                "path": fixture.contextA.fileURL.path,
                                "context_id": fixture.contextA.tabID.uuidString,
                                "_rawJSON": true
                            ]
                        )
                    }
                    try await clock.waitForSleeperCount(1)
                    try await cancellationGate.waitUntilEntered()
                    try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolExecutionDeadline)

                    let response = try await responseTask.value
                    let payload = try Self.toolResultObject(response)
                    XCTAssertEqual(payload["code"] as? String, "tool_execution_timeout")
                    XCTAssertEqual(payload["cancellation_origin"] as? String, "watchdog_deadline")
                    let observedCancellationCount = await cancellationGate.observedCancellationCount()
                    XCTAssertEqual(observedCancellationCount, 1)

                    let capture = EditFlowPerf.debugCaptureSnapshot(finish: false)
                    let trace = MCPToolExecutionTracer.debugEventSnapshot(captureID)
                    let deadlineTrace = try XCTUnwrap(trace.events.first { $0.event.phase == .deadlineExpired })
                    let packet = try MCPReadFileInvocationDiagnosticPacketAssembler.packet(
                        appInvocationID: deadlineTrace.event.invocationID,
                        capture: capture,
                        trace: trace,
                        work: MCPToolWorkCountDiagnostics.debugReadFileSnapshot(captureID: captureID),
                        runtimeIdentity: MCPReadFileDiagnosticRuntimeIdentity(
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
                    )
                    XCTAssertTrue(packet.openInnerStagesAtWatchdogTerminal.isEmpty)
                    XCTAssertNil(packet.longestClosedInnerStage)
                    XCTAssertFalse(packet.requiredEvidenceComplete)
                    XCTAssertTrue(packet.lifecycle.truncated)
                    XCTAssertTrue(packet.missingRequiredEvidence.contains("lifecycle:truncated"))
                    XCTAssertEqual(packet.freshnessAuthorityIngress.openSpanCount, 0)
                    XCTAssertEqual(packet.freshnessAuthorityIngress.terminalIntegrity, "balanced")

                    let lifecycle = capture.lifecycleEvents.filter {
                        $0.requestIdentity?.appInvocationID == deadlineTrace.event.invocationID.uuidString
                    }
                    let boundary = try XCTUnwrap(lifecycle.first {
                        $0.eventName == "ReadFile.SettlementTransition"
                            && $0.sanitizedDimensions.contains("purpose=execution_deadline_cancellation_boundary")
                    })
                    let freshnessEnd = try XCTUnwrap(lifecycle.first {
                        $0.eventName == String(describing: EditFlowPerf.Lifecycle.ReadFile.explicitFreshnessEnded)
                    })
                    let lateDeadlineObservation = try XCTUnwrap(lifecycle.first {
                        $0.eventName == "ReadFile.SettlementTransition"
                            && $0.sanitizedDimensions.contains("purpose=execution_deadline_expired")
                    })
                    XCTAssertLessThan(boundary.ordinal, freshnessEnd.ordinal)
                    XCTAssertLessThan(freshnessEnd.ordinal, lateDeadlineObservation.ordinal)

                    _ = EditFlowPerf.debugCaptureSnapshot(finish: true)
                    EditFlowPerf.resetDebugCaptureForTesting()
                    MCPToolExecutionTracer.resetDebugEvents()
                    MCPToolWorkCountDiagnostics.resetForTesting()
                    await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.readFile, operation: nil)
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    await fixture.cleanup()
                } catch {
                    _ = EditFlowPerf.debugCaptureSnapshot(finish: true)
                    EditFlowPerf.resetDebugCaptureForTesting()
                    MCPToolExecutionTracer.resetDebugEvents()
                    MCPToolWorkCountDiagnostics.resetForTesting()
                    await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.readFile, operation: nil)
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testUncooperativeFileReadsDetachFirstThenForceDisconnectCompetingExpiryAndFenceQueuedCall() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let clock = ExecutionWatchdogManualClock()
                let operationGate = MCPExecutionIgnoringCancellationGate()
                let recorder = MCPExecutionTraceRecorder()
                let manager = fixture.networkManager
                EditFlowPerf.resetDebugCaptureForTesting()
                let captureID: UUID
                switch EditFlowPerf.beginDebugCapture(
                    label: "read-file-watchdog-history",
                    maxSamples: 500,
                    expiryMilliseconds: 120_000,
                    toolFilter: .readFile,
                    prepare: { captureIdentity in
                        MCPToolExecutionTracer.prepareDebugCapture(captureIdentity)
                    }
                ) {
                case let .started(snapshot):
                    captureID = try XCTUnwrap(snapshot.captureID)
                case .busy:
                    await fixture.cleanup()
                    return XCTFail("Read-file watchdog capture should start")
                }
                MCPToolExecutionTracer.setTestSink { recorder.append($0) }
                await manager.debugSetToolExecutionWatchdogEnvironment(clock.environment)
                await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.readFile) {
                    await operationGate.enterAndWait()
                    return .null
                }
                do {
                    let endpoint = try fixture.endpointA()
                    _ = await manager.debugInstallConnectionLimiterForTesting(
                        connectionID: endpoint.connectionID,
                        fileReadLimit: 2
                    )
                    let arguments: [String: Any] = [
                        "path": fixture.contextA.fileURL.path,
                        "context_id": fixture.contextA.tabID.uuidString,
                        "_rawJSON": true
                    ]
                    let first = Task {
                        try await endpoint.callTool(
                            name: MCPWindowToolName.readFile,
                            arguments: arguments
                        )
                    }
                    try await clock.waitForSleeperCount(1)
                    try await operationGate.waitUntilEntered(count: 1)

                    let second = Task {
                        try await endpoint.callTool(
                            name: MCPWindowToolName.readFile,
                            arguments: arguments
                        )
                    }
                    try await clock.waitForSleeperCount(2)
                    try await operationGate.waitUntilEntered(count: 2)

                    let competingWatchdogCallCount = 2

                    let queuedBeyondCapacity = Task {
                        try await endpoint.callTool(
                            name: MCPWindowToolName.readFile,
                            arguments: arguments
                        )
                    }
                    let capacityWaiterRegistered = await Self.waitUntil {
                        let snapshot = await manager.connectionLimiterSnapshotForTesting(
                            connectionID: endpoint.connectionID,
                            lane: .fileRead
                        )
                        return snapshot?.activePermitCount == competingWatchdogCallCount
                            && snapshot?.waiterCount == 1
                    }
                    XCTAssertTrue(capacityWaiterRegistered)
                    let queuedLimiter = await manager.connectionLimiterSnapshotForTesting(
                        connectionID: endpoint.connectionID,
                        lane: .fileRead
                    )
                    XCTAssertEqual(queuedLimiter?.activePermitCount, competingWatchdogCallCount)
                    XCTAssertEqual(queuedLimiter?.waiterCount, 1)

                    try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolExecutionDeadline)
                    try await clock.waitForSleeperCount(2)
                    try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolExecutionDeadline)
                    try await clock.waitForSleeperCount(2)
                    try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolCancellationCleanupGrace)

                    let firstPayload = try await Self.toolResultObject(first.value)
                    XCTAssertEqual(firstPayload["code"] as? String, "tool_execution_timeout")
                    XCTAssertEqual(firstPayload["settlement"] as? String, "detached")
                    XCTAssertEqual(firstPayload["retryable"] as? Bool, true)

                    let queuedPayload = try await Self.toolResultObject(queuedBeyondCapacity.value)
                    XCTAssertEqual(queuedPayload["code"] as? String, "tool_execution_structure_settlement_busy")
                    XCTAssertEqual(queuedPayload["busy_reason"] as? String, "detached_settlement_in_progress")
                    XCTAssertEqual(queuedPayload["retryable"] as? Bool, true)

                    let enteredCount = await operationGate.enteredCount()
                    let isTerminal = await manager.debugIsExecutionWatchdogTerminal(connectionID: endpoint.connectionID)
                    XCTAssertEqual(enteredCount, competingWatchdogCallCount)
                    XCTAssertFalse(isTerminal)

                    try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolCancellationCleanupGrace)
                    let didCloseSocket = await Self.waitUntil {
                        endpoint.client.isClosedForTesting()
                    }
                    XCTAssertTrue(
                        didCloseSocket,
                        "Competing expiry force-disconnect must close the underlying client socket"
                    )
                    if !didCloseSocket {
                        endpoint.client.close()
                    }
                    await Self.assertSocketClosed(second, request: "second active read")
                    let terminalAfterCompetingExpiry = await manager.debugIsExecutionWatchdogTerminal(
                        connectionID: endpoint.connectionID
                    )
                    XCTAssertTrue(terminalAfterCompetingExpiry)

                    let events = recorder.snapshot().filter {
                        $0.connectionID == endpoint.connectionID && $0.toolName == MCPWindowToolName.readFile
                    }
                    XCTAssertFalse(events.contains { $0.phase == .handlerCompleted })
                    XCTAssertEqual(events.count { $0.phase == .cleanupGraceExpired }, 2)
                    XCTAssertEqual(events.count { $0.phase == .detachedForSettlement }, 1)
                    XCTAssertEqual(events.count { $0.phase == .connectionForceDisconnectRequested }, 1)

                    await operationGate.release()
                    let detachedSettlementDiagnosticArrived = await Self.waitUntil {
                        EditFlowPerf.debugCaptureSnapshot(finish: false).lifecycleEvents.contains {
                            $0.eventName == "ReadFile.SettlementTransition"
                                && $0.sanitizedDimensions.contains("purpose=execution_detached_settled")
                                && $0.sanitizedDimensions.contains("status=settled")
                                && $0.sanitizedDimensions.contains("blocksAdmission=false")
                                && $0.sanitizedDimensions.contains("isReleased=true")
                        }
                    }
                    XCTAssertTrue(detachedSettlementDiagnosticArrived)
                    let detachedSettlementTraceArrived = await Self.waitUntil {
                        recorder.snapshot().contains { $0.phase == .detachedSettled }
                    }
                    XCTAssertTrue(detachedSettlementTraceArrived)
                    await manager.debugAwaitCodeStructureSettlementDrain(
                        windowID: fixture.contextA.window.windowID
                    )

                    let retainedTrace = MCPToolExecutionTracer.debugEventSnapshot(captureID)
                    let retainedPhases = retainedTrace.events.map(\.event.phase)
                    XCTAssertTrue(retainedPhases.contains(.deadlineExpired))
                    XCTAssertTrue(retainedPhases.contains(.cancellationRequested))
                    XCTAssertTrue(retainedPhases.contains(.cleanupGraceExpired))
                    XCTAssertTrue(retainedPhases.contains(.detachedForSettlement))
                    XCTAssertTrue(retainedPhases.contains(.detachedSettled))
                    XCTAssertTrue(retainedPhases.contains(.connectionForceDisconnectRequested))

                    let lifecycleSnapshot = EditFlowPerf.debugCaptureSnapshot(finish: false)
                    let settlementTransitions = lifecycleSnapshot.lifecycleEvents.filter {
                        $0.eventName == "ReadFile.SettlementTransition"
                    }
                    let settlementHistory = settlementTransitions
                        .map(\.sanitizedDimensions)
                        .joined(separator: "\n")
                    XCTAssertFalse(settlementHistory.contains("providerActive="), settlementHistory)
                    XCTAssertFalse(settlementHistory.contains("permitActive="), settlementHistory)
                    XCTAssertTrue(settlementTransitions.contains {
                        $0.sanitizedDimensions.contains("purpose=admission")
                            && $0.sanitizedDimensions.contains("status=reserved")
                            && $0.sanitizedDimensions.contains("blocksAdmission=false")
                            && $0.sanitizedDimensions.contains("isReleased=false")
                    }, settlementHistory)
                    XCTAssertTrue(settlementTransitions.contains {
                        $0.sanitizedDimensions.contains("purpose=busy_admission")
                            && $0.sanitizedDimensions.contains("outcome=detached")
                    }, settlementHistory)
                    XCTAssertTrue(settlementTransitions.contains {
                        $0.sanitizedDimensions.contains("purpose=execution_detached_for_settlement")
                            && $0.sanitizedDimensions.contains("status=detached")
                            && $0.sanitizedDimensions.contains("blocksAdmission=true")
                            && $0.sanitizedDimensions.contains("isReleased=false")
                    }, settlementHistory)
                    XCTAssertTrue(settlementTransitions.contains {
                        $0.sanitizedDimensions.contains("purpose=execution_detached_settled")
                            && $0.sanitizedDimensions.contains("status=settled")
                            && $0.sanitizedDimensions.contains("blocksAdmission=false")
                            && $0.sanitizedDimensions.contains("isReleased=true")
                    }, settlementHistory)
                    XCTAssertTrue(settlementTransitions.contains {
                        $0.sanitizedDimensions.contains("purpose=connection_force_disconnect_requested")
                    }, settlementHistory)
                    _ = EditFlowPerf.debugCaptureSnapshot(finish: true)
                    EditFlowPerf.resetDebugCaptureForTesting()
                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.readFile, operation: nil)
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    await fixture.cleanup()
                } catch {
                    await operationGate.release()
                    _ = EditFlowPerf.debugCaptureSnapshot(finish: true)
                    EditFlowPerf.resetDebugCaptureForTesting()
                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.readFile, operation: nil)
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testExpiredReadFileCaptureSkipsRecoveryAndDrainTransitionEnumerationBeforeLazyExpiry() throws {
            EditFlowPerf.resetDebugCaptureForTesting()
            defer { EditFlowPerf.resetDebugCaptureForTesting() }
            let clock = MCPDebugCaptureManualMonotonicClock(nowNanoseconds: 1000)
            EditFlowPerf.setDebugCaptureMonotonicNowForTesting { clock.nowNanoseconds() }
            var admittedCaptureIdentity: EditFlowPerf.DebugCaptureIdentity?
            switch EditFlowPerf.beginDebugCapture(
                label: "expired-read-file-settlement-observer",
                maxSamples: 64,
                expiryMilliseconds: 10000,
                toolFilter: .readFile,
                prepare: { admittedCaptureIdentity = $0 }
            ) {
            case .started:
                break
            case .busy:
                return XCTFail("Read-file settlement capture should start")
            }
            let captureIdentity = try XCTUnwrap(admittedCaptureIdentity)
            let invocationID = UUID()
            let connectionID = UUID()
            let requestIdentity = MCPRequestTimelineIdentity(
                jsonRPCRequestID: .string("expired-settlement-observer"),
                connectionID: connectionID.uuidString,
                connectionGeneration: 1,
                appInvocationID: invocationID.uuidString,
                requestOrdinal: 1
            )
            let correlation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive(
                requestIdentity: requestIdentity,
                toolName: MCPWindowToolName.readFile
            ))
            let registry = MCPCodeStructureSettlementRegistry()
            let originSlot: MCPCodeStructureSettlementRegistry.Slot
            switch registry.admit(
                windowID: 1,
                connectionID: connectionID,
                invocationID: invocationID,
                toolName: MCPWindowToolName.readFile,
                now: .zero,
                handlerPhase: { "executing" }
            ) {
            case let .admitted(slot):
                originSlot = slot
            case .busy:
                return XCTFail("Initial read-file settlement lease should be admitted")
            }
            defer { _ = originSlot.recordCompletion(.success) }
            let transitions = MCPSettlementTransitionEvidenceRecorder()
            let captureAccepts = try XCTUnwrap(EditFlowPerf.debugCaptureAcceptancePredicate(captureIdentity))
            originSlot.setDebugTransitionObserver(accepts: captureAccepts) { evidence in
                transitions.append(evidence)
                EditFlowPerf.lifecycleEvent(
                    "ReadFile.SettlementTransition",
                    correlation: correlation,
                    .init(
                        runPurpose: "recovery_released",
                        status: evidence.state,
                        outcome: "released_provider_limit",
                        blocksAdmission: evidence.blocksAdmission,
                        isReleased: evidence.isReleased
                    )
                )
            }
            XCTAssertEqual(originSlot.resolveGraceExpiry(now: .zero), .detach)
            XCTAssertEqual(originSlot.activateDetach(), .activated)

            let activeSnapshot = EditFlowPerf.debugCaptureSnapshot(finish: false)
            let enumerationCount = registry.debugTransitionEnumerationCountForTesting()
            let transitionCount = transitions.snapshot().count
            let lifecycleCount = activeSnapshot.lifecycleEvents.count
            let expiryBoundaryNanoseconds: UInt64 = 10_000_001_000
            clock.setNowNanoseconds(expiryBoundaryNanoseconds)
            XCTAssertFalse(captureAccepts(), "Capture acceptance must expire at deadline equality")
            clock.setNowNanoseconds(expiryBoundaryNanoseconds + 1)

            let recoveredSlot: MCPCodeStructureSettlementRegistry.Slot
            switch registry.admit(
                windowID: 1,
                connectionID: UUID(),
                invocationID: UUID(),
                toolName: MCPWindowToolName.readFile,
                now: MCPCodeStructureSettlementRegistry.recoveryHorizon,
                handlerPhase: { "executing" }
            ) {
            case let .admitted(slot):
                recoveredSlot = slot
            case .busy:
                return XCTFail("Recovery-horizon read-file lease should be admitted")
            }
            defer { _ = recoveredSlot.closeBeforeExecutionExit() }
            XCTAssertEqual(recoveredSlot.closeBeforeExecutionExit(), .released)
            XCTAssertEqual(originSlot.recordCompletion(.success), .settleDetached)

            XCTAssertEqual(registry.debugTransitionEnumerationCountForTesting(), enumerationCount)
            XCTAssertEqual(transitions.snapshot().count, transitionCount)
            XCTAssertEqual(EditFlowPerf.debugCaptureSnapshot(finish: false).lifecycleEvents.count, lifecycleCount)
        }

        func testClosedReadFileCaptureSkipsRecoveryAndDrainTransitionEnumerationAndLifecycle() throws {
            EditFlowPerf.resetDebugCaptureForTesting()
            defer { EditFlowPerf.resetDebugCaptureForTesting() }
            var admittedCaptureIdentity: EditFlowPerf.DebugCaptureIdentity?
            switch EditFlowPerf.beginDebugCapture(
                label: "closed-read-file-settlement-observer",
                maxSamples: 64,
                toolFilter: .readFile,
                prepare: { admittedCaptureIdentity = $0 }
            ) {
            case .started:
                break
            case .busy:
                return XCTFail("Read-file settlement capture should start")
            }
            let captureIdentity = try XCTUnwrap(admittedCaptureIdentity)
            let invocationID = UUID()
            let connectionID = UUID()
            let requestIdentity = MCPRequestTimelineIdentity(
                jsonRPCRequestID: .string("closed-settlement-observer"),
                connectionID: connectionID.uuidString,
                connectionGeneration: 1,
                appInvocationID: invocationID.uuidString,
                requestOrdinal: 1
            )
            let correlation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive(
                requestIdentity: requestIdentity,
                toolName: MCPWindowToolName.readFile
            ))
            let registry = MCPCodeStructureSettlementRegistry()
            let originSlot: MCPCodeStructureSettlementRegistry.Slot
            switch registry.admit(
                windowID: 1,
                connectionID: connectionID,
                invocationID: invocationID,
                toolName: MCPWindowToolName.readFile,
                now: .zero,
                handlerPhase: { "executing" }
            ) {
            case let .admitted(slot):
                originSlot = slot
            case .busy:
                return XCTFail("Initial read-file settlement lease should be admitted")
            }
            let transitions = MCPSettlementTransitionEvidenceRecorder()
            let captureAccepts = try XCTUnwrap(EditFlowPerf.debugCaptureAcceptancePredicate(captureIdentity))
            originSlot.setDebugTransitionObserver(
                accepts: captureAccepts
            ) { evidence in
                transitions.append(evidence)
                EditFlowPerf.lifecycleEvent(
                    "ReadFile.SettlementTransition",
                    correlation: correlation,
                    .init(
                        runPurpose: evidence.kind == .recoveryReleased ? "recovery_released" : "admission",
                        status: evidence.state,
                        outcome: evidence.kind == .recoveryReleased ? "released_provider_limit" : "admitted",
                        blocksAdmission: evidence.blocksAdmission,
                        isReleased: evidence.isReleased
                    )
                )
            }
            XCTAssertEqual(originSlot.resolveGraceExpiry(now: .zero), .detach)
            XCTAssertEqual(originSlot.activateDetach(), .activated)

            let closedSnapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            let enumerationCount = registry.debugTransitionEnumerationCountForTesting()
            let transitionCount = transitions.snapshot().count
            let lifecycleCount = closedSnapshot.lifecycleEvents.count

            let recoveredSlot: MCPCodeStructureSettlementRegistry.Slot
            switch registry.admit(
                windowID: 1,
                connectionID: UUID(),
                invocationID: UUID(),
                toolName: MCPWindowToolName.readFile,
                now: MCPCodeStructureSettlementRegistry.recoveryHorizon,
                handlerPhase: { "executing" }
            ) {
            case let .admitted(slot):
                recoveredSlot = slot
            case .busy:
                return XCTFail("Recovery-horizon read-file lease should be admitted")
            }
            XCTAssertEqual(recoveredSlot.closeBeforeExecutionExit(), .released)
            XCTAssertEqual(originSlot.recordCompletion(.success), .settleDetached)

            XCTAssertEqual(registry.debugTransitionEnumerationCountForTesting(), enumerationCount)
            XCTAssertEqual(transitions.snapshot().count, transitionCount)
            XCTAssertEqual(EditFlowPerf.debugCaptureSnapshot(finish: false).lifecycleEvents.count, lifecycleCount)
        }

        func testActiveReadFileCaptureEnumeratesRecoveryTransitionOnceWithDisplacedTruth() throws {
            EditFlowPerf.resetDebugCaptureForTesting()
            defer { EditFlowPerf.resetDebugCaptureForTesting() }
            var admittedCaptureIdentity: EditFlowPerf.DebugCaptureIdentity?
            switch EditFlowPerf.beginDebugCapture(
                label: "active-read-file-settlement-observer",
                maxSamples: 64,
                toolFilter: .readFile,
                prepare: { admittedCaptureIdentity = $0 }
            ) {
            case .started:
                break
            case .busy:
                return XCTFail("Read-file settlement capture should start")
            }
            let captureIdentity = try XCTUnwrap(admittedCaptureIdentity)
            let invocationID = UUID()
            let connectionID = UUID()
            let registry = MCPCodeStructureSettlementRegistry()
            let originSlot: MCPCodeStructureSettlementRegistry.Slot
            switch registry.admit(
                windowID: 1,
                connectionID: connectionID,
                invocationID: invocationID,
                toolName: MCPWindowToolName.readFile,
                now: .zero,
                handlerPhase: { "executing" }
            ) {
            case let .admitted(slot):
                originSlot = slot
            case .busy:
                return XCTFail("Initial read-file settlement lease should be admitted")
            }
            let transitions = MCPSettlementTransitionEvidenceRecorder()
            let captureAccepts = try XCTUnwrap(EditFlowPerf.debugCaptureAcceptancePredicate(captureIdentity))
            originSlot.setDebugTransitionObserver(
                accepts: captureAccepts
            ) { evidence in
                transitions.append(evidence)
            }
            XCTAssertEqual(originSlot.resolveGraceExpiry(now: .zero), .detach)
            XCTAssertEqual(originSlot.activateDetach(), .activated)
            let enumerationCount = registry.debugTransitionEnumerationCountForTesting()
            let transitionCount = transitions.snapshot().count

            let recoveredSlot: MCPCodeStructureSettlementRegistry.Slot
            switch registry.admit(
                windowID: 1,
                connectionID: UUID(),
                invocationID: UUID(),
                toolName: MCPWindowToolName.readFile,
                now: MCPCodeStructureSettlementRegistry.recoveryHorizon,
                handlerPhase: { "executing" }
            ) {
            case let .admitted(slot):
                recoveredSlot = slot
            case .busy:
                return XCTFail("Recovery-horizon read-file lease should be admitted")
            }

            XCTAssertEqual(registry.debugTransitionEnumerationCountForTesting(), enumerationCount + 1)
            let recoveryTransitions = transitions.snapshot().dropFirst(transitionCount)
            let recovery = try XCTUnwrap(recoveryTransitions.first)
            XCTAssertEqual(recoveryTransitions.count, 1)
            XCTAssertEqual(recovery.kind, .recoveryReleased)
            XCTAssertEqual(recovery.invocationID, invocationID)
            XCTAssertEqual(recovery.connectionID, connectionID)
            XCTAssertFalse(recovery.blocksAdmission)
            XCTAssertTrue(recovery.isReleased)

            XCTAssertEqual(recoveredSlot.closeBeforeExecutionExit(), .released)
            XCTAssertEqual(originSlot.recordCompletion(.success), .settleDetached)
            _ = EditFlowPerf.debugCaptureSnapshot(finish: true)
        }

        func testReadFileSettlementTransitionsRetainDisplacedInvocationThroughRecoveryAndDrain() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let clock = ExecutionWatchdogManualClock()
                let operationGate = MCPExecutionIgnoringCancellationGate()
                let recorder = MCPExecutionTraceRecorder()
                let manager = fixture.networkManager
                EditFlowPerf.resetDebugCaptureForTesting()
                let captureID: UUID
                switch EditFlowPerf.beginDebugCapture(
                    label: "read-file-settlement-transitions",
                    maxSamples: 500,
                    expiryMilliseconds: 120_000,
                    toolFilter: .readFile,
                    prepare: { captureIdentity in
                        MCPToolExecutionTracer.prepareDebugCapture(captureIdentity)
                    }
                ) {
                case let .started(snapshot):
                    captureID = try XCTUnwrap(snapshot.captureID)
                case .busy:
                    await fixture.cleanup()
                    return XCTFail("Read-file settlement capture should start")
                }
                MCPToolExecutionTracer.setTestSink { recorder.append($0) }
                await manager.debugSetToolExecutionWatchdogEnvironment(clock.environment)
                await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.readFile) {
                    await operationGate.enterAndWait()
                    return .null
                }
                do {
                    let endpoint = try fixture.endpointA()
                    let fixtureTimelineGeneration = UInt64.max
                    defer {
                        MCPRequestTimelineRegistry.shared.removeConnection(
                            connectionID: endpoint.connectionID.uuidString,
                            connectionGeneration: fixtureTimelineGeneration
                        )
                    }
                    let timelineFrame = try JSONSerialization.data(withJSONObject: [
                        "jsonrpc": "2.0",
                        "id": "read-file-settlement-transitions",
                        "method": "tools/call",
                        "params": [
                            "name": MCPWindowToolName.readFile,
                            "arguments": [:]
                        ]
                    ])
                    _ = MCPRequestTimelineRegistry.shared.recordAcceptedFrame(
                        timelineFrame,
                        connectionID: endpoint.connectionID.uuidString,
                        correlationConnectionID: endpoint.connectionID.uuidString,
                        connectionGeneration: fixtureTimelineGeneration
                    )
                    let arguments: [String: Any] = [
                        "path": fixture.contextA.fileURL.path,
                        "context_id": fixture.contextA.tabID.uuidString,
                        "_rawJSON": true
                    ]
                    let detachedCall = Task {
                        try await endpoint.callTool(name: MCPWindowToolName.readFile, arguments: arguments)
                    }
                    try await clock.waitForSleeperCount(1)
                    try await operationGate.waitUntilEntered(count: 1)
                    try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolExecutionDeadline)
                    try await clock.waitForSleeperCount(1)
                    try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolCancellationCleanupGrace)

                    let timeoutPayload = try await Self.toolResultObject(detachedCall.value)
                    XCTAssertEqual(timeoutPayload["code"] as? String, "tool_execution_timeout")
                    XCTAssertEqual(timeoutPayload["settlement"] as? String, "detached")
                    let origin = try XCTUnwrap(Self.detachedReadFileOrigin(
                        in: recorder.snapshot(),
                        connectionID: endpoint.connectionID
                    ))
                    let recoveryReleasedTransition = expectation(
                        description: "displaced read-file invocation recovery release"
                    )
                    recoveryReleasedTransition.assertForOverFulfill = true
                    let detachedSettledTransition = expectation(
                        description: "displaced read-file invocation detached settlement"
                    )
                    detachedSettledTransition.assertForOverFulfill = true
                    MCPToolExecutionTracer.setTestSink { event in
                        recorder.append(event)
                        guard event.invocationID == origin.invocationID,
                              event.phase == .detachedSettled,
                              EditFlowPerf.debugCaptureSnapshot(finish: false).lifecycleEvents.contains(where: {
                                  $0.requestIdentity?.appInvocationID == origin.invocationID.uuidString
                                      && $0.eventName == "ReadFile.SettlementTransition"
                                      && $0.sanitizedDimensions.contains("purpose=execution_detached_settled")
                                      && $0.sanitizedDimensions.contains("status=settled")
                                      && $0.sanitizedDimensions.contains("blocksAdmission=false")
                                      && $0.sanitizedDimensions.contains("isReleased=true")
                              })
                        else { return }
                        detachedSettledTransition.fulfill()
                    }

                    try await clock.advanceWithoutSleepers(
                        by: MCPCodeStructureSettlementRegistry.recoveryHorizon
                    )
                    await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.readFile) {
                        if EditFlowPerf.debugCaptureSnapshot(finish: false).lifecycleEvents.contains(where: {
                            $0.requestIdentity?.appInvocationID == origin.invocationID.uuidString
                                && $0.eventName == "ReadFile.SettlementTransition"
                                && $0.sanitizedDimensions.contains("purpose=recovery_released")
                                && $0.sanitizedDimensions.contains("status=detached")
                                && $0.sanitizedDimensions.contains("blocksAdmission=false")
                                && $0.sanitizedDimensions.contains("isReleased=true")
                        }) {
                            recoveryReleasedTransition.fulfill()
                        }
                        return .null
                    }
                    let recoveredEndpoint = try await fixture.makeAdditionalEndpoint(
                        label: "read-file-settlement-recovery"
                    )
                    _ = try await recoveredEndpoint.callTool(
                        name: MCPWindowToolName.readFile,
                        arguments: arguments
                    )
                    await fulfillment(of: [recoveryReleasedTransition], timeout: 5)

                    await operationGate.release()
                    await fulfillment(of: [detachedSettledTransition], timeout: 5)
                    await manager.debugAwaitCodeStructureSettlementDrain(
                        windowID: fixture.contextA.window.windowID
                    )

                    let capture = EditFlowPerf.debugCaptureSnapshot(finish: false)
                    let originTransitions = capture.lifecycleEvents.filter {
                        $0.requestIdentity?.appInvocationID == origin.invocationID.uuidString
                            && $0.eventName == "ReadFile.SettlementTransition"
                    }
                    let rawHistory = originTransitions.map(\.sanitizedDimensions).joined(separator: "\n")
                    XCTAssertFalse(rawHistory.contains("providerActive="), rawHistory)
                    XCTAssertFalse(rawHistory.contains("permitActive="), rawHistory)
                    for expected in [
                        (purpose: "admission", status: "reserved", outcome: "admitted"),
                        (purpose: "execution_detached_for_settlement", status: "detached", outcome: "detached"),
                        (purpose: "recovery_released", status: "detached", outcome: "released_provider_limit"),
                        (purpose: "execution_detached_settled", status: "settled", outcome: "success")
                    ] {
                        XCTAssertTrue(originTransitions.contains {
                            $0.sanitizedDimensions.contains("purpose=\(expected.purpose)")
                                && $0.sanitizedDimensions.contains("status=\(expected.status)")
                                && $0.sanitizedDimensions.contains("outcome=\(expected.outcome)")
                        }, rawHistory)
                    }

                    let trace = MCPToolExecutionTracer.debugEventSnapshot(captureID)
                    let packet = try MCPReadFileInvocationDiagnosticPacketAssembler.packet(
                        appInvocationID: origin.invocationID,
                        capture: capture,
                        trace: trace,
                        work: MCPToolWorkCountDiagnostics.debugReadFileSnapshot(captureID: captureID),
                        runtimeIdentity: MCPReadFileDiagnosticRuntimeIdentity(
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
                    )
                    let packetHistory = packet.settlement.entries.map { entry in
                        entry.dimensions
                            .sorted { $0.key < $1.key }
                            .map { "\($0.key)=\($0.value)" }
                            .joined(separator: " ")
                    }.joined(separator: "\n")
                    for purpose in [
                        "admission", "execution_detached_for_settlement", "recovery_released",
                        "execution_detached_settled"
                    ] {
                        XCTAssertTrue(packetHistory.contains("purpose=\(purpose)"), packetHistory)
                    }
                    XCTAssertFalse(packetHistory.contains("providerActive="), packetHistory)
                    XCTAssertFalse(packetHistory.contains("permitActive="), packetHistory)

                    _ = EditFlowPerf.debugCaptureSnapshot(finish: true)
                    EditFlowPerf.resetDebugCaptureForTesting()
                    MCPToolExecutionTracer.setTestSink(nil)
                    MCPToolExecutionTracer.resetDebugEvents()
                    MCPToolWorkCountDiagnostics.resetForTesting()
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPWindowToolName.readFile,
                        operation: nil
                    )
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    await fixture.cleanup()
                } catch {
                    await operationGate.release()
                    _ = EditFlowPerf.debugCaptureSnapshot(finish: true)
                    EditFlowPerf.resetDebugCaptureForTesting()
                    MCPToolExecutionTracer.setTestSink(nil)
                    MCPToolExecutionTracer.resetDebugEvents()
                    MCPToolWorkCountDiagnostics.resetForTesting()
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPWindowToolName.readFile,
                        operation: nil
                    )
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testManageSelectionWatchdogPersistsAttributedTerminalRecordThroughPeerPIDGuard() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let clock = ExecutionWatchdogManualClock()
                let operationGate = MCPExecutionIgnoringCancellationGate()
                let recorder = MCPExecutionTraceRecorder()
                let manager = fixture.networkManager
                let terminalRecordDirectory = fixture.rootURL.appendingPathComponent(
                    "terminal-records",
                    isDirectory: true
                )
                MCPToolExecutionTracer.setTestSink { recorder.append($0) }
                await manager.debugSetTerminalRecordDirectoryURLForTesting(terminalRecordDirectory)
                await manager.debugSetToolExecutionWatchdogEnvironment(clock.environment)
                await manager.debugSetResolvedToolOperationOverride(
                    toolName: MCPWindowToolName.manageSelection
                ) {
                    await MCPToolExecutionHandlerPhaseContext.report(.manageSelectionConstruction)
                    await operationGate.enterAndWait()
                    return .null
                }
                do {
                    let endpoint = try fixture.endpointA()
                    let call = Task {
                        try await endpoint.callTool(
                            name: MCPWindowToolName.manageSelection,
                            arguments: [
                                "op": "get",
                                "context_id": fixture.contextA.tabID.uuidString
                            ]
                        )
                    }
                    try await clock.waitForSleeperCount(1)
                    try await operationGate.waitUntilEntered(count: 1)
                    let invocationID = try XCTUnwrap(recorder.snapshot().first {
                        $0.connectionID == endpoint.connectionID
                            && $0.toolName == MCPWindowToolName.manageSelection
                            && $0.phase == .started
                    }?.invocationID)

                    try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolExecutionDeadline)
                    try await clock.waitForSleeperCount(1)
                    try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolCancellationCleanupGrace)
                    await Self.assertSocketClosed(call)

                    let didPersist = await Self.waitUntil {
                        (try? FileManager.default.contentsOfDirectory(
                            at: terminalRecordDirectory,
                            includingPropertiesForKeys: nil
                        ).contains { $0.lastPathComponent.hasPrefix("terminal-") }) == true
                    }
                    XCTAssertTrue(didPersist)
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let records = try FileManager.default.contentsOfDirectory(
                        at: terminalRecordDirectory,
                        includingPropertiesForKeys: nil
                    ).filter { $0.lastPathComponent.hasPrefix("terminal-") }.map {
                        try decoder.decode(MCPTerminalRecord.self, from: Data(contentsOf: $0))
                    }
                    let record = try XCTUnwrap(records.first {
                        $0.appConnectionID == endpoint.connectionID
                            && $0.reason == "tool_execution_watchdog"
                    })
                    XCTAssertEqual(record.layer, .appAcceptedSocket)
                    XCTAssertEqual(record.peerPID, Int(getpid()))
                    XCTAssertEqual(record.toolName, MCPWindowToolName.manageSelection)
                    XCTAssertEqual(record.invocationID, invocationID)
                    XCTAssertGreaterThanOrEqual(record.elapsedMilliseconds ?? -1, 35000)
                    XCTAssertEqual(record.handlerPhase, "manage_selection.selection_construction")
                    XCTAssertGreaterThanOrEqual(record.handlerPhaseAgeMilliseconds ?? -1, 35000)
                    XCTAssertEqual(record.executionDeadlineMilliseconds, 30000)
                    XCTAssertEqual(record.cleanupGraceMilliseconds, 5000)

                    await operationGate.release()
                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPWindowToolName.manageSelection,
                        operation: nil
                    )
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    await manager.debugSetTerminalRecordDirectoryURLForTesting(nil)
                    await fixture.cleanup()
                } catch {
                    await operationGate.release()
                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPWindowToolName.manageSelection,
                        operation: nil
                    )
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    await manager.debugSetTerminalRecordDirectoryURLForTesting(nil)
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testCancelledCodeStructureFencesDetachClassToolsUntilLateSettlementAndKeepsConnectionUsable() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let clock = ExecutionWatchdogManualClock()
                let provider = MCPCodeStructureSettlementProviderProbe()
                let manager = fixture.networkManager
                let windowID = fixture.contextA.window.windowID
                var cancelledTask: Task<PersistentMCPTestRPCResponse, Error>?

                await manager.debugSetToolExecutionWatchdogEnvironment(clock.environment)
                await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.getCodeStructure) {
                    try await provider.run()
                }

                do {
                    let endpoint = try fixture.endpointA()
                    let arguments: [String: Any] = [
                        "paths": [fixture.contextA.fileURL.path],
                        "context_id": fixture.contextA.tabID.uuidString,
                        "_rawJSON": true
                    ]
                    let requestID = endpoint.client.nextRequestIDForTesting()
                    let activeTask = Task {
                        try await endpoint.callTool(
                            name: MCPWindowToolName.getCodeStructure,
                            arguments: arguments
                        )
                    }
                    cancelledTask = activeTask
                    try await provider.waitUntilEntered(count: 1)
                    try endpoint.client.sendNotification(
                        method: "notifications/cancelled",
                        params: ["requestId": requestID]
                    )

                    let cancellationFenced = await Self.waitUntil {
                        await manager.debugCodeStructureSettlementSnapshot(windowID: windowID)
                            == .init(activeCount: 1, detachedCount: 1)
                    }
                    XCTAssertTrue(cancellationFenced)
                    _ = try? await activeTask.value
                    cancelledTask = nil

                    let limiterReleased = await Self.waitUntil {
                        let snapshot = await manager.connectionLimiterSnapshotForTesting(
                            connectionID: endpoint.connectionID,
                            lane: .smallRead
                        )
                        return snapshot?.activePermitCount == 0
                    }
                    XCTAssertTrue(limiterReleased)

                    for _ in 0 ..< 3 {
                        let busyResponse = try await endpoint.callTool(
                            name: MCPWindowToolName.getCodeStructure,
                            arguments: arguments
                        )
                        let busyPayload = try Self.toolResultObject(busyResponse)
                        XCTAssertEqual(
                            busyPayload["code"] as? String,
                            "tool_execution_structure_settlement_busy"
                        )
                        XCTAssertEqual(
                            busyPayload["busy_reason"] as? String,
                            "abandoned_settlement_in_progress"
                        )
                    }
                    let enteredWhileBusy = await provider.enteredCount()
                    XCTAssertEqual(enteredWhileBusy, 1)

                    let readResponse = try await endpoint.callTool(
                        name: MCPWindowToolName.readFile,
                        arguments: [
                            "path": fixture.contextA.fileURL.path,
                            "context_id": fixture.contextA.tabID.uuidString,
                            "_rawJSON": true
                        ]
                    )
                    let readPayload = try Self.toolResultObject(readResponse)
                    XCTAssertEqual(readPayload["code"] as? String, "tool_execution_structure_settlement_busy")
                    XCTAssertEqual(readPayload["retryable"] as? Bool, true)
                    XCTAssertEqual((readPayload["retry_after_ms"] as? NSNumber)?.intValue, 30000)
                    XCTAssertEqual(readPayload["busy_reason"] as? String, "abandoned_settlement_in_progress")
                    XCTAssertEqual(readPayload["settlement"] as? String, "busy")
                    XCTAssertTrue((readPayload["error"] as? String)?.contains("prior canceled MCP operation") == true)
                    XCTAssertFalse((readPayload["error"] as? String)?.contains("canceled read_file") == true)

                    let selectionResponse = try await endpoint.callTool(
                        name: MCPWindowToolName.manageSelection,
                        arguments: [
                            "op": "get",
                            "context_id": fixture.contextA.tabID.uuidString
                        ]
                    )
                    let selectionText = try Self.toolResultText(selectionResponse)
                    XCTAssertTrue(selectionText.contains("## Selection"), selectionText)
                    XCTAssertFalse(selectionText.contains("tool_execution_structure_settlement_busy"))
                    let terminal = await manager.debugIsExecutionWatchdogTerminal(
                        connectionID: endpoint.connectionID
                    )
                    XCTAssertFalse(terminal)

                    await provider.releaseFirst()
                    await manager.debugAwaitCodeStructureSettlementDrain(windowID: windowID)
                    let postSettlementResponse = try await endpoint.callTool(
                        name: MCPWindowToolName.getCodeStructure,
                        arguments: arguments
                    )
                    XCTAssertEqual(
                        try (Self.toolResultObject(postSettlementResponse)["ordinal"] as? NSNumber)?.intValue,
                        2
                    )
                    let postSettlementReadResponse = try await endpoint.callTool(
                        name: MCPWindowToolName.readFile,
                        arguments: [
                            "path": fixture.contextA.fileURL.path,
                            "context_id": fixture.contextA.tabID.uuidString
                        ]
                    )
                    XCTAssertTrue(
                        try Self.toolResultText(postSettlementReadResponse)
                            .contains(fixture.contextA.sentinel)
                    )
                    let maximumProviderConcurrency = await provider.maximumConcurrentCount()
                    XCTAssertLessThanOrEqual(
                        maximumProviderConcurrency,
                        MCPToolAdmissionPolicy.smallReadPerWindowLimit + 1
                    )

                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPWindowToolName.getCodeStructure,
                        operation: nil
                    )
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    await provider.releaseFirst()
                    cancelledTask?.cancel()
                    if let cancelledTask { _ = try? await cancelledTask.value }
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPWindowToolName.getCodeStructure,
                        operation: nil
                    )
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testReadFileDeadlineReportsProductionContentReadPhase() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let clock = ExecutionWatchdogManualClock()
                let providerGate = MCPExecutionIgnoringCancellationGate()
                let recorder = MCPExecutionTraceRecorder()
                let manager = fixture.networkManager
                let store = fixture.contextA.window.workspaceFileContextStore
                let rootID = fixture.contextA.rootID
                let relativePath = "HandlerPhaseRead-\(UUID().uuidString).swift"
                let fileURL = fixture.contextA.rootURL.appendingPathComponent(relativePath)
                let windowID = fixture.contextA.window.windowID
                var originTask: Task<PersistentMCPTestRPCResponse, Error>?

                _ = try await store.createFile(
                    rootID: rootID,
                    relativePath: relativePath,
                    content: String(repeating: "let handlerPhaseRead = true\n", count: 4096)
                )
                await store.clearSearchDecodedContentCache()
                try await store.setSearchContentReadChunkHandlerForTesting(rootID: rootID) { path in
                    guard path == relativePath else { return }
                    await providerGate.enterAndWait()
                }
                MCPToolExecutionTracer.setTestSink { recorder.append($0) }
                await manager.debugSetToolExecutionWatchdogEnvironment(clock.environment)

                do {
                    let endpoint = try fixture.endpointA()
                    let activeOriginTask = Task {
                        try await endpoint.callTool(
                            name: MCPWindowToolName.readFile,
                            arguments: [
                                "path": fileURL.path,
                                "context_id": fixture.contextA.tabID.uuidString,
                                "_rawJSON": true
                            ]
                        )
                    }
                    originTask = activeOriginTask
                    try await clock.waitForSleeperCount(1)
                    try await providerGate.waitUntilEntered(count: 1)
                    try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolExecutionDeadline)

                    let phaseArrived = await Self.waitUntil {
                        recorder.snapshot().contains {
                            $0.toolName == MCPWindowToolName.readFile
                                && $0.phase == .deadlineExpired
                                && $0.handlerPhase?.phase == .readFileContentRead
                        }
                    }
                    XCTAssertTrue(phaseArrived)
                    let deadlineEvent = try XCTUnwrap(recorder.snapshot().first {
                        $0.toolName == MCPWindowToolName.readFile && $0.phase == .deadlineExpired
                    })
                    XCTAssertEqual(deadlineEvent.handlerPhase?.phase, .readFileContentRead)
                    XCTAssertEqual(deadlineEvent.handlerPhase?.transition, .started)

                    await providerGate.release()
                    try await store.setSearchContentReadChunkHandlerForTesting(rootID: rootID, nil)
                    let timeoutPayload = try await Self.toolResultObject(activeOriginTask.value)
                    originTask = nil
                    XCTAssertEqual(timeoutPayload["code"] as? String, "tool_execution_timeout")
                    await manager.debugAwaitCodeStructureSettlementDrain(windowID: windowID)
                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    originTask?.cancel()
                    await providerGate.release()
                    try? await store.setSearchContentReadChunkHandlerForTesting(rootID: rootID, nil)
                    if let originTask { _ = try? await originTask.value }
                    await manager.debugAwaitCodeStructureSettlementDrain(windowID: windowID)
                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testFileTreeDeadlineReportsProductionIngressPhase() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let clock = ExecutionWatchdogManualClock()
                let providerGate = MCPExecutionIgnoringCancellationGate()
                let recorder = MCPExecutionTraceRecorder()
                let manager = fixture.networkManager
                let store = fixture.contextA.window.workspaceFileContextStore
                let rootID = fixture.contextA.rootID
                let windowID = fixture.contextA.window.windowID
                var originTask: Task<PersistentMCPTestRPCResponse, Error>?

                await store.setScopedIngressBarrierWillFlushHandler { observedRootID in
                    guard observedRootID == rootID else { return }
                    await providerGate.enterAndWait()
                }
                MCPToolExecutionTracer.setTestSink { recorder.append($0) }
                await manager.debugSetToolExecutionWatchdogEnvironment(clock.environment)

                do {
                    let endpoint = try fixture.endpointA()
                    let activeOriginTask = Task {
                        try await endpoint.callTool(
                            name: MCPWindowToolName.getFileTree,
                            arguments: [
                                "type": "files",
                                "context_id": fixture.contextA.tabID.uuidString,
                                "_rawJSON": true
                            ]
                        )
                    }
                    originTask = activeOriginTask
                    try await clock.waitForSleeperCount(1)
                    try await providerGate.waitUntilEntered(count: 1)
                    try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolExecutionDeadline)

                    let phaseArrived = await Self.waitUntil {
                        recorder.snapshot().contains {
                            $0.toolName == MCPWindowToolName.getFileTree
                                && $0.phase == .deadlineExpired
                                && $0.handlerPhase?.phase == .getFileTreeIngressWait
                        }
                    }
                    XCTAssertTrue(phaseArrived)
                    let deadlineEvent = try XCTUnwrap(recorder.snapshot().first {
                        $0.toolName == MCPWindowToolName.getFileTree && $0.phase == .deadlineExpired
                    })
                    XCTAssertEqual(deadlineEvent.handlerPhase?.phase, .getFileTreeIngressWait)
                    XCTAssertEqual(deadlineEvent.handlerPhase?.transition, .started)

                    await providerGate.release()
                    await store.setScopedIngressBarrierWillFlushHandler(nil)
                    let timeoutPayload = try await Self.toolResultObject(activeOriginTask.value)
                    originTask = nil
                    XCTAssertEqual(timeoutPayload["code"] as? String, "tool_execution_timeout")
                    await manager.debugAwaitCodeStructureSettlementDrain(windowID: windowID)
                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    originTask?.cancel()
                    await providerGate.release()
                    await store.setScopedIngressBarrierWillFlushHandler(nil)
                    if let originTask { _ = try? await originTask.value }
                    await manager.debugAwaitCodeStructureSettlementDrain(windowID: windowID)
                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testDetachedCodeStructureTimeoutRecoversBeforeLateProviderDrains() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let clock = ExecutionWatchdogManualClock()
                let provider = MCPCodeStructureSettlementProviderProbe()
                let repeatedEscapeGate = MCPExecutionIgnoringCancellationGate()
                let recorder = MCPExecutionTraceRecorder()
                let manager = fixture.networkManager
                let windowID = fixture.contextA.window.windowID
                var firstResponseTask: Task<PersistentMCPTestRPCResponse, Error>?

                EditFlowPerf.resetDebugCaptureForTesting()
                switch EditFlowPerf.beginDebugCapture(label: "code-structure-detached-settlement", maxSamples: 500) {
                case .started:
                    break
                case .busy:
                    return XCTFail("EditFlow capture should start")
                }
                MCPToolExecutionTracer.setTestSink { recorder.append($0) }
                await manager.debugSetToolExecutionWatchdogEnvironment(clock.environment)
                await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.getCodeStructure) {
                    await MCPToolExecutionHandlerPhaseContext.report(.getCodeStructureGraphTraversal)
                    return try await provider.run()
                }

                do {
                    let endpoint = try fixture.endpointA()
                    let arguments: [String: Any] = [
                        "paths": [fixture.contextA.fileURL.path],
                        "context_id": fixture.contextA.tabID.uuidString,
                        "_rawJSON": true
                    ]
                    let detachedCandidate = Task {
                        try await endpoint.callTool(
                            name: MCPWindowToolName.getCodeStructure,
                            arguments: arguments
                        )
                    }
                    firstResponseTask = detachedCandidate
                    try await clock.waitForSleeperCount(1)
                    try await provider.waitUntilEntered(count: 1)

                    // MF1: the second currently legal same-window structure call still enters.
                    let competingResponse = try await endpoint.callTool(
                        name: MCPWindowToolName.getCodeStructure,
                        arguments: arguments
                    )
                    let competingPayload = try Self.toolResultObject(competingResponse)
                    XCTAssertEqual((competingPayload["ordinal"] as? NSNumber)?.intValue, 2)
                    try await provider.waitUntilEntered(count: 2)
                    let competingSleeperDrained = await Self.waitUntil { await clock.sleeperCount() == 1 }
                    XCTAssertTrue(competingSleeperDrained)
                    let reservedDiagnostic = await manager.debugCodeStructureSettlementDiagnosticSnapshot(
                        windowID: windowID,
                        now: clock.currentTime()
                    )
                    let reservedLease = try XCTUnwrap(reservedDiagnostic.leases.first)
                    XCTAssertEqual(reservedLease.state, "reserved")
                    XCTAssertFalse(reservedLease.blocksAdmission)
                    XCTAssertFalse(reservedLease.isReleased)

                    try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolExecutionDeadline)
                    try await clock.waitForSleeperCount(1)
                    try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolCancellationCleanupGrace)

                    let timeoutResponse = try await detachedCandidate.value
                    firstResponseTask = nil
                    let timeoutPayload = try Self.toolResultObject(timeoutResponse)
                    XCTAssertEqual(timeoutPayload["code"] as? String, "tool_execution_timeout")
                    XCTAssertEqual(timeoutPayload["settlement"] as? String, "detached")
                    XCTAssertEqual(timeoutPayload["cancellation_origin"] as? String, "watchdog_deadline")
                    XCTAssertEqual(timeoutPayload["retryable"] as? Bool, true)
                    let detachSleepersDrained = await Self.waitUntil { await clock.sleeperCount() == 0 }
                    XCTAssertTrue(detachSleepersDrained)
                    try await clock.advanceWithoutSleepers(by: .seconds(1))
                    let elapsedAfterTimeout = clock.currentTime()
                    XCTAssertEqual(elapsedAfterTimeout, .seconds(36))

                    let detachedSnapshot = await manager.debugCodeStructureSettlementSnapshot(windowID: windowID)
                    XCTAssertEqual(detachedSnapshot, .init(activeCount: 1, detachedCount: 1))
                    let detachedDiagnostic = await manager.debugCodeStructureSettlementDiagnosticSnapshot(
                        windowID: windowID,
                        now: clock.currentTime()
                    )
                    let detachedLease = try XCTUnwrap(detachedDiagnostic.leases.first)
                    XCTAssertEqual(detachedLease.state, "detached")
                    XCTAssertTrue(detachedLease.blocksAdmission)
                    XCTAssertFalse(detachedLease.isReleased)
                    let terminal = await manager.debugIsExecutionWatchdogTerminal(connectionID: endpoint.connectionID)
                    XCTAssertFalse(terminal)

                    // The timed-out request has released its ordinary small-read permit. The one
                    // lingering read-only provider is the documented bounded +1 capacity exception.
                    let limiter = await manager.connectionLimiterSnapshotForTesting(
                        connectionID: endpoint.connectionID,
                        lane: .smallRead
                    )
                    XCTAssertEqual(limiter?.activePermitCount, 0)

                    let detachEvents = recorder.snapshot().filter {
                        $0.connectionID == endpoint.connectionID
                            && $0.toolName == MCPWindowToolName.getCodeStructure
                            && $0.phase == .detachedForSettlement
                    }
                    XCTAssertEqual(detachEvents.count, 1)
                    let detachedEvent = try XCTUnwrap(detachEvents.first)

                    // The affected window remains fenced until the registry's recovery horizon expires.
                    let readResponse = try await endpoint.callTool(
                        name: MCPWindowToolName.readFile,
                        arguments: [
                            "path": fixture.contextA.fileURL.path,
                            "context_id": fixture.contextA.tabID.uuidString,
                            "_rawJSON": true
                        ]
                    )
                    let readPayload = try Self.toolResultObject(readResponse)
                    XCTAssertEqual(readPayload["code"] as? String, "tool_execution_structure_settlement_busy")
                    XCTAssertEqual(readPayload["retryable"] as? Bool, true)
                    XCTAssertEqual((readPayload["retry_after_ms"] as? NSNumber)?.intValue, 29000)
                    XCTAssertEqual((readPayload["detached_age_ms"] as? NSNumber)?.intValue, 1000)
                    XCTAssertEqual(readPayload["origin_tool"] as? String, MCPWindowToolName.getCodeStructure)
                    XCTAssertEqual(readPayload["origin_invocation_id"] as? String, detachedEvent.invocationID.uuidString)
                    XCTAssertEqual(readPayload["origin_connection_id"] as? String, endpoint.connectionID.uuidString)
                    XCTAssertEqual(
                        readPayload["last_handler_phase"] as? String,
                        MCPToolExecutionHandlerPhase.getCodeStructureGraphTraversal.rawValue
                    )
                    XCTAssertTrue((readPayload["error"] as? String)?.contains("prior timed-out MCP operation") == true)

                    // The settlement fence is window-scoped; unrelated MCP traffic stays usable.
                    let siblingResponse = try await fixture.endpointB().callTool(
                        name: MCPWindowToolName.readFile,
                        arguments: [
                            "path": fixture.contextB.fileURL.path,
                            "context_id": fixture.contextB.tabID.uuidString
                        ]
                    )
                    XCTAssertTrue(try Self.toolResultText(siblingResponse).contains(fixture.contextB.sentinel))
                    _ = try await endpoint.callTool(
                        name: MCPWindowToolName.manageSelection,
                        arguments: [
                            "op": "get",
                            "context_id": fixture.contextA.tabID.uuidString
                        ]
                    )
                    let readSleepersDrained = await Self.waitUntil { await clock.sleeperCount() == 0 }
                    XCTAssertTrue(readSleepersDrained)

                    let busyResponse = try await endpoint.callTool(
                        name: MCPWindowToolName.getCodeStructure,
                        arguments: arguments
                    )
                    let busyPayload = try Self.toolResultObject(busyResponse)
                    XCTAssertEqual(busyPayload["code"] as? String, "tool_execution_structure_settlement_busy")
                    XCTAssertEqual(busyPayload["retryable"] as? Bool, true)
                    XCTAssertEqual((busyPayload["retry_after_ms"] as? NSNumber)?.intValue, 29000)
                    XCTAssertEqual(busyPayload["busy_reason"] as? String, "detached_settlement_in_progress")
                    XCTAssertEqual(busyPayload["settlement"] as? String, "busy")

                    // A fresh client succeeds when the recovery horizon expires while the original
                    // provider remains blocked.
                    try await clock.advanceWithoutSleepers(by: .seconds(29))
                    let recoveredEndpoint = try await fixture.makeAdditionalEndpoint(label: "issue-818-recovery")
                    let recoveredResponse = try await recoveredEndpoint.callTool(
                        name: MCPWindowToolName.readFile,
                        arguments: [
                            "path": fixture.contextA.fileURL.path,
                            "context_id": fixture.contextA.tabID.uuidString
                        ]
                    )
                    XCTAssertTrue(try Self.toolResultText(recoveredResponse).contains(fixture.contextA.sentinel))
                    let enteredCountAtRecovery = await provider.enteredCount()
                    let recoveredSnapshot = await manager.debugCodeStructureSettlementSnapshot(windowID: windowID)
                    XCTAssertEqual(enteredCountAtRecovery, 2)
                    XCTAssertEqual(
                        recoveredSnapshot,
                        .init(activeCount: 1, detachedCount: 1, releasedCount: 1)
                    )
                    let releasedDiagnostic = await manager.debugCodeStructureSettlementDiagnosticSnapshot(
                        windowID: windowID,
                        now: clock.currentTime()
                    )
                    let releasedLease = try XCTUnwrap(releasedDiagnostic.leases.first)
                    XCTAssertEqual(releasedLease.state, "detached")
                    XCTAssertFalse(releasedLease.blocksAdmission)
                    XCTAssertTrue(releasedLease.isReleased)

                    // A second escaped provider exhausts the window-scoped recovery budget.
                    await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.getCodeStructure) {
                        await MCPToolExecutionHandlerPhaseContext.report(.getCodeStructureGraphTraversal)
                        await repeatedEscapeGate.enterAndWait()
                        return .null
                    }
                    let repeatedEscape = Task {
                        try await recoveredEndpoint.callTool(
                            name: MCPWindowToolName.getCodeStructure,
                            arguments: arguments
                        )
                    }
                    try await clock.waitForSleeperCount(1)
                    try await repeatedEscapeGate.waitUntilEntered(count: 1)
                    try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolExecutionDeadline)
                    try await clock.waitForSleeperCount(1)
                    try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolCancellationCleanupGrace)
                    let repeatedEscapePayload = try await Self.toolResultObject(repeatedEscape.value)
                    XCTAssertEqual(repeatedEscapePayload["code"] as? String, "tool_execution_timeout")
                    XCTAssertEqual(repeatedEscapePayload["settlement"] as? String, "detached")

                    try await clock.advanceWithoutSleepers(by: MCPCodeStructureSettlementRegistry.recoveryHorizon)
                    let terminalResponse = try await recoveredEndpoint.callTool(
                        name: MCPWindowToolName.readFile,
                        arguments: [
                            "path": fixture.contextA.fileURL.path,
                            "context_id": fixture.contextA.tabID.uuidString,
                            "_rawJSON": true
                        ]
                    )
                    let terminalPayload = try Self.toolResultObject(terminalResponse)
                    XCTAssertEqual(terminalPayload["code"] as? String, "tool_execution_structure_settlement_busy")
                    XCTAssertEqual(terminalPayload["retryable"] as? Bool, false)
                    XCTAssertNil(terminalPayload["retry_after_ms"])
                    XCTAssertEqual(terminalPayload["busy_reason"] as? String, "released_provider_limit_reached")
                    XCTAssertEqual(terminalPayload["origin_tool"] as? String, MCPWindowToolName.getCodeStructure)
                    XCTAssertEqual(
                        terminalPayload["origin_connection_id"] as? String,
                        recoveredEndpoint.connectionID.uuidString
                    )
                    XCTAssertEqual((terminalPayload["detached_age_ms"] as? NSNumber)?.intValue, 30000)
                    XCTAssertEqual(
                        terminalPayload["last_handler_phase"] as? String,
                        MCPToolExecutionHandlerPhase.getCodeStructureGraphTraversal.rawValue
                    )
                    XCTAssertTrue((terminalPayload["error"] as? String)?.contains("restart RepoPrompt CE") == true)

                    let siblingAtLimitResponse = try await fixture.endpointB().callTool(
                        name: MCPWindowToolName.readFile,
                        arguments: [
                            "path": fixture.contextB.fileURL.path,
                            "context_id": fixture.contextB.tabID.uuidString
                        ]
                    )
                    XCTAssertTrue(try Self.toolResultText(siblingAtLimitResponse).contains(fixture.contextB.sentinel))

                    XCTAssertTrue(detachedEvent.isAlwaysEmitted)
                    XCTAssertEqual(detachedEvent.cleanupDisposition, .detachAndSettle)
                    XCTAssertEqual(detachedEvent.cancellationOrigin, .watchdogDeadline)
                    XCTAssertEqual(detachedEvent.settlement, "detached")
                    XCTAssertTrue(detachedEvent.description.contains("cancellation_origin=watchdog_deadline"))
                    XCTAssertTrue(detachedEvent.description.contains("settlement=detached"))
                    XCTAssertFalse(recorder.snapshot().contains {
                        $0.invocationID == detachedEvent.invocationID
                            && $0.phase == .connectionForceDisconnectRequested
                    })
                    XCTAssertFalse(recorder.snapshot().contains {
                        $0.invocationID == detachedEvent.invocationID && $0.phase == .handlerCompleted
                    })

                    let responseReadyCountBeforeLateSettlement = EditFlowPerf.debugCaptureSnapshot(finish: false)
                        .lifecycleEvents
                        .count { $0.eventName == "MCP.ToolCall.HandlerResultReady" }

                    await provider.releaseFirst()
                    await repeatedEscapeGate.release()
                    let lateTraceArrived = await Self.waitUntil {
                        recorder.snapshot().contains {
                            $0.invocationID == detachedEvent.invocationID && $0.phase == .detachedSettled
                        }
                    }
                    XCTAssertTrue(lateTraceArrived)
                    let ownershipStateArrived = await Self.waitUntil {
                        EditFlowPerf.debugCaptureSnapshot(finish: false).lifecycleEvents.contains {
                            $0.eventName == "MCP.ToolCall.PublicationOwnershipState"
                                && $0.sanitizedDimensions.contains("tool=get_code_structure")
                                && $0.sanitizedDimensions.contains("outcome=detached_settled")
                                && $0.sanitizedDimensions.contains("providerActive=false")
                                && $0.sanitizedDimensions.contains("networkScopeActive=false")
                                && $0.sanitizedDimensions.contains("permitActive=false")
                                && $0.sanitizedDimensions.contains("publicationPending=false")
                        }
                    }
                    XCTAssertTrue(ownershipStateArrived)
                    await manager.debugAwaitCodeStructureSettlementDrain(windowID: windowID)

                    let finalEvents = recorder.snapshot().filter { $0.invocationID == detachedEvent.invocationID }
                    let settledEvent = try XCTUnwrap(finalEvents.first { $0.phase == .detachedSettled })
                    XCTAssertTrue(settledEvent.isAlwaysEmitted)
                    XCTAssertEqual(settledEvent.cancellationOutcome, "success")
                    XCTAssertEqual(settledEvent.cancellationOrigin, .watchdogDeadline)
                    XCTAssertEqual(settledEvent.settlement, "detached")
                    XCTAssertFalse(finalEvents.contains { $0.phase == .handlerCompleted })

                    let lateCapture = EditFlowPerf.debugCaptureSnapshot(finish: false)
                    XCTAssertEqual(
                        lateCapture.lifecycleEvents.count { $0.eventName == "MCP.ToolCall.HandlerResultReady" },
                        responseReadyCountBeforeLateSettlement,
                        "Late provider settlement must not publish a handler-result-ready companion"
                    )
                    XCTAssertTrue(lateCapture.lifecycleEvents.contains {
                        $0.eventName == "MCP.ToolCall.ResolvedProviderEnded"
                            && $0.sanitizedDimensions.contains("tool=get_code_structure")
                            && $0.sanitizedDimensions.contains("outcome=detached_settled_success")
                    })
                    XCTAssertTrue(lateCapture.lifecycleEvents.contains {
                        $0.eventName == "MCP.ToolCall.PublicationOwnershipState"
                            && $0.sanitizedDimensions.contains("tool=get_code_structure")
                            && $0.sanitizedDimensions.contains("outcome=detached_settled")
                            && $0.sanitizedDimensions.contains("providerActive=false")
                            && $0.sanitizedDimensions.contains("networkScopeActive=false")
                            && $0.sanitizedDimensions.contains("permitActive=false")
                            && $0.sanitizedDimensions.contains("publicationPending=false")
                    })
                    let drainedSnapshot = await manager.debugCodeStructureSettlementSnapshot(windowID: windowID)
                    XCTAssertEqual(
                        drainedSnapshot,
                        .init(activeCount: 0, detachedCount: 0)
                    )
                    let lateSettledDiagnostic = await manager.debugCodeStructureSettlementDiagnosticSnapshot(
                        windowID: windowID,
                        now: clock.currentTime()
                    )
                    XCTAssertTrue(lateSettledDiagnostic.leases.isEmpty)
                    let sleeperCountAfterDrain = await clock.sleeperCount()
                    XCTAssertEqual(sleeperCountAfterDrain, 0)

                    // A fresh generation is admitted after drain and completes normally.
                    await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.getCodeStructure) {
                        await MCPToolExecutionHandlerPhaseContext.report(.getCodeStructureGraphTraversal)
                        return try await provider.run()
                    }
                    let postDrainResponse = try await endpoint.callTool(
                        name: MCPWindowToolName.getCodeStructure,
                        arguments: arguments
                    )
                    let postDrainPayload = try Self.toolResultObject(postDrainResponse)
                    XCTAssertEqual((postDrainPayload["ordinal"] as? NSNumber)?.intValue, 3)
                    let finalSleepersDrained = await Self.waitUntil { await clock.sleeperCount() == 0 }
                    XCTAssertTrue(finalSleepersDrained)

                    _ = EditFlowPerf.debugCaptureSnapshot(finish: true)
                    EditFlowPerf.resetDebugCaptureForTesting()
                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPWindowToolName.getCodeStructure,
                        operation: nil
                    )
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    await provider.releaseFirst()
                    await repeatedEscapeGate.release()
                    firstResponseTask?.cancel()
                    if let firstResponseTask { _ = try? await firstResponseTask.value }
                    _ = EditFlowPerf.debugCaptureSnapshot(finish: true)
                    EditFlowPerf.resetDebugCaptureForTesting()
                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPWindowToolName.getCodeStructure,
                        operation: nil
                    )
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    await fixture.cleanup()
                    throw error
                }
            }
        }

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
                    fingerprint: "test:verified:prompt-export-watchdog"
                )
            )
            try await activateWorkspace(for: context)
            let bindResponse = try await endpoint.callTool(
                name: "bind_context",
                arguments: ["op": "bind", "context_id": context.tabID.uuidString]
            )
            let bindText = try toolResultText(bindResponse)
            XCTAssertFalse(bindText.contains("Error:"), bindText)
            await context.window.mcpServer.domainRoutingPublishTask?.value
        }

        private static func journalRecord(operationID: String) async throws -> DomainMutationJournalRecord {
            let snapshot = try await AppDomainRuntimeComposition.shared.runtime.mutationJournal.snapshot()
            return try XCTUnwrap(
                snapshot.recordSnapshots.last { $0.operationID == operationID },
                "Missing mutation journal record for \(operationID)"
            )
        }

        private static func activateWorkspace(for context: PersistentMCPTestContext) async throws {
            let workspace = try XCTUnwrap(
                context.window.workspaceManager.workspaces.first { $0.id == context.workspaceID }
            )
            await context.window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "MCPToolExecutionWatchdogIntegrationTests"
            )
            context.window.promptManager.loadComposeTabsFromWorkspace(
                workspace,
                syncPromptText: true
            )
        }

        private static func waitUntil(
            timeout: Duration = .seconds(10),
            condition: () async -> Bool
        ) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline {
                if await condition() {
                    return true
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return await condition()
        }

        private static func cleanupEndpoint(
            _ endpoint: PersistentMCPTestEndpoint,
            manager: ServerNetworkManager
        ) async {
            endpoint.client.close()
            await endpoint.connectionManager.stop()
            await manager.debugRemoveConnection(endpoint.connectionID)
            await manager.debugClearPersistedRoutingState(for: endpoint.clientName)
        }

        private static func toolResultText(_ response: PersistentMCPTestRPCResponse) throws -> String {
            let data = try XCTUnwrap(response.rawJSON.data(using: .utf8))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let result = try XCTUnwrap(object["result"] as? [String: Any])
            let content = try XCTUnwrap(result["content"] as? [[String: Any]])
            return content.compactMap { $0["text"] as? String }.joined()
        }

        private static func toolResultObject(_ response: PersistentMCPTestRPCResponse) throws -> [String: Any] {
            let text = try toolResultText(response)
            let data = try XCTUnwrap(text.data(using: .utf8))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        private static func detachedReadFileOrigin(
            in events: [MCPToolExecutionTraceEvent],
            connectionID: UUID
        ) -> MCPToolExecutionTraceEvent? {
            events.first {
                $0.connectionID == connectionID
                    && $0.toolName == MCPWindowToolName.readFile
                    && $0.phase == .detachedForSettlement
            }
        }

        private static func assertSocketClosed(
            _ task: Task<PersistentMCPTestRPCResponse, Error>,
            request: String = "request"
        ) async {
            do {
                _ = try await task.value
                XCTFail("Expected socket closure for \(request)")
            } catch PersistentMCPTestSocketClient.ClientError.closed {
                // Expected.
            } catch {
                XCTFail("Expected socket closure for \(request), got \(error)")
            }
        }
    }

    @MainActor
    private final class MCPAppSettingsServiceScope {
        private let baselineDisabled: Bool
        private var restored = false

        private init(baselineDisabled: Bool) {
            self.baselineDisabled = baselineDisabled
        }

        static func install() async throws -> MCPAppSettingsServiceScope {
            try await AppGlobalMCPServiceComposition.shared.ensureRegistered()
            let baselineDisabled = ToolAvailabilityStore.shared.disabledTools.contains(MCPGlobalToolName.appSettings)
            let scope = MCPAppSettingsServiceScope(baselineDisabled: baselineDisabled)
            if baselineDisabled {
                await ToolAvailabilityStore.shared.toggle(MCPGlobalToolName.appSettings, enabled: true)
            }

            let catalog = await AppDomainRuntimeComposition.shared.catalogSnapshot()
            let isRegistered = catalog.activeScopesByToolName[MCPGlobalToolName.appSettings]?.contains(.application) == true
            let isAvailable = ToolAvailabilityStore.shared.toolSummaries.contains {
                $0.name == MCPGlobalToolName.appSettings
            }
            guard isRegistered, isAvailable else {
                await scope.restore()
                throw MCPExecutionWatchdogIntegrationFixtureError.toolAvailabilityDidNotPublish(
                    MCPGlobalToolName.appSettings
                )
            }
            XCTAssertTrue(ToolAvailabilityStore.shared.isEnabled(MCPGlobalToolName.appSettings))
            return scope
        }

        func restore() async {
            guard !restored else { return }
            restored = true

            let isDisabled = ToolAvailabilityStore.shared.disabledTools.contains(MCPGlobalToolName.appSettings)
            if isDisabled != baselineDisabled {
                await ToolAvailabilityStore.shared.toggle(
                    MCPGlobalToolName.appSettings,
                    enabled: !baselineDisabled
                )
            }
        }

        func assertRestored(file: StaticString = #filePath, line: UInt = #line) async {
            let catalog = await AppDomainRuntimeComposition.shared.catalogSnapshot()
            let isRegistered = catalog.activeScopesByToolName[MCPGlobalToolName.appSettings]?.contains(.application) == true
            XCTAssertTrue(isRegistered, file: file, line: line)
            XCTAssertTrue(
                ToolAvailabilityStore.shared.toolSummaries.contains {
                    $0.name == MCPGlobalToolName.appSettings
                },
                file: file,
                line: line
            )
            XCTAssertEqual(
                ToolAvailabilityStore.shared.disabledTools.contains(MCPGlobalToolName.appSettings),
                baselineDisabled,
                file: file,
                line: line
            )
        }
    }

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

    private final class MCPSettlementTransitionEvidenceRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var transitions: [MCPCodeStructureSettlementRegistry.DebugTransitionEvidence] = []

        func append(_ evidence: MCPCodeStructureSettlementRegistry.DebugTransitionEvidence) {
            lock.withLock {
                transitions.append(evidence)
            }
        }

        func snapshot() -> [MCPCodeStructureSettlementRegistry.DebugTransitionEvidence] {
            lock.withLock { transitions }
        }
    }

    private final class MCPDebugCaptureManualMonotonicClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64

        init(nowNanoseconds: UInt64) {
            value = nowNanoseconds
        }

        func nowNanoseconds() -> UInt64 {
            lock.withLock { value }
        }

        func setNowNanoseconds(_ value: UInt64) {
            lock.withLock {
                self.value = value
            }
        }
    }

    private actor MCPQualifiedReadCompletionProbe {
        private var completed = false

        func markCompleted() {
            completed = true
        }

        func isCompleted() -> Bool {
            completed
        }
    }

    /// Cooperative cancel probe: thin wrapper over shared `TestCancellationGate`.
    private actor MCPExecutionCooperativeCancellationGate {
        private static let synchronizationTimeout: Duration = .seconds(10)

        private let gate = TestCancellationGate(name: "MCP execution cooperative cancellation gate")

        func enterAndWait() async throws {
            try await gate.waitUntilCancelled()
        }

        func waitUntilEntered(
            timeout: Duration = synchronizationTimeout
        ) async throws {
            let entered = await gate.waitUntilEntered(
                timeout: TestFenceDefaults.timeInterval(timeout),
                failOnTimeout: false
            )
            guard entered else {
                throw MCPExecutionWatchdogIntegrationFixtureError.cooperativeGateDidNotEnter
            }
        }

        func waitUntilCancellationObserved(
            timeout: Duration = synchronizationTimeout
        ) async throws {
            let timeoutInterval = TestFenceDefaults.timeInterval(timeout)
            do {
                try await AsyncTestWait.waitUntil(
                    "MCP cooperative gate cancellation observed",
                    timeout: timeoutInterval
                ) {
                    self.gate.cancellationCount > 0
                }
            } catch {
                throw MCPExecutionWatchdogIntegrationFixtureError.cooperativeGateCancellationNotObserved
            }
        }

        func observedCancellationCount() async -> Int {
            gate.cancellationCount
        }

        func cancelForCleanup() async {
            gate.forceCancel()
        }
    }

    private actor MCPPostProviderAdmissionProbe {
        private static let synchronizationTimeout: Duration = .seconds(10)

        private var connectionIDs: [UUID] = []

        func record(connectionID: UUID?) -> Value {
            if let connectionID {
                connectionIDs.append(connectionID)
            }
            return .object(["status": .string("ok")])
        }

        func waitUntilEntered(
            connectionID: UUID,
            timeout: Duration = synchronizationTimeout
        ) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while !connectionIDs.contains(connectionID) {
                try Task.checkCancellation()
                guard clock.now < deadline else {
                    throw MCPExecutionWatchdogIntegrationFixtureError.gateDidNotEnter(
                        expected: 1,
                        actual: connectionIDs.count
                    )
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    private actor MCPCodeStructureSettlementProviderProbe {
        private static let synchronizationTimeout: Duration = .seconds(10)

        private var count = 0
        private var activeCount = 0
        private var maximumActiveCount = 0
        private var firstReleased = false
        private var firstReleaseWaiters: [CheckedContinuation<Void, Never>] = []

        func run() async throws -> Value {
            count += 1
            activeCount += 1
            maximumActiveCount = max(maximumActiveCount, activeCount)
            defer { activeCount -= 1 }
            let ordinal = count
            if ordinal == 1, !firstReleased {
                await withCheckedContinuation { firstReleaseWaiters.append($0) }
            }
            return .object(["ordinal": .int(ordinal)])
        }

        func waitUntilEntered(
            count expected: Int,
            timeout: Duration = synchronizationTimeout
        ) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while count < expected {
                try Task.checkCancellation()
                guard clock.now < deadline else {
                    throw MCPExecutionWatchdogIntegrationFixtureError.gateDidNotEnter(
                        expected: expected,
                        actual: count
                    )
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        func enteredCount() -> Int {
            count
        }

        func maximumConcurrentCount() -> Int {
            maximumActiveCount
        }

        func releaseFirst() {
            firstReleased = true
            firstReleaseWaiters.forEach { $0.resume() }
            firstReleaseWaiters.removeAll()
        }
    }

    actor MCPExecutionIgnoringCancellationGate {
        private static let synchronizationTimeout: Duration = .seconds(10)

        private var count = 0
        private var released = false
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func enterAndWait() async {
            count += 1
            guard !released else { return }
            await withCheckedContinuation { releaseWaiters.append($0) }
        }

        func waitUntilEntered(
            count expected: Int,
            timeout: Duration = synchronizationTimeout
        ) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while count < expected {
                try Task.checkCancellation()
                guard clock.now < deadline else {
                    throw MCPExecutionWatchdogIntegrationFixtureError.gateDidNotEnter(
                        expected: expected,
                        actual: count
                    )
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        func enteredCount() -> Int {
            count
        }

        func release() {
            released = true
            releaseWaiters.forEach { $0.resume() }
            releaseWaiters.removeAll()
        }
    }

    private enum MCPExecutionWatchdogIntegrationFixtureError: Error {
        case cooperativeGateCancellationNotObserved
        case cooperativeGateDidNotEnter
        case gateDidNotEnter(expected: Int, actual: Int)
        case toolAvailabilityDidNotPublish(String)
    }

#endif
