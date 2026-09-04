import Darwin
import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptShared
import XCTest

final class MCPToolExecutionPhaseHistoryTests: XCTestCase {
    func testHistoryPreservesObservedTimeAndAssignsOrderedIngestionSequenceAtFixedCapacity() async throws {
        let history = MCPToolExecutionPhaseHistoryRecorder(
            maximumInvocationCount: 2,
            maximumEventsPerInvocation: 3
        )
        let clock = LockedDurationClock()
        let connectionID = UUID()
        let invocationID = UUID()
        let recorder = makeRecorder(
            history: history,
            clock: clock,
            connectionID: connectionID,
            invocationID: invocationID
        )

        clock.set(.milliseconds(30))
        await recorder.report(.readFileRequestResolution, transition: .started)
        clock.set(.milliseconds(20))
        await recorder.report(.readFileRequestResolution, transition: .completed)
        clock.set(.milliseconds(40))
        await recorder.report(.readFileContentRead, transition: .started)
        clock.set(.milliseconds(50))
        await recorder.report(.readFileContentRead, transition: .completed)

        let invocation = try XCTUnwrap(history.snapshot().only)
        XCTAssertEqual(invocation.appConnectionID, connectionID)
        XCTAssertEqual(invocation.invocationID, invocationID)
        XCTAssertEqual(invocation.canonicalToolName, "read_file")
        XCTAssertEqual(invocation.droppedEventCount, 1)
        XCTAssertEqual(invocation.events.map(\.ingestionSequence), [2, 3, 4])
        XCTAssertEqual(invocation.events.map(\.observedElapsedMilliseconds), [20, 40, 50])
        XCTAssertEqual(invocation.events.map(\.handlerTransition), [.completed, .started, .completed])
        XCTAssertEqual(recorder.snapshot()?.phase, .readFileContentRead)
        recorder.reset()
        XCTAssertNil(recorder.snapshot())
        XCTAssertEqual(history.snapshot().only?.events.count, 3)
    }

    func testHandlerLatestSnapshotClampsElapsedToZeroWhenClockMovesBackwards() async {
        let clock = LockedDurationClock()
        clock.set(.milliseconds(20))
        #if DEBUG
            let recorder = MCPToolExecutionHandlerPhaseRecorder(
                operationIdentity: readFileOperationIdentity(),
                appConnectionID: UUID(),
                correlationConnectionID: MCPDiagnosticBoundedString("backwards-clock-test"),
                invocationID: UUID(),
                origin: .milliseconds(30),
                now: { clock.now() },
                phaseHistory: MCPToolExecutionPhaseHistoryRecorder()
            )
        #else
            let recorder = MCPToolExecutionHandlerPhaseRecorder(
                origin: .milliseconds(30),
                now: { clock.now() }
            )
        #endif

        await recorder.report(.readFileRequestResolution, transition: .started)

        XCTAssertEqual(recorder.snapshot()?.elapsedMilliseconds, 0)
    }

    func testConcurrentObservationsKeepTheirOriginalTimeAndUseSynchronizedIngestionOrder() async throws {
        let history = MCPToolExecutionPhaseHistoryRecorder(
            maximumInvocationCount: 1,
            maximumEventsPerInvocation: 4
        )
        let appConnectionID = UUID()
        let invocationID = UUID()
        let firstClock = ControlledDurationClock()
        let secondClock = ControlledDurationClock()
        let first = MCPToolExecutionHandlerPhaseRecorder(
            operationIdentity: readFileOperationIdentity(),
            appConnectionID: appConnectionID,
            correlationConnectionID: MCPDiagnosticBoundedString("bridge-connection"),
            invocationID: invocationID,
            origin: .zero,
            now: { await firstClock.now() },
            phaseHistory: history
        )
        let second = MCPToolExecutionHandlerPhaseRecorder(
            operationIdentity: readFileOperationIdentity(),
            appConnectionID: appConnectionID,
            correlationConnectionID: MCPDiagnosticBoundedString("bridge-connection"),
            invocationID: invocationID,
            origin: .zero,
            now: { await secondClock.now() },
            phaseHistory: history
        )

        let firstReport = Task {
            await first.report(.readFileRequestResolution, transition: .started)
        }
        let secondReport = Task {
            await second.report(.readFileContentRead, transition: .started)
        }
        await firstClock.waitUntilObserved()
        await secondClock.waitUntilObserved()
        await firstClock.release(.milliseconds(30))
        await firstReport.value
        await secondClock.release(.milliseconds(10))
        await secondReport.value

        let events = try XCTUnwrap(history.snapshot().only).events
        XCTAssertEqual(events.map(\.ingestionSequence), [1, 2])
        XCTAssertEqual(events.map(\.observedElapsedMilliseconds), [30, 10])
    }

    func testLifecycleCannotIngestBeforeHandlerPhaseItObserved() async throws {
        let history = MCPToolExecutionPhaseHistoryRecorder(
            maximumInvocationCount: 1,
            maximumEventsPerInvocation: 4
        )
        let clock = LockedDurationClock()
        let connectionID = UUID()
        let invocationID = UUID()
        let recorder = makeRecorder(
            history: history,
            clock: clock,
            connectionID: connectionID,
            invocationID: invocationID
        )
        let epoch = history.captureEpoch()
        let lifecycleTrace = traceEvent(
            phase: .started,
            historyEpoch: epoch,
            operationIdentity: readFileOperationIdentity(),
            connectionID: connectionID,
            invocationID: invocationID,
            elapsedMilliseconds: 2
        )
        let publicationGate = FirstPhasePublicationGate()
        MCPDiagnosticCaptureCoordinator.setTestWillEnterSink { operation in
            publicationGate.intercept(operation)
        }
        defer {
            publicationGate.release()
            MCPDiagnosticCaptureCoordinator.setTestWillEnterSink(nil)
        }

        clock.set(.milliseconds(1))
        let handlerReport = Task {
            await recorder.report(.readFileRequestResolution, transition: .started)
        }
        XCTAssertTrue(publicationGate.waitUntilBlocked())

        let lifecycleTaskStarted = DispatchSemaphore(value: 0)
        let snapshotReturned = DispatchSemaphore(value: 0)
        let lifecycleReport = Task.detached {
            lifecycleTaskStarted.signal()
            _ = recorder.snapshot()
            snapshotReturned.signal()
            history.recordExecutionTrace(lifecycleTrace)
        }
        XCTAssertEqual(lifecycleTaskStarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(snapshotReturned.wait(timeout: .now() + 2), .timedOut)
        XCTAssertEqual(history.snapshot(), [])

        publicationGate.release()
        await handlerReport.value
        await lifecycleReport.value

        let events = try XCTUnwrap(history.snapshot().only).events
        XCTAssertEqual(events.map(\.kind), [.handlerPhase, .executionLifecycle])
        XCTAssertEqual(events.map(\.ingestionSequence), [1, 2])
    }

    func testInvocationHistoriesAreIsolatedAndResetDeterministically() async throws {
        let history = MCPToolExecutionPhaseHistoryRecorder(
            maximumInvocationCount: 2,
            maximumEventsPerInvocation: 4
        )
        let clock = LockedDurationClock()
        let connectionID = UUID()
        let firstInvocationID = UUID()
        let secondInvocationID = UUID()
        let first = makeRecorder(
            history: history,
            clock: clock,
            connectionID: connectionID,
            invocationID: firstInvocationID
        )
        let second = makeRecorder(
            history: history,
            clock: clock,
            connectionID: connectionID,
            invocationID: secondInvocationID
        )

        clock.set(.milliseconds(1))
        await first.report(.readFileRequestResolution, transition: .started)
        clock.set(.milliseconds(2))
        await second.report(.readFileContentRead, transition: .started)

        let histories = history.snapshot()
        XCTAssertEqual(histories.map(\.invocationID), [firstInvocationID, secondInvocationID])
        XCTAssertEqual(histories.map { $0.events.map(\.ingestionSequence) }, [[1], [1]])
        XCTAssertEqual(histories[0].events.only?.handlerPhase, .readFileRequestResolution)
        XCTAssertEqual(histories[1].events.only?.handlerPhase, .readFileContentRead)

        history.reset()
        XCTAssertEqual(history.snapshot(), [])

        clock.set(.milliseconds(3))
        await second.report(.readFileContentRead, transition: .completed)
        XCTAssertEqual(history.snapshot(), [], "A recorder from the prior capture epoch must not repopulate reset state")

        let afterReset = makeRecorder(
            history: history,
            clock: clock,
            connectionID: connectionID,
            invocationID: UUID()
        )
        await afterReset.report(.readFileContentRead, transition: .completed)
        let restarted = try XCTUnwrap(history.snapshot().only)
        XCTAssertEqual(restarted.events.map(\.ingestionSequence), [1])
    }

    func testHistorySchemaContainsOnlyBoundedDiagnosticFields() async throws {
        let history = MCPToolExecutionPhaseHistoryRecorder(
            maximumInvocationCount: 1,
            maximumEventsPerInvocation: 1
        )
        let clock = LockedDurationClock()
        let recorder = makeRecorder(
            history: history,
            clock: clock,
            connectionID: UUID(),
            invocationID: UUID(),
            correlationConnectionID: String(repeating: "é", count: 64) + "x"
        )

        clock.set(.milliseconds(5))
        await recorder.report(.readFileContentRead, transition: .started)

        let payload = try XCTUnwrap(history.snapshot().only?.debugPayload)
        XCTAssertEqual(Set(payload.keys), Set([
            "tool",
            "app_connection_id",
            "correlation_connection_id",
            "correlation_connection_id_omitted",
            "correlation_connection_id_truncated",
            "correlation_connection_id_utf8_byte_count",
            "app_invocation_id",
            "dropped_event_count",
            "events"
        ]))
        let eventPayload = try XCTUnwrap((payload["events"] as? [[String: Any]])?.only)
        XCTAssertEqual(Set(eventPayload.keys), Set([
            "ingestion_sequence",
            "observed_elapsed_ms",
            "kind",
            "handler_phase",
            "handler_transition",
            "execution_phase",
            "cancellation_requested",
            "cancellation_origin",
            "terminal_outcome"
        ]))
        XCTAssertEqual(payload["tool"] as? String, "read_file")
        XCTAssertTrue(payload["correlation_connection_id"] is NSNull)
        XCTAssertEqual(payload["correlation_connection_id_omitted"] as? Bool, true)
        XCTAssertEqual(payload["correlation_connection_id_truncated"] as? Bool, false)
        XCTAssertEqual(payload["correlation_connection_id_utf8_byte_count"] as? Int, 129)

        history.reset()
        let absentRecorder = makeRecorder(
            history: history,
            clock: clock,
            connectionID: UUID(),
            invocationID: UUID()
        )
        await absentRecorder.report(.readFileContentRead, transition: .started)
        let absentPayload = try XCTUnwrap(history.snapshot().only?.debugPayload)
        XCTAssertTrue(absentPayload["correlation_connection_id"] is NSNull)
        XCTAssertEqual(absentPayload["correlation_connection_id_omitted"] as? Bool, false)
        XCTAssertEqual(absentPayload["correlation_connection_id_truncated"] as? Bool, false)
        XCTAssertTrue(absentPayload["correlation_connection_id_utf8_byte_count"] is NSNull)

        history.reset()
        let acceptedCorrelationID = String(repeating: "é", count: 64)
        let inBoundRecorder = makeRecorder(
            history: history,
            clock: clock,
            connectionID: UUID(),
            invocationID: UUID(),
            correlationConnectionID: acceptedCorrelationID
        )
        await inBoundRecorder.report(.readFileContentRead, transition: .started)
        let inBoundPayload = try XCTUnwrap(history.snapshot().only?.debugPayload)
        XCTAssertEqual(inBoundPayload["correlation_connection_id"] as? String, acceptedCorrelationID)
        XCTAssertEqual(inBoundPayload["correlation_connection_id_omitted"] as? Bool, false)
        XCTAssertEqual(inBoundPayload["correlation_connection_id_truncated"] as? Bool, false)
        XCTAssertEqual(inBoundPayload["correlation_connection_id_utf8_byte_count"] as? Int, 128)
    }

    func testCaptureBeginResetsDiagnosticsOnlyAfterAdmissionAndBusyBeginPreservesThem() async throws {
        let history = MCPToolExecutionPhaseHistoryRecorder.shared
        EditFlowPerf.resetDebugCaptureForTesting()
        history.reset()
        MCPResponseDeliveryTracer.resetDebugEvents()
        MCPDiagnosticCaptureCoordinator.withBoundary(operation: .captureMutation) {
            MCPDiagnosticCaptureCoordinator.beginCapture()
        }
        defer {
            _ = MCPDiagnosticCaptureCoordinator.finishCapture()
            _ = EditFlowPerf.debugCaptureSnapshot(finish: true)
            EditFlowPerf.resetDebugCaptureForTesting()
            history.reset()
            MCPResponseDeliveryTracer.resetDebugEvents()
        }

        let connectionID = UUID()
        let invocationID = UUID()
        MCPToolExecutionTracer.emit(traceEvent(
            phase: .started,
            historyEpoch: history.captureEpoch(),
            operationIdentity: readFileOperationIdentity(),
            connectionID: connectionID,
            invocationID: invocationID,
            elapsedMilliseconds: 1
        ))
        MCPResponseDeliveryTracer.emit(deliveryEvent(
            layer: "app_tool_handler",
            generation: 1,
            invocationID: invocationID
        ), to: -1)
        XCTAssertEqual(history.snapshot().count, 1)
        XCTAssertEqual(MCPResponseDeliveryTracer.debugEventSnapshot().count, 1)

        let initialEpoch = history.captureEpoch()
        let started = await ServerNetworkManager.shared.debugMCPReadSearchCaptureBeginPayload(
            op: "mcp_read_search_capture_begin",
            arguments: ["label": .string("first")]
        )
        let startedPayload = try diagnosticsPayload(started)
        XCTAssertEqual(startedPayload["ok"] as? Bool, true)
        XCTAssertEqual(history.captureEpoch(), initialEpoch + 1)
        XCTAssertEqual(history.snapshot(), [])
        XCTAssertEqual(MCPResponseDeliveryTracer.debugEventSnapshot(), [])

        let activeEpoch = history.captureEpoch()
        let activeInvocationID = UUID()
        history.recordExecutionTrace(traceEvent(
            phase: .started,
            historyEpoch: activeEpoch,
            operationIdentity: readFileOperationIdentity(),
            connectionID: connectionID,
            invocationID: activeInvocationID,
            elapsedMilliseconds: 2
        ))
        MCPResponseDeliveryTracer.emit(deliveryEvent(
            layer: "app_tool_handler",
            generation: 1,
            invocationID: activeInvocationID
        ), to: -1)

        let busy = await ServerNetworkManager.shared.debugMCPReadSearchCaptureBeginPayload(
            op: "mcp_read_search_capture_begin",
            arguments: ["label": .string("second")]
        )
        let busyPayload = try diagnosticsPayload(busy)
        XCTAssertEqual(busyPayload["ok"] as? Bool, false)
        XCTAssertEqual(busyPayload["code"] as? String, "capture_busy")
        XCTAssertEqual(history.captureEpoch(), activeEpoch)
        XCTAssertEqual(history.snapshot().map(\.invocationID), [activeInvocationID])
        XCTAssertEqual(MCPResponseDeliveryTracer.debugEventSnapshot().count, 1)
    }

    func testSharedCoordinationPreventsPublicationBetweenResetStoresAndFencesOldRecorders() async {
        let history = MCPToolExecutionPhaseHistoryRecorder.shared
        EditFlowPerf.resetDebugCaptureForTesting()
        history.reset()
        MCPResponseDeliveryTracer.resetDebugEvents()
        MCPToolWorkCountDiagnostics.resetForTesting()
        MCPDiagnosticCaptureCoordinator.withBoundary(operation: .captureMutation) {
            MCPDiagnosticCaptureCoordinator.beginCapture()
        }
        let attempts = PublicationAttemptLatch()
        MCPDiagnosticCaptureCoordinator.setTestWillEnterSink { attempts.record($0) }
        defer {
            MCPDiagnosticCaptureCoordinator.setTestWillEnterSink(nil)
            _ = MCPDiagnosticCaptureCoordinator.finishCapture()
            _ = EditFlowPerf.debugCaptureSnapshot(finish: true)
            EditFlowPerf.resetDebugCaptureForTesting()
            history.reset()
            MCPResponseDeliveryTracer.resetDebugEvents()
            MCPToolWorkCountDiagnostics.resetForTesting()
        }

        let workEntered = AsyncOneShotGate()
        let releaseWork = AsyncOneShotGate()
        let workTask = Task {
            await MCPToolWorkCountDiagnostics.withReadFileInvocation {
                await workEntered.open()
                await releaseWork.wait()
            }
        }
        await workEntered.wait()

        let clock = LockedDurationClock()
        clock.set(.milliseconds(1))
        let phaseRecorder = makeRecorder(
            history: history,
            clock: clock,
            connectionID: UUID(),
            invocationID: UUID()
        )
        let midpoint = DispatchSemaphore(value: 0)
        let continueReset = DispatchSemaphore(value: 0)
        let resetTask = Task.detached {
            MCPDiagnosticCaptureCoordinator.withBoundary(operation: .captureMutation) {
                _ = EditFlowPerf.beginDebugCapture(label: "coordinated-reset", maxSamples: 100)
                MCPDiagnosticCaptureCoordinator.beginCapture()
                MCPResponseDeliveryTracer.resetDebugEvents()
                midpoint.signal()
                continueReset.wait()
                history.reset()
                MCPToolWorkCountDiagnostics.resetForTesting()
                let work = MCPToolWorkCountDiagnostics.debugSnapshots()
                return (
                    delivery: MCPResponseDeliveryTracer.debugEventSnapshot().count,
                    phase: history.snapshot().count,
                    work: work.git.count + work.readFile.count
                )
            }
        }

        XCTAssertEqual(midpoint.wait(timeout: .now() + 2), .success)
        let phaseTask = Task { await phaseRecorder.report(.readFileContentRead, transition: .started) }
        let delivery = deliveryEvent(layer: "app_tool_handler", generation: 1, invocationID: UUID())
        let deliveryTask = Task.detached {
            MCPResponseDeliveryTracer.emit(delivery, to: -1)
        }
        await releaseWork.open()
        XCTAssertTrue(attempts.waitForAllPublications())
        continueReset.signal()

        let cut = await resetTask.value
        await phaseTask.value
        await workTask.value
        await deliveryTask.value
        XCTAssertEqual(cut.delivery, 0)
        XCTAssertEqual(cut.phase, 0)
        XCTAssertEqual(cut.work, 0)
        XCTAssertEqual(MCPResponseDeliveryTracer.debugEventSnapshot(), [])
        XCTAssertEqual(history.snapshot(), [])
        let finalWork = MCPToolWorkCountDiagnostics.debugSnapshots()
        XCTAssertEqual(finalWork.git, [])
        XCTAssertEqual(finalWork.readFile, [])
    }

    func testSharedCoordinationProducesConsistentFinishSnapshotCut() async {
        let history = MCPToolExecutionPhaseHistoryRecorder.shared
        EditFlowPerf.resetDebugCaptureForTesting()
        history.reset()
        MCPResponseDeliveryTracer.resetDebugEvents()
        MCPToolWorkCountDiagnostics.resetForTesting()
        _ = await ServerNetworkManager.shared.debugMCPReadSearchCaptureBeginPayload(
            op: "mcp_read_search_capture_begin",
            arguments: ["label": .string("coordinated-finish")]
        )
        let attempts = PublicationAttemptLatch()
        MCPDiagnosticCaptureCoordinator.setTestWillEnterSink { attempts.record($0) }
        defer {
            MCPDiagnosticCaptureCoordinator.setTestWillEnterSink(nil)
            _ = MCPDiagnosticCaptureCoordinator.finishCapture()
            _ = EditFlowPerf.debugCaptureSnapshot(finish: true)
            EditFlowPerf.resetDebugCaptureForTesting()
            history.reset()
            MCPResponseDeliveryTracer.resetDebugEvents()
            MCPToolWorkCountDiagnostics.resetForTesting()
        }

        let workEntered = AsyncOneShotGate()
        let releaseWork = AsyncOneShotGate()
        let workTask = Task {
            await MCPToolWorkCountDiagnostics.withReadFileInvocation {
                await workEntered.open()
                await releaseWork.wait()
            }
        }
        await workEntered.wait()

        let clock = LockedDurationClock()
        clock.set(.milliseconds(1))
        let phaseRecorder = makeRecorder(
            history: history,
            clock: clock,
            connectionID: UUID(),
            invocationID: UUID()
        )
        let midpoint = DispatchSemaphore(value: 0)
        let continueSnapshot = DispatchSemaphore(value: 0)
        let snapshotTask = Task.detached {
            MCPDiagnosticCaptureCoordinator.withBoundary(operation: .captureMutation) {
                let capture = EditFlowPerf.debugCaptureSnapshot(finish: true)
                let delivery = MCPResponseDeliveryTracer.debugEventSnapshot()
                midpoint.signal()
                continueSnapshot.wait()
                let phase = history.snapshot()
                let work = MCPToolWorkCountDiagnostics.debugSnapshots()
                _ = MCPDiagnosticCaptureCoordinator.finishCapture()
                return (
                    captureActive: capture.active,
                    delivery: delivery.count,
                    phase: phase.count,
                    work: work.git.count + work.readFile.count
                )
            }
        }

        XCTAssertEqual(midpoint.wait(timeout: .now() + 2), .success)
        let phaseTask = Task { await phaseRecorder.report(.readFileContentRead, transition: .started) }
        let delivery = deliveryEvent(layer: "app_tool_handler", generation: 1, invocationID: UUID())
        let deliveryTask = Task.detached {
            MCPResponseDeliveryTracer.emit(delivery, to: -1)
        }
        await releaseWork.open()
        XCTAssertTrue(attempts.waitForAllPublications())
        continueSnapshot.signal()

        let cut = await snapshotTask.value
        await phaseTask.value
        await workTask.value
        await deliveryTask.value
        XCTAssertFalse(cut.captureActive)
        XCTAssertEqual(cut.delivery, 0)
        XCTAssertEqual(cut.phase, 0)
        XCTAssertEqual(cut.work, 0)
        XCTAssertEqual(MCPResponseDeliveryTracer.debugEventSnapshot(), [])
        XCTAssertEqual(history.snapshot(), [])
        XCTAssertEqual(MCPToolWorkCountDiagnostics.debugSnapshots().readFile, [])
    }

    func testInactiveCaptureSkipsSharedHistoriesButPreservesHandlerLatestSnapshot() async {
        let history = MCPToolExecutionPhaseHistoryRecorder.shared
        _ = MCPDiagnosticCaptureCoordinator.finishCapture()
        history.reset()
        MCPResponseDeliveryTracer.resetDebugEvents()
        MCPToolWorkCountDiagnostics.resetForTesting()
        defer {
            _ = MCPDiagnosticCaptureCoordinator.finishCapture()
            history.reset()
            MCPResponseDeliveryTracer.resetDebugEvents()
            MCPToolWorkCountDiagnostics.resetForTesting()
        }

        let clock = LockedDurationClock()
        clock.set(.milliseconds(7))
        let recorder = makeRecorder(
            history: history,
            clock: clock,
            connectionID: UUID(),
            invocationID: UUID()
        )
        await recorder.report(.readFileContentRead, transition: .started)
        await MCPToolWorkCountDiagnostics.withReadFileInvocation {}
        MCPResponseDeliveryTracer.emit(deliveryEvent(
            layer: "app_tool_handler",
            generation: 1,
            invocationID: UUID()
        ), to: -1)

        XCTAssertEqual(recorder.snapshot()?.phase, .readFileContentRead)
        XCTAssertEqual(history.snapshot(), [])
        XCTAssertEqual(MCPToolWorkCountDiagnostics.debugSnapshots().readFile, [])
        XCTAssertEqual(MCPResponseDeliveryTracer.debugEventSnapshot(), [])
    }

    func testDeliveryRechecksCaptureAfterCoordinatorAdmission() async {
        let history = MCPToolExecutionPhaseHistoryRecorder.shared
        _ = MCPDiagnosticCaptureCoordinator.finishCapture()
        history.reset()
        MCPResponseDeliveryTracer.resetDebugEvents()
        MCPDiagnosticCaptureCoordinator.withBoundary(operation: .captureMutation) {
            MCPDiagnosticCaptureCoordinator.beginCapture()
        }
        defer {
            MCPDiagnosticCaptureCoordinator.setTestWillEnterSink(nil)
            _ = MCPDiagnosticCaptureCoordinator.finishCapture()
            history.reset()
            MCPResponseDeliveryTracer.resetDebugEvents()
        }

        var descriptors = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(pipe(&descriptors), 0)
        defer {
            if descriptors[0] >= 0 { close(descriptors[0]) }
            if descriptors[1] >= 0 { close(descriptors[1]) }
        }

        let reachedCoordinator = DispatchSemaphore(value: 0)
        let continuePublication = DispatchSemaphore(value: 0)
        MCPDiagnosticCaptureCoordinator.setTestWillEnterSink { operation in
            guard case .deliveryPublication = operation else { return }
            reachedCoordinator.signal()
            continuePublication.wait()
        }
        let event = deliveryEvent(layer: "stale_capture_probe", generation: 1, invocationID: UUID())
        let writeDescriptor = descriptors[1]
        let publication = Task.detached {
            MCPResponseDeliveryTracer.emit(event, to: writeDescriptor)
        }
        XCTAssertEqual(reachedCoordinator.wait(timeout: .now() + 2), .success)
        let losses = MCPDiagnosticCaptureCoordinator.withBoundary(operation: .captureMutation) {
            MCPDiagnosticCaptureCoordinator.finishCapture()
        }
        continuePublication.signal()
        await publication.value
        MCPDiagnosticCaptureCoordinator.setTestWillEnterSink(nil)

        close(descriptors[1])
        descriptors[1] = -1
        var bytes = [UInt8](repeating: 0, count: 1024)
        let byteCount = read(descriptors[0], &bytes, bytes.count)
        XCTAssertGreaterThan(byteCount, 0)
        guard byteCount > 0 else { return }
        XCTAssertTrue(String(decoding: bytes.prefix(byteCount), as: UTF8.self).contains("stale_capture_probe"))
        XCTAssertEqual(MCPResponseDeliveryTracer.debugEventSnapshot(), [])
        XCTAssertEqual(losses.coordinatorBoundaryContention, 0)
        XCTAssertEqual(losses.tracerLockContention, 0)
        XCTAssertEqual(losses.deliveryHistoryCapacity, 0)
        XCTAssertEqual(losses.phaseHistoryInvocationCapacity, 0)
        XCTAssertEqual(losses.workHistorySnapshotCapacity, 0)
    }

    func testDeliveryLossCountersAndCaptureScopeAreExportedByActualSnapshotHandler() async throws {
        let history = MCPToolExecutionPhaseHistoryRecorder.shared
        EditFlowPerf.resetDebugCaptureForTesting()
        _ = MCPDiagnosticCaptureCoordinator.finishCapture()
        history.reset()
        MCPResponseDeliveryTracer.resetDebugEvents()
        MCPToolWorkCountDiagnostics.resetForTesting()
        defer {
            _ = MCPDiagnosticCaptureCoordinator.finishCapture()
            _ = EditFlowPerf.debugCaptureSnapshot(finish: true)
            EditFlowPerf.resetDebugCaptureForTesting()
            history.reset()
            MCPResponseDeliveryTracer.resetDebugEvents()
            MCPToolWorkCountDiagnostics.resetForTesting()
        }

        _ = await ServerNetworkManager.shared.debugMCPReadSearchCaptureBeginPayload(
            op: "mcp_read_search_capture_begin",
            arguments: ["label": .string("losses")]
        )
        let event = deliveryEvent(layer: "app_tool_handler", generation: 1, invocationID: UUID())

        let boundaryHeld = DispatchSemaphore(value: 0)
        let releaseBoundary = DispatchSemaphore(value: 0)
        let boundaryTask = Task.detached {
            MCPDiagnosticCaptureCoordinator.withBoundary(operation: .captureMutation) {
                boundaryHeld.signal()
                releaseBoundary.wait()
            }
        }
        XCTAssertEqual(boundaryHeld.wait(timeout: .now() + 2), .success)
        MCPResponseDeliveryTracer.emit(event, to: -1)
        releaseBoundary.signal()
        await boundaryTask.value

        let tracerHeld = DispatchSemaphore(value: 0)
        let releaseTracer = DispatchSemaphore(value: 0)
        let tracerTask = Task.detached {
            MCPResponseDeliveryTracer.withDebugTracerLockForTesting {
                tracerHeld.signal()
                releaseTracer.wait()
            }
        }
        XCTAssertEqual(tracerHeld.wait(timeout: .now() + 2), .success)
        MCPResponseDeliveryTracer.emit(event, to: -1)
        releaseTracer.signal()
        await tracerTask.value

        MCPResponseDeliveryTracer.fillDebugEventHistoryToCapacityForTesting(with: event)
        MCPResponseDeliveryTracer.emit(event, to: -1)

        let phaseEpoch = history.captureEpoch()
        let oversizedRequestID = String(repeating: "é", count: 65)
        let oversizedConnectionID = String(repeating: "c", count: 129)
        let oversizedInvocationID = String(repeating: "i", count: 129)
        for index in 0 ... 64 {
            history.recordExecutionTrace(traceEvent(
                phase: .started,
                historyEpoch: phaseEpoch,
                operationIdentity: readFileOperationIdentity(),
                connectionID: UUID(),
                invocationID: UUID(),
                elapsedMilliseconds: Double(index)
            ))
            let identity = index == 64
                ? MCPRequestTimelineIdentity(
                    jsonRPCRequestID: .string(oversizedRequestID),
                    connectionID: oversizedConnectionID,
                    connectionGeneration: 1,
                    appInvocationID: oversizedInvocationID,
                    requestOrdinal: 1
                )
                : nil
            await MCPRequestTimelineContext.$current.withValue(identity) {
                await MCPToolWorkCountDiagnostics.withReadFileInvocation {}
            }
        }

        let result = await ServerNetworkManager.shared.debugMCPReadSearchCaptureSnapshotPayload(
            op: "mcp_read_search_capture_snapshot",
            arguments: [:]
        )
        let payload = try diagnosticsPayload(result)
        let scope = try XCTUnwrap(payload["capture_scope"] as? [String: Any])
        XCTAssertEqual(scope["process"] as? String, "app")
        XCTAssertEqual(
            scope["coordinated_delivery_through"] as? String,
            "app_uds_transport.transport_write_completed"
        )
        XCTAssertEqual(scope["proxy_stdout_evidence"] as? String, "external_cli_completion_or_timeout_required")
        XCTAssertEqual(scope["same_process_proxy_coverage"] as? String, "unit_tests_only")
        let losses = try XCTUnwrap(payload["delivery_event_losses"] as? [String: Any])
        XCTAssertEqual(losses["coordinator_boundary_contention"] as? Int, 1)
        XCTAssertEqual(losses["tracer_lock_contention"] as? Int, 1)
        XCTAssertEqual(losses["history_capacity"] as? Int, 1)
        let retentionLosses = try XCTUnwrap(payload["evidence_retention_losses"] as? [String: Any])
        XCTAssertEqual(retentionLosses["phase_history_invocation_capacity"] as? Int, 1)
        XCTAssertEqual(retentionLosses["work_history_snapshot_capacity"] as? Int, 1)
        XCTAssertEqual((payload["phase_histories"] as? [[String: Any]])?.count, 64)
        let workEvidence = try XCTUnwrap(payload["work_count_evidence"] as? [String: Any])
        let readFileEvidence = try XCTUnwrap(workEvidence["read_file"] as? [[String: Any]])
        XCTAssertEqual(readFileEvidence.count, 64)
        let requestIdentity = try XCTUnwrap(readFileEvidence.last?["request_identity"] as? [String: Any])
        XCTAssertTrue(requestIdentity["jsonrpc_request_id"] is NSNull)
        XCTAssertEqual(requestIdentity["jsonrpc_request_id_omitted"] as? Bool, true)
        XCTAssertEqual(requestIdentity["jsonrpc_request_id_truncated"] as? Bool, false)
        XCTAssertEqual(requestIdentity["jsonrpc_request_id_utf8_byte_count"] as? Int, 130)
        XCTAssertTrue(requestIdentity["connection_id"] is NSNull)
        XCTAssertEqual(requestIdentity["connection_id_omitted"] as? Bool, true)
        XCTAssertEqual(requestIdentity["connection_id_utf8_byte_count"] as? Int, 129)
        XCTAssertTrue(requestIdentity["app_invocation_id"] is NSNull)
        XCTAssertEqual(requestIdentity["app_invocation_id_omitted"] as? Bool, true)
        XCTAssertEqual(requestIdentity["app_invocation_id_utf8_byte_count"] as? Int, 129)
        XCTAssertEqual(payload["incomplete_capture"] as? Bool, true)

        _ = await ServerNetworkManager.shared.debugMCPReadSearchCaptureBeginPayload(
            op: "mcp_read_search_capture_begin",
            arguments: ["label": .string("loss-reset")]
        )
        let resetResult = await ServerNetworkManager.shared.debugMCPReadSearchCaptureSnapshotPayload(
            op: "mcp_read_search_capture_snapshot",
            arguments: [:]
        )
        let resetPayload = try diagnosticsPayload(resetResult)
        let resetLosses = try XCTUnwrap(resetPayload["evidence_retention_losses"] as? [String: Any])
        XCTAssertEqual(resetLosses["phase_history_invocation_capacity"] as? Int, 0)
        XCTAssertEqual(resetLosses["work_history_snapshot_capacity"] as? Int, 0)
        XCTAssertEqual(resetPayload["incomplete_capture"] as? Bool, false)
    }

    func testPhaseEventEvictionMarksCaptureIncomplete() async throws {
        let history = MCPToolExecutionPhaseHistoryRecorder.shared
        EditFlowPerf.resetDebugCaptureForTesting()
        _ = MCPDiagnosticCaptureCoordinator.finishCapture()
        history.reset()
        defer {
            _ = MCPDiagnosticCaptureCoordinator.finishCapture()
            _ = EditFlowPerf.debugCaptureSnapshot(finish: true)
            EditFlowPerf.resetDebugCaptureForTesting()
            history.reset()
        }

        _ = await ServerNetworkManager.shared.debugMCPReadSearchCaptureBeginPayload(
            op: "mcp_read_search_capture_begin",
            arguments: ["label": .string("phase-event-capacity")]
        )
        let epoch = history.captureEpoch()
        let connectionID = UUID()
        let invocationID = UUID()
        let operationIdentity = readFileOperationIdentity()
        for index in 0 ..< 129 {
            history.recordExecutionTrace(traceEvent(
                phase: .started,
                historyEpoch: epoch,
                operationIdentity: operationIdentity,
                connectionID: connectionID,
                invocationID: invocationID,
                elapsedMilliseconds: Double(index)
            ))
        }

        let result = await ServerNetworkManager.shared.debugMCPReadSearchCaptureSnapshotPayload(
            op: "mcp_read_search_capture_snapshot",
            arguments: [:]
        )
        let payload = try diagnosticsPayload(result)
        let phaseHistories = try XCTUnwrap(payload["phase_histories"] as? [[String: Any]])
        let invocation = try XCTUnwrap(phaseHistories.only)
        XCTAssertEqual(invocation["dropped_event_count"] as? Int, 1)
        XCTAssertEqual((invocation["events"] as? [[String: Any]])?.count, 128)
        let losses = try XCTUnwrap(payload["evidence_retention_losses"] as? [String: Any])
        XCTAssertEqual(losses["phase_history_event_capacity"] as? Int, 1)
        XCTAssertEqual(payload["incomplete_capture"] as? Bool, true)

        _ = await ServerNetworkManager.shared.debugMCPReadSearchCaptureBeginPayload(
            op: "mcp_read_search_capture_begin",
            arguments: ["label": .string("phase-event-capacity-reset")]
        )
        let resetResult = await ServerNetworkManager.shared.debugMCPReadSearchCaptureSnapshotPayload(
            op: "mcp_read_search_capture_snapshot",
            arguments: [:]
        )
        let resetPayload = try diagnosticsPayload(resetResult)
        let resetLosses = try XCTUnwrap(resetPayload["evidence_retention_losses"] as? [String: Any])
        XCTAssertEqual(resetLosses["phase_history_event_capacity"] as? Int, 0)
        XCTAssertEqual(resetPayload["incomplete_capture"] as? Bool, false)
    }

    func testJSONRPCStringIDIsUTF8BoundedInPayloadAndRawTraceDescription() throws {
        let accepted = String(repeating: "é", count: 60)
        let oversized = accepted + "é"
        XCTAssertEqual("string:\(accepted)".utf8.count, 127)
        XCTAssertEqual("string:\(oversized)".utf8.count, 129)

        let acceptedEvent = MCPResponseDeliveryTraceEvent(
            layer: "app_tool_handler",
            phase: "test",
            id: .string(accepted),
            terminalReason: "test"
        )
        XCTAssertEqual(acceptedEvent.payload["jsonrpc_request_id"] as? String, "string:\(accepted)")
        XCTAssertEqual(acceptedEvent.payload["jsonrpc_request_id_omitted"] as? Bool, false)
        XCTAssertTrue(acceptedEvent.description.contains(accepted))

        let framedSHA256 = String(repeating: "a", count: 64)
        let oversizedEvent = MCPResponseDeliveryTraceEvent(
            layer: "app_tool_handler",
            phase: "test",
            id: .string(oversized),
            framedSHA256: framedSHA256,
            terminalReason: "test"
        )
        XCTAssertTrue(oversizedEvent.payload["jsonrpc_request_id"] is NSNull)
        XCTAssertEqual(oversizedEvent.payload["jsonrpc_request_id_omitted"] as? Bool, true)
        XCTAssertEqual(oversizedEvent.payload["jsonrpc_request_id_truncated"] as? Bool, false)
        XCTAssertEqual(oversizedEvent.payload["jsonrpc_request_id_utf8_byte_count"] as? Int, 122)
        XCTAssertEqual(oversizedEvent.payload["framed_sha256"] as? String, framedSHA256)
        XCTAssertFalse(oversizedEvent.description.contains(oversized))
        XCTAssertTrue(oversizedEvent.description.contains("id=<omitted>"))
        XCTAssertTrue(oversizedEvent.description.contains("id_utf8_bytes=122"))

        let oversizedConnectionID = String(repeating: "c", count: 129)
        let oversizedInvocationID = String(repeating: "i", count: 129)
        let oversizedIdentityEvent = MCPResponseDeliveryTraceEvent(
            layer: "proxy_stdout",
            phase: "test",
            connectionID: oversizedConnectionID,
            connectionGeneration: 1,
            id: .number(42),
            invocationID: oversizedInvocationID,
            requestOrdinal: 1,
            terminalReason: "test"
        )
        let identityPayload = try XCTUnwrap(
            ServerNetworkManager.debugPhaseAttributionDeliveryPayloads([oversizedIdentityEvent]).only
        )
        XCTAssertTrue(identityPayload["correlation_connection_id"] is NSNull)
        XCTAssertEqual(identityPayload["correlation_connection_id_omitted"] as? Bool, true)
        XCTAssertEqual(identityPayload["correlation_connection_id_truncated"] as? Bool, false)
        XCTAssertEqual(identityPayload["correlation_connection_id_utf8_byte_count"] as? Int, 129)
        XCTAssertTrue(identityPayload["app_invocation_id"] is NSNull)
        XCTAssertEqual(identityPayload["app_invocation_id_omitted"] as? Bool, true)
        XCTAssertEqual(identityPayload["app_invocation_id_utf8_byte_count"] as? Int, 129)
        XCTAssertEqual(identityPayload["attribution_status"] as? String, "unsupported")
        XCTAssertFalse(oversizedIdentityEvent.description.contains(oversizedConnectionID))
        XCTAssertFalse(oversizedIdentityEvent.description.contains(oversizedInvocationID))

        let oversizedFaultID = String(repeating: "é", count: 65)
        let errorFactories: [(JSONRPCBridgeID) -> JSONRPCBridgeLedgerError] = [
            { .duplicateActiveID(.serverToClient, $0) },
            { .unknownResponse(.serverToClient, $0) },
            { .cancelledIDReuse(.serverToClient, $0) }
        ]
        for makeError in errorFactories {
            let oversizedDescription = makeError(.string(oversizedFaultID)).description
            XCTAssertFalse(oversizedDescription.contains(oversizedFaultID))
            XCTAssertTrue(oversizedDescription.contains("id=<omitted>"))
            XCTAssertTrue(oversizedDescription.contains("id_utf8_byte_count=130"))
            XCTAssertTrue(makeError(.number(42)).description.contains("id=number:42"))
            XCTAssertTrue(makeError(.null).description.contains("id=null"))
        }

        let faultDescription = JSONRPCBridgeLedgerError.injectedFault(
            .serverToClient,
            .string(oversizedFaultID)
        ).description
        XCTAssertFalse(faultDescription.contains(oversizedFaultID))
        XCTAssertTrue(faultDescription.contains("direction=server_to_client"))
        XCTAssertTrue(faultDescription.contains("id=<omitted>"))
        XCTAssertTrue(faultDescription.contains("id_omitted=true"))
        XCTAssertTrue(faultDescription.contains("id_truncated=false"))
        XCTAssertTrue(faultDescription.contains("id_utf8_byte_count=130"))
        XCTAssertTrue(
            JSONRPCBridgeLedgerError.injectedFault(.clientToServer, .number(42)).description.contains("id=number:42")
        )
        XCTAssertTrue(
            JSONRPCBridgeLedgerError.injectedFault(.clientToServer, .null).description.contains("id=null")
        )

        XCTAssertEqual(
            MCPResponseDeliveryTraceEvent(layer: "test", phase: "test", id: .number(42)).payload["jsonrpc_request_id"] as? String,
            "number:42"
        )
        XCTAssertEqual(
            MCPResponseDeliveryTraceEvent(layer: "test", phase: "test", id: .null).payload["jsonrpc_request_id"] as? String,
            "null"
        )

        let invocationID = UUID()
        let timeoutMetadata = ServerNetworkManager.executionTimeoutAttributionMetadata(
            invocationID: invocationID,
            lastHandlerPhase: MCPToolExecutionHandlerPhase.readFileContentRead.rawValue
        )
        if case let .string(exportedInvocationID)? = timeoutMetadata["app_invocation_id"] {
            XCTAssertEqual(exportedInvocationID, invocationID.uuidString)
        } else {
            XCTFail("Expected bounded app invocation identity in timeout metadata")
        }
        if case let .string(lastHandlerPhase)? = timeoutMetadata["last_handler_phase"] {
            XCTAssertEqual(lastHandlerPhase, MCPToolExecutionHandlerPhase.readFileContentRead.rawValue)
        } else {
            XCTFail("Expected last handler phase in timeout metadata")
        }
    }

    func testDeliveryAttributionUsesExplicitGenerationDomainsAcrossReconnects() {
        let invocationID = UUID()
        let events = [
            deliveryEvent(
                layer: "app_tool_handler",
                generation: 4,
                invocationID: invocationID,
                requestID: 17,
                requestOrdinal: 8
            ),
            deliveryEvent(
                layer: "app_uds_transport",
                generation: 4,
                invocationID: UUID(),
                requestID: 17,
                requestOrdinal: 8
            ),
            deliveryEvent(
                layer: "proxy_stdout",
                generation: 3,
                invocationID: UUID(),
                requestID: 17,
                requestOrdinal: 8
            )
        ]

        let payloads = ServerNetworkManager.debugPhaseAttributionDeliveryPayloads(events)
        XCTAssertEqual(payloads.count, 3)
        for payload in payloads {
            XCTAssertEqual(payload["app_invocation_id"] as? String, invocationID.uuidString)
            XCTAssertEqual(payload["attribution_status"] as? String, "joined")
            XCTAssertEqual(payload["attribution_candidate_count"] as? Int, 1)
        }
    }

    func testDeliveryAttributionCandidateCountUsesExplicitLowerBoundAfterRetentionCap() throws {
        let authoritative = (0 ..< 9).map { _ in
            deliveryEvent(layer: "app_tool_handler", generation: 2, invocationID: UUID())
        }
        let transportID = UUID()
        let payloads = ServerNetworkManager.debugPhaseAttributionDeliveryPayloads(
            authoritative + [deliveryEvent(layer: "proxy_stdout", generation: 1, invocationID: transportID)]
        )

        let transportPayload = try XCTUnwrap(payloads.last)
        XCTAssertEqual(transportPayload["app_invocation_id"] as? String, transportID.uuidString)
        XCTAssertEqual(transportPayload["attribution_status"] as? String, "ambiguous")
        XCTAssertEqual(transportPayload["attribution_candidate_count"] as? Int, 9)
        XCTAssertEqual(transportPayload["attribution_candidate_count_truncated"] as? Bool, true)
    }

    func testExecutionTraceCorrelationConnectionIDPreservesBoundedPrivacyMetadata() {
        let accepted = String(repeating: "é", count: 64)
        let oversized = accepted + "x"
        XCTAssertEqual(accepted.utf8.count, 128)
        XCTAssertEqual(oversized.utf8.count, 129)

        let absent = MCPToolExecutionTraceEvent.boundedCorrelationConnectionID(nil)
        XCTAssertNil(absent.value)
        XCTAssertFalse(absent.omitted)
        XCTAssertNil(absent.originalUTF8ByteCount)

        let inBound = MCPToolExecutionTraceEvent.boundedCorrelationConnectionID(accepted)
        XCTAssertEqual(inBound.value, accepted)
        XCTAssertFalse(inBound.omitted)
        XCTAssertEqual(inBound.originalUTF8ByteCount, 128)

        let redacted = MCPToolExecutionTraceEvent.boundedCorrelationConnectionID(oversized)
        XCTAssertNil(redacted.value)
        XCTAssertTrue(redacted.omitted)
        XCTAssertFalse(redacted.truncated)
        XCTAssertEqual(redacted.originalUTF8ByteCount, 129)

        let history = MCPToolExecutionPhaseHistoryRecorder()
        let event = traceEvent(
            phase: .started,
            historyEpoch: history.captureEpoch(),
            operationIdentity: readFileOperationIdentity(),
            connectionID: UUID(),
            invocationID: UUID(),
            elapsedMilliseconds: 1,
            correlationConnectionID: oversized
        )
        XCTAssertFalse(event.description.contains(oversized))
        XCTAssertTrue(event.description.contains("correlation_connection_id=<omitted>"))
        XCTAssertTrue(event.description.contains("correlation_connection_id_omitted=true"))
        XCTAssertTrue(event.description.contains("correlation_connection_id_truncated=false"))
        XCTAssertTrue(event.description.contains("correlation_connection_id_utf8_byte_count=129"))
    }

    func testExecutionTraceMapsExistingTerminalSignalsWithoutTransportIdentityClaims() throws {
        let history = MCPToolExecutionPhaseHistoryRecorder()
        let connectionID = UUID()
        let invocationID = UUID()
        let operationIdentity = readFileOperationIdentity()
        let epoch = history.captureEpoch()
        history.recordExecutionTrace(traceEvent(
            phase: .settledDuringGrace,
            historyEpoch: epoch,
            operationIdentity: operationIdentity,
            connectionID: connectionID,
            invocationID: invocationID,
            elapsedMilliseconds: 1,
            cancellationOutcome: MCPToolExecutionSettlement.cancellation.rawValue
        ))
        history.recordExecutionTrace(traceEvent(
            phase: .detachedForSettlement,
            historyEpoch: epoch,
            operationIdentity: operationIdentity,
            connectionID: connectionID,
            invocationID: invocationID,
            elapsedMilliseconds: 2
        ))
        history.recordExecutionTrace(traceEvent(
            phase: .connectionForceDisconnectRequested,
            historyEpoch: epoch,
            operationIdentity: operationIdentity,
            connectionID: connectionID,
            invocationID: invocationID,
            elapsedMilliseconds: 3
        ))

        let invocation = try XCTUnwrap(history.snapshot().only)
        XCTAssertEqual(invocation.events.map(\.terminalOutcome), [.cancellation, .detached, .forceDisconnected])
    }

    private func diagnosticsPayload(_ result: CallTool.Result) throws -> [String: Any] {
        let text = try XCTUnwrap(result.content.compactMap { content -> String? in
            if case let .text(text, _, _) = content { return text }
            return nil
        }.first)
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func deliveryEvent(
        layer: String,
        generation: UInt64,
        invocationID: UUID,
        requestID: Int64 = 7,
        requestOrdinal: UInt64 = 3
    ) -> MCPResponseDeliveryTraceEvent {
        MCPResponseDeliveryTraceEvent(
            layer: layer,
            phase: "test",
            connectionID: "bounded-correlation-connection",
            connectionGeneration: generation,
            id: .number(requestID),
            method: "tools/call",
            tool: "read_file",
            invocationID: invocationID.uuidString,
            requestOrdinal: requestOrdinal,
            terminalReason: "test"
        )
    }

    private func deliveryEventRaw(
        layer: String,
        generation: UInt64,
        invocationID: String,
        requestID: Int64 = 7,
        requestOrdinal: UInt64 = 3
    ) -> MCPResponseDeliveryTraceEvent {
        MCPResponseDeliveryTraceEvent(
            layer: layer,
            phase: "test",
            connectionID: "bounded-correlation-connection",
            connectionGeneration: generation,
            id: .number(requestID),
            method: "tools/call",
            tool: "read_file",
            invocationID: invocationID,
            requestOrdinal: requestOrdinal,
            terminalReason: "test"
        )
    }

    private func makeRecorder(
        history: MCPToolExecutionPhaseHistoryRecorder,
        clock: LockedDurationClock,
        connectionID: UUID,
        invocationID: UUID,
        correlationConnectionID: String? = nil
    ) -> MCPToolExecutionHandlerPhaseRecorder {
        MCPToolExecutionHandlerPhaseRecorder(
            operationIdentity: readFileOperationIdentity(),
            appConnectionID: connectionID,
            correlationConnectionID: MCPDiagnosticBoundedString(correlationConnectionID),
            invocationID: invocationID,
            origin: .zero,
            now: { clock.now() },
            phaseHistory: history
        )
    }

    private func readFileOperationIdentity() -> MCPToolOperationIdentity {
        MCPToolAdmissionPolicy.operationIdentity(
            forCanonicalToolName: "read_file",
            arguments: [:]
        )
    }

    private func traceEvent(
        phase: MCPToolExecutionTraceEvent.Phase,
        historyEpoch: UInt64,
        operationIdentity: MCPToolOperationIdentity,
        connectionID: UUID,
        invocationID: UUID,
        elapsedMilliseconds: Double,
        correlationConnectionID: String? = nil,
        includesCorrelationConnectionID: Bool = true,
        cancellationRequested: Bool? = nil,
        cancellationOutcome: String? = nil,
        cancellationOrigin: MCPToolExecutionCancellationOrigin? = nil
    ) -> MCPToolExecutionTraceEvent {
        MCPToolExecutionTraceEvent(
            toolName: "read_file",
            operationIdentity: operationIdentity,
            connectionID: connectionID,
            correlationConnectionID: MCPDiagnosticBoundedString(
                includesCorrelationConnectionID
                    ? correlationConnectionID ?? connectionID.uuidString
                    : nil
            ),
            invocationID: invocationID,
            runID: nil,
            contractKind: .bounded,
            executionDeadlineSeconds: nil,
            cleanupGraceSeconds: nil,
            cleanupDisposition: nil,
            phase: phase,
            elapsedMilliseconds: elapsedMilliseconds,
            cancellationRequested: cancellationRequested,
            cancellationOutcome: cancellationOutcome,
            cancellationOrigin: cancellationOrigin,
            settlement: nil,
            graceOutcome: nil,
            escalationReason: nil,
            handlerPhase: nil,
            handlerPhaseAgeMilliseconds: nil,
            historyEpoch: historyEpoch
        )
    }
}

private actor AsyncOneShotGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func open() {
        guard !isOpen else { return }
        isOpen = true
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }
}

private final class FirstPhasePublicationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let blocked = DispatchSemaphore(value: 0)
    private let continuation = DispatchSemaphore(value: 0)
    private var didBlock = false

    func intercept(_ operation: MCPDiagnosticCaptureCoordinationOperation) {
        guard case .phasePublication = operation else { return }
        lock.lock()
        guard !didBlock else {
            lock.unlock()
            return
        }
        didBlock = true
        lock.unlock()
        blocked.signal()
        continuation.wait()
    }

    func waitUntilBlocked() -> Bool {
        blocked.wait(timeout: .now() + 2) == .success
    }

    func release() {
        continuation.signal()
    }
}

private final class PublicationAttemptLatch: @unchecked Sendable {
    private let lock = NSLock()
    private let completed = DispatchSemaphore(value: 0)
    private var sawPhase = false
    private var sawDelivery = false
    private var sawWorkCount = false
    private var didSignal = false

    func record(_ operation: MCPDiagnosticCaptureCoordinationOperation) {
        lock.lock()
        switch operation {
        case .phasePublication: sawPhase = true
        case .deliveryPublication: sawDelivery = true
        case .workCountPublication: sawWorkCount = true
        case .captureMutation: break
        }
        if sawPhase, sawDelivery, sawWorkCount, !didSignal {
            didSignal = true
            completed.signal()
        }
        lock.unlock()
    }

    func waitForAllPublications() -> Bool {
        completed.wait(timeout: .now() + 2) == .success
    }
}

private final class LockedDurationClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Duration = .zero

    func set(_ value: Duration) {
        lock.lock()
        current = value
        lock.unlock()
    }

    func now() -> Duration {
        lock.lock()
        defer { lock.unlock() }
        return current
    }
}

private actor ControlledDurationClock {
    private var observationContinuation: CheckedContinuation<Duration, Never>?
    private var arrivalContinuations: [CheckedContinuation<Void, Never>] = []
    private var didObserve = false

    func now() async -> Duration {
        didObserve = true
        arrivalContinuations.forEach { $0.resume() }
        arrivalContinuations.removeAll()
        return await withCheckedContinuation { continuation in
            observationContinuation = continuation
        }
    }

    func waitUntilObserved() async {
        guard !didObserve else { return }
        await withCheckedContinuation { continuation in
            arrivalContinuations.append(continuation)
        }
    }

    func release(_ value: Duration) {
        observationContinuation?.resume(returning: value)
        observationContinuation = nil
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}
