import Foundation
import MCP
@testable import RepoPromptMCP
import RepoPromptShared
import XCTest

#if DEBUG
    final class InteractiveMCPClientSessionCancellationTests: XCTestCase {
        func testContextBuilderAndAskOracleDefaultsHaveNoClientDeadline() async {
            let session = makeUnconnectedSession()

            let contextBuilderTimeout = await session.test_resolvedToolCallTimeout(
                toolName: "context_builder"
            )
            let askOracleTimeout = await session.test_resolvedToolCallTimeout(
                toolName: "ask_oracle"
            )

            XCTAssertNil(contextBuilderTimeout)
            XCTAssertNil(askOracleTimeout)
        }

        func testOrdinaryToolRetains300SecondClientDeadline() async {
            let session = makeUnconnectedSession()
            let cases: [(toolName: String, arguments: [String: Value])] = [
                ("read_file", [:]),
                ("prompt", ["op": .string("get")]),
                ("workspace_context", [:]),
                ("read_file", ["op": .string("export")])
            ]

            for testCase in cases {
                let timeout = await session.test_resolvedToolCallTimeout(
                    toolName: testCase.toolName,
                    arguments: testCase.arguments
                )

                XCTAssertEqual(
                    timeout,
                    MCPTimeoutPolicy.cliDefaultToolCallTimeoutSeconds,
                    "Unexpected timeout for \(testCase.toolName) with \(testCase.arguments)"
                )
            }
        }

        func testPromptContextExportsRetain300SecondClientDeadline() async {
            let session = makeUnconnectedSession()
            let cases: [(toolName: String, operation: String)] = [
                ("prompt", "export"),
                ("prompt", "  EXPORT\n"),
                ("workspace_context", "export"),
                ("workspace_context", "\tExPoRt ")
            ]

            for testCase in cases {
                let timeout = await session.test_resolvedToolCallTimeout(
                    toolName: testCase.toolName,
                    arguments: ["op": .string(testCase.operation)]
                )

                XCTAssertEqual(
                    timeout,
                    MCPTimeoutPolicy.cliDefaultToolCallTimeoutSeconds,
                    "Unexpected export timeout for \(testCase.toolName) op=\(testCase.operation.debugDescription)"
                )
            }
        }

        func testAgentRun600SecondWaitUsesRequestedWaitPlusDeliveryMargin() async {
            let session = makeUnconnectedSession()

            let timeout = await session.test_resolvedToolCallTimeout(
                toolName: "agent_run",
                arguments: [
                    "op": .string("wait"),
                    "session_id": .string(UUID().uuidString),
                    "timeout": .double(600)
                ]
            )

            XCTAssertEqual(
                timeout,
                600 + MCPTimeoutPolicy.cliSemanticWaitResponseMarginSeconds
            )
            XCTAssertNotEqual(timeout, MCPTimeoutPolicy.cliDefaultToolCallTimeoutSeconds)
        }

        func testAnotherControlToolWaitUsesRequestedWaitPlusDeliveryMargin() async {
            let session = makeUnconnectedSession()

            let timeout = await session.test_resolvedToolCallTimeout(
                toolName: "wait_for_next_user_instruction",
                arguments: ["timeout_seconds": .int(900)]
            )

            XCTAssertEqual(
                timeout,
                900 + MCPTimeoutPolicy.cliSemanticWaitResponseMarginSeconds
            )
        }

        func testExplicitCLITimeoutPolicyOverridesToolDefaults() async {
            let session = makeUnconnectedSession()
            await session.setDefaultToolCallTimeout(.seconds(450))

            for toolName in ["prompt", "workspace_context"] {
                let explicitDeadline = await session.test_resolvedToolCallTimeout(
                    toolName: toolName,
                    arguments: ["op": .string("export")]
                )
                XCTAssertEqual(explicitDeadline, 450)
            }

            await session.setDefaultToolCallTimeout(.none)
            let explicitNone = await session.test_resolvedToolCallTimeout(
                toolName: "read_file"
            )
            XCTAssertNil(explicitNone)
        }

        func testExplicitPerCallTimeoutPolicyOverridesSemanticWait() async {
            let session = makeUnconnectedSession()
            let arguments: [String: Value] = [
                "op": .string("wait"),
                "session_id": .string(UUID().uuidString),
                "timeout": .double(1200)
            ]

            let explicitDeadline = await session.test_resolvedToolCallTimeout(
                .seconds(777),
                toolName: "agent_run",
                arguments: arguments
            )
            let explicitNone = await session.test_resolvedToolCallTimeout(
                .none,
                toolName: "agent_run",
                arguments: arguments
            )
            let explicitZero = await session.test_resolvedToolCallTimeout(
                .seconds(0),
                toolName: "agent_run",
                arguments: arguments
            )

            XCTAssertEqual(explicitDeadline, 777)
            XCTAssertNil(explicitNone)
            XCTAssertNil(explicitZero)
        }

        func testExplicitPerCallTimeoutPolicyOverridesPromptExportDefault() async {
            let session = makeUnconnectedSession()
            let arguments: [String: Value] = ["op": .string("export")]

            let explicitDeadline = await session.test_resolvedToolCallTimeout(
                .seconds(777),
                toolName: "prompt",
                arguments: arguments
            )
            let explicitNone = await session.test_resolvedToolCallTimeout(
                .none,
                toolName: "workspace_context",
                arguments: arguments
            )

            XCTAssertEqual(explicitDeadline, 777)
            XCTAssertNil(explicitNone)
        }

        func testZeroSemanticWaitLeavesClientDeadlineUnbounded() async {
            let session = makeUnconnectedSession()

            let timeout = await session.test_resolvedToolCallTimeout(
                toolName: "agent_run",
                arguments: [
                    "op": .string("wait"),
                    "session_id": .string(UUID().uuidString),
                    "timeout": .int(0)
                ]
            )

            XCTAssertNil(timeout)
        }

        private func makeUnconnectedSession() -> InteractiveMCPClientSession {
            InteractiveMCPClientSession(
                sessionToken: "timeout-contract-test",
                clientName: "timeout-contract-test"
            )
        }

        func testOrdinaryDefaultExportOverwritesAndTransmitsVersionedEnvelope() async throws {
            let transports = await InMemoryTransport.createConnectedPair()
            let recorder = CLIToolArgumentsRecorder()
            let server = Server(
                name: "CLI envelope test server",
                version: "1.0",
                capabilities: .init(tools: .init())
            )
            await server.withMethodHandler(CallTool.self) { params in
                await recorder.record(params.arguments ?? [:])
                return .init(
                    content: [.text(text: "ok", annotations: nil, _meta: nil)],
                    isError: false
                )
            }
            try await server.start(transport: transports.server)
            let requestSendBarrier = MCPRequestSendBarrier()
            let clientTransport = OrderedMCPTransport(
                underlying: transports.client,
                requestSendBarrier: requestSendBarrier,
                logger: transports.client.logger
            )
            let client = Client(name: "CLI envelope test client", version: "1.0")
            do {
                _ = try await client.connect(transport: clientTransport)
                let session = InteractiveMCPClientSession(
                    connectedClientForTesting: client,
                    requestSendBarrier: requestSendBarrier,
                    timeoutNowNanoseconds: { 10000 },
                    wallNowUnixMilliseconds: { 1000 }
                )
                _ = try await session.callTool(
                    name: "prompt",
                    arguments: [
                        "op": .string("export"),
                        MCPTimeoutPolicy.promptExportReservedEnvelopeArgumentKey: .string("caller-value")
                    ]
                )
                _ = try await session.callTool(
                    name: "prompt",
                    arguments: [
                        "op": .string("get"),
                        MCPTimeoutPolicy.promptExportReservedEnvelopeArgumentKey: .string("caller-value")
                    ]
                )
                _ = try await session.callTool(
                    name: "workspace_context",
                    arguments: ["op": .string("export")],
                    timeout: .seconds(300)
                )
                _ = try await session.callTool(
                    name: "prompt",
                    arguments: ["op": .string("export")],
                    timeout: .none
                )
                _ = try await session.callTool(
                    name: "prompt",
                    arguments: [
                        "args": .object([
                            "op": .string("export"),
                            MCPTimeoutPolicy.promptExportReservedEnvelopeArgumentKey: .object([
                                "kind": .string(MCPToolCallDeadlineEnvelope.Kind.ordinaryPromptExportV1.rawValue),
                                "expires_at_unix_milliseconds": .int(999_999)
                            ])
                        ])
                    ]
                )

                let calls = await recorder.snapshot()
                XCTAssertEqual(calls.count, 5)
                let envelope = calls[0][MCPTimeoutPolicy.promptExportReservedEnvelopeArgumentKey]?.objectValue
                XCTAssertEqual(
                    envelope?["kind"]?.stringValue,
                    MCPToolCallDeadlineEnvelope.Kind.ordinaryPromptExportV1.rawValue
                )
                XCTAssertEqual(envelope?["timeout_mode"]?.stringValue, "default")
                XCTAssertEqual(envelope?["expires_at_unix_milliseconds"]?.intValue, 301_000)
                XCTAssertNil(calls[1][MCPTimeoutPolicy.promptExportReservedEnvelopeArgumentKey])
                let finiteMarker = calls[2][MCPTimeoutPolicy.promptExportReservedEnvelopeArgumentKey]?.objectValue
                XCTAssertEqual(finiteMarker?["timeout_mode"]?.stringValue, "explicit_finite")
                XCTAssertNil(finiteMarker?["expires_at_unix_milliseconds"])
                let unboundedMarker = calls[3][MCPTimeoutPolicy.promptExportReservedEnvelopeArgumentKey]?.objectValue
                XCTAssertEqual(unboundedMarker?["timeout_mode"]?.stringValue, "explicit_unbounded")
                XCTAssertNil(unboundedMarker?["expires_at_unix_milliseconds"])
                XCTAssertEqual(
                    calls[4][MCPTimeoutPolicy.promptExportReservedEnvelopeArgumentKey]?
                        .objectValue?["expires_at_unix_milliseconds"]?.intValue,
                    301_000
                )
                await client.disconnect()
                await server.stop()
            } catch {
                await client.disconnect()
                await server.stop()
                throw error
            }
        }

        func testDefaultExportTimeoutBeforeRegistrationReturnsWithoutSending() async throws {
            let requestStartGate = CLIAsyncGate()
            let fixture = try await makeFixture(
                requestSendWillStart: {
                    await requestStartGate.arriveAndWait()
                },
                timeoutSleep: { _ in }
            )
            do {
                let call = Task {
                    try await fixture.session.callTool(
                        name: "workspace_context",
                        arguments: ["op": .string("export")]
                    )
                }
                await requestStartGate.waitUntilArrived()
                do {
                    _ = try await call.value
                    XCTFail("Expected pre-registration export timeout")
                } catch let error as InteractiveSessionError {
                    guard case let .toolCallTimeout(toolName, seconds) = error else {
                        XCTFail("Expected tool timeout, got \(error)")
                        await requestStartGate.release()
                        await fixture.cleanup()
                        return
                    }
                    XCTAssertEqual(toolName, "workspace_context")
                    XCTAssertEqual(seconds, MCPTimeoutPolicy.cliDefaultToolCallTimeoutSeconds)
                }
                let handlerDidStart = await fixture.handlerStarted.isSignalled()
                XCTAssertFalse(handlerDidStart)
                await requestStartGate.release()
                for _ in 0 ..< 100 {
                    let count = await fixture.session.test_pendingToolCallResponseTaskCount()
                    if count == 0 { break }
                    await Task.yield()
                }
                let pendingResponseTaskCount = await fixture.session.test_pendingToolCallResponseTaskCount()
                XCTAssertEqual(pendingResponseTaskCount, 0)
                let handlerStartedAfterAbandonment = await fixture.handlerStarted.isSignalled()
                XCTAssertFalse(handlerStartedAfterAbandonment)
                await fixture.cleanup()
            } catch {
                await requestStartGate.release()
                await fixture.cleanup()
                throw error
            }
        }

        func testDefaultExportTimeoutAfterRegistrationOrdersCancellationBehindSend() async throws {
            let registrationGate = CLIAsyncGate()
            let timeoutGate = CLIAsyncGate()
            let cancellationDelivered = CLIAsyncSignal()
            let fixture = try await makeFixture(
                requestSendDidRegister: {
                    await registrationGate.arriveAndWait()
                },
                cancellationDeliveryOverride: { client, requestID, reason in
                    try? await client.cancelRequest(requestID, reason: reason)
                    await cancellationDelivered.signal()
                },
                timeoutSleep: { _ in
                    await timeoutGate.arriveAndWait()
                }
            )
            do {
                let call = Task {
                    try await fixture.session.callTool(
                        name: "prompt",
                        arguments: ["op": .string("export")]
                    )
                }
                await registrationGate.waitUntilArrived()
                await timeoutGate.waitUntilArrived()
                await timeoutGate.release()
                let cancellationBeforeSend = await cancellationDelivered.isSignalled()
                XCTAssertFalse(cancellationBeforeSend)
                let handlerBeforeSend = await fixture.handlerStarted.isSignalled()
                XCTAssertFalse(handlerBeforeSend)

                await registrationGate.release()
                await fixture.handlerStarted.wait()
                await cancellationDelivered.wait()
                await fixture.handlerCancelled.wait()

                do {
                    _ = try await call.value
                    XCTFail("Expected prompt export timeout")
                } catch let error as InteractiveSessionError {
                    guard case let .toolCallTimeout(toolName, seconds) = error else {
                        XCTFail("Expected tool timeout, got \(error)")
                        await fixture.cleanup()
                        return
                    }
                    XCTAssertEqual(toolName, "prompt")
                    XCTAssertEqual(seconds, MCPTimeoutPolicy.cliDefaultToolCallTimeoutSeconds)
                }
                await fixture.cleanup()
            } catch {
                await timeoutGate.release()
                await registrationGate.release()
                await fixture.cleanup()
                throw error
            }
        }

        func testImmediateTimeoutWaitsForCancellationAttemptToFinish() async throws {
            let cancellationDeliveryFinished = CLIAsyncSignal()
            let fixture = try await makeFixture(
                cancellationBehavior: .ignoreUntilReleased,
                cancellationDeliveryOverride: { client, requestID, reason in
                    try? await client.cancelRequest(requestID, reason: reason)
                    await cancellationDeliveryFinished.signal()
                },
                timeoutSleep: { _ in }
            )
            do {
                let call = Task {
                    try await fixture.session.callTool(
                        name: "slow_tool",
                        arguments: nil,
                        timeout: .seconds(42)
                    )
                }
                do {
                    _ = try await call.value
                    XCTFail("Expected tool timeout")
                } catch let error as InteractiveSessionError {
                    guard case let .toolCallTimeout(toolName, seconds) = error else {
                        XCTFail("Expected tool timeout, got \(error)")
                        await fixture.cleanup()
                        return
                    }
                    XCTAssertEqual(toolName, "slow_tool")
                    XCTAssertEqual(seconds, 42)
                }

                let cancellationDelivered = await cancellationDeliveryFinished.isSignalled()
                XCTAssertTrue(cancellationDelivered)
                await fixture.handlerCancelled.wait()
                await fixture.cleanup()
            } catch {
                await fixture.cleanup()
                throw error
            }
        }

        func testTimeoutWinsSettlementAndCancelsAndDrainsExactlyOnce() async throws {
            let timeoutGate = CLIAsyncGate()
            let cancellationDeliveryGate = CLIAsyncGate()
            let cancellationDrainStarted = CLIAsyncSignal()
            let recorder = CLICancellationSettlementRecorder()
            let fixture = try await makeFixture(
                cancellationBehavior: .ignoreUntilReleased,
                cancellationDeliveryOverride: { _, _, reason in
                    await recorder.recordDelivery(reason: reason)
                    await cancellationDeliveryGate.arriveAndWait()
                },
                timeoutSleep: { _ in await timeoutGate.arriveAndWait() },
                cancellationDeliveryDrainSleep: { _ in
                    await recorder.recordDrain()
                    await cancellationDrainStarted.signal()
                    try await Task.sleep(for: .seconds(60))
                }
            )
            do {
                let call = Task {
                    try await fixture.session.callTool(
                        name: "slow_tool",
                        arguments: nil,
                        timeout: .seconds(42)
                    )
                }
                await fixture.handlerStarted.wait()
                await timeoutGate.waitUntilArrived()
                await timeoutGate.release()
                await cancellationDeliveryGate.waitUntilArrived()
                call.cancel()
                await cancellationDrainStarted.wait()
                await cancellationDeliveryGate.release()

                do {
                    _ = try await call.value
                    XCTFail("Expected tool timeout")
                } catch let error as InteractiveSessionError {
                    guard case let .toolCallTimeout(toolName, seconds) = error else {
                        XCTFail("Expected tool timeout, got \(error)")
                        await fixture.cleanup()
                        return
                    }
                    XCTAssertEqual(toolName, "slow_tool")
                    XCTAssertEqual(seconds, 42)
                }

                let recorded = await recorder.snapshot()
                XCTAssertEqual(recorded.deliveryReasons, ["CLI tool call timed out after 42.0 seconds"])
                XCTAssertEqual(recorded.drainCount, 1)
                await fixture.cleanup()
            } catch {
                await timeoutGate.release()
                await cancellationDeliveryGate.release()
                await fixture.cleanup()
                throw error
            }
        }

        func testCallerCancellationWinsSettlementAndCancelsAndDrainsExactlyOnce() async throws {
            let timeoutGate = CLIAsyncGate()
            let cancellationDeliveryGate = CLIAsyncGate()
            let cancellationDrainStarted = CLIAsyncSignal()
            let recorder = CLICancellationSettlementRecorder()
            let fixture = try await makeFixture(
                cancellationBehavior: .ignoreUntilReleased,
                cancellationDeliveryOverride: { _, _, reason in
                    await recorder.recordDelivery(reason: reason)
                    await cancellationDeliveryGate.arriveAndWait()
                },
                timeoutSleep: { _ in await timeoutGate.arriveAndWait() },
                cancellationDeliveryDrainSleep: { _ in
                    await recorder.recordDrain()
                    await cancellationDrainStarted.signal()
                    try await Task.sleep(for: .seconds(60))
                }
            )
            do {
                let call = Task {
                    try await fixture.session.callTool(
                        name: "slow_tool",
                        arguments: nil,
                        timeout: .seconds(42)
                    )
                }
                await fixture.handlerStarted.wait()
                await timeoutGate.waitUntilArrived()
                call.cancel()
                await cancellationDeliveryGate.waitUntilArrived()
                await timeoutGate.release()
                await cancellationDrainStarted.wait()
                await cancellationDeliveryGate.release()

                do {
                    _ = try await call.value
                    XCTFail("Expected caller cancellation")
                } catch is CancellationError {
                    // Expected.
                }

                let recorded = await recorder.snapshot()
                XCTAssertEqual(recorded.deliveryReasons, ["CLI caller cancelled tool request"])
                XCTAssertEqual(recorded.drainCount, 1)
                await fixture.cleanup()
            } catch {
                await timeoutGate.release()
                await cancellationDeliveryGate.release()
                await fixture.cleanup()
                throw error
            }
        }

        func testPromptExportImplicitTimeoutDeliversCancellationWithoutIndefiniteWait() async throws {
            let cancellationDeliveryFinished = CLIAsyncSignal()
            let timeoutGate = CLIAsyncGate()
            let fixture = try await makeFixture(
                cancellationBehavior: .ignoreUntilReleased,
                cancellationDeliveryOverride: { client, requestID, reason in
                    try? await client.cancelRequest(requestID, reason: reason)
                    await cancellationDeliveryFinished.signal()
                },
                timeoutSleep: { _ in await timeoutGate.arriveAndWait() }
            )
            do {
                let call = Task {
                    try await fixture.session.callTool(
                        name: "prompt",
                        arguments: ["op": .string("export")]
                    )
                }
                await fixture.handlerStarted.wait()
                await timeoutGate.release()
                do {
                    _ = try await call.value
                    XCTFail("Expected prompt export timeout")
                } catch let error as InteractiveSessionError {
                    guard case let .toolCallTimeout(toolName, seconds) = error else {
                        XCTFail("Expected tool timeout, got \(error)")
                        await fixture.cleanup()
                        return
                    }
                    XCTAssertEqual(toolName, "prompt")
                    XCTAssertEqual(seconds, MCPTimeoutPolicy.cliDefaultToolCallTimeoutSeconds)
                }

                let cancellationDelivered = await cancellationDeliveryFinished.isSignalled()
                XCTAssertTrue(cancellationDelivered)
                await fixture.handlerCancelled.wait()
                await fixture.cleanup()
            } catch {
                await fixture.cleanup()
                throw error
            }
        }

        func testTimeoutCancellationDrainIsBoundedWhenAttemptStalls() async throws {
            let cancellationStartGate = CLIAsyncGate()
            let cancellationDeliveryFinished = CLIAsyncSignal()
            let fixture = try await makeFixture(
                cancellationDeliveryOverride: { client, requestID, reason in
                    await cancellationStartGate.arriveAndWait()
                    try? await client.cancelRequest(requestID, reason: reason)
                    await cancellationDeliveryFinished.signal()
                },
                timeoutSleep: { _ in },
                cancellationDeliveryDrainTimeoutNanoseconds: 42,
                cancellationDeliveryDrainSleep: { _ in }
            )
            do {
                let call = Task {
                    try await fixture.session.callTool(
                        name: "slow_tool",
                        arguments: nil,
                        timeout: .seconds(42)
                    )
                }
                await cancellationStartGate.waitUntilArrived()

                do {
                    _ = try await call.value
                    XCTFail("Expected tool timeout")
                } catch let error as InteractiveSessionError {
                    guard case .toolCallTimeout = error else {
                        XCTFail("Expected tool timeout, got \(error)")
                        await cancellationStartGate.release()
                        await fixture.cleanup()
                        return
                    }
                }

                let didFinishBeforeRelease = await cancellationDeliveryFinished.isSignalled()
                XCTAssertFalse(didFinishBeforeRelease)
                await cancellationStartGate.release()
                await cancellationDeliveryFinished.wait()
                await fixture.cleanup()
            } catch {
                await cancellationStartGate.release()
                await fixture.cleanup()
                throw error
            }
        }

        func testCallerCancellationWhilePromptExportIsQueuedDoesNotSend() async throws {
            let requestStartGate = CLIAsyncGate()
            let fixture = try await makeFixture(
                requestSendWillStart: {
                    await requestStartGate.arriveAndWait()
                }
            )
            do {
                let call = Task {
                    try await fixture.session.callTool(
                        name: "prompt",
                        arguments: ["op": .string("export")]
                    )
                }
                await requestStartGate.waitUntilArrived()
                call.cancel()
                await requestStartGate.release()

                do {
                    _ = try await call.value
                    XCTFail("Expected caller cancellation")
                } catch is CancellationError {
                    // Expected.
                }

                let handlerStarted = await fixture.handlerStarted.isSignalled()
                XCTAssertFalse(handlerStarted)
                await fixture.cleanup()
            } catch {
                await fixture.cleanup()
                throw error
            }
        }

        func testProgressEnabledToolCallsRequestStandardMCPProgress() async throws {
            let transports = await InMemoryTransport.createConnectedPair()
            let recorder = CLIProgressTokenRecorder()
            let server = Server(
                name: "CLI progress metadata test server",
                version: "1.0",
                capabilities: .init(tools: .init())
            )
            await server.withMethodHandler(CallTool.self) { params in
                await recorder.record(params._meta?.progressToken)
                return .init(
                    content: [.text(text: "ok", annotations: nil, _meta: nil)],
                    isError: false
                )
            }
            try await server.start(transport: transports.server)

            let requestSendBarrier = MCPRequestSendBarrier()
            let clientTransport = OrderedMCPTransport(
                underlying: transports.client,
                requestSendBarrier: requestSendBarrier,
                logger: transports.client.logger
            )
            let client = Client(name: "CLI progress metadata test client", version: "1.0")

            do {
                _ = try await client.connect(transport: clientTransport)
                let session = InteractiveMCPClientSession(
                    connectedClientForTesting: client,
                    requestSendBarrier: requestSendBarrier
                )
                await session.setProgressEnabled(true)

                let result = try await session.callTool(
                    name: "context_builder",
                    arguments: nil,
                    timeout: .none
                )

                XCTAssertFalse(result.isError == true)
                let recordedToken = await recorder.recordedToken()
                XCTAssertNotNil(recordedToken)
                await client.disconnect()
                await server.stop()
            } catch {
                await client.disconnect()
                await server.stop()
                throw error
            }
        }

        private func makeFixture(
            cancellationBehavior: CLICancellationBehavior = .cooperative,
            requestSendWillStart: (@Sendable () async -> Void)? = nil,
            requestSendDidRegister: (@Sendable () async -> Void)? = nil,
            cancellationDeliveryOverride: InteractiveMCPClientSession.CancellationDeliveryOverride? = nil,
            timeoutSleep: @escaping @Sendable (UInt64) async throws -> Void = { nanoseconds in
                try await Task.sleep(nanoseconds: nanoseconds)
            },
            cancellationDeliveryDrainTimeoutNanoseconds: UInt64 = 2_000_000_000,
            cancellationDeliveryDrainSleep: @escaping @Sendable (UInt64) async throws -> Void = { nanoseconds in
                try await Task.sleep(nanoseconds: nanoseconds)
            }
        ) async throws -> CLISessionCancellationFixture {
            let transports = await InMemoryTransport.createConnectedPair()
            let handlerStarted = CLIAsyncSignal()
            let handlerCancelled = CLIAsyncSignal()
            let ignoredCancellationRelease = CLIAsyncSignal()
            let cancellationSuspension = CLICancellationSuspension()
            let server = Server(
                name: "CLI cancellation test server",
                version: "1.0",
                capabilities: .init(tools: .init())
            )
            await server.withMethodHandler(CallTool.self) { _ in
                await handlerStarted.signal()
                do {
                    try await cancellationSuspension.wait()
                    return .init(
                        content: [.text(text: "unexpected", annotations: nil, _meta: nil)],
                        isError: false
                    )
                } catch is CancellationError {
                    await handlerCancelled.signal()
                    switch cancellationBehavior {
                    case .cooperative:
                        throw CancellationError()
                    case .ignoreUntilReleased:
                        await ignoredCancellationRelease.wait()
                        return .init(
                            content: [.text(text: "late result", annotations: nil, _meta: nil)],
                            isError: false
                        )
                    }
                }
            }
            try await server.start(transport: transports.server)

            let requestSendBarrier = MCPRequestSendBarrier()
            let clientTransport = OrderedMCPTransport(
                underlying: transports.client,
                requestSendBarrier: requestSendBarrier,
                logger: transports.client.logger
            )
            let client = Client(name: "CLI cancellation test client", version: "1.0")
            _ = try await client.connect(transport: clientTransport)
            let session = InteractiveMCPClientSession(
                connectedClientForTesting: client,
                requestSendBarrier: requestSendBarrier,
                requestSendWillStart: requestSendWillStart,
                requestSendDidRegister: requestSendDidRegister,
                cancellationDeliveryOverride: cancellationDeliveryOverride,
                timeoutSleep: timeoutSleep,
                cancellationDeliveryDrainTimeoutNanoseconds: cancellationDeliveryDrainTimeoutNanoseconds,
                cancellationDeliveryDrainSleep: cancellationDeliveryDrainSleep
            )
            return CLISessionCancellationFixture(
                client: client,
                server: server,
                session: session,
                handlerStarted: handlerStarted,
                handlerCancelled: handlerCancelled,
                ignoredCancellationRelease: ignoredCancellationRelease
            )
        }
    }

    private enum CLICancellationBehavior {
        case cooperative
        case ignoreUntilReleased
    }

    private struct CLISessionCancellationFixture {
        let client: Client
        let server: Server
        let session: InteractiveMCPClientSession
        let handlerStarted: CLIAsyncSignal
        let handlerCancelled: CLIAsyncSignal
        let ignoredCancellationRelease: CLIAsyncSignal

        func cleanup() async {
            await ignoredCancellationRelease.signal()
            await client.disconnect()
            await server.stop()
        }
    }

    private actor CLIAsyncGate {
        private var arrived = false
        private var released = false
        private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func arriveAndWait() async {
            arrived = true
            let arrivalWaiters = arrivalWaiters
            self.arrivalWaiters.removeAll()
            for waiter in arrivalWaiters {
                waiter.resume()
            }
            guard !released else { return }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        func waitUntilArrived() async {
            guard !arrived else { return }
            await withCheckedContinuation { continuation in
                arrivalWaiters.append(continuation)
            }
        }

        func release() {
            guard !released else { return }
            released = true
            let releaseWaiters = releaseWaiters
            self.releaseWaiters.removeAll()
            for waiter in releaseWaiters {
                waiter.resume()
            }
        }
    }

    private actor CLIAsyncSignal {
        private var signalled = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func signal() {
            guard !signalled else { return }
            signalled = true
            let waiters = waiters
            self.waiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }

        func wait() async {
            guard !signalled else { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func isSignalled() -> Bool {
            signalled
        }
    }

    private actor CLICancellationSettlementRecorder {
        private var deliveryReasons: [String] = []
        private var drainCount = 0

        func recordDelivery(reason: String) {
            deliveryReasons.append(reason)
        }

        func recordDrain() {
            drainCount += 1
        }

        func snapshot() -> (deliveryReasons: [String], drainCount: Int) {
            (deliveryReasons, drainCount)
        }
    }

    private actor CLIToolArgumentsRecorder {
        private var calls: [[String: Value]] = []

        func record(_ arguments: [String: Value]) {
            calls.append(arguments)
        }

        func snapshot() -> [[String: Value]] {
            calls
        }
    }

    private actor CLIProgressTokenRecorder {
        private var token: ProgressToken?

        func record(_ token: ProgressToken?) {
            self.token = token
        }

        func recordedToken() -> ProgressToken? {
            token
        }
    }

    private actor CLICancellationSuspension {
        private struct Waiter {
            let id: UUID
            let continuation: CheckedContinuation<Void, Error>
        }

        private var waiter: Waiter?
        private var cancelledWaiterIDs: Set<UUID> = []

        func wait() async throws {
            let waiterID = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled || cancelledWaiterIDs.remove(waiterID) != nil {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        waiter = Waiter(id: waiterID, continuation: continuation)
                    }
                }
            } onCancel: {
                Task { await self.cancel(waiterID) }
            }
        }

        private func cancel(_ waiterID: UUID) {
            guard let waiter, waiter.id == waiterID else {
                cancelledWaiterIDs.insert(waiterID)
                return
            }
            self.waiter = nil
            waiter.continuation.resume(throwing: CancellationError())
        }
    }
#endif
