import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptShared
import XCTest

final class MCPToolExecutionContractTests: XCTestCase {
    func testCentralTimeoutPolicyMatchesProductContract() {
        XCTAssertEqual(MCPTimeoutPolicy.boundedToolExecutionDeadlineSeconds, 30)
        XCTAssertEqual(MCPTimeoutPolicy.promptExportAdmissionHeadroomSeconds, 25)
        XCTAssertEqual(MCPTimeoutPolicy.promptExportExecutionDeadlineSeconds, 240)
        XCTAssertEqual(MCPTimeoutPolicy.fileActionTrashExecutionDeadlineSeconds, 60)
        XCTAssertEqual(MCPTimeoutPolicy.workspaceFreshnessWaitTimeoutSeconds, 30)
        XCTAssertEqual(MCPTimeoutPolicy.workspaceSwitchToolExecutionDeadlineSeconds, 120)
        XCTAssertEqual(MCPTimeoutPolicy.boundedToolCancellationCleanupGraceSeconds, 5)
        XCTAssertEqual(MCPTimeoutPolicy.promptExportResponseDeliveryAllowanceSeconds, 30)
        XCTAssertEqual(MCPTimeoutPolicy.responseSendDeadlineSeconds, 30)
        XCTAssertEqual(MCPTimeoutPolicy.promptExportReservedProviderAndCleanupSeconds, 275)
        XCTAssertEqual(MCPTimeoutPolicy.promptExportTotalEnvelopeSeconds, 300)
        XCTAssertEqual(
            TimeInterval(MCPTimeoutPolicy.promptExportTotalEnvelopeSeconds),
            MCPTimeoutPolicy.cliDefaultToolCallTimeoutSeconds
        )
        XCTAssertEqual(
            MCPTimeoutPolicy.promptExportReservedEnvelopeArgumentKey,
            "_repoprompt_execution_envelope"
        )
        XCTAssertEqual(MCPTimeoutPolicy.codexServerActiveTimeoutSeconds, 10000)
        XCTAssertEqual(MCPTimeoutPolicy.agentLifecycleDefaultWaitSeconds, 120)
        XCTAssertEqual(MCPTimeoutPolicy.askUserDefaultTimeoutSeconds, 300)
        XCTAssertEqual(MCPTimeoutPolicy.nextUserInstructionDefaultWaitSeconds, 600)
        XCTAssertEqual(MCPTimeoutPolicy.applyEditsApprovalTimeoutSeconds, 300)
        XCTAssertEqual(MCPTimeoutPolicy.worktreeMergeApprovalTimeoutSeconds, 600)
    }

    func testToolCallDeadlineEnvelopeJSONCodablePreservesWireSchema() throws {
        let envelope = MCPToolCallDeadlineEnvelope(
            kind: .ordinaryPromptExportV1,
            expiresAtUnixMilliseconds: 1_800_000_000_123
        )

        let data = try JSONEncoder().encode(envelope)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["kind"] as? String, "ordinary_prompt_export_v1")
        XCTAssertEqual(object["timeout_mode"] as? String, "default")
        XCTAssertEqual(
            (object["expires_at_unix_milliseconds"] as? NSNumber)?.int64Value,
            1_800_000_000_123
        )
        XCTAssertNil(object["expiresAtUnixMilliseconds"])
        XCTAssertEqual(
            try JSONDecoder().decode(MCPToolCallDeadlineEnvelope.self, from: data),
            envelope
        )
    }

    func testToolCallDeadlineEnvelopeValueCodecPreservesWireSchema() {
        let envelope = MCPToolCallDeadlineEnvelope(
            kind: .ordinaryPromptExportV1,
            expiresAtUnixMilliseconds: 1_800_000_000_123
        )
        let encoded = MCPToolCallDeadlineEnvelopeValueCodec.encode(envelope)

        XCTAssertEqual(encoded, .object([
            "kind": .string("ordinary_prompt_export_v1"),
            "timeout_mode": .string("default"),
            "expires_at_unix_milliseconds": .int(1_800_000_000_123)
        ]))
        XCTAssertEqual(MCPToolCallDeadlineEnvelopeValueCodec.decode(encoded), envelope)

        for mode in [
            MCPToolCallDeadlineEnvelope.TimeoutMode.explicitFinite,
            .explicitUnbounded
        ] {
            let marker = MCPToolCallDeadlineEnvelope(
                kind: .ordinaryPromptExportV1,
                timeoutMode: mode
            )
            let markerValue = MCPToolCallDeadlineEnvelopeValueCodec.encode(marker)
            XCTAssertEqual(markerValue, .object([
                "kind": .string("ordinary_prompt_export_v1"),
                "timeout_mode": .string(mode.rawValue)
            ]))
            XCTAssertEqual(MCPToolCallDeadlineEnvelopeValueCodec.decode(markerValue), marker)
        }
    }

    func testPromptContextExportUsesExtendedBoundedForceDisconnectContract() {
        let cases: [(label: String, toolName: String, arguments: [String: Value])] = [
            ("prompt", MCPWindowToolName.prompt, ["op": .string("export")]),
            ("normalized prompt", MCPWindowToolName.prompt, ["op": .string("  ExPoRt  ")]),
            ("workspace context", MCPWindowToolName.workspaceContext, ["op": .string("export")]),
            ("normalized workspace context", MCPWindowToolName.workspaceContext, ["op": .string("  ExPoRt  ")])
        ]

        for testCase in cases {
            guard case let .bounded(deadline, cancellationGrace, cleanupDisposition) = MCPToolExecutionContractCatalog.contract(
                for: testCase.toolName,
                arguments: testCase.arguments
            ) else {
                XCTFail("Expected bounded export contract for \(testCase.label)")
                continue
            }
            XCTAssertEqual(deadline, MCPTimeoutPolicy.promptExportExecutionDeadline, testCase.label)
            XCTAssertEqual(cancellationGrace, MCPTimeoutPolicy.boundedToolCancellationCleanupGrace, testCase.label)
            XCTAssertEqual(cleanupDisposition, .forceDisconnect, testCase.label)

            XCTAssertEqual(
                MCPTimeoutPolicy.promptExportAdmissionHeadroomSeconds
                    + MCPTimeoutPolicy.promptExportExecutionDeadlineSeconds
                    + MCPTimeoutPolicy.boundedToolCancellationCleanupGraceSeconds
                    + MCPTimeoutPolicy.promptExportResponseDeliveryAllowanceSeconds,
                Int(MCPTimeoutPolicy.cliDefaultToolCallTimeoutSeconds),
                testCase.label
            )
        }
    }

    func testPromptContextNonExportOperationsRetainOrdinaryContract() {
        let cases: [(label: String, toolName: String, arguments: [String: Value])] = [
            ("prompt default", MCPWindowToolName.prompt, [:]),
            ("prompt malformed", MCPWindowToolName.prompt, ["op": .bool(true)]),
            ("prompt unknown", MCPWindowToolName.prompt, ["op": .string("  Future_Op  ")]),
            ("prompt set", MCPWindowToolName.prompt, ["op": .string("set")]),
            ("workspace default", MCPWindowToolName.workspaceContext, [:]),
            ("workspace malformed", MCPWindowToolName.workspaceContext, ["op": .bool(true)]),
            ("workspace unknown", MCPWindowToolName.workspaceContext, ["op": .string("  Future_Op  ")]),
            ("workspace snapshot", MCPWindowToolName.workspaceContext, ["op": .string("snapshot")])
        ]

        for testCase in cases {
            XCTAssertEqual(
                MCPToolExecutionContractCatalog.contract(
                    for: testCase.toolName,
                    arguments: testCase.arguments
                ),
                MCPToolExecutionContractCatalog.contract(for: testCase.toolName),
                testCase.label
            )
        }
    }

    func testFileActionsDeleteUsesFinderTrashDeadline() {
        guard case let .bounded(deadline, cancellationGrace, cleanupDisposition) = MCPToolExecutionContractCatalog.contract(
            for: MCPWindowToolName.fileActions,
            arguments: ["action": .string("  DeLeTe  ")]
        ) else {
            return XCTFail("Expected bounded Finder Trash contract")
        }
        XCTAssertEqual(deadline, MCPTimeoutPolicy.fileActionTrashExecutionDeadline)
        XCTAssertEqual(cancellationGrace, MCPTimeoutPolicy.boundedToolCancellationCleanupGrace)
        XCTAssertEqual(cleanupDisposition, .detachAndSettle)

        XCTAssertEqual(
            MCPToolExecutionContractCatalog.contract(
                for: MCPWindowToolName.fileActions,
                arguments: ["action": .string("create")]
            ),
            MCPToolExecutionContractCatalog.contract(for: MCPWindowToolName.fileActions)
        )
    }

    func testAdvertisedToolCatalogMatchesExecutionContractClassificationMatrix() {
        do {
            let caseLabel = "testCatalogCoversEveryAdvertisedGlobalAndWindowToolExactlyOnce"
            XCTAssertEqual(
                MCPToolExecutionContractCatalog.orderedAdvertisedToolNames,
                MCPGlobalToolName.orderedToolNames + MCPAppToolGroup.orderedToolNames,
                caseLabel
            )
            XCTAssertEqual(MCPToolExecutionContractCatalog.orderedAdvertisedToolNames.count, 27, caseLabel)
            XCTAssertEqual(
                Set(MCPToolExecutionContractCatalog.orderedAdvertisedToolNames).count,
                MCPToolExecutionContractCatalog.orderedAdvertisedToolNames.count,
                caseLabel
            )
            XCTAssertEqual(
                Set(MCPToolExecutionContractCatalog.contracts.keys),
                Set(MCPToolExecutionContractCatalog.orderedAdvertisedToolNames),
                caseLabel
            )
            XCTAssertEqual(
                MCPGlobalToolName.orderedToolNames,
                ["app_settings", "bind_context", "manage_workspaces"],
                caseLabel
            )
        }

        do {
            let caseLabel = "testBoundedCatalogContainsOnlyComputationalAndLocalOperations"
            XCTAssertEqual(names(for: .bounded), [
                MCPGlobalToolName.appSettings,
                MCPWindowToolName.manageSelection,
                MCPWindowToolName.fileActions,
                MCPWindowToolName.getCodeStructure,
                MCPWindowToolName.getFileTree,
                MCPWindowToolName.readFile,
                MCPWindowToolName.workspaceContext,
                MCPWindowToolName.prompt,
                MCPWindowToolName.agentManage,
                MCPWindowToolName.shareThoughts,
                MCPWindowToolName.setStatus,
                MCPWindowToolName.history
            ], caseLabel)

            let detachAndSettleToolNames: Set<String> = [
                MCPWindowToolName.fileActions,
                MCPWindowToolName.getCodeStructure,
                MCPWindowToolName.readFile,
                MCPWindowToolName.getFileTree
            ]
            for toolName in names(for: .bounded) {
                guard case let .bounded(deadline, cancellationGrace, cleanupDisposition) = MCPToolExecutionContractCatalog.contract(for: toolName) else {
                    return XCTFail(caseLabel + ": Expected bounded contract for \(toolName)")
                }
                XCTAssertEqual(deadline, MCPTimeoutPolicy.boundedToolExecutionDeadline, caseLabel + ": " + toolName)
                XCTAssertEqual(cancellationGrace, MCPTimeoutPolicy.boundedToolCancellationCleanupGrace, caseLabel + ": " + toolName)
                XCTAssertEqual(
                    cleanupDisposition,
                    detachAndSettleToolNames.contains(toolName) ? .detachAndSettle : .forceDisconnect,
                    caseLabel + ": " + toolName
                )
            }
        }

        do {
            let caseLabel = "testSearchOracleAndContextBuilderUseLongSynchronousExemption"
            XCTAssertEqual(names(for: .longSynchronousCancellable), [
                MCPWindowToolName.search,
                MCPWindowToolName.oracleUtils,
                MCPWindowToolName.askOracle,
                MCPWindowToolName.oracleSend,
                MCPWindowToolName.oracleChatLog,
                MCPWindowToolName.contextBuilder
            ], caseLabel)
            assertNoWatchdogDeadline(for: names(for: .longSynchronousCancellable), label: caseLabel)
        }

        do {
            let caseLabel = "testAgentRunAndExploreUseLifecycleManagedExemption"
            XCTAssertEqual(names(for: .lifecycleManagedCancellable), [
                MCPWindowToolName.agentExplore,
                MCPWindowToolName.agentRun
            ], caseLabel)
            assertNoWatchdogDeadline(for: names(for: .lifecycleManagedCancellable), label: caseLabel)
        }

        do {
            let caseLabel = "testInteractiveToolsUseInteractiveCancellableExemption"
            XCTAssertEqual(names(for: .interactiveCancellable), [
                MCPWindowToolName.applyEdits,
                MCPWindowToolName.askUser,
                MCPWindowToolName.waitForNextInstruction
            ], caseLabel)
            assertNoWatchdogDeadline(for: names(for: .interactiveCancellable), label: caseLabel)
        }

        do {
            let caseLabel = "testWorkspaceAndVCSLifecycleToolsUseWorkspaceCancellableExemption"
            XCTAssertEqual(names(for: .workspaceLifecycleCancellable), [
                MCPGlobalToolName.bindContext,
                MCPGlobalToolName.manageWorkspaces,
                MCPWindowToolName.git,
                MCPWindowToolName.manageWorktree
            ], caseLabel)
            assertNoWatchdogDeadline(for: names(for: .workspaceLifecycleCancellable), label: caseLabel)
        }
    }

    func testManageWorkspacesUsesBoundedContractOnlyForSwitchProducingArguments() {
        let boundedCases: [(label: String, arguments: [String: Value])] = [
            ("switch", ["action": .string("switch")]),
            ("normalized switch", ["action": .string("  SwItCh  ")]),
            ("create default", ["action": .string("create")]),
            ("create true", ["action": .string("create"), "switch_to_created": .bool(true)]),
            // The handler resolves a present-but-non-bool flag as `?? true` and switches,
            // so the contract must keep the watchdog on that path.
            ("create malformed flag", ["action": .string("create"), "switch_to_created": .string("true")]),
            ("delete close window", ["action": .string("delete"), "close_window": .bool(true)])
        ]

        for testCase in boundedCases {
            guard case let .bounded(deadline, cancellationGrace, cleanupDisposition) = MCPToolExecutionContractCatalog.contract(
                for: MCPGlobalToolName.manageWorkspaces,
                arguments: testCase.arguments
            ) else {
                XCTFail("Expected bounded contract for \(testCase.label)")
                continue
            }
            XCTAssertEqual(deadline, MCPTimeoutPolicy.workspaceSwitchToolExecutionDeadline, testCase.label)
            XCTAssertEqual(cancellationGrace, MCPTimeoutPolicy.boundedToolCancellationCleanupGrace, testCase.label)
            XCTAssertEqual(cleanupDisposition, .forceDisconnect, testCase.label)
        }

        let unboundedCases: [(label: String, arguments: [String: Value])] = [
            ("list", ["action": .string("list")]),
            ("create false", ["action": .string("create"), "switch_to_created": .bool(false)]),
            ("delete default", ["action": .string("delete")]),
            ("delete false", ["action": .string("delete"), "close_window": .bool(false)]),
            ("delete malformed flag", ["action": .string("delete"), "close_window": .string("true")]),
            ("missing action", [:]),
            ("malformed action", ["action": .bool(true)])
        ]

        for testCase in unboundedCases {
            XCTAssertEqual(
                MCPToolExecutionContractCatalog.contract(
                    for: MCPGlobalToolName.manageWorkspaces,
                    arguments: testCase.arguments
                ),
                .workspaceLifecycleCancellable,
                testCase.label
            )
        }

        XCTAssertEqual(
            MCPToolExecutionContractCatalog.contract(
                for: MCPWindowToolName.git,
                arguments: ["action": .string("switch")]
            ),
            .workspaceLifecycleCancellable
        )
    }

    func testConnectionPermitReleasedWhenDeadlineExpiresImmediatelyAfterHandoff() async throws {
        let limiter = MCPDomainAsyncLimiter(limit: 1)
        let holderGate = AdmissionDeadlineGate()
        let bodyRan = AdmissionDeadlineFlag()
        let holder = Task {
            try await limiter.withPermit {
                await holderGate.wait()
            }
        }
        _ = try await waitForAdmissionState(
            expected: "limiter activePermitCount == 1",
            snapshot: { await limiter.debugSnapshot() },
            matches: { $0.activePermitCount == 1 }
        )

        let now = AdmissionDeadlineNowSequence(beforeExpiryCalls: 2, expiry: .seconds(10))
        let deadline = MCPDomainAdmissionDeadline(
            instant: .seconds(10),
            now: now.value,
            sleep: { duration in try await Task.sleep(for: duration) }
        )
        let waiter = Task {
            try await limiter.withPermit(admissionDeadline: deadline) {
                await bodyRan.mark()
            }
        }
        _ = try await waitForAdmissionState(
            expected: "limiter waiterCount == 1",
            snapshot: { await limiter.debugSnapshot() },
            matches: { $0.waiterCount == 1 }
        )
        await holderGate.release()
        try await holder.value

        do {
            try await waiter.value
            XCTFail("Expected the post-handoff deadline check to reject the permit")
        } catch is MCPDomainAdmissionDeadline.Expired {
            // Expected.
        }
        let didRunBody = await bodyRan.value()
        XCTAssertFalse(didRunBody)
        let settled = await limiter.debugSnapshot()
        XCTAssertEqual(settled.activePermitCount, 0)
        XCTAssertEqual(settled.permits, settled.limit)
        XCTAssertEqual(settled.waiterCount, 0)
        XCTAssertTrue(settled.isIdle)
    }

    func testConnectionPermitReleasedWhenDeadlineWinsAfterImmediateAcquisition() async throws {
        let limiter = MCPDomainAsyncLimiter(limit: 1)
        let permitAcquired = AdmissionDeadlineFlag()
        await limiter.setDebugImmediatePermitAcquiredHandler {
            await permitAcquired.mark()
            while !Task.isCancelled {
                await Task.yield()
            }
        }
        let deadline = MCPDomainAdmissionDeadline(
            instant: .seconds(10),
            now: { .zero },
            sleep: { _ in
                while await !permitAcquired.value() {
                    await Task.yield()
                }
            }
        )

        do {
            try await limiter.withPermit(admissionDeadline: deadline) {}
            XCTFail("Expected the deadline child to win after permit acquisition")
        } catch is MCPDomainAdmissionDeadline.Expired {
            // Expected.
        }
        await limiter.setDebugImmediatePermitAcquiredHandler(nil)

        let capacityProbeRan = AdmissionDeadlineFlag()
        let capacityProbeDeadline = MCPDomainAdmissionDeadline(
            instant: .seconds(10),
            now: { .zero },
            sleep: { _ in try await Task.sleep(for: .milliseconds(50)) }
        )
        try await limiter.withPermit(admissionDeadline: capacityProbeDeadline) {
            await capacityProbeRan.mark()
        }

        let didRunCapacityProbe = await capacityProbeRan.value()
        XCTAssertTrue(didRunCapacityProbe)
        let settled = await limiter.debugSnapshot()
        XCTAssertEqual(settled.activePermitCount, 0)
        XCTAssertEqual(settled.permits, settled.limit)
        XCTAssertEqual(settled.waiterCount, 0)
        XCTAssertTrue(settled.isIdle)
    }

    func testResourceLeaseReleasedWhenDeadlineExpiresImmediatelyAfterHandoff() async throws {
        let controller = MCPDomainToolResourceAdmissionController(limit: 1)
        let resource = MCPDomainToolResourceAdmissionController.Resource.window(42)
        let firstLease = try await controller.acquire(resource)
        let now = AdmissionDeadlineNowSequence(beforeExpiryCalls: 2, expiry: .seconds(10))
        let deadline = MCPDomainAdmissionDeadline(
            instant: .seconds(10),
            now: now.value,
            sleep: { duration in try await Task.sleep(for: duration) }
        )
        let waiter = Task {
            try await controller.acquire(resource, admissionDeadline: deadline)
        }
        _ = try await waitForAdmissionState(
            expected: "resource waiterCount == 1",
            snapshot: {
                (
                    activeCountForResource: controller.activeCount(for: resource),
                    waiterCountForResource: controller.waiterCount(for: resource),
                    controller: controller.snapshot()
                )
            },
            matches: { $0.waiterCountForResource == 1 }
        )
        firstLease.release()

        do {
            _ = try await waiter.value
            XCTFail("Expected the post-handoff deadline check to reject the lease")
        } catch is MCPDomainAdmissionDeadline.Expired {
            // Expected.
        }
        XCTAssertEqual(controller.activeCount(for: resource), 0)
        XCTAssertEqual(controller.waiterCount(for: resource), 0)
        XCTAssertEqual(controller.snapshot().activeLeaseCount, 0)
    }

    func testTentativeConnectionLimiterRetryExpiresAndRemovesWaiter() async throws {
        let limiters = MCPDomainConnectionCallLimiters(
            limit: 1,
            controlLimit: 1,
            smallReadLimit: 1,
            fileReadLimit: 1,
            gitReadLimit: 1,
            fileSearchLimit: 1
        )
        let closeGate = AdmissionDeadlineGate()
        let closeTask = Task {
            await limiters.closeIfIdle {
                await closeGate.wait()
            }
        }
        await closeGate.waitUntilEntered()

        let clock = ExecutionWatchdogManualClock()
        let deadline = MCPDomainAdmissionDeadline(
            instant: .seconds(MCPTimeoutPolicy.promptExportAdmissionHeadroomSeconds),
            now: clock.currentTime,
            sleep: { try await clock.sleep(for: $0) }
        )
        let retryTask = Task {
            try await limiters.admissionRetryReplacement(admissionDeadline: deadline)
        }
        try await clock.waitForSleeperCount(1)
        let queuedRetryWaiterCount = await limiters.admissionRetryWaiterCountForTesting()
        XCTAssertEqual(queuedRetryWaiterCount, 1)
        try await clock.advanceNext(expected: .seconds(
            MCPTimeoutPolicy.promptExportAdmissionHeadroomSeconds
        ))

        do {
            _ = try await retryTask.value
            XCTFail("Expected tentative limiter replacement retry to expire")
        } catch is MCPDomainAdmissionDeadline.Expired {
            // Expected.
        }
        let expiredRetryWaiterCount = await limiters.admissionRetryWaiterCountForTesting()
        XCTAssertEqual(expiredRetryWaiterCount, 0)

        await closeGate.release()
        let didClose = await closeTask.value
        XCTAssertTrue(didClose)
        await limiters.markTentativeCloseCommitted()
        let finalRetryWaiterCount = await limiters.admissionRetryWaiterCountForTesting()
        XCTAssertEqual(finalRetryWaiterCount, 0)
    }

    func testMissingClassificationIsDetectedBeforeProviderEntry() {
        var providerEntered = false
        let toolName = "unclassified_test_tool"

        guard MCPToolExecutionContractCatalog.contract(for: toolName) != nil else {
            XCTAssertFalse(providerEntered)
            XCTAssertNil(MCPToolExecutionContractCatalog.contract(for: toolName))
            return
        }
        providerEntered = true
        XCTFail("Unexpected contract allowed provider entry")
    }

    private func waitForAdmissionState<State>(
        expected: String,
        timeout: Duration = .seconds(1),
        snapshot: () async -> State,
        matches: (State) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> State {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            let actual = await snapshot()
            if matches(actual) {
                return actual
            }
            guard clock.now < deadline else {
                XCTFail(
                    "Timed out waiting for admission state. Expected: \(expected). Actual: \(String(describing: actual))",
                    file: file,
                    line: line
                )
                throw AdmissionStateWaitError.timedOut
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private func names(for kind: MCPToolExecutionContract.Kind) -> [String] {
        MCPToolExecutionContractCatalog.orderedAdvertisedToolNames.filter {
            MCPToolExecutionContractCatalog.contract(for: $0)?.kind == kind
        }
    }

    private func assertNoWatchdogDeadline(
        for toolNames: [String],
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(toolNames.allSatisfy {
            let contract = MCPToolExecutionContractCatalog.contract(for: $0)
            return contract?.deadline == nil && contract?.cancellationGrace == nil
        }, label, file: file, line: line)
    }
}

private enum AdmissionStateWaitError: Error {
    case timedOut
}

private final class AdmissionDeadlineNowSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var remainingBeforeExpiryCalls: Int
    private let expiry: Duration

    init(beforeExpiryCalls: Int, expiry: Duration) {
        remainingBeforeExpiryCalls = beforeExpiryCalls
        self.expiry = expiry
    }

    func value() -> Duration {
        lock.withLock {
            guard remainingBeforeExpiryCalls > 0 else { return expiry }
            remainingBeforeExpiryCalls -= 1
            return .zero
        }
    }
}

private actor AdmissionDeadlineGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor AdmissionDeadlineFlag {
    private var marked = false

    func mark() {
        marked = true
    }

    func value() -> Bool {
        marked
    }
}
