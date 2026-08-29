#if DEBUG
    import CryptoKit
    import Foundation
    import MachO

    struct MCPReadFileDiagnosticRuntimeIdentity: Equatable {
        let bundleIdentifier: String?
        let marketingVersion: String?
        let buildNumber: String?
        let machOUUID: UUID?
        let executableSHA256: String?
        let sourceBaseCommit: String?
        let sourceTreeDirty: Bool?
        let diagnosticPatchPresent: Bool?
        let diagnosticPatchDigest: String?
        let processStartID: UUID
    }

    struct MCPReadFileDebugProvenance: Equatable {
        let sourceBaseCommit: String?
        let sourceTreeDirty: Bool?
        let diagnosticPatchPresent: Bool?
        let diagnosticPatchDigest: String?
    }

    enum MCPReadFileDiagnosticRuntimeIdentityReader {
        private struct ProvenanceDocument: Decodable {
            let commit: String?
            let dirty: Bool?
            let diagnosticPatchPresent: Bool?
            let diagnosticPatchDigest: String?
        }

        static func readCurrentProcess(processStartID: UUID) -> MCPReadFileDiagnosticRuntimeIdentity {
            let bundle = Bundle.main
            let provenanceData = bundle.url(
                forResource: "RepoPromptDebugProvenance",
                withExtension: "json"
            ).flatMap { try? Data(contentsOf: $0) }
            return makeIdentityFromHash(
                bundleIdentifier: bundle.bundleIdentifier,
                marketingVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                buildNumber: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                provenanceData: provenanceData,
                executableSHA256: bundle.executableURL.flatMap(sha256OfFile),
                machOUUID: currentMachOUUID(),
                processStartID: processStartID
            )
        }

        static func makeIdentity(
            bundleIdentifier: String?,
            marketingVersion: String?,
            buildNumber: String?,
            provenanceData: Data?,
            executableData: Data?,
            machOUUID: UUID?,
            processStartID: UUID
        ) -> MCPReadFileDiagnosticRuntimeIdentity {
            makeIdentityFromHash(
                bundleIdentifier: bundleIdentifier,
                marketingVersion: marketingVersion,
                buildNumber: buildNumber,
                provenanceData: provenanceData,
                executableSHA256: executableData.map(sha256),
                machOUUID: machOUUID,
                processStartID: processStartID
            )
        }

        static func sha256OfFile(_ url: URL) -> String? {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            var hasher = SHA256()
            do {
                while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    hasher.update(data: chunk)
                }
                return hasher.finalize().map { String(format: "%02x", $0) }.joined()
            } catch {
                return nil
            }
        }

        private static func makeIdentityFromHash(
            bundleIdentifier: String?,
            marketingVersion: String?,
            buildNumber: String?,
            provenanceData: Data?,
            executableSHA256: String?,
            machOUUID: UUID?,
            processStartID: UUID
        ) -> MCPReadFileDiagnosticRuntimeIdentity {
            let provenance = provenanceData.flatMap(decodeProvenance)
            return MCPReadFileDiagnosticRuntimeIdentity(
                bundleIdentifier: safeMetadata(bundleIdentifier, maximumLength: 255),
                marketingVersion: safeMetadata(marketingVersion, maximumLength: 64),
                buildNumber: safeMetadata(buildNumber, maximumLength: 64),
                machOUUID: machOUUID,
                executableSHA256: executableSHA256,
                sourceBaseCommit: provenance?.sourceBaseCommit,
                sourceTreeDirty: provenance?.sourceTreeDirty,
                diagnosticPatchPresent: provenance?.diagnosticPatchPresent,
                diagnosticPatchDigest: provenance?.diagnosticPatchDigest,
                processStartID: processStartID
            )
        }

        static func decodeProvenance(_ data: Data) -> MCPReadFileDebugProvenance? {
            guard let document = try? JSONDecoder().decode(ProvenanceDocument.self, from: data) else {
                return nil
            }
            return MCPReadFileDebugProvenance(
                sourceBaseCommit: normalizedHex(document.commit, length: 40),
                sourceTreeDirty: document.dirty,
                diagnosticPatchPresent: document.diagnosticPatchPresent,
                diagnosticPatchDigest: normalizedHex(document.diagnosticPatchDigest, length: 64)
            )
        }

        private static func safeMetadata(_ value: String?, maximumLength: Int) -> String? {
            guard let value,
                  !value.isEmpty,
                  value.utf8.count <= maximumLength,
                  value.unicodeScalars.allSatisfy({ safeMetadataCharacterSet.contains($0) })
            else { return nil }
            return value
        }

        private static let safeMetadataCharacterSet = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: ".+-_"))

        private static func normalizedHex(_ value: String?, length: Int) -> String? {
            guard let value else { return nil }
            let normalized = value.lowercased()
            guard normalized.utf8.count == length,
                  normalized.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) })
            else { return nil }
            return normalized
        }

        private static func sha256(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        private static func currentMachOUUID() -> UUID? {
            guard let header = _dyld_get_image_header(0) else { return nil }
            let headerSize: Int = switch header.pointee.magic {
            case MH_MAGIC_64, MH_CIGAM_64:
                MemoryLayout<mach_header_64>.size
            default:
                MemoryLayout<mach_header>.size
            }

            var cursor = UnsafeRawPointer(header).advanced(by: headerSize)
            for _ in 0 ..< header.pointee.ncmds {
                let command = cursor.load(as: load_command.self)
                guard Int(command.cmdsize) >= MemoryLayout<load_command>.size else { return nil }
                if command.cmd == LC_UUID {
                    let uuidCommand = cursor.load(as: uuid_command.self)
                    return withUnsafeBytes(of: uuidCommand.uuid) { rawBytes in
                        guard let bytes = rawBytes.bindMemory(to: UInt8.self).baseAddress else { return nil }
                        return NSUUID(uuidBytes: bytes) as UUID
                    }
                }
                cursor = cursor.advanced(by: Int(command.cmdsize))
            }
            return nil
        }
    }

    enum MCPReadFileDiagnosticRuntimeIdentityProvider {
        private final class Cache: @unchecked Sendable {
            private let lock = NSLock()
            private var task: Task<MCPReadFileDiagnosticRuntimeIdentity, Never>?

            func snapshot(processStartID: UUID) async -> MCPReadFileDiagnosticRuntimeIdentity {
                let task = lock.withLock {
                    if let existingTask = self.task {
                        return existingTask
                    }
                    let task = Task.detached(priority: .utility) {
                        MCPReadFileDiagnosticRuntimeIdentityReader.readCurrentProcess(
                            processStartID: processStartID
                        )
                    }
                    self.task = task
                    return task
                }
                return await task.value
            }
        }

        private static let cache = Cache()
        static let processStartID = UUID()

        static func snapshot() async -> MCPReadFileDiagnosticRuntimeIdentity {
            await cache.snapshot(processStartID: processStartID)
        }
    }
#endif
