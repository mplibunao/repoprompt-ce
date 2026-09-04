import CryptoKit
import Darwin
import Foundation

public enum JSONRPCBridgeDirection: String, Codable, Sendable {
    case clientToServer = "client_to_server"
    case serverToClient = "server_to_client"

    public var opposite: JSONRPCBridgeDirection {
        switch self {
        case .clientToServer: .serverToClient
        case .serverToClient: .clientToServer
        }
    }
}

#if DEBUG
    public struct MCPDiagnosticBoundedString: Equatable, Sendable {
        public static let maximumUTF8ByteCount = 128

        public let value: String?
        public let omitted: Bool
        public let truncated: Bool
        public let originalUTF8ByteCount: Int?

        public init(_ rawValue: String?) {
            originalUTF8ByteCount = rawValue?.utf8.count
            if let rawValue, rawValue.utf8.count <= Self.maximumUTF8ByteCount {
                value = rawValue
                omitted = false
            } else {
                value = nil
                omitted = rawValue != nil
            }
            truncated = false
        }

        init(prefix: String, rawValue: String?) {
            originalUTF8ByteCount = rawValue?.utf8.count
            guard let rawValue else {
                value = nil
                omitted = false
                truncated = false
                return
            }

            let prefixByteCount = prefix.utf8.count
            if prefixByteCount <= Self.maximumUTF8ByteCount,
               rawValue.utf8.count <= Self.maximumUTF8ByteCount - prefixByteCount
            {
                value = prefix + rawValue
                omitted = false
            } else {
                value = nil
                omitted = true
            }
            truncated = false
        }
    }
#endif

public enum JSONRPCBridgeID: Hashable, Codable, Sendable, CustomStringConvertible {
    case number(Int64)
    case string(String)
    case null

    public var description: String {
        switch self {
        case let .number(value): "number:\(value)"
        case let .string(value): "string:\(value)"
        case .null: "null"
        }
    }

    #if DEBUG
        public var boundedDiagnosticDescription: String? {
            switch self {
            case .number, .null:
                description
            case let .string(value):
                MCPDiagnosticBoundedString(prefix: "string:", rawValue: value).value
            }
        }

        public var diagnosticStringOmitted: Bool {
            if case let .string(value) = self {
                return MCPDiagnosticBoundedString(prefix: "string:", rawValue: value).omitted
            }
            return false
        }

        public var diagnosticStringTruncated: Bool {
            if case let .string(value) = self {
                return MCPDiagnosticBoundedString(prefix: "string:", rawValue: value).truncated
            }
            return false
        }

        public var diagnosticStringUTF8ByteCount: Int? {
            if case let .string(value) = self { return value.utf8.count }
            return nil
        }
    #endif

    public static func parseFaultSelector(_ raw: String) -> JSONRPCBridgeID? {
        if raw == "null" { return .null }
        if raw.hasPrefix("number:"), let value = Int64(raw.dropFirst("number:".count)) {
            return .number(value)
        }
        if raw.hasPrefix("string:") {
            return .string(String(raw.dropFirst("string:".count)))
        }
        return nil
    }

    public static func parseJSONValue(_ value: Any?) -> JSONRPCBridgeID? {
        guard let value else { return nil }
        if value is NSNull { return .null }
        if let value = value as? String { return .string(value) }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return nil
        }
        let double = number.doubleValue
        let integer = number.int64Value
        guard double.isFinite, double == Double(integer) else { return nil }
        return .number(integer)
    }
}

public enum JSONRPCBridgeReplayPolicy {
    private static let replayableMethods: Set<String> = [
        "initialize",
        "ping",
        "tools/list",
        "resources/list",
        "resources/templates/list",
        "resources/read",
        "prompts/list",
        "prompts/get",
        "completion/complete"
    ]

    private static let replayableToolCalls: Set<String> = [
        "file_search",
        "get_code_structure",
        "get_file_tree",
        "git",
        "oracle_utils",
        "read_file",
        "workspace_context"
    ]

    public static func isReplayableClientRequest(
        method: String?,
        tool: String?,
        toolArguments: [String: Any]? = nil
    ) -> Bool {
        guard let method else { return false }
        if replayableMethods.contains(method) {
            return true
        }
        guard method == "tools/call", let tool else {
            return false
        }
        if tool == "workspace_context" {
            return isReplayableWorkspaceContext(arguments: toolArguments)
        }
        return replayableToolCalls.contains(tool)
    }

    private static func isReplayableWorkspaceContext(arguments: [String: Any]?) -> Bool {
        guard let rawOperation = arguments?["op"] else {
            return true
        }
        guard let operation = rawOperation as? String else {
            return false
        }
        let normalized = operation.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty || normalized == "snapshot"
    }
}

public struct JSONRPCBridgeMessageMetadata: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case request
        case response
        case notification
        case invalidClientMessage = "invalid_client_message"
    }

    public let kind: Kind
    public let id: JSONRPCBridgeID?
    public let method: String?
    public let tool: String?
    public let requestOrdinal: UInt64?

    public init(
        kind: Kind,
        id: JSONRPCBridgeID?,
        method: String?,
        tool: String?,
        requestOrdinal: UInt64?
    ) {
        self.kind = kind
        self.id = id
        self.method = method
        self.tool = tool
        self.requestOrdinal = requestOrdinal
    }
}

#if DEBUG
    public enum MCPResponseDeliveryCaptureLossReason: Sendable {
        case coordinatorBoundaryContention
        case tracerLockContention
        case historyCapacity
    }

    public struct MCPResponseDeliveryCaptureHooks: Sendable {
        public let isActive: @Sendable () -> Bool
        public let tryWithBoundary: @Sendable (@Sendable () -> Bool) -> Bool?
        public let recordLoss: @Sendable (MCPResponseDeliveryCaptureLossReason) -> Void

        public init(
            isActive: @escaping @Sendable () -> Bool,
            tryWithBoundary: @escaping @Sendable (@Sendable () -> Bool) -> Bool?,
            recordLoss: @escaping @Sendable (MCPResponseDeliveryCaptureLossReason) -> Void
        ) {
            self.isActive = isActive
            self.tryWithBoundary = tryWithBoundary
            self.recordLoss = recordLoss
        }
    }

    public enum MCPResponseDeliveryCapturePublicationTestEvent: Sendable {
        case hookLookupLockFailed
        case captureDeactivated
    }

    public enum MCPResponseDeliveryCapturePublication {
        private static let hooksLock = NSLock()
        private nonisolated(unsafe) static var installedHooks: MCPResponseDeliveryCaptureHooks?
        private nonisolated(unsafe) static var captureActive: Int32 = 0
        private nonisolated(unsafe) static var hookLookupRecorderCount: Int32 = 0
        private nonisolated(unsafe) static var hookLookupContention: Int64 = 0
        private static let testEventSinkLock = NSLock()
        private nonisolated(unsafe) static var testEventSink: (@Sendable (MCPResponseDeliveryCapturePublicationTestEvent) -> Void)?

        public static func install(_ hooks: MCPResponseDeliveryCaptureHooks) {
            hooksLock.lock()
            installedHooks = hooks
            hooksLock.unlock()
        }

        static var isCaptureActive: Bool {
            OSAtomicAdd32Barrier(0, &captureActive) == 1
        }

        public static func beginCapture() {
            OSAtomicCompareAndSwap32Barrier(1, 0, &captureActive)
            waitForHookLookupRecorders()
            _ = drainHookLookupContention()
            OSAtomicCompareAndSwap32Barrier(0, 1, &captureActive)
        }

        public static func finishCaptureAndDrainHookLookupContention() -> UInt64 {
            OSAtomicCompareAndSwap32Barrier(1, 0, &captureActive)
            notifyTestEvent(.captureDeactivated)
            waitForHookLookupRecorders()
            return UInt64(max(0, drainHookLookupContention()))
        }

        public static func hookLookupContentionSnapshot() -> UInt64 {
            UInt64(max(0, OSAtomicAdd64Barrier(0, &hookLookupContention)))
        }

        static func currentHooks() -> MCPResponseDeliveryCaptureHooks? {
            OSAtomicIncrement32Barrier(&hookLookupRecorderCount)
            defer { OSAtomicDecrement32Barrier(&hookLookupRecorderCount) }
            let captureWasActive = isCaptureActive
            guard hooksLock.try() else {
                // Diagnostic lookup must not delay transport writes or dereference
                // closure-bearing state while another thread is replacing it.
                notifyTestEvent(.hookLookupLockFailed)
                if captureWasActive {
                    OSAtomicIncrement64Barrier(&hookLookupContention)
                }
                return nil
            }
            defer { hooksLock.unlock() }
            return installedHooks
        }

        public static func setTestEventSink(
            _ sink: (@Sendable (MCPResponseDeliveryCapturePublicationTestEvent) -> Void)?
        ) {
            testEventSinkLock.lock()
            testEventSink = sink
            testEventSinkLock.unlock()
        }

        public static func withInstalledHooksForTesting<T>(
            _ hooks: MCPResponseDeliveryCaptureHooks,
            _ body: () throws -> T
        ) rethrows -> T {
            hooksLock.lock()
            let previousHooks = installedHooks
            installedHooks = hooks
            defer {
                installedHooks = previousHooks
                hooksLock.unlock()
            }
            return try body()
        }

        private static func drainHookLookupContention() -> Int64 {
            let count = OSAtomicAdd64Barrier(0, &hookLookupContention)
            OSAtomicAdd64Barrier(-count, &hookLookupContention)
            return count
        }

        private static func waitForHookLookupRecorders() {
            while OSAtomicAdd32Barrier(0, &hookLookupRecorderCount) != 0 {
                sched_yield()
            }
        }

        private static func notifyTestEvent(_ event: MCPResponseDeliveryCapturePublicationTestEvent) {
            guard testEventSinkLock.try() else { return }
            let sink = testEventSink
            testEventSinkLock.unlock()
            sink?(event)
        }
    }
#endif

public struct MCPResponseDeliveryTraceEvent: Equatable, Sendable, CustomStringConvertible {
    public let layer: String
    public let phase: String
    public let connectionID: String?
    public let connectionGeneration: UInt64?
    public let direction: JSONRPCBridgeDirection?
    public let id: JSONRPCBridgeID?
    public let method: String?
    public let tool: String?
    public let invocationID: String?
    public let lifecycleState: String?
    public let requestOrdinal: UInt64?
    public let framedByteCount: Int?
    public let framedSHA256: String?
    public let activeRequestCount: Int?
    public let responseInDeliveryCount: Int?
    public let terminalReason: String?
    public let requestIdentity: MCPRequestTimelineIdentity?
    public let providerActive: Bool?
    public let networkScopeActive: Bool?
    public let permitActive: Bool?
    public let publicationPending: Bool?
    public let terminalBarrier: Bool?
    #if DEBUG
        /// Same-process monotonic timestamp used to correlate response delivery with deferred work.
        public let monotonicUptimeMS: Double
    #endif

    public init(
        layer: String,
        phase: String,
        connectionID: String? = nil,
        connectionGeneration: UInt64? = nil,
        direction: JSONRPCBridgeDirection? = nil,
        id: JSONRPCBridgeID? = nil,
        method: String? = nil,
        tool: String? = nil,
        invocationID: String? = nil,
        lifecycleState: String? = nil,
        requestOrdinal: UInt64? = nil,
        framedByteCount: Int? = nil,
        framedSHA256: String? = nil,
        activeRequestCount: Int? = nil,
        responseInDeliveryCount: Int? = nil,
        terminalReason: String? = nil,
        requestIdentity: MCPRequestTimelineIdentity? = nil,
        providerActive: Bool? = nil,
        networkScopeActive: Bool? = nil,
        permitActive: Bool? = nil,
        publicationPending: Bool? = nil,
        terminalBarrier: Bool? = nil
    ) {
        self.layer = layer
        self.phase = phase
        self.connectionID = connectionID
        self.connectionGeneration = connectionGeneration
        self.direction = direction
        self.id = id
        self.method = method
        self.tool = tool
        self.invocationID = invocationID
        self.lifecycleState = lifecycleState
        self.requestOrdinal = requestOrdinal
        self.framedByteCount = framedByteCount
        self.framedSHA256 = framedSHA256
        self.activeRequestCount = activeRequestCount
        self.responseInDeliveryCount = responseInDeliveryCount
        self.terminalReason = terminalReason
        #if DEBUG
            self.requestIdentity = MCPRequestTimelineIdentity(
                jsonRPCRequestID: id,
                connectionID: connectionID,
                connectionGeneration: connectionGeneration,
                appInvocationID: invocationID,
                requestOrdinal: requestOrdinal
            ).fillingMissingFields(from: requestIdentity)
        #else
            self.requestIdentity = requestIdentity
        #endif
        self.providerActive = providerActive
        self.networkScopeActive = networkScopeActive
        self.permitActive = permitActive
        self.publicationPending = publicationPending
        self.terminalBarrier = terminalBarrier
        #if DEBUG
            monotonicUptimeMS = ProcessInfo.processInfo.systemUptime * 1000
        #endif
    }

    public var payload: [String: Any] {
        var value: [String: Any] = [
            "layer": layer,
            "phase": phase
        ]
        #if DEBUG
            let connectionIdentity = MCPDiagnosticBoundedString(connectionID)
            value["connection_id"] = connectionIdentity.value ?? NSNull()
            value["connection_id_omitted"] = connectionIdentity.omitted
            value["connection_id_truncated"] = connectionIdentity.truncated
            value["connection_id_utf8_byte_count"] = connectionIdentity.originalUTF8ByteCount ?? NSNull()
        #else
            value["connection_id"] = connectionID ?? NSNull()
        #endif
        value["connection_generation"] = connectionGeneration ?? NSNull()
        value["direction"] = direction?.rawValue ?? NSNull()
        #if DEBUG
            value["jsonrpc_request_id"] = id?.boundedDiagnosticDescription ?? NSNull()
            value["jsonrpc_request_id_omitted"] = id?.diagnosticStringOmitted ?? false
            value["jsonrpc_request_id_truncated"] = id?.diagnosticStringTruncated ?? false
            value["jsonrpc_request_id_utf8_byte_count"] = id?.diagnosticStringUTF8ByteCount ?? NSNull()
        #else
            value["jsonrpc_request_id"] = id?.description ?? NSNull()
        #endif
        value["method"] = method ?? NSNull()
        value["tool"] = tool ?? NSNull()
        #if DEBUG
            let invocationIdentity = MCPDiagnosticBoundedString(requestIdentity?.appInvocationID ?? invocationID)
            value["app_invocation_id"] = invocationIdentity.value ?? NSNull()
            value["app_invocation_id_omitted"] = invocationIdentity.omitted
            value["app_invocation_id_truncated"] = invocationIdentity.truncated
            value["app_invocation_id_utf8_byte_count"] = invocationIdentity.originalUTF8ByteCount ?? NSNull()
        #else
            value["app_invocation_id"] = requestIdentity?.appInvocationID ?? invocationID ?? NSNull()
        #endif
        value["lifecycle_state"] = lifecycleState ?? NSNull()
        value["request_ordinal"] = requestOrdinal ?? NSNull()
        value["framed_byte_count"] = framedByteCount ?? NSNull()
        #if DEBUG
            value["framed_sha256"] = framedSHA256 ?? NSNull()
        #endif
        value["active_request_count"] = activeRequestCount ?? NSNull()
        value["response_in_delivery_count"] = responseInDeliveryCount ?? NSNull()
        value["terminal_reason"] = terminalReason ?? NSNull()
        value["provider_active"] = providerActive ?? NSNull()
        value["network_scope_active"] = networkScopeActive ?? NSNull()
        value["permit_active"] = permitActive ?? NSNull()
        value["publication_pending"] = publicationPending ?? NSNull()
        value["terminal_barrier"] = terminalBarrier ?? NSNull()
        #if DEBUG
            value["monotonic_uptime_ms"] = monotonicUptimeMS
        #endif
        return value
    }

    public var description: String {
        var fields = ["layer=\(layer)", "phase=\(phase)"]
        #if DEBUG
            func appendIdentity(_ rawValue: String?, field: String) {
                let identity = MCPDiagnosticBoundedString(rawValue)
                if let value = identity.value {
                    fields.append("\(field)=\(value)")
                } else if identity.omitted {
                    fields.append("\(field)=<omitted>")
                    if let byteCount = identity.originalUTF8ByteCount {
                        fields.append("\(field)_utf8_bytes=\(byteCount)")
                    }
                }
            }

            appendIdentity(connectionID, field: "connection_id")
        #else
            if let connectionID { fields.append("connection_id=\(connectionID)") }
        #endif
        if let connectionGeneration { fields.append("generation=\(connectionGeneration)") }
        if let direction { fields.append("direction=\(direction.rawValue)") }
        #if DEBUG
            if let id {
                if let boundedID = id.boundedDiagnosticDescription {
                    fields.append("id=\(boundedID)")
                } else {
                    fields.append("id=<omitted>")
                    if let byteCount = id.diagnosticStringUTF8ByteCount {
                        fields.append("id_utf8_bytes=\(byteCount)")
                    }
                }
            }
        #else
            if let id { fields.append("id=\(id)") }
        #endif
        if let method { fields.append("method=\(method)") }
        if let tool { fields.append("tool=\(tool)") }
        #if DEBUG
            appendIdentity(requestIdentity?.appInvocationID ?? invocationID, field: "app_invocation_id")
        #else
            if let invocationID { fields.append("invocation_id=\(invocationID)") }
        #endif
        if let lifecycleState { fields.append("state=\(lifecycleState)") }
        if let requestOrdinal { fields.append("ordinal=\(requestOrdinal)") }
        if let framedByteCount { fields.append("bytes=\(framedByteCount)") }
        if let framedSHA256 { fields.append("sha256=\(framedSHA256)") }
        if let activeRequestCount { fields.append("active=\(activeRequestCount)") }
        if let responseInDeliveryCount { fields.append("in_delivery=\(responseInDeliveryCount)") }
        if let terminalReason { fields.append("terminal_reason=\(terminalReason)") }
        if let providerActive { fields.append("provider_active=\(providerActive)") }
        if let networkScopeActive { fields.append("network_scope_active=\(networkScopeActive)") }
        if let permitActive { fields.append("permit_active=\(permitActive)") }
        if let publicationPending { fields.append("publication_pending=\(publicationPending)") }
        if let terminalBarrier { fields.append("terminal_barrier=\(terminalBarrier)") }
        #if !DEBUG
            if let appInvocationID = requestIdentity?.appInvocationID, invocationID == nil {
                fields.append("app_invocation_id=\(appInvocationID)")
            }
        #endif
        return fields.joined(separator: " ")
    }
}

public enum MCPResponseDeliveryTracer {
    private static let lock = NSLock()
    #if DEBUG
        private nonisolated(unsafe) static var debugEvents: [MCPResponseDeliveryTraceEvent] = []
        private static let maximumDebugEvents = 20000
    #endif

    public static var successTracingEnabled: Bool {
        #if DEBUG
            ProcessInfo.processInfo.environment["REPOPROMPT_MCP_RESPONSE_TRACE"] == "1"
                || UserDefaults.standard.bool(forKey: "enableMCPResponseDeliveryTrace")
                || UserDefaults.standard.bool(forKey: "enableAgentModePerfDiagnostics")
        #else
            UserDefaults.standard.bool(forKey: "enableMCPResponseDeliveryTrace")
        #endif
    }

    public static func emit(
        _ event: MCPResponseDeliveryTraceEvent,
        to descriptor: Int32 = STDERR_FILENO
    ) {
        let writeToStderr = event.terminalReason != nil || successTracingEnabled
        #if DEBUG
            guard writeToStderr || MCPResponseDeliveryCapturePublication.isCaptureActive else { return }
            guard let data = "[MCPResponseDelivery] \(event)\n".data(using: .utf8) else { return }
            if let captureHooks = MCPResponseDeliveryCapturePublication.currentHooks(),
               captureHooks.isActive()
            {
                if let emitted = captureHooks.tryWithBoundary({
                    emitUnderTracerLock(
                        event,
                        data: data,
                        descriptor: descriptor,
                        captureEvent: captureHooks.isActive(),
                        writeToStderr: writeToStderr,
                        captureHooks: captureHooks
                    )
                }) {
                    _ = emitted
                } else {
                    captureHooks.recordLoss(.coordinatorBoundaryContention)
                    _ = emitUnderTracerLock(
                        event,
                        data: data,
                        descriptor: descriptor,
                        captureEvent: false,
                        writeToStderr: writeToStderr,
                        captureHooks: captureHooks
                    )
                }
            } else {
                _ = emitUnderTracerLock(
                    event,
                    data: data,
                    descriptor: descriptor,
                    captureEvent: false,
                    writeToStderr: writeToStderr,
                    captureHooks: nil
                )
            }
        #else
            guard writeToStderr else { return }
            guard let data = "[MCPResponseDelivery] \(event)\n".data(using: .utf8) else { return }
            _ = emitUnderTracerLock(event, data: data, descriptor: descriptor, captureEvent: false)
        #endif
    }

    #if DEBUG
        private static func emitUnderTracerLock(
            _ event: MCPResponseDeliveryTraceEvent,
            data: Data,
            descriptor: Int32,
            captureEvent: Bool,
            writeToStderr: Bool,
            captureHooks: MCPResponseDeliveryCaptureHooks?
        ) -> Bool {
            // Terminal tracing must not wait behind another diagnostic emitter or
            // a full stderr pipe. Dropping a contended/unwritable trace is safer
            // than delaying the transport's required terminal exit.
            guard lock.try() else {
                if captureEvent || captureHooks?.isActive() == true {
                    captureHooks?.recordLoss(.tracerLockContention)
                }
                return false
            }
            defer { lock.unlock() }
            if captureEvent {
                if debugEvents.count < maximumDebugEvents {
                    debugEvents.append(event)
                } else {
                    captureHooks?.recordLoss(.historyCapacity)
                }
            }
            if writeToStderr {
                // Terminal events run during transport failure handling when stderr
                // may already be closed, so writing remains best effort and nonblocking.
                BestEffortStderrWriter.writeNonBlocking(data, to: descriptor)
            }
            return true
        }
    #else
        private static func emitUnderTracerLock(
            _: MCPResponseDeliveryTraceEvent,
            data: Data,
            descriptor: Int32,
            captureEvent _: Bool
        ) -> Bool {
            // Terminal tracing must not wait behind another diagnostic emitter or
            // a full stderr pipe. Dropping a contended/unwritable trace is safer
            // than delaying the transport's required terminal exit.
            guard lock.try() else { return false }
            defer { lock.unlock() }
            // Terminal events are emitted even with success tracing disabled, so
            // this path runs during transport failure handling when stderr may
            // already be closed. Best-effort raw write; never FileHandle.write,
            // whose ObjC exception on a broken pipe would abort the process.
            BestEffortStderrWriter.writeNonBlocking(data, to: descriptor)
            return true
        }
    #endif

    #if DEBUG
        public static func resetDebugEvents() {
            lock.lock()
            debugEvents.removeAll(keepingCapacity: true)
            lock.unlock()
        }

        public static func debugEventSnapshot() -> [MCPResponseDeliveryTraceEvent] {
            lock.lock()
            defer { lock.unlock() }
            return debugEvents
        }

        public static func withDebugTracerLockForTesting<T>(_ body: () throws -> T) rethrows -> T {
            lock.lock()
            defer { lock.unlock() }
            return try body()
        }

        public static func fillDebugEventHistoryToCapacityForTesting(with event: MCPResponseDeliveryTraceEvent) {
            lock.lock()
            debugEvents = Array(repeating: event, count: maximumDebugEvents)
            lock.unlock()
        }
    #endif

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func emitPreparedFrame(
        layer: String,
        phase: String,
        prepared: JSONRPCBridgePreparedFrame,
        terminalReason: String? = nil,
        publicationPending: Bool? = nil,
        terminalBarrier: Bool? = nil
    ) {
        #if DEBUG
            guard terminalReason != nil || successTracingEnabled || MCPResponseDeliveryCapturePublication.isCaptureActive else { return }
        #else
            guard terminalReason != nil || successTracingEnabled else { return }
        #endif
        let messages = prepared.messages.isEmpty ? [nil] : prepared.messages.map(Optional.some)
        for message in messages {
            emit(MCPResponseDeliveryTraceEvent(
                layer: layer,
                phase: phase,
                connectionID: prepared.connectionID,
                connectionGeneration: prepared.connectionGeneration,
                direction: prepared.direction,
                id: message?.id,
                method: message?.method,
                tool: message?.tool,
                lifecycleState: message?.kind.rawValue,
                requestOrdinal: message?.requestOrdinal,
                framedByteCount: prepared.deliveryFrame?.count ?? prepared.framedByteCount,
                framedSHA256: prepared.framedSHA256,
                terminalReason: terminalReason,
                publicationPending: publicationPending,
                terminalBarrier: terminalBarrier
            ))
        }
    }

    public static func emitFrame(
        layer: String,
        phase: String,
        frame: Data,
        direction: JSONRPCBridgeDirection,
        connectionID: String? = nil,
        connectionGeneration: UInt64? = nil,
        terminalReason: String? = nil
    ) {
        #if DEBUG
            guard terminalReason != nil || successTracingEnabled || MCPResponseDeliveryCapturePublication.isCaptureActive else { return }
        #else
            guard terminalReason != nil || successTracingEnabled else { return }
        #endif
        let summaries = JSONRPCBridgeFrameInspector.inspectPermissively(frame, direction: direction)
        let metadata = summaries.isEmpty ? [nil] : summaries.map(Optional.some)
        for summary in metadata {
            emit(MCPResponseDeliveryTraceEvent(
                layer: layer,
                phase: phase,
                connectionID: connectionID,
                connectionGeneration: connectionGeneration,
                direction: direction,
                id: summary?.id,
                method: summary?.method,
                tool: summary?.tool,
                requestOrdinal: summary?.requestOrdinal,
                framedByteCount: frame.count,
                framedSHA256: sha256Hex(frame),
                terminalReason: terminalReason
            ))
        }
    }
}

public struct JSONRPCBridgeFaultRule: Equatable, Sendable {
    public enum Action: String, Sendable {
        case failDestinationWrite = "fail_destination_write"
    }

    public let direction: JSONRPCBridgeDirection
    public let id: JSONRPCBridgeID?
    public let method: String?
    public let tool: String?
    public let requestOrdinal: UInt64?
    public let action: Action

    public init(
        direction: JSONRPCBridgeDirection,
        id: JSONRPCBridgeID? = nil,
        method: String? = nil,
        tool: String? = nil,
        requestOrdinal: UInt64? = nil,
        action: Action = .failDestinationWrite
    ) {
        self.direction = direction
        self.id = id
        self.method = method
        self.tool = tool
        self.requestOrdinal = requestOrdinal
        self.action = action
    }

    public func matches(_ prepared: JSONRPCBridgePreparedFrame) -> Bool {
        guard prepared.direction == direction else { return false }
        return prepared.messages.contains { message in
            if let id, message.id != id { return false }
            if let method, message.method != method { return false }
            if let tool, message.tool != tool { return false }
            if let requestOrdinal, message.requestOrdinal != requestOrdinal { return false }
            return id != nil || method != nil || tool != nil || requestOrdinal != nil
        }
    }
}

public enum JSONRPCBridgeDeliveryDisposition: Equatable, Sendable {
    case forward
    case forwardFilteredCancelledResponses
    case discardCancelledResponse
}

public struct JSONRPCBridgePreparedFrame: Equatable, Sendable {
    public let token: UUID
    public let direction: JSONRPCBridgeDirection
    public let connectionID: String?
    public let connectionGeneration: UInt64
    public let disposition: JSONRPCBridgeDeliveryDisposition
    public let messages: [JSONRPCBridgeMessageMetadata]
    public let deliveryFrame: Data?
    public let framedByteCount: Int
    public let framedSHA256: String

    public init(
        token: UUID,
        direction: JSONRPCBridgeDirection,
        connectionID: String?,
        connectionGeneration: UInt64,
        disposition: JSONRPCBridgeDeliveryDisposition,
        messages: [JSONRPCBridgeMessageMetadata],
        deliveryFrame: Data?,
        framedByteCount: Int,
        framedSHA256: String
    ) {
        self.token = token
        self.direction = direction
        self.connectionID = connectionID
        self.connectionGeneration = connectionGeneration
        self.disposition = disposition
        self.messages = messages
        self.deliveryFrame = deliveryFrame
        self.framedByteCount = framedByteCount
        self.framedSHA256 = framedSHA256
    }
}

public enum JSONRPCBridgeEOFDisposition: Equatable, Sendable {
    case clean
    case terminal(reason: String)
}

public struct JSONRPCBridgeLedgerSnapshot: Equatable, Sendable {
    public let connectionGeneration: UInt64
    public let activeRequestCount: Int
    public let responseInDeliveryCount: Int
    public let cancellationTombstoneCount: Int
    public let recentCompletionCount: Int
    public let pendingTransactionCount: Int
    public let replayableClientRequestCount: Int
    public let unreplayableActiveRequestCount: Int
    public let hasForwardedProtocolFrame: Bool
    public let terminalReason: String?

    public var canReconnect: Bool {
        unreplayableActiveRequestCount == 0
            && responseInDeliveryCount == 0
            && pendingTransactionCount == 0
            && terminalReason == nil
    }

    public func canFinishSocketDrain(partialByteCount: Int) -> Bool {
        terminalReason == nil
            && activeRequestCount == 0
            && pendingTransactionCount == 0
            && partialByteCount == 0
    }

    public func socketDrainBlockerDescription(partialByteCount: Int) -> String {
        [
            "active_requests=\(activeRequestCount)",
            "replayable_client_requests=\(replayableClientRequestCount)",
            "unreplayable_active_requests=\(unreplayableActiveRequestCount)",
            "pending_transactions=\(pendingTransactionCount)",
            "partial_bytes=\(max(0, partialByteCount))",
            "response_in_delivery=\(responseInDeliveryCount)",
            "terminal_reason=\(terminalReason ?? "none")"
        ].joined(separator: " ")
    }
}

public enum JSONRPCBridgeLedgerError: Swift.Error, Equatable, CustomStringConvertible {
    case terminal(String)
    case malformedBackendFrame
    case duplicateActiveID(JSONRPCBridgeDirection, JSONRPCBridgeID)
    case unknownResponse(JSONRPCBridgeDirection, JSONRPCBridgeID)
    case cancelledIDReuse(JSONRPCBridgeDirection, JSONRPCBridgeID)
    case activeCapacityExceeded(Int)
    case tombstoneCapacityExceeded(Int)
    case invalidTransaction
    case injectedFault(JSONRPCBridgeDirection, JSONRPCBridgeID?)

    public var description: String {
        switch self {
        case let .terminal(reason): "bridge session is terminal: \(reason)"
        case .malformedBackendFrame: "malformed backend JSON-RPC frame"
        #if DEBUG
            case let .duplicateActiveID(direction, id):
                "duplicate active JSON-RPC \(Self.diagnosticIDDescription(id)) in \(direction.rawValue)"
            case let .unknownResponse(direction, id):
                "unknown JSON-RPC response \(Self.diagnosticIDDescription(id)) in \(direction.rawValue)"
            case let .cancelledIDReuse(direction, id):
                "cancelled JSON-RPC \(Self.diagnosticIDDescription(id)) cannot be reused yet in \(direction.rawValue)"
        #else
            case let .duplicateActiveID(direction, id): "duplicate active JSON-RPC id \(id) in \(direction.rawValue)"
            case let .unknownResponse(direction, id): "unknown JSON-RPC response id \(id) in \(direction.rawValue)"
            case let .cancelledIDReuse(direction, id): "cancelled JSON-RPC id \(id) cannot be reused yet in \(direction.rawValue)"
        #endif
        case let .activeCapacityExceeded(limit): "active JSON-RPC request limit exceeded (\(limit))"
        case let .tombstoneCapacityExceeded(limit): "JSON-RPC cancellation tombstone limit exceeded (\(limit))"
        case .invalidTransaction: "invalid or completed JSON-RPC bridge transaction"
        #if DEBUG
            case let .injectedFault(direction, id):
                "injected JSON-RPC bridge write failure direction=\(direction.rawValue) \(Self.diagnosticIDDescription(id))"
        #else
            case let .injectedFault(direction, id):
                "injected JSON-RPC bridge write failure direction=\(direction.rawValue) id=\(id?.description ?? "none")"
        #endif
        }
    }

    #if DEBUG
        private static func diagnosticIDDescription(_ id: JSONRPCBridgeID?) -> String {
            guard let id else { return "id=none" }
            if let boundedID = id.boundedDiagnosticDescription {
                return "id=\(boundedID)"
            }
            return [
                "id=<omitted>",
                "id_omitted=\(id.diagnosticStringOmitted)",
                "id_truncated=\(id.diagnosticStringTruncated)",
                "id_utf8_byte_count=\(id.diagnosticStringUTF8ByteCount ?? 0)"
            ].joined(separator: " ")
        }
    #endif
}

public actor JSONRPCBridgeLedger {
    public static let postStdinHalfCloseDrainDeadlineExceededReason = "post_stdin_half_close_drain_deadline_exceeded"

    public struct Configuration: Equatable, Sendable {
        public var cancellationTombstoneTTL: TimeInterval
        public var maximumCancellationTombstones: Int
        public var maximumActiveRequests: Int
        public var maximumRecentCompletions: Int

        public init(
            cancellationTombstoneTTL: TimeInterval = 30,
            maximumCancellationTombstones: Int = 1024,
            maximumActiveRequests: Int = 4096,
            maximumRecentCompletions: Int = 256
        ) {
            self.cancellationTombstoneTTL = max(0.001, cancellationTombstoneTTL)
            self.maximumCancellationTombstones = max(1, maximumCancellationTombstones)
            self.maximumActiveRequests = max(1, maximumActiveRequests)
            self.maximumRecentCompletions = max(0, maximumRecentCompletions)
        }
    }

    public typealias TraceSink = @Sendable (MCPResponseDeliveryTraceEvent) -> Void

    private struct RequestKey: Hashable {
        let direction: JSONRPCBridgeDirection
        let id: JSONRPCBridgeID
    }

    private struct RequestMetadata: Equatable {
        let method: String?
        let tool: String?
        let ordinal: UInt64
        let isReplayable: Bool
    }

    private struct SuccessorRequest: Equatable {
        let metadata: RequestMetadata
        let transaction: UUID
        var isForwarded: Bool
    }

    private enum RequestState: Equatable {
        case reserved(RequestMetadata, transaction: UUID)
        case forwarded(RequestMetadata)
        case responseInDelivery(
            RequestMetadata,
            transaction: UUID,
            successor: SuccessorRequest?
        )

        var metadata: RequestMetadata {
            switch self {
            case let .reserved(metadata, _), let .forwarded(metadata): metadata
            case let .responseInDelivery(metadata, _, _): metadata
            }
        }

        var isResponseInDelivery: Bool {
            if case .responseInDelivery = self { return true }
            return false
        }

        var requestCount: Int {
            switch self {
            case .reserved, .forwarded: 1
            case let .responseInDelivery(_, _, successor): successor == nil ? 1 : 2
            }
        }
    }

    private struct Tombstone: Equatable {
        let expiresAt: TimeInterval
        let ordinal: UInt64
        let method: String?
        let tool: String?
    }

    private enum Operation: Equatable {
        case reserve(RequestKey)
        case response(RequestKey)
        case cancellation(RequestKey)
        case discardedTombstoneResponse(RequestKey)
    }

    private struct PendingTransaction: Equatable {
        let operations: [Operation]
        let prepared: JSONRPCBridgePreparedFrame
    }

    private struct ParsedMessage {
        enum Kind {
            case request(id: JSONRPCBridgeID, method: String?, tool: String?, toolArguments: [String: Any]?)
            case response(id: JSONRPCBridgeID)
            case notification(method: String?, cancellationID: JSONRPCBridgeID?)
            case invalidClientMessage(id: JSONRPCBridgeID?)
        }

        let kind: Kind
    }

    private let configuration: Configuration
    private let connectionID: String?
    private let traceSink: TraceSink?
    private var connectionGeneration: UInt64 = 0
    private var nextRequestOrdinal: UInt64 = 0
    private var active: [RequestKey: RequestState] = [:]
    private var tombstones: [RequestKey: Tombstone] = [:]
    private var pendingTransactions: [UUID: PendingTransaction] = [:]
    private var recentCompletions: [RequestKey] = []
    private var hasForwardedProtocolFrame = false
    private var terminalReason: String?

    public init(
        configuration: Configuration = .init(),
        connectionID: String? = nil,
        traceSink: TraceSink? = nil
    ) {
        self.configuration = configuration
        self.connectionID = connectionID
        self.traceSink = traceSink
    }

    @discardableResult
    public func beginConnection() throws -> UInt64 {
        guard terminalReason == nil else {
            throw JSONRPCBridgeLedgerError.terminal(terminalReason ?? "unknown")
        }
        guard pendingTransactions.isEmpty,
              Self.unreplayableActiveRequestCount(in: active) == 0
        else {
            throw failTerminal("reconnection_attempted_with_unreplayable_work")
        }
        connectionGeneration &+= 1
        emit(phase: "connection_started", direction: nil, messages: [], prepared: nil, terminalReason: nil)
        return connectionGeneration
    }

    public func prepare(
        frame: Data,
        direction: JSONRPCBridgeDirection,
        now: TimeInterval = Date().timeIntervalSinceReferenceDate
    ) throws -> JSONRPCBridgePreparedFrame {
        guard terminalReason == nil else {
            throw JSONRPCBridgeLedgerError.terminal(terminalReason ?? "unknown")
        }
        purgeExpiredTombstones(now: now)

        let parsed: [ParsedMessage]
        do {
            parsed = try Self.parse(frame: frame, direction: direction)
        } catch {
            if direction == .clientToServer {
                parsed = [ParsedMessage(kind: .invalidClientMessage(id: nil))]
            } else {
                throw failTerminal("malformed_backend_frame", preferredError: .malformedBackendFrame)
            }
        }

        let token = UUID()
        let frameIsBatch = Self.frameIsBatch(frame)
        var simulatedActive = active
        var simulatedNextOrdinal = nextRequestOrdinal
        var operations: [Operation] = []
        var messages: [JSONRPCBridgeMessageMetadata] = []
        var discardedMessageIndices: Set<Int> = []

        for (messageIndex, parsedMessage) in parsed.enumerated() {
            switch parsedMessage.kind {
            case let .request(id, method, tool, toolArguments):
                guard id != .null else {
                    messages.append(JSONRPCBridgeMessageMetadata(
                        kind: .invalidClientMessage,
                        id: id,
                        method: method,
                        tool: tool,
                        requestOrdinal: nil
                    ))
                    continue
                }
                let key = RequestKey(direction: direction, id: id)
                if tombstones[key] != nil {
                    throw failTerminal("cancelled_id_reuse", preferredError: .cancelledIDReuse(direction, id))
                }
                guard Self.activeRequestCount(in: simulatedActive) < configuration.maximumActiveRequests else {
                    throw failTerminal(
                        "active_request_capacity_exceeded",
                        preferredError: .activeCapacityExceeded(configuration.maximumActiveRequests)
                    )
                }
                simulatedNextOrdinal &+= 1
                let metadata = RequestMetadata(
                    method: method,
                    tool: tool,
                    ordinal: simulatedNextOrdinal,
                    isReplayable: direction == .clientToServer
                        && !frameIsBatch
                        && JSONRPCBridgeReplayPolicy.isReplayableClientRequest(
                            method: method,
                            tool: tool,
                            toolArguments: toolArguments
                        )
                )
                if let existingState = simulatedActive[key] {
                    guard case let .responseInDelivery(
                        responseMetadata,
                        responseTransaction,
                        successor: nil
                    ) = existingState
                    else {
                        throw failTerminal("duplicate_active_id", preferredError: .duplicateActiveID(direction, id))
                    }
                    simulatedActive[key] = .responseInDelivery(
                        responseMetadata,
                        transaction: responseTransaction,
                        successor: SuccessorRequest(
                            metadata: metadata,
                            transaction: token,
                            isForwarded: false
                        )
                    )
                } else {
                    simulatedActive[key] = .reserved(metadata, transaction: token)
                }
                operations.append(.reserve(key))
                messages.append(JSONRPCBridgeMessageMetadata(
                    kind: .request,
                    id: id,
                    method: method,
                    tool: tool,
                    requestOrdinal: metadata.ordinal
                ))

            case let .response(id):
                if id == .null {
                    messages.append(JSONRPCBridgeMessageMetadata(
                        kind: .response,
                        id: .null,
                        method: nil,
                        tool: nil,
                        requestOrdinal: nil
                    ))
                    continue
                }
                let key = RequestKey(direction: direction.opposite, id: id)
                if let state = simulatedActive[key] {
                    if state.isResponseInDelivery {
                        throw failTerminal("duplicate_response_in_delivery", preferredError: .unknownResponse(direction, id))
                    }
                    simulatedActive[key] = .responseInDelivery(
                        state.metadata,
                        transaction: token,
                        successor: nil
                    )
                    operations.append(.response(key))
                    messages.append(JSONRPCBridgeMessageMetadata(
                        kind: .response,
                        id: id,
                        method: state.metadata.method,
                        tool: state.metadata.tool,
                        requestOrdinal: state.metadata.ordinal
                    ))
                } else if let tombstone = tombstones[key] {
                    discardedMessageIndices.insert(messageIndex)
                    operations.append(.discardedTombstoneResponse(key))
                    messages.append(JSONRPCBridgeMessageMetadata(
                        kind: .response,
                        id: id,
                        method: tombstone.method,
                        tool: tombstone.tool,
                        requestOrdinal: tombstone.ordinal
                    ))
                } else {
                    throw failTerminal("unknown_response_id", preferredError: .unknownResponse(direction, id))
                }

            case let .notification(method, cancellationID):
                if let cancellationID, cancellationID != .null {
                    operations.append(.cancellation(RequestKey(direction: direction, id: cancellationID)))
                }
                messages.append(JSONRPCBridgeMessageMetadata(
                    kind: .notification,
                    id: cancellationID,
                    method: method,
                    tool: nil,
                    requestOrdinal: nil
                ))

            case let .invalidClientMessage(id):
                if let id, id != .null {
                    let key = RequestKey(direction: direction, id: id)
                    if tombstones[key] != nil {
                        throw failTerminal("cancelled_id_reuse", preferredError: .cancelledIDReuse(direction, id))
                    }
                    guard Self.activeRequestCount(in: simulatedActive) < configuration.maximumActiveRequests else {
                        throw failTerminal(
                            "active_request_capacity_exceeded",
                            preferredError: .activeCapacityExceeded(configuration.maximumActiveRequests)
                        )
                    }
                    simulatedNextOrdinal &+= 1
                    let metadata = RequestMetadata(
                        method: nil,
                        tool: nil,
                        ordinal: simulatedNextOrdinal,
                        isReplayable: false
                    )
                    if let existingState = simulatedActive[key] {
                        guard case let .responseInDelivery(
                            responseMetadata,
                            responseTransaction,
                            successor: nil
                        ) = existingState
                        else {
                            throw failTerminal("duplicate_active_id", preferredError: .duplicateActiveID(direction, id))
                        }
                        simulatedActive[key] = .responseInDelivery(
                            responseMetadata,
                            transaction: responseTransaction,
                            successor: SuccessorRequest(
                                metadata: metadata,
                                transaction: token,
                                isForwarded: false
                            )
                        )
                    } else {
                        simulatedActive[key] = .reserved(metadata, transaction: token)
                    }
                    operations.append(.reserve(key))
                    messages.append(JSONRPCBridgeMessageMetadata(
                        kind: .invalidClientMessage,
                        id: id,
                        method: nil,
                        tool: nil,
                        requestOrdinal: metadata.ordinal
                    ))
                } else {
                    messages.append(JSONRPCBridgeMessageMetadata(
                        kind: .invalidClientMessage,
                        id: id,
                        method: nil,
                        tool: nil,
                        requestOrdinal: nil
                    ))
                }
            }
        }

        active = simulatedActive
        nextRequestOrdinal = simulatedNextOrdinal
        let deliveryFrame: Data?
        let disposition: JSONRPCBridgeDeliveryDisposition
        if discardedMessageIndices.isEmpty {
            deliveryFrame = frame
            disposition = .forward
        } else if discardedMessageIndices.count == parsed.count {
            deliveryFrame = nil
            disposition = .discardCancelledResponse
        } else {
            deliveryFrame = try Self.filterBatchFrame(
                frame,
                removingMessageIndices: discardedMessageIndices
            )
            disposition = .forwardFilteredCancelledResponses
        }
        let prepared = JSONRPCBridgePreparedFrame(
            token: token,
            direction: direction,
            connectionID: connectionID,
            connectionGeneration: connectionGeneration,
            disposition: disposition,
            messages: messages,
            deliveryFrame: deliveryFrame,
            framedByteCount: frame.count,
            framedSHA256: MCPResponseDeliveryTracer.sha256Hex(frame)
        )
        pendingTransactions[token] = PendingTransaction(operations: operations, prepared: prepared)
        emit(phase: "frame_prepared", direction: direction, messages: messages, prepared: prepared, terminalReason: nil)
        return prepared
    }

    public func commit(
        _ prepared: JSONRPCBridgePreparedFrame,
        now: TimeInterval = Date().timeIntervalSinceReferenceDate
    ) throws {
        guard terminalReason == nil else {
            throw JSONRPCBridgeLedgerError.terminal(terminalReason ?? "unknown")
        }
        guard let transaction = pendingTransactions.removeValue(forKey: prepared.token),
              transaction.prepared == prepared
        else {
            throw failTerminal("invalid_commit_token", preferredError: .invalidTransaction)
        }

        var committedActive = active
        var committedTombstones = tombstones
        var committedCompletions = recentCompletions

        for operation in transaction.operations {
            switch operation {
            case let .reserve(key):
                switch committedActive[key] {
                case let .reserved(metadata, transactionID) where transactionID == prepared.token:
                    committedActive[key] = .forwarded(metadata)
                case let .responseInDelivery(metadata, responseTransaction, successor?):
                    guard successor.transaction == prepared.token else { break }
                    committedActive[key] = .responseInDelivery(
                        metadata,
                        transaction: responseTransaction,
                        successor: SuccessorRequest(
                            metadata: successor.metadata,
                            transaction: successor.transaction,
                            isForwarded: true
                        )
                    )
                default:
                    break
                }

            case let .response(key):
                guard case let .responseInDelivery(_, transactionID, successor) = committedActive[key],
                      transactionID == prepared.token
                else {
                    throw failTerminal("response_commit_state_mismatch", preferredError: .invalidTransaction)
                }
                if let successor, committedTombstones[key] == nil {
                    committedActive[key] = successor.isForwarded
                        ? .forwarded(successor.metadata)
                        : .reserved(successor.metadata, transaction: successor.transaction)
                } else {
                    committedActive.removeValue(forKey: key)
                }
                Self.appendCompletion(
                    key,
                    to: &committedCompletions,
                    maximumCount: configuration.maximumRecentCompletions
                )

            case let .cancellation(key):
                guard let state = committedActive[key] else { continue }
                let cancellationMetadata: RequestMetadata
                if case let .responseInDelivery(metadata, transaction, successor?) = state {
                    cancellationMetadata = successor.metadata
                    committedActive[key] = .responseInDelivery(
                        metadata,
                        transaction: transaction,
                        successor: nil
                    )
                } else if state.isResponseInDelivery {
                    continue
                } else {
                    cancellationMetadata = state.metadata
                    committedActive.removeValue(forKey: key)
                }
                guard committedTombstones.count < configuration.maximumCancellationTombstones else {
                    throw failTerminal(
                        "cancellation_tombstone_capacity_exceeded",
                        preferredError: .tombstoneCapacityExceeded(configuration.maximumCancellationTombstones)
                    )
                }
                committedTombstones[key] = Tombstone(
                    expiresAt: now + configuration.cancellationTombstoneTTL,
                    ordinal: cancellationMetadata.ordinal,
                    method: cancellationMetadata.method,
                    tool: cancellationMetadata.tool
                )

            case .discardedTombstoneResponse:
                break
            }
        }

        active = committedActive
        tombstones = committedTombstones
        recentCompletions = committedCompletions
        hasForwardedProtocolFrame = true
        purgeExpiredTombstones(now: now)
        let commitPhase = switch prepared.disposition {
        case .forward: "frame_committed"
        case .forwardFilteredCancelledResponses: "filtered_batch_committed"
        case .discardCancelledResponse: "cancelled_response_discarded"
        }
        emit(
            phase: commitPhase,
            direction: prepared.direction,
            messages: prepared.messages,
            prepared: prepared,
            terminalReason: nil
        )
    }

    public func abort(_ prepared: JSONRPCBridgePreparedFrame, reason: String) {
        pendingTransactions.removeValue(forKey: prepared.token)
        _ = failTerminal(reason)
        emit(
            phase: "frame_delivery_uncertain",
            direction: prepared.direction,
            messages: prepared.messages,
            prepared: prepared,
            terminalReason: reason
        )
    }

    public func noteEOF(
        direction: JSONRPCBridgeDirection,
        pendingByteCount: Int = 0,
        reason: String = "eof"
    ) -> JSONRPCBridgeEOFDisposition {
        if pendingByteCount > 0 {
            let terminal = "\(reason)_with_incomplete_frame"
            _ = failTerminal(terminal)
            emit(phase: "terminal_eof", direction: direction, messages: [], prepared: nil, terminalReason: terminal)
            return .terminal(reason: terminal)
        }

        if direction == .clientToServer {
            let hasRequestAwaitingClosedInput = active.keys.contains { $0.direction == .serverToClient }
            let hasClosedDirectionWriteInFlight = pendingTransactions.values.contains {
                $0.prepared.direction == .clientToServer
            }
            if hasRequestAwaitingClosedInput || hasClosedDirectionWriteInFlight {
                let terminal = "\(reason)_with_outstanding_work"
                _ = failTerminal(terminal)
                emit(phase: "terminal_eof", direction: direction, messages: [], prepared: nil, terminalReason: terminal)
                return .terminal(reason: terminal)
            }

            // stdin is a half-close: requests already forwarded to the server may
            // still produce responses that must drain through stdout.
            emit(phase: "input_half_closed", direction: direction, messages: [], prepared: nil, terminalReason: nil)
            return .clean
        }

        if !active.isEmpty || !pendingTransactions.isEmpty {
            let terminal = "\(reason)_with_outstanding_work"
            _ = failTerminal(terminal)
            emit(phase: "terminal_eof", direction: direction, messages: [], prepared: nil, terminalReason: terminal)
            return .terminal(reason: terminal)
        }
        emit(phase: "clean_eof", direction: direction, messages: [], prepared: nil, terminalReason: nil)
        return .clean
    }

    @discardableResult
    public func terminalizePostStdinHalfCloseDrainDeadline() -> String {
        if let terminalReason {
            return terminalReason
        }

        let reason = Self.postStdinHalfCloseDrainDeadlineExceededReason
        _ = failTerminal(reason)
        emit(
            phase: "post_stdin_half_close_drain_deadline_exceeded",
            direction: .serverToClient,
            messages: [],
            prepared: nil,
            terminalReason: reason
        )
        return reason
    }

    public func recordConnectionFailure(
        _ reason: String,
        now: TimeInterval = Date().timeIntervalSinceReferenceDate
    ) -> Bool {
        if terminalReason != nil {
            emit(phase: "connection_terminal", direction: nil, messages: [], prepared: nil, terminalReason: terminalReason)
            return true
        }
        if !pendingTransactions.isEmpty {
            _ = failTerminal(reason)
            emit(phase: "connection_terminal", direction: nil, messages: [], prepared: nil, terminalReason: reason)
            return true
        }

        abandonServerOriginatedRequests(now: now)
        if terminalReason != nil {
            emit(phase: "connection_terminal", direction: nil, messages: [], prepared: nil, terminalReason: terminalReason)
            return true
        }

        guard Self.unreplayableActiveRequestCount(in: active) == 0 else {
            _ = failTerminal(reason)
            emit(phase: "connection_terminal", direction: nil, messages: [], prepared: nil, terminalReason: reason)
            return true
        }

        let phase: String = if !active.isEmpty {
            "active_connection_failure"
        } else {
            hasForwardedProtocolFrame ? "idle_connection_failure" : "startup_connection_failure"
        }
        emit(phase: phase, direction: nil, messages: [], prepared: nil, terminalReason: nil)
        return false
    }

    @discardableResult
    public func terminalizeConnection(reason: String) -> String {
        if let terminalReason {
            return terminalReason
        }
        _ = failTerminal(reason)
        emit(phase: "connection_terminal", direction: nil, messages: [], prepared: nil, terminalReason: reason)
        return reason
    }

    public func snapshot(now: TimeInterval = Date().timeIntervalSinceReferenceDate) -> JSONRPCBridgeLedgerSnapshot {
        purgeExpiredTombstones(now: now)
        return JSONRPCBridgeLedgerSnapshot(
            connectionGeneration: connectionGeneration,
            activeRequestCount: Self.activeRequestCount(in: active),
            responseInDeliveryCount: active.values.filter(\.isResponseInDelivery).count,
            cancellationTombstoneCount: tombstones.count,
            recentCompletionCount: recentCompletions.count,
            pendingTransactionCount: pendingTransactions.count,
            replayableClientRequestCount: Self.replayableClientRequestCount(in: active),
            unreplayableActiveRequestCount: Self.unreplayableActiveRequestCount(in: active),
            hasForwardedProtocolFrame: hasForwardedProtocolFrame,
            terminalReason: terminalReason
        )
    }

    private func abandonServerOriginatedRequests(now: TimeInterval) {
        guard !active.isEmpty else { return }
        let abandoned = active.filter { key, _ in key.direction == .serverToClient }
        for (key, state) in abandoned {
            let metadata = state.metadata
            guard tombstones.count < configuration.maximumCancellationTombstones else {
                _ = failTerminal("cancellation_tombstone_capacity_exceeded")
                return
            }
            tombstones[key] = Tombstone(
                expiresAt: now + configuration.cancellationTombstoneTTL,
                ordinal: metadata.ordinal,
                method: metadata.method,
                tool: metadata.tool
            )
            active.removeValue(forKey: key)
        }
    }

    private func purgeExpiredTombstones(now: TimeInterval) {
        tombstones = tombstones.filter { $0.value.expiresAt > now }
    }

    private static func activeRequestCount(in states: [RequestKey: RequestState]) -> Int {
        states.values.reduce(0) { $0 + $1.requestCount }
    }

    private static func replayableClientRequestCount(in states: [RequestKey: RequestState]) -> Int {
        states.reduce(0) { partial, element in
            guard element.key.direction == .clientToServer,
                  case let .forwarded(metadata) = element.value,
                  metadata.isReplayable
            else {
                return partial
            }
            return partial + 1
        }
    }

    private static func unreplayableActiveRequestCount(in states: [RequestKey: RequestState]) -> Int {
        activeRequestCount(in: states) - replayableClientRequestCount(in: states)
    }

    private static func appendCompletion(
        _ key: RequestKey,
        to completions: inout [RequestKey],
        maximumCount: Int
    ) {
        guard maximumCount > 0 else { return }
        completions.append(key)
        if completions.count > maximumCount {
            completions.removeFirst(completions.count - maximumCount)
        }
    }

    @discardableResult
    private func failTerminal(
        _ reason: String,
        preferredError: JSONRPCBridgeLedgerError? = nil
    ) -> JSONRPCBridgeLedgerError {
        if terminalReason == nil {
            terminalReason = reason
        }
        return preferredError ?? .terminal(reason)
    }

    private func emit(
        phase: String,
        direction: JSONRPCBridgeDirection?,
        messages: [JSONRPCBridgeMessageMetadata],
        prepared: JSONRPCBridgePreparedFrame?,
        terminalReason: String?
    ) {
        guard let traceSink else { return }
        let inDelivery = active.values.filter(\.isResponseInDelivery).count
        let summaries = messages.isEmpty ? [nil] : messages.map(Optional.some)
        for message in summaries {
            traceSink(MCPResponseDeliveryTraceEvent(
                layer: "proxy_ledger",
                phase: phase,
                connectionID: connectionID,
                connectionGeneration: connectionGeneration,
                direction: direction,
                id: message?.id,
                method: message?.method,
                tool: message?.tool,
                lifecycleState: message?.kind.rawValue,
                requestOrdinal: message?.requestOrdinal,
                framedByteCount: prepared?.framedByteCount,
                framedSHA256: prepared?.framedSHA256,
                activeRequestCount: Self.activeRequestCount(in: active),
                responseInDeliveryCount: inDelivery,
                terminalReason: terminalReason
            ))
        }
    }

    private static func parse(
        frame: Data,
        direction: JSONRPCBridgeDirection
    ) throws -> [ParsedMessage] {
        let unframed: Data = if frame.last == UInt8(ascii: "\n") {
            frame.dropLast()
        } else {
            frame
        }
        let root = try JSONSerialization.jsonObject(with: unframed, options: [.fragmentsAllowed])
        let objects: [Any]
        if let batch = root as? [Any] {
            guard !batch.isEmpty else { throw JSONRPCBridgeLedgerError.malformedBackendFrame }
            objects = batch
        } else {
            objects = [root]
        }

        var messages: [ParsedMessage] = []
        for object in objects {
            guard let dictionary = object as? [String: Any] else {
                if direction == .clientToServer {
                    messages.append(ParsedMessage(kind: .invalidClientMessage(id: nil)))
                    continue
                }
                throw JSONRPCBridgeLedgerError.malformedBackendFrame
            }

            let hasID = dictionary.keys.contains("id")
            let id = hasID ? parseID(dictionary["id"]) : nil
            let hasMethod = dictionary.keys.contains("method")
            let method = dictionary["method"] as? String
            let hasResult = dictionary.keys.contains("result")
            let hasError = dictionary.keys.contains("error")

            if direction == .serverToClient {
                try validateBackendEnvelope(
                    dictionary,
                    hasID: hasID,
                    id: id,
                    hasMethod: hasMethod,
                    method: method,
                    hasResult: hasResult,
                    hasError: hasError
                )
            }

            if hasResult || hasError {
                guard hasID, let id else {
                    if direction == .clientToServer {
                        messages.append(ParsedMessage(kind: .invalidClientMessage(id: nil)))
                        continue
                    }
                    throw JSONRPCBridgeLedgerError.malformedBackendFrame
                }
                messages.append(ParsedMessage(kind: .response(id: id)))
                continue
            }

            if let method {
                let tool = extractTool(from: dictionary, method: method)
                let toolArguments = extractToolArguments(from: dictionary, method: method)
                if let id, id != .null {
                    messages.append(ParsedMessage(kind: .request(
                        id: id,
                        method: method,
                        tool: tool,
                        toolArguments: toolArguments
                    )))
                } else if hasID {
                    if direction == .clientToServer {
                        messages.append(ParsedMessage(kind: .invalidClientMessage(id: id)))
                    } else {
                        throw JSONRPCBridgeLedgerError.malformedBackendFrame
                    }
                } else {
                    let cancellationID = method == "notifications/cancelled"
                        ? cancellationID(from: dictionary)
                        : nil
                    messages.append(ParsedMessage(kind: .notification(
                        method: method,
                        cancellationID: cancellationID
                    )))
                }
                continue
            }

            if direction == .clientToServer {
                messages.append(ParsedMessage(kind: .invalidClientMessage(id: id)))
            } else {
                throw JSONRPCBridgeLedgerError.malformedBackendFrame
            }
        }
        return messages
    }

    private static func frameIsBatch(_ frame: Data) -> Bool {
        for byte in frame {
            switch byte {
            case UInt8(ascii: " "), UInt8(ascii: "\n"), UInt8(ascii: "\r"), UInt8(ascii: "\t"):
                continue
            default:
                return byte == UInt8(ascii: "[")
            }
        }
        return false
    }

    private static func parseID(_ value: Any?) -> JSONRPCBridgeID? {
        JSONRPCBridgeID.parseJSONValue(value)
    }

    private static func validateBackendEnvelope(
        _ dictionary: [String: Any],
        hasID: Bool,
        id: JSONRPCBridgeID?,
        hasMethod: Bool,
        method: String?,
        hasResult: Bool,
        hasError: Bool
    ) throws {
        guard dictionary["jsonrpc"] as? String == "2.0" else {
            throw JSONRPCBridgeLedgerError.malformedBackendFrame
        }
        if let params = dictionary["params"],
           !(params is [String: Any]),
           !(params is [Any])
        {
            throw JSONRPCBridgeLedgerError.malformedBackendFrame
        }
        if hasResult || hasError {
            guard !hasMethod,
                  hasID,
                  id != nil,
                  hasResult != hasError
            else {
                throw JSONRPCBridgeLedgerError.malformedBackendFrame
            }
            if hasError {
                guard let error = dictionary["error"] as? [String: Any],
                      let code = error["code"] as? NSNumber,
                      CFGetTypeID(code) != CFBooleanGetTypeID(),
                      code.doubleValue == Double(code.int64Value),
                      error["message"] is String
                else {
                    throw JSONRPCBridgeLedgerError.malformedBackendFrame
                }
            }
            return
        }
        guard method != nil else {
            throw JSONRPCBridgeLedgerError.malformedBackendFrame
        }
        if hasID {
            guard let id, id != .null else {
                throw JSONRPCBridgeLedgerError.malformedBackendFrame
            }
        }
    }

    private static func filterBatchFrame(
        _ frame: Data,
        removingMessageIndices indices: Set<Int>
    ) throws -> Data {
        let hadNewline = frame.last == UInt8(ascii: "\n")
        let unframed = hadNewline ? Data(frame.dropLast()) : frame
        guard let batch = try JSONSerialization.jsonObject(with: unframed) as? [Any] else {
            throw JSONRPCBridgeLedgerError.malformedBackendFrame
        }
        let filtered = batch.enumerated().compactMap { index, element in
            indices.contains(index) ? nil : element
        }
        guard !filtered.isEmpty else { return Data() }
        var data = try JSONSerialization.data(
            withJSONObject: filtered,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        if hadNewline {
            data.append(UInt8(ascii: "\n"))
        }
        return data
    }

    private static func extractTool(from dictionary: [String: Any], method: String) -> String? {
        guard method == "tools/call",
              let params = dictionary["params"] as? [String: Any]
        else {
            return nil
        }
        return params["name"] as? String
    }

    private static func extractToolArguments(from dictionary: [String: Any], method: String) -> [String: Any]? {
        guard method == "tools/call",
              let params = dictionary["params"] as? [String: Any]
        else {
            return nil
        }
        return params["arguments"] as? [String: Any]
    }

    private static func cancellationID(from dictionary: [String: Any]) -> JSONRPCBridgeID? {
        guard let params = dictionary["params"] as? [String: Any] else { return nil }
        return parseID(params["requestId"] ?? params["id"])
    }
}

public enum JSONRPCBridgeFrameInspector {
    public static func inspectPermissively(
        _ frame: Data,
        direction _: JSONRPCBridgeDirection
    ) -> [JSONRPCBridgeMessageMetadata] {
        let unframed = frame.last == UInt8(ascii: "\n") ? Data(frame.dropLast()) : frame
        guard let root = try? JSONSerialization.jsonObject(with: unframed, options: [.fragmentsAllowed]) else {
            return []
        }
        let objects = (root as? [Any]) ?? [root]
        return objects.compactMap { object in
            guard let dictionary = object as? [String: Any] else { return nil }
            let hasID = dictionary.keys.contains("id")
            let id = hasID ? parseID(dictionary["id"]) : nil
            let method = dictionary["method"] as? String
            let tool: String? = if method == "tools/call",
                                   let params = dictionary["params"] as? [String: Any]
            {
                params["name"] as? String
            } else {
                nil
            }
            let kind: JSONRPCBridgeMessageMetadata.Kind = if dictionary.keys.contains("result") || dictionary.keys.contains("error") {
                .response
            } else if method != nil, hasID {
                .request
            } else if method != nil {
                .notification
            } else {
                .invalidClientMessage
            }
            return JSONRPCBridgeMessageMetadata(
                kind: kind,
                id: id,
                method: method,
                tool: tool,
                requestOrdinal: nil
            )
        }
    }

    private static func parseID(_ value: Any?) -> JSONRPCBridgeID? {
        JSONRPCBridgeID.parseJSONValue(value)
    }
}

public enum JSONRPCBridgeDelivery {
    public static func forward(
        frame: Data,
        direction: JSONRPCBridgeDirection,
        ledger: JSONRPCBridgeLedger,
        faultRule: JSONRPCBridgeFaultRule? = nil,
        now: TimeInterval = Date().timeIntervalSinceReferenceDate,
        writer: @escaping @Sendable (Data) async throws -> Void
    ) async throws -> JSONRPCBridgePreparedFrame {
        let prepared = try await ledger.prepare(frame: frame, direction: direction, now: now)
        guard let deliveryFrame = prepared.deliveryFrame else {
            try await ledger.commit(prepared, now: now)
            return prepared
        }
        if let faultRule, faultRule.matches(prepared) {
            let selectedID = prepared.messages.first(where: { message in
                faultRule.id == nil || message.id == faultRule.id
            })?.id
            let error = JSONRPCBridgeLedgerError.injectedFault(direction, selectedID)
            await ledger.abort(prepared, reason: "fault_injected_\(faultRule.action.rawValue)")
            throw error
        }
        do {
            try await writer(deliveryFrame)
        } catch {
            await ledger.abort(prepared, reason: "destination_write_uncertain")
            throw error
        }
        try await ledger.commit(prepared, now: now)
        return prepared
    }
}
