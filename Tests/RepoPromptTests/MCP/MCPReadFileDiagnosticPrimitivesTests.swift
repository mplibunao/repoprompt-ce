#if DEBUG
    import Foundation
    @testable import RepoPromptApp
    import RepoPromptShared
    import XCTest

    final class MCPReadFileDiagnosticPrimitivesTests: XCTestCase {
        override func tearDown() {
            MCPToolExecutionTracer.setBeforeRetentionMutationHookForTesting(nil)
            EditFlowPerf.setDebugCaptureLockContentionHookForTesting(nil)
            EditFlowPerf.resetDebugCaptureForTesting()
            MCPToolExecutionTracer.resetDebugEvents()
            super.tearDown()
        }

        func testCaptureTokenCannotLeakRawValueAndSeparatesDomainAndCapture() throws {
            let rawValue = "/Users/example/private/Secret.swift: free-form failure"
            let first = try startedCapture(label: "privacy-a", toolFilter: .readFile)
            let firstIdentity = try XCTUnwrap(EditFlowPerf.debugCaptureIdentity(toolName: "read_file"))
            XCTAssertNil(EditFlowPerf.debugCaptureIdentity(toolName: "file_search"))

            let firstToken = try XCTUnwrap(EditFlowPerf.debugCaptureToken(
                rawValue,
                domain: .jsonRPCRequest,
                captureIdentity: firstIdentity
            ))
            let repeatedToken = try XCTUnwrap(EditFlowPerf.debugCaptureToken(
                rawValue,
                domain: .jsonRPCRequest,
                captureIdentity: firstIdentity
            ))
            let otherDomainToken = try XCTUnwrap(EditFlowPerf.debugCaptureToken(
                rawValue,
                domain: .cacheKey,
                captureIdentity: firstIdentity
            ))

            XCTAssertEqual(firstToken, repeatedToken)
            XCTAssertNotEqual(firstToken, otherDomainToken)
            XCTAssertFalse(firstToken.contains(rawValue))
            XCTAssertFalse(first.captureLabelToken?.contains("privacy-a") ?? true)

            _ = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertNil(EditFlowPerf.debugCaptureToken(
                rawValue,
                domain: .jsonRPCRequest,
                captureIdentity: firstIdentity
            ))

            _ = try startedCapture(label: "privacy-b", toolFilter: .readFile)
            let secondIdentity = try XCTUnwrap(EditFlowPerf.debugCaptureIdentity(toolName: "read_file"))
            let secondToken = try XCTUnwrap(EditFlowPerf.debugCaptureToken(
                rawValue,
                domain: .jsonRPCRequest,
                captureIdentity: secondIdentity
            ))
            XCTAssertNotEqual(firstIdentity.captureID, secondIdentity.captureID)
            XCTAssertNotEqual(firstToken, secondToken)
        }

        func testCapturePayloadSerializesLabelTokenWithoutRawOperatorLabel() throws {
            let rawLabel = "operator-private-label-7D19C4"
            let snapshot = try startedCapture(label: rawLabel, toolFilter: .readFile)
            let payload = snapshot.payload()

            XCTAssertEqual(payload["capture_label_token"] as? String, snapshot.captureLabelToken)
            XCTAssertNotNil(snapshot.captureLabelToken)
            XCTAssertFalse(payloadContains(rawLabel, in: payload))
        }

        func testSerializedLifecycleIdentityReplacesCallerControlledRequestIDWithTypedToken() throws {
            let canary = "/Users/example/private/Secret.swift|private-value-canary-7D19C4|free-form failure detail"
            _ = try startedCapture(label: "request-privacy", toolFilter: .readFile)
            let requestIdentity = MCPRequestTimelineIdentity(
                jsonRPCRequestID: .string(canary),
                connectionID: UUID().uuidString,
                connectionGeneration: 9,
                appInvocationID: UUID().uuidString,
                requestOrdinal: 17
            )
            let correlation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive(
                requestIdentity: requestIdentity,
                toolName: "read_file"
            ))
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.MCPToolCall.received,
                correlation: correlation,
                EditFlowPerf.Dimensions(toolName: "read_file")
            )

            let payload = EditFlowPerf.debugCaptureSnapshot(finish: true).payload()
            let lifecycleEvents = try XCTUnwrap(payload["lifecycle_events"] as? [[String: Any]])
            let serializedIdentity = try XCTUnwrap(
                lifecycleEvents.first?["request_identity"] as? [String: Any]
            )
            XCTAssertEqual(serializedIdentity["jsonrpc_request_kind"] as? String, "string")
            XCTAssertTrue(
                (serializedIdentity["jsonrpc_request_token"] as? String)?
                    .hasPrefix("jsonrpc_request:") == true
            )
            XCTAssertNil(serializedIdentity["jsonrpc_request_id"])
            for forbidden in ["/Users/example/private/Secret.swift", "private-value-canary-7D19C4", "free-form failure detail"] {
                XCTAssertFalse(payloadContains(forbidden, in: payload))
            }
        }

        func testExpiredCaptureRejectsItsLateEventAndClosedEpochCannotPopulateNextCapture() throws {
            _ = try startedCapture(label: "expiring", toolFilter: .readFile)
            let staleCaptureIdentity = try XCTUnwrap(EditFlowPerf.debugCaptureIdentity(toolName: "read_file"))
            let staleCorrelation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive(
                toolName: "read_file"
            ))

            EditFlowPerf.expireDebugCaptureForTesting()
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.MCPToolCall.received,
                correlation: staleCorrelation,
                EditFlowPerf.Dimensions(toolName: "read_file")
            )
            MCPToolExecutionTracer.emit(
                Self.traceEvent(elapsedMilliseconds: 900),
                captureIdentity: staleCaptureIdentity
            )
            let expired = EditFlowPerf.debugCaptureSnapshot(finish: false)
            XCTAssertEqual(expired.captureState, .expired)
            XCTAssertFalse(expired.active)
            XCTAssertEqual(expired.retainedLifecycleEventCount, 0)
            XCTAssertEqual(expired.droppedClosedEpochEventCount, 1)
            XCTAssertEqual(MCPToolExecutionTracer.debugEventSnapshot(staleCaptureIdentity.captureID).droppedEventCount, 1)

            _ = try startedCapture(label: "replacement", toolFilter: .readFile)
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.MCPToolCall.received,
                correlation: staleCorrelation,
                EditFlowPerf.Dimensions(toolName: "read_file")
            )
            MCPToolExecutionTracer.emit(
                Self.traceEvent(elapsedMilliseconds: 901),
                captureIdentity: staleCaptureIdentity
            )
            let replacement = EditFlowPerf.debugCaptureSnapshot(finish: false)
            XCTAssertEqual(replacement.captureState, .active)
            XCTAssertEqual(replacement.retainedLifecycleEventCount, 0)
            XCTAssertEqual(replacement.droppedClosedEpochEventCount, 1)
            XCTAssertEqual(MCPToolExecutionTracer.debugEventSnapshot(staleCaptureIdentity.captureID).droppedEventCount, 2)
        }

        func testExecutionTraceRingIsBounded() throws {
            _ = try startedCapture(label: "bounded-trace", toolFilter: .readFile)
            let captureIdentity = try XCTUnwrap(EditFlowPerf.debugCaptureIdentity(toolName: "read_file"))
            for ordinal in 0 ... 512 {
                MCPToolExecutionTracer.emit(
                    Self.traceEvent(elapsedMilliseconds: Double(ordinal)),
                    captureIdentity: captureIdentity
                )
            }

            let bounded = MCPToolExecutionTracer.debugEventSnapshot(captureIdentity.captureID)
            XCTAssertEqual(bounded.maxEventCount, 512)
            XCTAssertEqual(bounded.retainedEventCount, 512)
            XCTAssertEqual(bounded.droppedEventCount, 1)
            XCTAssertEqual(bounded.events.first?.event.elapsedMilliseconds, 1)
            XCTAssertEqual(bounded.events.last?.event.elapsedMilliseconds, 512)
        }

        func testFinishedCaptureRejectsLateTraceEvent() throws {
            _ = try startedCapture(label: "finished-trace", toolFilter: .readFile)
            let captureIdentity = try XCTUnwrap(EditFlowPerf.debugCaptureIdentity(toolName: "read_file"))
            MCPToolExecutionTracer.emit(Self.traceEvent(elapsedMilliseconds: 1), captureIdentity: captureIdentity)
            _ = EditFlowPerf.debugCaptureSnapshot(finish: true)
            MCPToolExecutionTracer.emit(Self.traceEvent(elapsedMilliseconds: 2), captureIdentity: captureIdentity)

            let snapshot = MCPToolExecutionTracer.debugEventSnapshot(captureIdentity.captureID)
            XCTAssertEqual(snapshot.events.map(\.event.elapsedMilliseconds), [1])
            XCTAssertEqual(snapshot.droppedEventCount, 1)
        }

        func testResetCaptureRejectsLateTraceEvent() throws {
            _ = try startedCapture(label: "reset-trace", toolFilter: .readFile)
            let captureIdentity = try XCTUnwrap(EditFlowPerf.debugCaptureIdentity(toolName: "read_file"))
            EditFlowPerf.resetDebugCaptureForTesting()
            MCPToolExecutionTracer.emit(Self.traceEvent(elapsedMilliseconds: 1), captureIdentity: captureIdentity)

            let snapshot = MCPToolExecutionTracer.debugEventSnapshot(captureIdentity.captureID)
            XCTAssertEqual(snapshot.retainedEventCount, 0)
            XCTAssertEqual(snapshot.droppedEventCount, 1)
        }

        func testReplacementCaptureRejectsPriorEpochTraceWithoutContaminatingCurrentHistory() throws {
            _ = try startedCapture(label: "prior-trace", toolFilter: .readFile)
            let priorIdentity = try XCTUnwrap(EditFlowPerf.debugCaptureIdentity(toolName: "read_file"))
            _ = EditFlowPerf.debugCaptureSnapshot(finish: true)
            _ = try startedCapture(label: "current-trace", toolFilter: .readFile)
            let currentIdentity = try XCTUnwrap(EditFlowPerf.debugCaptureIdentity(toolName: "read_file"))
            MCPToolExecutionTracer.emit(Self.traceEvent(elapsedMilliseconds: 1), captureIdentity: currentIdentity)
            MCPToolExecutionTracer.emit(Self.traceEvent(elapsedMilliseconds: 900), captureIdentity: priorIdentity)

            let prior = MCPToolExecutionTracer.debugEventSnapshot(priorIdentity.captureID)
            XCTAssertEqual(prior.retainedEventCount, 0)
            XCTAssertEqual(prior.droppedEventCount, 1)
            let replacement = MCPToolExecutionTracer.debugEventSnapshot(currentIdentity.captureID)
            XCTAssertEqual(replacement.events.map(\.event.elapsedMilliseconds), [1])
        }

        func testLateScopedTraceCleanupCannotEraseReplacementHistory() throws {
            _ = try startedCapture(label: "cleanup-prior", toolFilter: .readFile)
            let priorIdentity = try XCTUnwrap(EditFlowPerf.debugCaptureIdentity(toolName: "read_file"))
            MCPToolExecutionTracer.emit(Self.traceEvent(elapsedMilliseconds: 1), captureIdentity: priorIdentity)
            _ = EditFlowPerf.debugCaptureSnapshot(finish: true)

            _ = try startedCapture(label: "cleanup-replacement", toolFilter: .readFile)
            let replacementIdentity = try XCTUnwrap(EditFlowPerf.debugCaptureIdentity(toolName: "read_file"))
            MCPToolExecutionTracer.emit(Self.traceEvent(elapsedMilliseconds: 2), captureIdentity: replacementIdentity)
            MCPToolExecutionTracer.emit(Self.traceEvent(elapsedMilliseconds: 3), captureIdentity: replacementIdentity)

            MCPToolExecutionTracer.resetDebugEvents(closingCaptureID: priorIdentity.captureID)

            let replacement = MCPToolExecutionTracer.debugEventSnapshot(replacementIdentity.captureID)
            XCTAssertEqual(replacement.events.map(\.event.elapsedMilliseconds), [2, 3])
            XCTAssertEqual(replacement.retainedEventCount, 2)
            XCTAssertEqual(replacement.droppedEventCount, 0)
        }

        func testUnrelatedRejectionAndScopedCleanupPreserveRetainedCaptureRejectionAccounting() throws {
            _ = try startedCapture(label: "rejected-old", toolFilter: .readFile)
            let oldIdentity = try XCTUnwrap(EditFlowPerf.debugCaptureIdentity(toolName: "read_file"))
            _ = EditFlowPerf.debugCaptureSnapshot(finish: true)

            _ = try startedCapture(label: "rejected-retained", toolFilter: .readFile)
            let retainedIdentity = try XCTUnwrap(EditFlowPerf.debugCaptureIdentity(toolName: "read_file"))
            MCPToolExecutionTracer.emit(Self.traceEvent(elapsedMilliseconds: 2), captureIdentity: retainedIdentity)
            _ = EditFlowPerf.debugCaptureSnapshot(finish: true)
            MCPToolExecutionTracer.emit(Self.traceEvent(elapsedMilliseconds: 3), captureIdentity: retainedIdentity)
            MCPToolExecutionTracer.emit(Self.traceEvent(elapsedMilliseconds: 900), captureIdentity: oldIdentity)

            MCPToolExecutionTracer.resetDebugEvents(closingCaptureID: oldIdentity.captureID)

            let retained = MCPToolExecutionTracer.debugEventSnapshot(retainedIdentity.captureID)
            XCTAssertEqual(retained.events.map(\.event.elapsedMilliseconds), [2])
            XCTAssertEqual(retained.retainedEventCount, 1)
            XCTAssertEqual(retained.droppedEventCount, 1)
        }

        func testTraceRejectionDoesNotForgetAnEpochAfterMoreThanSixtyFourCaptureClosures() throws {
            _ = try startedCapture(label: "oldest-trace", toolFilter: .readFile)
            let oldestIdentity = try XCTUnwrap(EditFlowPerf.debugCaptureIdentity(toolName: "read_file"))
            _ = EditFlowPerf.debugCaptureSnapshot(finish: true)
            for ordinal in 0 ..< 65 {
                _ = try startedCapture(label: "closure-\(ordinal)", toolFilter: .readFile)
                _ = EditFlowPerf.debugCaptureSnapshot(finish: true)
            }
            _ = try startedCapture(label: "current-after-closures", toolFilter: .readFile)

            MCPToolExecutionTracer.emit(
                Self.traceEvent(elapsedMilliseconds: 900),
                captureIdentity: oldestIdentity
            )

            let oldest = MCPToolExecutionTracer.debugEventSnapshot(oldestIdentity.captureID)
            XCTAssertEqual(oldest.retainedEventCount, 0)
            XCTAssertEqual(oldest.droppedEventCount, 1)
        }

        func testFinishAndReplacementLinearizeAgainstTraceRetention() throws {
            try assertCaptureTransitionCannotInterleaveTraceRetention(.finish)
        }

        func testExpiryAndReplacementLinearizeAgainstTraceRetention() throws {
            try assertCaptureTransitionCannotInterleaveTraceRetention(.expiry)
        }

        func testResetAndReplacementLinearizeAgainstTraceRetention() throws {
            try assertCaptureTransitionCannotInterleaveTraceRetention(.reset)
        }

        func testRuntimeIdentityFieldPickingRejectsInvalidMetadataAndHashesExactExecutableBytes() throws {
            let commit = "D4563C57A2E1309EB6526FBE6F1F4F140E1AC933"
            let patchDigest = String(repeating: "AB", count: 32)
            let provenance = try JSONSerialization.data(withJSONObject: [
                "version": 2,
                "commit": commit,
                "dirty": true,
                "diagnosticPatchPresent": true,
                "diagnosticPatchDigest": patchDigest
            ])
            let processStartID = UUID()
            let machOUUID = UUID()
            let identity = MCPReadFileDiagnosticRuntimeIdentityReader.makeIdentity(
                bundleIdentifier: "com.example.RepoPrompt.debug",
                marketingVersion: "1.2.3-beta+4",
                buildNumber: "456",
                provenanceData: provenance,
                executableData: Data("abc".utf8),
                machOUUID: machOUUID,
                processStartID: processStartID
            )

            XCTAssertEqual(identity.bundleIdentifier, "com.example.RepoPrompt.debug")
            XCTAssertEqual(identity.marketingVersion, "1.2.3-beta+4")
            XCTAssertEqual(identity.buildNumber, "456")
            XCTAssertEqual(identity.machOUUID, machOUUID)
            XCTAssertEqual(
                identity.executableSHA256,
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
            )
            XCTAssertEqual(identity.sourceBaseCommit, commit.lowercased())
            XCTAssertEqual(identity.sourceTreeDirty, true)
            XCTAssertEqual(identity.diagnosticPatchPresent, true)
            XCTAssertEqual(identity.diagnosticPatchDigest, patchDigest.lowercased())
            XCTAssertEqual(identity.processStartID, processStartID)

            let invalidIdentity = MCPReadFileDiagnosticRuntimeIdentityReader.makeIdentity(
                bundleIdentifier: "com.example/private",
                marketingVersion: "invalid version",
                buildNumber: "invalid\nbuild",
                provenanceData: Data("{\"dirty\":\"unknown\"}".utf8),
                executableData: nil,
                machOUUID: nil,
                processStartID: UUID()
            )
            XCTAssertNil(invalidIdentity.bundleIdentifier)
            XCTAssertNil(invalidIdentity.marketingVersion)
            XCTAssertNil(invalidIdentity.buildNumber)
            XCTAssertNil(invalidIdentity.sourceBaseCommit)
            XCTAssertNil(invalidIdentity.sourceTreeDirty)
            XCTAssertNil(invalidIdentity.diagnosticPatchPresent)
            XCTAssertNil(invalidIdentity.diagnosticPatchDigest)
        }

        func testRuntimeExecutableHashStreamsEveryChunkAndFailsClosedForMissingFile() throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let executable = directory.appendingPathComponent("diagnostic-executable")
            let bytes = Data((0 ..< (64 * 1024 * 2 + 137)).map { UInt8($0 % 251) })
            try bytes.write(to: executable)

            XCTAssertEqual(
                MCPReadFileDiagnosticRuntimeIdentityReader.sha256OfFile(executable),
                "2baea35543cb7f6db413805a3f1883e8bd1779b110291760d8d3b013f75b1db9"
            )
            XCTAssertNil(
                MCPReadFileDiagnosticRuntimeIdentityReader.sha256OfFile(
                    directory.appendingPathComponent("missing-executable")
                )
            )
        }

        private func startedCapture(
            label: String,
            toolFilter: EditFlowPerf.DebugCaptureToolFilter
        ) throws -> EditFlowPerf.DebugCaptureSnapshot {
            switch EditFlowPerf.beginDebugCapture(
                label: label,
                maxSamples: 100,
                expiryMilliseconds: 120_000,
                toolFilter: toolFilter
            ) {
            case let .started(snapshot):
                return snapshot
            case .busy:
                XCTFail("Expected a fresh DEBUG capture.")
                throw CaptureError.busy
            }
        }

        private static func traceEvent(elapsedMilliseconds: Double) -> MCPToolExecutionTraceEvent {
            MCPToolExecutionTraceEvent(
                toolName: "read_file",
                operationIdentity: MCPDomainToolCatalog.operationIdentity(
                    for: "read_file",
                    input: .missing
                ),
                connectionID: UUID(),
                invocationID: UUID(),
                runID: nil,
                contractKind: .bounded,
                executionDeadlineSeconds: 30,
                cleanupGraceSeconds: 5,
                cleanupDisposition: .detachAndSettle,
                phase: .started,
                elapsedMilliseconds: elapsedMilliseconds,
                cancellationRequested: nil,
                cancellationOutcome: nil,
                cancellationOrigin: nil,
                settlement: nil,
                graceOutcome: nil,
                escalationReason: nil,
                handlerPhase: nil,
                handlerPhaseAgeMilliseconds: nil
            )
        }

        private func assertCaptureTransitionCannotInterleaveTraceRetention(
            _ transition: CaptureTransition
        ) throws {
            _ = try startedCapture(label: "atomic-prior", toolFilter: .readFile)
            let priorIdentity = try XCTUnwrap(EditFlowPerf.debugCaptureIdentity(toolName: "read_file"))
            let retentionEntered = DispatchSemaphore(value: 0)
            let releaseRetention = DispatchSemaphore(value: 0)
            let transitionProgress = DispatchSemaphore(value: 0)
            let startedWorkers = DispatchGroup()
            var retentionWorkerStarted = false
            var transitionWorkerStarted = false
            // Immediate gates share one deadline; cleanup gets the same bounded allowance after release.
            let gateTimeout: DispatchTimeInterval = .seconds(5)
            let gateDeadline = DispatchTime.now() + gateTimeout
            let releaseWaitResult = GateWaitResultBox()

            MCPToolExecutionTracer.setBeforeRetentionMutationHookForTesting { identity in
                guard identity == priorIdentity else { return }
                retentionEntered.signal()
                releaseWaitResult.store(releaseRetention.wait(timeout: gateDeadline))
            }
            EditFlowPerf.setDebugCaptureLockContentionHookForTesting {
                transitionProgress.signal()
            }
            defer {
                releaseRetention.signal()
                if retentionWorkerStarted || transitionWorkerStarted {
                    let cleanupResult = startedWorkers.wait(timeout: .now() + gateTimeout)
                    XCTAssertEqual(cleanupResult, .success, "Diagnostic gate workers must finish before hook cleanup.")
                }
                MCPToolExecutionTracer.setBeforeRetentionMutationHookForTesting(nil)
                EditFlowPerf.setDebugCaptureLockContentionHookForTesting(nil)
            }

            startedWorkers.enter()
            retentionWorkerStarted = true
            DispatchQueue.global().async {
                defer { startedWorkers.leave() }
                MCPToolExecutionTracer.emit(
                    Self.traceEvent(elapsedMilliseconds: 1),
                    captureIdentity: priorIdentity
                )
            }
            let retentionEnteredResult = retentionEntered.wait(timeout: gateDeadline)
            XCTAssertEqual(retentionEnteredResult, .success)
            guard retentionEnteredResult == .success else { return }

            startedWorkers.enter()
            transitionWorkerStarted = true
            DispatchQueue.global().async {
                defer {
                    transitionProgress.signal()
                    startedWorkers.leave()
                }
                switch transition {
                case .finish:
                    _ = EditFlowPerf.debugCaptureSnapshot(finish: true)
                case .expiry:
                    EditFlowPerf.expireDebugCaptureForTesting()
                case .reset:
                    EditFlowPerf.resetDebugCaptureForTesting()
                }
                guard case .started = EditFlowPerf.beginDebugCapture(
                    label: "atomic-replacement",
                    maxSamples: 100,
                    expiryMilliseconds: 120_000,
                    toolFilter: .readFile
                ), let replacementIdentity = EditFlowPerf.debugCaptureIdentity(toolName: "read_file")
                else { return }
                MCPToolExecutionTracer.emit(
                    Self.traceEvent(elapsedMilliseconds: 2),
                    captureIdentity: replacementIdentity
                )
            }

            let transitionProgressResult = transitionProgress.wait(timeout: gateDeadline)
            XCTAssertEqual(transitionProgressResult, .success)
            releaseRetention.signal()
            guard transitionProgressResult == .success else { return }
            let workersFinishedResult = startedWorkers.wait(timeout: gateDeadline)
            XCTAssertEqual(workersFinishedResult, .success)
            XCTAssertEqual(releaseWaitResult.load(), .success)
            guard workersFinishedResult == .success else { return }

            let replacementIdentity = try XCTUnwrap(EditFlowPerf.debugCaptureIdentity(toolName: "read_file"))
            let replacement = MCPToolExecutionTracer.debugEventSnapshot(replacementIdentity.captureID)
            XCTAssertEqual(replacement.events.map(\.event.elapsedMilliseconds), [2])
            XCTAssertEqual(replacement.droppedEventCount, 0)
        }

        private func payloadContains(_ rawLabel: String, in value: Any) -> Bool {
            if let string = value as? String {
                return string.contains(rawLabel)
            }
            if let dictionary = value as? [String: Any] {
                return dictionary.contains { key, nestedValue in
                    key.contains(rawLabel) || payloadContains(rawLabel, in: nestedValue)
                }
            }
            if let array = value as? [Any] {
                return array.contains { payloadContains(rawLabel, in: $0) }
            }
            return false
        }

        private enum CaptureError: Error {
            case busy
        }

        private enum CaptureTransition {
            case finish
            case expiry
            case reset
        }

        private final class GateWaitResultBox: @unchecked Sendable {
            private let lock = NSLock()
            private var result: DispatchTimeoutResult?

            func store(_ result: DispatchTimeoutResult) {
                lock.withLock {
                    self.result = result
                }
            }

            func load() -> DispatchTimeoutResult? {
                lock.withLock { result }
            }
        }
    }
#endif
