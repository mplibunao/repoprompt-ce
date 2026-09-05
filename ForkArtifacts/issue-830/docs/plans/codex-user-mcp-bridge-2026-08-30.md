# 1. Summary

Issue #830 should add a narrowly scoped, in-memory bridge from the user’s ordinary, read-only `~/.codex/config.toml` into native Codex Agent Mode. RepoPrompt will discover and safely parse only the `mcp_servers` subtree, show every detected server in the Codex card under CLI Providers, require an explicit saved authorization decision before any definition leaves that file, and inject only authorized and runtime-enabled complete definitions into nested `config["mcp_servers"]` on `thread/start` and every fresh-controller `thread/resume`. The CE-managed private Codex config remains byte-identical and continues to supply `RepoPromptCE`; exec, Chat, Toolkit, global instructions, and unrelated Codex configuration remain unchanged. The implementation should be a targeted bridge with shared typed models, secure permission persistence, native controller lifecycle integration, structural diagnostic redaction, and generation-aware UI—not a general Codex configuration importer.

---

# 2. Current-state analysis

## 2.1 Ownership and responsibilities today

| Area | Current owner | Relevant behavior |
|---|---|---|
| Managed Codex executable and isolated state | `CodexRuntimeAuthority` | Resolves bundled or explicit external Codex, enforces version `>= 0.149.0`, and supplies Debug/Release `CODEX_HOME` and `CODEX_SQLITE_HOME`. It intentionally does not represent the ordinary `~/.codex` home. |
| CE private `config.toml` | `CodexIntegrationConfiguration` | Parses and mutates RepoPrompt’s isolated config, owns the `RepoPromptCE` block, locks in-process writes, repairs policy, and writes atomically. Its `ServerEntry` is identity-only; it is not a complete MCP definition. |
| Codex integration façade | `MCPIntegrationHelper` | Exposes managed entries, installation, discovery provisioning, and RepoPrompt server constants to UI and Agent Mode. |
| Native app-server transport | `CodexAppServerClient` actor | Resolves/captures a launch runtime and environment, starts one app-server transport generation, serializes arbitrary JSON-RPC request parameters, and currently logs exact outbound JSON in debug mode. |
| Native session/thread binding | `CodexNativeSessionController` | Resolves one runtime, fail-closes CE MCP provisioning before launch, starts app-server, then sends `thread/start` or `thread/resume`. Its `Options.configOverridesProvider` supplies thread-level feature and flattened MCP enablement overrides. |
| Native runtime lifecycle | `CodexAgentModeCoordinator` | Owns controller replacement, reconnect flags, active-turn semantics, fallback queues, pending interactions, and generation/run lineage. |
| Session lineage | `AgentTabSession` | Pins fallback input to controller instance, controller generation, thread, run, and attempt. Replacing a controller abandons/restores its queued entries. |
| Runtime MCP toggles | `CodexAgentToolPreferences` and `SecureCodexPermissionDocument` | Store normalized private-config server enablement. `RepoPromptCE` is always enabled. This represents runtime enablement, not permission to export an ordinary-home definition. |
| Canonical Codex settings | `CLIProvidersSettingsView` | Hosts the Codex provider card and the shared direct-provider permission/runtime controls. |
| Inline controls | `AgentInputBar` | Exposes runtime tool and MCP toggles, but locks them during an active Codex run. |
| Global JSON settings | `GlobalSettingsDocument` / `GlobalSettingsStore` | Own ordinary product preferences and cross-window notification/reload behavior. It is not currently the security boundary for provider permission decisions. |

## 2.2 Current native data flow

```text
AgentModeViewModel
  → CodexAgentModeCoordinator creates a fresh controller/client
  → CodexNativeSessionController.startOrResume
      → CodexAppServerClient.prepareRuntimeForLaunch
          → CodexRuntimeAuthority resolves executable and isolated state
      → Options.repoPromptMCPProvisioner
          → CodexIntegrationConfiguration.ensureServerForDiscovery(runtime:)
              → CE private config may be repaired
      → CodexAppServerClient.startIfNeeded
      → Options.configOverridesProvider
      → requestThreadBinding
          → thread/start or thread/resume with params.config
      → later turn/start or turn/steer
```

Important boundaries:

- `turn/start` cannot carry a config override bag.
- `turn/steer` cannot carry config.
- A same-controller thread cannot be treated as dynamically reconfigured.
- A fresh controller’s `thread/resume` does accept the new nested `mcp_servers` definitions and respawns the corresponding MCP children.
- The disk `RepoPromptCE` definition remains active independently of the proposed nested source definitions.

## 2.3 What can be reused

- Reuse `CodexRuntimeAuthority` unchanged for executable and isolated-state resolution.
- Reuse `CodexIntegrationConfiguration` unchanged as the sole private-config writer and collision inventory source.
- Reuse `MCPIntegrationHelper` as the façade exposed to Agent Mode and UI.
- Extend the existing secure Codex permission document instead of introducing a second authorization store.
- Reuse `codexToolPreferencesGeneration`, `codexNeedsReconnect`, controller retirement, and idle-send reconnect behavior.
- Reuse secure-store notifications for cross-window authorization/runtime changes.
- Reuse the existing Settings provider-permissions view model for runtime rows, but introduce a separate Codex source-selection view model because drafts and Save semantics do not fit immediate toggle mutation.
- Reuse the existing captured-request and fake app-server test infrastructure.

## 2.4 What blocks #830

1. No reader or location abstraction exists for the ordinary `~/.codex/config.toml`.
2. `ServerEntry` cannot represent complete nested definitions.
3. The managed line parser does not provide a general multiline TOML value tree.
4. Existing MCP toggles lowercase names, so they cannot safely represent case-distinct imported names.
5. No persisted “first selection completed” or source authorization state exists.
6. The controller does not capture a consistent source-definition snapshot before launch.
7. Sessions do not distinguish:
   - source revision,
   - authorization,
   - runtime enablement,
   - desired application generation,
   - applied controller generation.
8. Exact outbound debug logging would expose imported command arguments, environment values, headers, or tokens.
9. There is no reliable pinned-runtime evidence for an in-place MCP reload request. The proven reload mechanism is fresh-controller start/resume.

## 2.5 Targeted change versus broader refactor

Use a targeted bridge. A general Codex configuration projection would enlarge the privacy surface, create a second private configuration authority, complicate rollback, and overlap adjacent global-instructions and general-parity work. The only cross-cutting changes justified for #830 are:

- a typed MCP-only TOML reader,
- secure authorization fields,
- a shared bridge service,
- native thread-config injection,
- lifecycle generation tracking,
- diagnostic redaction,
- focused Settings/runtime UI.

Do not refactor `CodexIntegrationConfiguration` into a general TOML document writer. Its preservation-oriented managed mutation logic and the new semantic source reader have different requirements.

---

# 3. Design

## 3.1 Ownership model

```text
Ordinary ~/.codex/config.toml          Secure Codex permission document
(read-only source definitions)        (authorization + exact runtime choices)
               │                                      │
               └──────────┬───────────────────────────┘
                          ▼
              CodexUserMCPBridgeService
       parsed source + authorization + runtime state
       → immutable desired application generation
                          │
                          ▼
        fresh CodexNativeSessionController snapshot
                          │
             config["mcp_servers"] only
                          ▼
        thread/start or fresh-controller thread/resume
                          │
                          ▼
        per-tab applied-generation receipt/status

CE private config ── RepoPromptCE + existing managed content
                   (unchanged bytes; independent disk substrate)
```

### Four separate concepts

1. **Identity:** exact, case-preserved server name. Valid runtime names match `^[A-Za-z0-9_-]+$`. `Foo` and `foo` are distinct.
2. **Authorization:** whether this exact source identity may leave ordinary `~/.codex/config.toml`.
3. **Definition revision:** an in-memory digest of the complete parsed definition. It changes when command, arguments, environment, URL, headers, or any other represented field changes.
4. **Applied generation:** an aggregate monotonic bridge generation successfully acknowledged by a particular fresh controller’s thread binding.

Runtime enablement is a fifth, separate choice: an authorized definition may be omitted from the next application snapshot while disabled.

The in-memory ownership model excludes a managed-region copy of ordinary definitions, generation leases for disk state, rollback machinery, normalized imported identities, a hard startup block when the source is unusable, and mid-startup retry when the bridge advances. Those mechanisms solve problems created by a second disk projection. Source failure instead omits imports from future fresh controllers. A generation that advances during binding becomes pending after the older receipt commits.

---

## 3.2 Source discovery and parsing

### New models

Create `Sources/RepoPrompt/Infrastructure/AI/Providers/Codex/Shared/CodexUserMCPSourceModels.swift`.

#### `CodexConfigValue`

An internal, `Equatable`, `Sendable` tagged value used from TOML parsing through app-server serialization:

- `string(String)`
- `integer(Int64)`
- `double(Double)`
- `bool(Bool)`
- `array([CodexConfigValue])`
- `table([String: CodexConfigValue])`

It must provide only a controlled conversion to `[String: Any]`/JSON values. It must not conform to `CustomStringConvertible` or expose raw values in localized errors.

TOML date/time values are not accepted in an eligible MCP definition until the pinned app-server contract proves their JSON projection. They produce a safe unsupported-value status for the affected server.

#### `CodexUserMCPSourceEntry`

Fields:

- `exactName: String`
- `status: CodexUserMCPSourceEntryStatus`
- `definition: [String: CodexConfigValue]?`
- `definitionRevision: CodexUserMCPDefinitionRevision?`
- `sourceLocations: [CodexTOMLSourceLocation]` for safe line/column diagnostics
- `sourceEnabled: Bool?`, derived only when an `enabled` boolean exists; any present non-boolean `enabled` value makes the definition unsupported

#### `CodexUserMCPSourceEntryStatus`

Closed cases:

- `eligible`
- `invalidRuntimeName`
- `duplicateOrRedefined`
- `conflictsWithRepoPrompt`
- `conflictsWithManagedPrivateServer`
- `malformed(reason: CodexUserMCPDiagnosticCode)`
- `unsupported(reason: CodexUserMCPDiagnosticCode)`

Diagnostic codes are finite and non-sensitive, such as `unsupportedDateValue`, `nonBooleanEnabled`, `invalidTableShape`, `arrayTableAtServerRoot`, or `ambiguousRedefinition`.

#### `CodexUserMCPSourceSnapshot`

Fields:

- `sourceState`
- `entries`, ordered by first safe appearance
- `documentRevision`, an opaque in-memory digest
- `capturedAt`
- `sourceFileIdentity`, non-display inode/device metadata used only for stability checks

Source states:

- `missing`
- `ready`
- `unreadable`
- `notRegularFile`
- `unstableDuringRead`
- `tooLarge`
- `malformedDocument`
- `permissionDenied`

The snapshot must never retain raw file text after parsing completes.

### Source location and read safety

Create `CodexUserMCPSourceReader.swift`.

`CodexUserMCPSourceLocation` owns the ordinary source URL:

- Production default: `FileManager.default.homeDirectoryForCurrentUser/.codex/config.toml`.
- Tests/POC inject an explicit source URL.
- Do not derive it from `CODEX_HOME`, the child environment, or `CodexRuntimeAuthority`.

`CodexUserMCPSourceReader` should be an actor with an asynchronous interface similar to:

```text
readSnapshot(
  sourceURL,
  managedPrivateEntries
) async -> CodexUserMCPSourceSnapshot
```

Read discipline:

1. Open `~/.codex/config.toml` read-only and follow the OS-resolved symlink chain without modifying it.
2. Validate that the already-open final object is a regular file, including root-owned read-only/Nix targets; do not validate one path and reopen another.
3. Reject directories, sockets, FIFOs, devices, and unresolved symlink loops.
4. Apply a fixed size ceiling chosen during POC, recommended 4 MiB.
5. Capture target device/inode/size/mtime from that descriptor before and after reading from the same descriptor.
6. If they differ, debounce and retry once; never combine bytes from two revisions.
7. If the second attempt is unstable, publish `unstableDuringRead` and no eligible definitions.
8. Never execute commands, expand `~` inside values, interpolate `$VAR`, resolve paths from definitions, or test source server executables.
9. Treat file-system watches as refresh hints only. Correctness comes from a stable read before every fresh-controller application snapshot.
10. Do not acquire `CodexIntegrationConfiguration.fileLock`; the ordinary source is read-only and outside that lock’s ownership.

V1 does not discover a user-relocated `CODEX_HOME`. The missing-source state names the exact path RepoPrompt read: `~/.codex/config.toml`. This explains why custom-home definitions were not found without implying that RepoPrompt inspected shell-only environment state.

### TOML dependency and semantic adapter

Create `CodexUserMCPSourceParser.swift`.

Use a maintained Swift TOML 1.0 library to parse the complete document strictly, then extract and validate only the `mcp_servers` subtree into `CodexConfigValue`. This aligns source acceptance with Codex's whole-document TOML behavior and avoids maintaining a second partial TOML grammar.

Before broad integration, run a bounded dependency POC that verifies:

- strict TOML 1.0 parsing for the representative and adversarial fixtures below;
- preservation of every Codex-supported MCP value needed for JSON-compatible thread config;
- safe line/column diagnostics without exposing raw library error text or source fragments;
- deterministic conversion into `CodexConfigValue` and semantic revisions;
- Swift toolchain, platform, package-size, license, supply-chain, and maintenance compatibility;
- upstream maintainer acceptance of the dependency.

Do not build or vendor a custom parser in parallel. If no maintained dependency satisfies the syntax, security, licensing, maintenance, package-size, and Codex-compatibility gates—or if maintainers reject the dependency—stop the implementation workstream with the evidence and request a maintainer decision. A custom parser requires an explicit follow-up design decision; it is not an automatic fallback.

The library-backed adapter must support source definitions expressed through:

- bare, basic-quoted, and literal-quoted keys;
- exact `[mcp_servers.<name>]` server tables;
- quoted names containing characters that are syntactically valid TOML but later fail the runtime-name rule;
- nested tables such as `[mcp_servers.foo.env]`;
- dotted assignments such as `mcp_servers.foo.command = "..."`;
- `mcp_servers = { ... }` inline-table definitions;
- inline tables within definitions;
- basic and literal strings;
- multiline basic and multiline literal strings;
- comments outside strings;
- booleans;
- decimal and TOML radix integers with underscores;
- finite floating-point values;
- single-line and multiline arrays with trailing commas;
- arrays of inline tables;
- nested array tables such as `[[mcp_servers.foo.someList]]`, represented as arrays of tables;
- library-provided line/column tracking for safe diagnostics.

Restrictions:

- `[[mcp_servers.foo]]` is invalid because a server definition must be a table, not an array.
- Duplicate keys, duplicate server-root tables, and conflicting table/scalar redefinitions invalidate the affected server.
- TOML date/time values make the affected definition unsupported, rather than silently converting them to strings.
- Non-finite floats are unsupported because JSON cannot represent them.
- A present `enabled` value that is not a boolean makes the affected definition unsupported instead of deferring the error to whole-thread binding.
- Any TOML syntax error invalidates the document for application, matching Codex's whole-document parse behavior.
- Top-level content outside `mcp_servers` is parsed by the library but never projected, persisted, or displayed.

The adapter should not reuse or refactor the managed line mutator. `CodexIntegrationConfiguration` keeps its existing mutation and preservation logic unchanged. Canonicalization, eligibility, collision checks, privacy-safe diagnostics, and definition/document revisions remain owned by the MCP adapter rather than the third-party library.

### Collision rules

For every safely detected source server:

- Exact `RepoPromptCE`, and every case-insensitive variant, is visible but ineligible with `Reserved name`. Case-insensitive reservation prevents a deceptive duplicate even though runtime names are technically case-distinct.
- A case-insensitive collision with another source name or a server already present in CE's private config is visible but ineligible with `Name conflict`. RepoPrompt must not silently shadow, replace, or present visually ambiguous alternatives.
- Exact case is preserved for display, authorization identity, semantic revision, and runtime injection.
- Case-insensitive comparison is used only for collision rejection and the reserved RepoPrompt name; it does not lowercase persisted identities.
- Invalid runtime names remain visible, cannot be authorized, and show the allowed-character rule.
- Removed but previously authorized identities appear in the saved-history subsection, not as currently detected entries.

### Failure behavior

- Missing source file: valid empty source; Settings says no Codex config was found at the exact path RepoPrompt reads, `~/.codex/config.toml`.
- Unreadable or unstable source: no new snapshot is eligible for application.
- Malformed document: no ambiguous or partial definition is sent.
- Last-applied controllers remain unchanged until they are intentionally replaced; source-read failure never causes in-place mutation.
- A future fresh controller receives no imported definitions if the latest stable source is unusable. `RepoPromptCE` and private config continue working.
- Errors include server name and line number when safe, but never values, arguments, paths, URLs, environment keys, headers, or literal fragments.

---

## 3.3 Authorization and persistence

### Recommended authority

Extend `SecureCodexPermissionDocument`; do not store authorization in `GlobalSettingsDocument`.

Rationale:

- Exporting a definition from an ordinary provider configuration is a permission decision.
- Codex runtime permissions already live in this Keychain-backed domain.
- Secure-store reads fail closed.
- Existing notifications already propagate Codex permission changes across windows.
- Putting the same decision in global JSON would create two authorities and could permit source export when secure storage is degraded.

`GlobalSettingsDocument.swift` and `GlobalSettingsManager.swift` should remain unchanged for #830.

### Secure document schema v2

Set `SecureCodexPermissionDocument.currentSchemaVersion` to 2 and add:

- `userMCPSelectionCompleted: Bool?`
- `authorizedUserMCPServerNames: [String]?`
- `userMCPRuntimeEnabledByExactName: [String: Bool]?`
- `userMCPAuthorizationRevision: UInt64?`

Defaults:

- Missing `userMCPSelectionCompleted` resolves to `false`.
- Missing authorization list resolves to empty.
- New names are unauthorized.
- An authorized name without an explicit runtime value resolves to enabled.
- Invalid/reserved/colliding source names are filtered from effective authorization, without deleting the saved history.
- Secure-store failure or future schema resolves imported authorization to empty and selection-completed to false.

Schema v2 is a deliberate hard cutover. Older builds must treat the document as a future schema and fail closed rather than silently reinterpret or partially rewrite bridge authorization. Future-version decode and automatic normalization paths must not overwrite the v2 document; only an explicit user-initiated permission save may replace it. A downgrade can therefore require reauthorization, including unrelated Codex permission choices, and the Settings copy and release notes must say so.

Loading a schema-v1 document in a schema-v2 build uses the secure store's existing older-version normalization path. Optional bridge fields resolve to the fail-closed defaults above, unrelated permission fields remain intact, and the schema label advances. The normalized document persists exactly once without incrementing `userMCPAuthorizationRevision`.

The decoder's existing future-schema rejection remains ahead of normalization and continues to fail closed without rewriting the stored payload. If a later schema needs a semantic transform rather than optional-field defaults, first make the load sequence explicit as decode → versioned migrate → normalize. Keep semantic migration out of generic normalization.

Persist only exact names, booleans, a revision counter, and `updatedAt`. Never persist definitions, fingerprints, file locations, commands, arguments, environment keys/values, URLs, or headers. Keep this as the single secure Codex permission authority; do not introduce a second record to soften rollback behavior.

### Authorization identity

Authorization is keyed by the exact, case-preserved server name with retained deletion/reappearance history.

Consequences:

- `Foo` and `foo` require separate decisions.
- A deleted and later reappearing `Foo` remains authorized.
- Changing `Foo`’s definition changes the definition revision and triggers reapplication, but does not require renewed consent.
- A literal credential or credential-selector change in `config.toml` changes the semantic definition revision and follows the same refresh path without prompting again.
- The user can explicitly revoke remembered authorization while the definition is absent.

This keeps consent stable and definition revision independent. A Keychain-only secret rotation does not change `config.toml`, so RepoPrompt cannot generically detect it; the per-agent restart action covers that case without making Keychain or Toolkit-specific behavior part of the bridge.

### Secure-store interfaces

Add focused APIs to `AgentPermissionSecureStore` rather than allowing UI code to edit the new fields directly:

- `codexUserMCPAuthorizationState() -> CodexUserMCPAuthorizationState`
- `updateCodexUserMCPAuthorization(expectedRevision:mutation:) -> Result<..., CodexUserMCPAuthorizationWriteError>`

The write must:

1. run under the existing secure-store lock;
2. compare `expectedRevision`;
3. reject stale cross-window drafts;
4. normalize exact names without lowercasing;
5. increment `userMCPAuthorizationRevision`;
6. save the entire Codex document atomically through the existing Keychain path;
7. post `.agentPermissionSecureStoreDidChange` only after success.

A failed or stale write preserves the Settings draft and leaves the bridge generation unchanged.

### Existing runtime toggles

Keep `mcpServerTogglesByNormalizedName` unchanged for private-config entries. Add source-specific exact-name helpers to `CodexAgentToolPreferences`:

- `userMCPAuthorizationState(...)`
- `userMCPServerRuntimeEnabled(exactName:...)`
- `setUserMCPServerRuntimeEnabled(exactName:enabled:...)`

Do not route source names through `normalizedKey(_:)`.

---

## 3.4 Bridge service and state flow

Create `CodexUserMCPBridgeService.swift`, owned as a shared `@MainActor ObservableObject` service with an injected reader and secure store for tests.

### Published state

`CodexUserMCPBridgeSnapshot` should contain:

- current `CodexUserMCPSourceSnapshot`;
- current `CodexUserMCPAuthorizationState`;
- rows combining source, authorization, runtime enablement, and eligibility;
- `desiredApplicationGeneration: UInt64`;
- `desiredApplicationRevision`, an opaque aggregate digest;
- counts: detected, eligible, authorized, enabled, invalid, removed-authorized;
- refresh phase and last safe refresh time.

`CodexUserMCPRuntimeSnapshot` is the immutable native-facing value:

- `generation`
- selected exact names
- complete selected definitions
- per-definition opaque revisions
- aggregate revision

Selection algorithm:

1. If the session's effective permission profile suppresses third-party MCP servers, return an empty imported-definition map; do not report authorized source servers as pending or applied for that session.
2. Start from stable eligible source entries.
3. Keep only exact names in the secure authorized set.
4. Keep only names whose source-specific runtime state is enabled.
5. If a source definition has `enabled = false`, keep the exact-name authorization history but exclude the definition from the desired native map and report it as source-disabled. A transition to `false` is a semantic generation removal.
6. Exclude all reserved/private-collision names.
7. Sort exact names for deterministic aggregation and serialization.
8. Include each remaining complete definition without modifying or flattening it.

Unauthorized and runtime-disabled definitions never enter native thread config.

### Generation rules

Increment `desiredApplicationGeneration` only when the effective native definition map changes, including:

- authorization grant or revocation;
- runtime enable/disable;
- definition content change;
- literal credential reference or selector change inside the source definition;
- eligible server addition/removal;
- collision eligibility change;
- transition from usable source to stable unusable source, or recovery.

Do not increment for:

- duplicate file watcher events;
- comments/formatting changes that preserve the semantic definition tree;
- Settings-only display timestamps;
- reorderings that produce the same named definition map.

Out-of-order refreshes carry a request sequence. The service discards any result older than the latest requested refresh. A dropped watcher is corrected by:

- refresh on Codex-card appearance;
- refresh on app activation while the card is visible;
- a low-frequency refresh while that Settings section is visible;
- mandatory stable refresh before producing each fresh-controller runtime snapshot.

### Notifications

Add `.codexUserMCPBridgeDidChange` with only:

- desired generation;
- reason code;
- privacy-safe source and authorization counts.

Do not include server definitions or file paths. Duplicate generation notifications are ignored.

---

## 3.5 Settings and inline UX

## Settings ownership

Global CLI Providers / Codex Settings owns only ordinary-source discovery and saved authorization. It must not display per-agent `Ready` or application state, cross-window current/pending/failed aggregates, or detailed session lists. Different agents may legitimately use different definition generations, and reconciling every window, suspended controller, and stale tab would add lifecycle and performance cost without enough product value.

Exact application and runtime state belongs to each affected Agent Mode tab. A green per-server `Ready` label is therefore not valid in Settings: it conflates source validity, authorization, runtime enablement, configuration application, and live server connectivity.

### Canonical source editor

Add a new “MCP servers from your Codex config” subsection to the Codex card in `CLIProvidersSettingsView`. It is visible whether Codex is connected or signed in.

Content:

- Source description: “Read-only source: ordinary `~/.codex/config.toml`. RepoPrompt never modifies or copies this file.”
- Last refresh/status and Refresh button.
- First-run explanation:
  > “Choose which MCP server definitions RepoPrompt may provide to native Codex Agent Mode. Nothing is shared until you save a choice.”
- Rows for every safely detected name, including invalid and conflicting names.
- An authorization checkbox for each eligible row. A normal valid row uses the checkbox alone—no `Allowed`, `Not allowed`, or `Disabled` label.
- Explicit text is reserved for exceptional states: `New`, `Unsupported name`, `Unsupported settings`, `Reserved name`, `Name conflict`, `Turned off in your Codex config`, `Not currently configured`, and a section-level config-unavailable state.
- Source-disabled rows retain their saved checkbox state but are inert until enabled at the source; their definitions never enter the desired native map.
- Previously authorized names that are absent from the source remain inline as `Not currently configured` rows with revoke controls.
- A display-only search/filter appears when the list is long. Filtering never changes the draft, authorization revision, or application generation.
- Save and Revert buttons.
- Explicit “Save no servers” first-run path; saving an empty selection completes first-use consent.
- Unsaved and externally outdated draft banners.
- No raw definition preview, command path, environment listing, URL, headers, or expandable TOML.

### Draft semantics

Create `CodexUserMCPSettingsViewModel`.

It owns:

- saved authorization snapshot/revision;
- draft authorized-name set;
- draft source revision;
- `hasUnsavedChanges`;
- `isDraftOutdated`;
- save phase and safe error;
- refresh phase.

Rules:

- Source refresh never silently adds a new name to the draft.
- New names show `New` and remain unchecked; the UI does not add a redundant `Not authorized` label.
- If a source or secure-store change arrives while no draft exists, reload automatically.
- If a change arrives while the draft is dirty, retain the draft and mark it outdated.
- Save uses the secure authorization revision as a compare-and-swap boundary.
- A stale Save is rejected with “Authorization changed in another window. Review the latest choices before saving.”
- Save failure retains the draft.
- Successful Save refreshes the bridge and notifies all windows/sessions.
- Closing Settings with a dirty draft discards it under the existing Settings-window behavior; if that surface normally confirms destructive draft loss, use the same convention rather than inventing a new modal.

### Per-agent runtime controls and status

Refine shared binding models so MCP rows express origin and exact identity:

`CodexMCPRuntimeServerBinding` fields:

- exact `id`
- display name
- origin: `repoPrompt`, `managedPrivateConfig`, or `authorizedUserSource`
- enabled
- editable
- pending-change marker when this row differs between the applied and desired generations;
- actual server runtime state when observed;
- safe status/badge.

`CodexToolSettingsBinding` changes from raw `ServerEntry` plus normalized-state dictionary to `mcpRuntimeServers: [CodexMCPRuntimeServerBinding]`.

Behavior:

- `RepoPromptCE`: required and disabled UI control.
- Existing private-config servers: current normalized runtime behavior.
- Authorized user-source servers: exact-name runtime toggles.
- Unauthorized source servers do not appear as runtime toggles. Authorization remains exclusively in CLI Providers.
- Agent Permissions reuses runtime rows only. It does not gain a source-definition or consent editor.
- The existing Agent Mode Tools popover's `MCP Servers` section shows the admitted runtime inventory. Do not create a second unrelated MCP popover.
- Show two independent layers:
  - one section-level configuration application state: `Not started`, `Current`, `Update pending`, `Refreshing`, or `Update failed`;
  - per-row actual server runtime: `Connected`, `Starting`, `Failed`, or `Unavailable` / `Not present`. Source-disabled definitions are excluded before runtime binding and remain a Settings-only exceptional state.
- Existing per-agent MCP runtime enable/disable toggles remain distinct from global authorization and desired-definition synchronization. Rows show the toggle, live runtime state, and only a compact pending-change marker when that row differs between desired and applied generations; they do not duplicate the section-level application state.
- The Tools button may carry a compact attention badge for pending or failed MCP state. It must not rely on color alone.
- Global Settings remains editable during an active Codex turn; its changes update the desired generation and remain pending for each affected conversation.
- The per-conversation Tools trigger remains available for read-only inspection while transcript text and tool-call output stream. All Bash, Search, Goals, Reasoning Summaries, Local Memories, and MCP mutation controls remain locked until the active turn and every replacement blocker settle. Apply/Refresh uses the coordinator-owned replacement blocker rather than a UI-only streaming flag.
- Keep Stop/Cancel independently reachable while the popover is open. Dismiss or rebind the popover when the selected conversation or provider changes, and render runtime state from a compact conversation-local snapshot rather than inferring it from toggle values.
- Explain a blocked action with visible text and an accessibility hint; do not rely on hover over a disabled control. Wide, medium, and narrow panes plus horizontal and vertical layouts must preserve access to status and actions.

### Final visual design authority

The selected visual direction is hybrid 2c progressive disclosure in global Settings plus a restrained 2b per-conversation status rail inside the existing Tools → MCP Servers popover. MP approved that direction, but the current five-image export packet is not final presentation authority: `final/qa.md` and the corrected-mockup critique retain unresolved fidelity findings, and the September 3 original-resolution review confirmed that those defects remain in the exported PNGs. Sections 3.6–3.7 own binding, dispatch, settlement, and desired-versus-applied semantics; the fidelity gate cannot redefine them.

The candidate packet uses five self-contained review boards: D1 covers ordinary Settings flow; D2 covers names and authorization exceptions; D3 covers source failures; D4 covers not-started, current, pending, and refreshing states; D5 covers failure, active-turn, settled-idle, mixed-generation, and server-row examples. Purple NOTE rails are design annotations outside native product frames. The packet becomes presentation authority only after corrected exports pass the original-resolution checks recorded in `final/qa.md`.

The current exports still require the approved Settings title and first-message copy, identical complete case-conflict guidance, on-position pending-enabled toggles, the binding-failure versus optional-child-failure split without an unsupported rollback claim, help text visually attached to its disabled action, complete Tools popovers with the required RepoPrompt row, and complete RepoPrompt frames for cross-conversation comparisons.

As of the September 3 reconciliation, issue #830 remains open with no comments, linked pull request, published presentation, or community-feedback record. The prepared text and candidate boards remain private until the fidelity gate passes and MP separately authorizes the destination and exact message.

The packet defines the presentation of the plan's state model, ownership and message semantics, exceptional Settings states, per-conversation application states, per-server runtime states, interaction annotations, accessibility requirements, and responsive variants. The unsaved notice is “Running agents pick up saved changes before their next genuinely new message.” A source error explains that future fresh controllers fail closed without imported servers while saved authorization remains unchanged.

Product and engineering evidence settles lifecycle semantics before visual critique. Design agents may critique comprehension, hierarchy, control presentation, accessibility, and provisional labels against those settled states; they do not choose whether a toggle represents desired or applied state or redefine message-dispatch behavior. Every user-visible state must appear inside its real containing surface. Comparisons across conversations use multiple complete RepoPrompt frames with their actual sidebar selections, chat panes, and Tools popovers; abstract diagrams may supplement but never replace those concrete mockups.

Verify the real split-pane UI at minimum width for clipping, composer coverage, internal scrolling, and reachable Refresh. If the status rail cannot remain legible without layout defects, use the packet's text-only 2a presentation as the narrow-width fallback without changing the underlying state or ownership model. Record any semantic mismatch in the design QA rather than silently changing behavior.

---

## 3.6 Native thread configuration

### Controller interfaces

Extend `CodexNativeSessionController.Options` with:

```text
userMCPRuntimeSnapshotProvider:
  (suppressThirdPartyMCPServers: Bool) async -> CodexUserMCPRuntimeSnapshot
```

The default returns an empty snapshot, preserving all non-Agent-Mode tests and callers.

Production `AgentModeViewModel` injects `CodexUserMCPBridgeService.runtimeSnapshotForFreshController(suppressThirdPartyMCPServers:)`. It uses the same effective per-session suppression input already supplied to `appServerMCPServerOverrides`. This keeps the captured snapshot, outbound nested map, and receipt identical. A Safe Managed or MCP-originated session omits the nested `mcp_servers` key and does not present suppressed source servers as pending or applied.

Add `CodexUserMCPApplicationReceipt`:

- `generation`
- applied exact names
- definition revisions by exact name
- aggregate revision

Extend `CodexSessionControlling` with a read-only:

```text
lastUserMCPApplicationReceipt:
  CodexUserMCPApplicationReceipt?
```

The controller sets it only after `thread/start` or `thread/resume` succeeds. A failed or timed-out request never reports the generation as applied.

### Capture point and ordering

Within `startOrResume`:

1. begin binding;
2. prepare the authoritative runtime;
3. provision CE MCP;
4. check cancellation;
5. request one stable user-MCP runtime snapshot;
6. check cancellation again;
7. update process launch policy/directory;
8. start app-server;
9. install inbound streams and skill roots;
10. produce the ordinary feature config;
11. merge the captured nested MCP definitions;
12. send the thread binding request;
13. commit the application receipt with the session binding.

The snapshot must be captured before process start so an authorization/source failure cannot launch a child that might receive inconsistent configuration.

The surrounding startup sequence continues through the existing routing-admission gate before first-turn dispatch. Neither the runner-level MCP readiness check nor routing admission changes for #830:

```text
runtime resolution → CE provisioning → source snapshot → process launch
→ skills → thread bind → receipt commit → routing admission → turn dispatch
```

A binding failure continues through the existing provider-startup terminal path without admitting a first turn.

### Config shape

Keep existing feature and flattened private-server overrides unchanged. Add exactly one nested value:

```text
params.config["mcp_servers"] =
  [exact source name: complete source definition]
```

Only add it when at least one selected definition exists. Do not include `RepoPromptCE` in the nested map.

Before sending:

- fail if the existing feature config already has a non-table `mcp_servers`;
- fail if a selected exact name collides with an existing nested name;
- do not rewrite or add `enabled`;
- do not flatten imported definition fields;
- do not copy any ordinary-home field outside `mcp_servers`.

### Binding failure settlement

`thread/start` and `thread/resume` are state-mutating requests. If an imported-config binding times out, is cancelled after dispatch, or fails ambiguously:

- terminate and settle that exact transport generation before returning;
- do not mark the generation applied;
- clear expected PID registration;
- preserve the previous thread reference for a later fresh-controller retry;
- show a generic safe error such as:
  > “Codex could not apply the selected MCP definitions. Review the server statuses or retry with a fresh session.”

When an idle user message owns this replacement, do not dispatch its provider turn until the fresh `thread/start` or `thread/resume` succeeds. If binding fails, restore the optimistic user item and composer payload through the existing manual-send failure path. This is a section-level application failure; do not infer it from an individual MCP child's runtime failure.

A decoded authoritative JSON-RPC rejection can include the server name if the server supplied it, but must pass through the diagnostic sanitizer before presentation. Never include rejected params or definition values.

### Exec and other providers

`CodexExecAgentProvider` remains disk-only:

- same isolated runtime;
- same CE MCP provisioning;
- same managed-entry flags;
- no ordinary-home source read;
- no nested imported definition projection.

Document this as deliberate non-parity: #830 is native Agent Mode only because exec’s argument/config behavior and retry lifecycle differ and were not part of the pinned proof.

Chat, Oracle, global Codex use, Toolkit, and unrelated MCP integrations also remain unchanged.

The bridge applies to every Codex runtime accepted by `CodexRuntimeAuthority`, including an explicitly selected external runtime at version `0.149.0` or newer. The POC evidence is pinned to bundled signed Codex `0.149.0`. Behavioral drift in a newer accepted runtime surfaces as an authoritative binding rejection and follows the binding-failure path.

---

## 3.7 Lifecycle and message semantics

### Application states per tab

Add to `AgentTabSession`:

- `codexDesiredUserMCPGeneration: UInt64?`
- `codexAppliedUserMCPGeneration: UInt64?`
- `codexUserMCPApplicationState`

Configuration application state cases:

- `notStarted(desired:)`
- `current(generation:)`
- `updatePending(applied: UInt64?, desired: UInt64, reason:)`
- `refreshing(desired:)`
- `updateFailed(applied: UInt64?, desired: UInt64, safeMessage:)`

Use a closed, privacy-safe pending-reason enum such as `authorizationChanged`, `definitionChanged`, `runtimeEnablementChanged`, `sourceUnavailable`, `sourceInvalid`, or `serverRemoved`. This lets the tab explain a fail-closed source error distinctly from an ordinary definition update without exposing configuration values.

Actual MCP process/runtime state is tracked separately per server as `connected`, `starting`, `failed`, or `unavailable` / `notPresent`. A successfully applied definition is not proof that its child process connected; a failed child process is not proof that the desired definition generation failed to bind.

After a successful binding, an optional MCP child that fails to start remains a per-row runtime failure: the application generation stays current, the chat remains usable, and the row may offer Reconnect. Do not show section-level `Update failed` or “message not sent” copy for this case. A required-server failure or authoritative rejection of the complete thread binding follows the binding-failure path above.

These are transient runtime fields unless existing session persistence has a clear need for a display-only last-known generation. Do not persist server names or generation receipts in chat/session artifacts for v1.

### Refresh propagation

Add one coordinator-owned settlement query, for example `codexMCPReplacementBlocker(for:) -> CodexMCPReplacementBlockingReason?`. It is the single source of truth for:

- whether a pending generation may replace the controller;
- whether Apply Current MCP Configuration/Refresh is enabled;
- the compact poll/wait blocking reason;
- whether every per-conversation Tools mutation control is enabled.

The reason enum covers active turn, queued/dispatching fallback, approval/permission/elicitation/user-input response, waiting continuation, hook/trust/binding work, active RepoPrompt tool or child wait, and replacement already in progress. Tests must prove all four consumers agree for every reason.

On `.codexUserMCPBridgeDidChange`:

1. `AgentModeViewModel` forwards the new desired generation to `CodexAgentModeCoordinator`.
2. Each Codex session that admits imported third-party MCP definitions records the desired generation. A session whose effective permission profile suppresses third-party MCP servers keeps an empty effective imported set and is not marked pending by source-bridge changes.
3. If the session's applied generation differs, increment `codexToolPreferencesGeneration` and mark `codexNeedsReconnect`.
4. Enable, change, and removal remain pending while `codexMCPReplacementBlocker(for:)` returns a reason. Settlement means the entire turn and its in-flight interactions are terminal—not merely that one tool call ended.
5. UI refreshes to show an exact per-tab pending state.

Duplicate notifications for the same effective generation do nothing.

Receipt commitment re-runs the same desired-versus-applied comparison. If the bridge advances while an older snapshot is binding, the completed session becomes `updatePending` as soon as the older receipt commits. V1 does not retry a binding merely because a newer generation arrived mid-startup.

### Truthful message semantics

The implementation preserves existing message categories:

- **Active turn + user message:** steer into the current turn using its existing MCP generation.
- **Idle user message + pending update:** replace the controller, fresh-resume the thread with the new definitions, then dispatch the message as a new turn.
- **Queued fallback:** retains existing controller/generation/thread/run/attempt-pinned behavior. Do not delay or reinterpret an ordinary queued follow-up merely because a new MCP generation exists.
- **Waiting continuation:** remains separate; do not reinterpret its response as steer or as a post-update new turn.
- **Approval, permission, MCP elicitation, and user-input response:** always respond through the controller that issued the request.
- **Hook review/trust/binding:** blocks replacement until its settlement path completes.
- **Literal credential or selector change in the definition:** produces a new definition/application generation and follows the same safe refresh path.
- **Removed or revoked server:** remains available to an already-running turn until that controller can safely retire. UI must say “Removal pending in this tab,” not imply immediate revocation.

If an active agent truly needs a newly enabled or changed MCP immediately, the supported practical workflow is: Stop/Cancel, wait for terminal settlement, then continue the same session with a new message so a fresh controller applies the desired generation before the new run. Otherwise, let the entire turn finish.

V1 uses one automatic policy: **lazy refresh**. Mark the tab pending and refresh synchronously before its next idle new turn. Do not proactively restart every settled-idle tab after a global authorization or definition change; that creates background process herds, unattended failures, and a second message-ownership race without improving correctness.

The existing idle-send path already owns the user’s unconsumed message across `ensureCodexNativeSession`; use that path rather than inventing a second queue.

### Why no session-owned pending-message handoff in v1

A generation-bound handoff is necessary only if RepoPrompt accepts a message while actively retiring/replacing a controller independently of the send operation. That would require exactly-once ownership across:

- composer attachments;
- optimistic transcript rows;
- MCP delivery acknowledgements;
- fallback queue lineage;
- cancellation;
- provider acceptance ambiguity.

The design never accepts such a message into an independent update queue. An idle send can synchronously own replacement and then send one new turn; an active send remains a steer on the old generation.

### Alternatives considered

1. **Automatic transparent background update:** best apparent convenience, but unsafe around active tools, interactions, fallback queues, and ambiguous thread binding.
2. **Explicit queue-after-update:** truthful but needs the new session-owned exactly-once handoff described above.
3. **Manual restart only:** simplest, but leaves long-lived stale sessions and makes credential rotation cumbersome.
4. **Lazy replacement:** selected for v1 because it uses existing send/reconnect ownership and attaches replacement cost or failure to the new turn that needs it.
5. **Proactive idle replacement:** rejected for v1 because it restarts process-local MCP state in every idle tab, including tabs the user may not use again.

### Apply Current MCP Configuration

Add a required v1 per-agent action inside Tools → MCP Servers for settled apply-now changes, Keychain-only credential rotation, stuck MCP children, and retry after failure. RepoPrompt is not repairing Keychain; it simply cannot generically observe a secret rotation when `config.toml` is unchanged. The visual label may use the shorter `Refresh` where space is constrained, but the accessible name must communicate that the current saved MCP configuration will be applied.

Derive the action intent from the section-level application state, not by aggregating row statuses. `updateFailed` takes precedence over `updatePending`, which takes precedence over `current`. Working visual labels are `Try again`, `Apply now`, and `Refresh` respectively; final copy review may refine the words without changing that precedence. A `current` section may still contain a failed optional child with its own row-level Reconnect action.

Enable the action only when all are true:

- an existing Codex thread reference is available to resume;
- `codexMCPReplacementBlocker(for:)` returns no blocking reason.

It retires the controller, fresh-resumes without sending a turn, respawns MCP children, and records the receipt. On failure it leaves the thread reference and reconnect flag intact; it cannot roll back to the retired process. The action belongs per agent, never in global Settings.

The approved presentation keeps the action visible but disabled while the conversation is unsettled. Inline text explains “Finishing this turn — tools stay as they are” and is wired to the disabled action for accessibility. A macOS help tooltip supplements it with the practical path: “Available when this chat is idle. To use [server] now: Stop this turn, wait for it to finish, then send a new message here.” Community feedback may refine these labels before implementation without changing the settlement rule or action precedence.

### Read-only orchestrator status

For native Codex Agent Mode sessions, `agent_run poll` and `agent_run wait` include a compact cached in-memory MCP summary sufficient for control decisions. The field is absent for other providers:

- configuration application state;
- privacy-safe blocking reason;
- failure flag;
- optional monotonic status revision.

Detailed privacy-safe per-server rows are opt-in through an additional poll/wait parameter. The detailed form may include exact server name, pending-change marker, runtime state, `lastTransition`, and a closed symbolic error category, but never commands, arguments, environment, headers, tokens, URLs, or complete definitions. Return at most ten rows per requested session and enforce the same total bound for multi-session calls; include truncation metadata rather than silently omitting overflow. Neither compact nor detailed status performs a live app-server query on every poll; the coordinator updates a cached snapshot from lifecycle events and bounded refreshes.

### Cleanup and cancellation

- Source refresh cancellation leaves the last completed bridge snapshot untouched.
- Native snapshot cancellation before process launch sends no thread request and registers no expected PID.
- Controller replacement continues restoring user-owned fallback content through existing abandonment behavior.
- A stale controller receipt is ignored unless controller identity, controller generation, run, and attempt still match.
- Terminal snapshot construction and publication retain the final cached MCP application summary. VM-owned asynchronous cleanup clears cached status only after terminal publication. `cancelEphemeralRuntimeState()` must not clear it early. Tab close, provider switch, and controller-clear paths otherwise remove the cache as specified.

---

## 3.8 Reload determination

The pinned control proved that disk `config/batchWrite` plus `config/mcpServer/reload` works for disk-backed configuration. It does not replace definitions supplied only through a thread's nested config, and the pinned matrix proved same-controller resume does not replace that thread configuration. Do not use the disk reload API as a substitute for fresh-controller thread-only application, and do not create a disk projection to make the API fit.

V1 reload mechanism:

- new thread: fresh-controller `thread/start`;
- existing thread: fresh-controller `thread/resume`;
- same controller: no definition replacement;
- active turn/steer: old generation remains authoritative.

During the POC, probe the pinned `0.149.0` schema/runtime for an MCP inventory or reload method. An inventory endpoint may be used only for validation if it is confirmed. An in-place reload may be proposed later only if all of the following are proven:

1. documented request shape;
2. deterministic completion response;
3. additions, modifications, removals, and credential rotation;
4. child cleanup and respawn;
5. safe behavior during turns/interactions;
6. transport-generation settlement;
7. inventory verification.

Even if found, do not expand #830’s first upstream patch unless it clearly simplifies the proven fresh-controller design.

---

## 3.9 Privacy and security

### Structural redaction release prerequisite

Create `CodexJSONRPCDiagnosticSanitizer.swift`.

No code path may ship complete thread-only definitions until this component and its tests land. It accepts parsed JSON-compatible objects and returns a diagnostic-only copy. Walk the diagnostic candidate recursively and replace the entire subtree of every object-valued key named `mcp_servers`, wherever it appears, with one fixed marker. The marker may contain a redaction flag and server count but must not retain server names. This protects outbound requests and any inbound response, notification, failure payload, or future echo that nests the definitions under a different path.

Rules:

- redact every object-valued `mcp_servers` subtree, including unknown future fields;
- do not inspect field names such as `env`, `headers`, or `token` individually;
- apply before stringification;
- never modify the original payload or serialized wire frame;
- if unstructured data contains an apparent MCP config but cannot be parsed safely, suppress the entire diagnostic line rather than regex-redacting fragments.

### Required sinks

Audit and route all applicable data through the sanitizer:

- `CodexAppServerClient.sendJSONLine` outbound debug logging;
- parsed inbound response/request debug logging;
- stdout/stderr JSON previews and captured tails;
- raw-event JSONL in `CodexNativeSessionController`;
- JSON-RPC `RequestFailure.data` before logs or user-facing conversion;
- thread-binding error details;
- transport failure diagnostic previews;
- transcript/system/error items created from provider rejection;
- `AgentModePerfDiagnostics` snapshots before DEBUG storage;
- `MCPConnectionManager+DebugDiagnosticsAgent` response payloads before DEBUG MCP response assembly;
- test trace dumps that include request payloads.

Raw event logs normally record inbound data, but the sanitizer must still be applied generically so echoed config cannot leak.

### Logging rules

- Settings may display exact server names and status only.
- Operational logs may include counts, phase, desired/applied generation, and safe reason codes.
- Do not log source path, definition fingerprint, command, args, cwd, environment keys/values, URL, headers, or raw rejection data.
- Definition digests remain internal opaque values and are not displayed.
- Errors must be constructed from finite local codes wherever possible.

### Memory and persistence

- Raw source text is discarded after parsing.
- Complete definitions exist only in the parser snapshot, bridge snapshot, captured native snapshot, and outbound payload.
- No definitions are written to private config, global settings, Keychain, chat persistence, session persistence, raw event files, or traces.
- A process crash may leave ordinary OS process memory artifacts; #830 does not add custom memory pinning or secret-zeroization primitives.

---

## 3.10 Source change, partial failure, and rollback behavior

| Event | Effective behavior |
|---|---|
| New eligible name | Visible immediately; unauthorized by default; no generation change until authorized. |
| Authorized definition changes | Definition/application generation changes; existing controllers become pending. |
| Literal credential, reference, or selector change in `config.toml` | Definition/application generation changes; exact-name authorization remains valid. |
| Keychain value rotates without a source-file change | CE cannot infer the change. The per-agent restart/refresh action replaces the controller and respawns MCP children so wrappers read the current credential. |
| Authorized definition removed | Removed from desired map; saved authorization retained; existing controllers pending removal. |
| Definition becomes malformed | Removed from desired map after stable read; shown invalid; fresh controllers omit it. |
| Source becomes unreadable | Desired imported map becomes empty after stable error; no private-config or active-controller mutation. |
| Private config later gains same exact name | Source row becomes collision-ineligible and is removed from future nested snapshots. |
| Authorization Save fails | Draft retained; no bridge generation change. |
| One selected definition causes app-server rejection | Entire thread binding is treated as failed; the fresh process is retired; no partial applied receipt. |
| Reconnect fails | Previous controller is retained only if it was not yet retired. After retirement, session remains reconnect-needed and retries fresh later. |
| App crashes during source read | No writes exist to recover. Next launch rereads source and secure authorization. |
| App crashes during secure Save | Existing Keychain document remains authoritative; incomplete Save reports through existing secure-store diagnostics on reload. |

---

## 3.11 Scope boundaries

- **#830:** sole tracking issue for discovery, consent, persistence, in-memory native application, reload lifecycle, UI, privacy, and validation.
- **#831:** do not absorb general configuration parity, private projection, or unrelated Codex preference work.
- **PR #678:** hook approval/trust and binding operations are quiescence constraints and regression tests only.
- **PR #824:** global skill-root registration must continue before thread binding; source integration must not reorder or replace it.
- **PR #906 / global instructions:** merged upstream on 2026-08-30. Sync the fork to current upstream main before implementation and validate #830 directly against the merged interfaces; do not recreate or bypass its instruction behavior.
- **PR #837 / isolated-state hook compatibility:** remains open at planning time. If it is still open when #830 implementation begins, use a disposable integration branch to expose concrete hook/runtime conflicts without basing #830 on the PR branch or adopting unstable types.
- **Toolkit:** no Toolkit code or configuration writes. Only parity fixtures validate that equivalent ordinary Codex MCP blocks are discovered consistently with or without Toolkit-authored surrounding content.
- **Classic import, global instructions, profiles, hooks, auth files, history, SQLite, plugins, apps, caches:** explicitly out of scope.
- **Cross-surface authorization hint:** a passive “N servers await authorization” indicator outside the canonical CLI Providers editor is deferred from v1. It adds coupling without affecting correctness; reconsider only with usage evidence.

---

# 4. File-by-file impact

## New production files

### `.../Shared/CodexUserMCPSourceModels.swift`

- Add `CodexConfigValue`, source snapshots, entry statuses, diagnostic codes, definition/document revisions, authorization/runtime snapshots, and application receipt.
- Foundation for every later workstream.

### `.../Shared/CodexUserMCPSourceParser.swift`

- Add a thin adapter over the accepted maintained TOML library: whole-document parse, MCP-subtree extraction, value validation, privacy-safe diagnostics, and deterministic canonicalization/digest behavior.
- Depends on source models and the dependency POC/maintainer acceptance gate.

### `.../Shared/CodexUserMCPSourceReader.swift`

- Add ordinary-home location resolution, stable symlink/regular-file reads, size limits, retry behavior, and safe source-state mapping.
- Depends on parser/models.

### `Sources/RepoPrompt/Features/AgentMode/Runtime/ProviderBindings/CodexUserMCPBridgeService.swift`

- Add shared observable bridge state, refresh sequencing, secure authorization combination, desired generation, notifications, and native runtime snapshots.
- Depends on reader and secure persistence.

### `Sources/RepoPrompt/Features/AgentMode/ViewModels/UI/CodexUserMCPSettingsViewModel.swift`

- Add Settings drafts, saved revision tracking, Save/Revert/Refresh, cross-window conflict handling, and safe user messages.
- Depends on bridge service and secure-store CAS API.

### `Sources/RepoPrompt/Infrastructure/AI/Providers/Codex/AppServer/CodexJSONRPCDiagnosticSanitizer.swift`

- Add structural whole-subtree redaction and fail-closed handling for unparseable diagnostic candidates.
- Must land atomically with native nested definition emission.

## Modified production files

### `CodexIntegrationConfiguration.swift`

- Keep all managed ownership, locking, mutation, and atomic-write behavior unchanged.
- No ordinary-home reads or imported-definition writes.

### `Package.swift` and resolved dependency metadata

- Add the maintained TOML library only after the bounded compatibility/security POC and upstream maintainer acceptance.
- Pin the accepted version according to repository policy.
- Do not add a custom parser dependency or vendored fallback in parallel.

### `CodexRuntimeAuthority.swift`

- No production behavior change planned.
- Add only focused tests confirming ordinary-source discovery is independent of its isolated `CODEX_HOME`; do not add an ordinary-home helper here.

### `MCPIntegrationHelper.swift`

- Add façade methods for bridge snapshots/refresh, combined runtime server bindings, and privacy-safe cached per-agent status projection.
- Keep existing managed install/provisioning methods unchanged.

### `AgentPermissionSecureStore.swift`

- Move `SecureCodexPermissionDocument` to schema v2 with authorization/runtime fields, fail-closed optional-field defaults, and revision-aware focused read/write APIs.
- Use the existing older-version normalization path to relabel and persist a v1 document exactly once without incrementing the bridge authorization revision; preserve the existing pre-normalization future-schema rejection and no-overwrite behavior.
- Allow replacement of a future-schema document only through an explicit user-initiated permission save.
- Ensure notification payloads remain non-sensitive and preserve this document as the single secure permission authority.

### `CodexAgentToolPreferences.swift`

- Add exact-name source authorization/runtime helpers.
- Keep normalized private-entry toggles and required `RepoPromptCE` behavior unchanged.

### `AgentProviderBindingModels.swift`

- Add `CodexMCPRuntimeServerBinding` and origin/status variants.
- Replace raw private-entry MCP binding fields with combined runtime rows.
- Add `CodexToolSettingMutation.userMCPServer(exactName:enabled:)`; retain `.mcpServer(normalizedName:enabled:)` for managed private entries.

### `AgentProviderPreferenceSnapshotStore.swift`

- Combine:
  - required `RepoPromptCE`,
  - managed private entries,
  - authorized source entries.
- Route private and source runtime mutations through their distinct persistence helpers.
- Safe Managed suppresses all third-party rows regardless of origin while preserving their displayed saved state.

### `AgentProviderPermissionsSettingsViewModel.swift`

- Observe bridge notifications as well as secure-store notifications.
- Rebuild runtime rows after source/application changes.
- Do not own source authorization drafts or Save.

### `SettingsView.swift`

- Construct and inject `CodexUserMCPSettingsViewModel` into CLI Providers.
- Keep Agent Permissions composition unchanged.

### `CLIProvidersSettingsView.swift`

- Add the always-available source/authorization editor to the Codex card.
- Add draft, outdated, source-error, exceptional-row, and saved-missing states. Do not add per-agent application aggregates.
- Keep connection/login controls independent.

### `AgentProviderPermissionControlsComponents.swift`

- Render origin-aware runtime MCP rows.
- Rename copy from general “MCP servers” to runtime availability.
- Add safe exceptional-state badges only where this shared runtime surface actually owns them.
- Do not add source authorization controls.

### `AgentInputBar.swift`

- Render combined admitted runtime rows.
- Keep authorization editing out of the popover.
- Add separate configuration-application and live-server states to the existing Tools popover's MCP Servers section.
- Add the required idle-safe Apply Current MCP Configuration/Refresh action and a compact non-color-only Tools-button attention badge.
- Allow the Tools trigger and popover to open while Codex transcript and tool output stream.
- Render passive state from one compact conversation-local snapshot.
- Disable only mutating Bash, Search, Goals, Reasoning Summaries, Local Memories, MCP toggle, Reconnect, and Apply/Refresh controls while the shared settlement blocker is present.
- Keep Stop/Cancel independently visible and reachable.
- Dismiss or rebind the popover when `currentTabID` or provider identity changes.
- Show the blocking reason as visible inline text plus an accessibility hint; a tooltip may supplement but must not own essential guidance.
- Preserve wide, medium, narrow, horizontal-split, and vertical-split access to status and actions.
- Preserve active steer, queued follow-up, new-turn, and waiting-interaction semantics.

### `CodexAppServerClient.swift`

- Sanitize all diagnostic serialization paths.
- Add a testable diagnostic logger seam if needed to avoid intercepting global `print`.
- Preserve original outbound payload and frame bytes.
- Use mutation settlement for config-carrying thread binding or expose the necessary settled request interface to the controller.

### `CodexNativeSessionController.swift`

- Add source snapshot provider option and application receipt state.
- Capture one snapshot before process launch.
- Merge nested `config["mcp_servers"]` into start/resume only.
- Commit receipt only after successful binding.
- Settle ambiguous binding failures.
- Distinguish authoritative thread-binding failure from post-binding optional child-runtime failure. Only the former prevents receipt commitment and requires transport-generation settlement.
- Apply sanitizer to raw-event/error paths.
- Leave `turn/start`, steer, skills, memory, goals, hooks, and interaction request shapes unchanged.

### `CodexAgentModeCoordinator.swift`

- Observe desired bridge generation.
- Mark sessions current/pending/reconnecting/failed.
- Reuse reconnect generation and controller retirement.
- Add the single coordinator-owned settlement/blocking query used by refresh deferral, Apply Current MCP Configuration/Refresh enablement, and poll/wait status.
- Ensure idle sends apply a pending generation before dispatching a new turn under the sole v1 lazy policy; do not proactively replace settled-idle controllers.
- Keep active sends as old-generation steer.
- Preserve existing queued follow-up behavior unless an explicit new queue-after-refresh operation is separately designed.
- Add idle-safe per-agent restart/refresh orchestration.
- After exact transport settlement, classify an idle manual send whose fresh thread binding failed as a pre-dispatch rejection so the existing optimistic-item/composer restoration path runs exactly once. Preserve the thread reference and reconnect-needed state, and never call `turn/start`.
- Treat a committed binding receipt as authoritative even if an optional MCP child later reports a runtime failure.
- Maintain a compact privacy-safe cached status summary for orchestrator poll/wait; never live-query the app-server on each poll.

### `CodexIntegratedAgentModeRunner.swift` and `AgentModeRunService.swift`

- No production behavior change planned.
- Preserve the runner-level MCP readiness gate and existing provider-startup terminalization. A source snapshot or imported binding failure must not bypass admission or produce a first turn.

### `AgentTabSession.swift`

- Add desired/applied generation and application state.
- Clear these with provider/controller lifecycle as specified.
- Preserve existing fallback pinning and abandonment behavior.
- Do not persist definitions or names.

### `AgentModeViewModel.swift`

- Inject the bridge snapshot provider into controller options.
- Subscribe to bridge notifications once per window.
- Route application state, live-server state, and restart actions to the existing Tools popover and button badge.
- Project an immutable, conversation-local Tools snapshot containing application state, runtime rows, action intent, blocker reason, and mutation-lock state. Do not derive runtime truth from toggle values or ambient window state.
- Expose cached compact and opt-in detailed privacy-safe MCP status to `agent_run` response projection.
- Preserve existing CE provisioning, skill roots, permission profiles, and feature providers.

### `Infrastructure/MCP/Agent/AgentRunMCPSnapshot.swift`

- Adapt the compact, cached, privacy-safe MCP configuration summary returned by normal `agent_run` poll/wait responses from the canonical domain snapshot; do not define a second schema in the app target.
- Add an opt-in detailed row shape containing only server name, configuration state, runtime state, `lastTransition`, and a closed symbolic error category; cap it at ten rows per requested session.
- Keep command, arguments, environment, headers, credentials, URLs, and full definitions out of both shapes.

### `Sources/RepoPromptDomainRuntime/DomainAgentSessionModels.swift`

- Own the additive canonical MCP configuration summary carried by `DomainAgentRunSnapshot` and serialized through `asObject()`.
- Keep the default compact shape limited to per-tab application state, pending reason, safe counts, and last transition; detailed server rows remain opt-in and bounded by the MCP tool service.
- Preserve existing run, interaction, worktree, and failure serialization for consumers that do not request MCP detail.

### `Infrastructure/MCP/Agent/AgentRunMCPToolService.swift`

- Project the cached compact summary into existing poll/wait responses.
- Accept an optional detail request on existing poll/wait operations, bounded to ten rows per requested session and a matching total bound; do not add a separate status operation unless implementation evidence proves the existing shape cannot carry it safely.
- Never turn polling into a live app-server status query.

### `Features/Diagnostics/AgentMode/AgentModePerfDiagnostics.swift` and `Features/Diagnostics/MCP/MCPConnectionManager+DebugDiagnosticsAgent.swift`

- Route DEBUG diagnostic snapshots through the structural sanitizer before storage and sanitize the assembled `agent_perf_metrics` response as a second egress boundary.
- Preserve safe lifecycle and generation metadata while ensuring nested imported definitions cannot enter the debug cache or response.

### `CodexExecAgentProvider.swift`

- No behavior change.
- Add a comment and regression assertion documenting native-only source projection.

### `GlobalSettingsDocument.swift` and `GlobalSettingsManager.swift`

- No changes planned.
- Validate during review that no convenience implementation adds duplicate authorization state here.

## New/focused tests

### Parser and reader

Create:

- `Tests/RepoPromptTests/MCP/CodexIntegration/CodexUserMCPSourceParserTests.swift`
- `.../CodexUserMCPSourceReaderTests.swift`

Cover:

- maintained TOML library compatibility, safe diagnostic wrapping, and deterministic adapter conversion;
- quoted/bare/case-distinct valid names;
- invalid runtime names still displayed;
- nested tables and dotted assignments;
- comments, multiline strings, arrays, inline tables, and array tables;
- duplicate/redefinition failures;
- date, non-finite, and non-boolean `enabled` unsupported values;
- malformed whole-document syntax;
- `RepoPromptCE` and private collision rules;
- semantic revision stability across formatting-only changes;
- secrets absent from error descriptions;
- missing, unreadable, oversized, non-regular, symlink-loop, stable symlink, and concurrent replacement cases.
- missing-source UI metadata names `~/.codex/config.toml` and no other inferred home.

### Existing managed configuration

Extend `CodexIntegrationConfigurationTests.swift`:

- private config bytes remain identical during source refresh/application;
- case-preserved source identities do not alter managed-entry parsing;
- existing idempotence and conflict tests remain green.

### Secure persistence

Extend `AgentPermissionSecureStoreTests.swift`:

- schema-v1 documents migrate through the existing normalization path to schema v2, persist exactly once, leave the bridge authorization revision unchanged, default bridge authorization to empty, and preserve unrelated permissions;
- schema-v2 documents round-trip the new fields through the single secure authority;
- an older/future-version decoder path fails closed and automatic normalization cannot overwrite the v2 document;
- only an explicit new user save may replace a version-mismatched document, and downgrade/reauthorization behavior is covered;
- exact case variants persist independently;
- runtime values remain exact-name keyed;
- deleted authorization history remains;
- stale revision Save fails;
- successful write increments revision and notifies;
- corrupt/future/Keychain-failure paths authorize nothing;
- no definition or secret field is serialized.

### Bridge and refresh

Create `CodexUserMCPBridgeServiceTests.swift`:

- new names unauthorized;
- Save-empty completes first selection;
- formatting-only refresh does not bump generation;
- definition/credential changes do;
- removed/malformed/collision changes remove future definitions;
- source `enabled = false` removes the definition from the desired map without deleting exact-name authorization, and re-enabling restores eligibility;
- out-of-order refresh result is discarded;
- duplicate watcher events deduplicate;
- pre-controller refresh is the correctness backstop.

### Settings

Create `CodexUserMCPSettingsViewModelTests.swift`:

- first-run draft;
- Save, Revert, and Save-empty;
- source refresh with clean versus dirty draft;
- cross-window secure change and stale-save rejection;
- failed secure Save preserves draft;
- unavailable or degraded secure storage leaves the draft intact and applies no bridge generation;
- invalid/new/removed rows;
- source-disabled rows show `Turned off in your Codex config`, retain saved authorization, remain inert, and contribute no definition to the desired map;
- valid TOML with unsupported date/time or non-finite values shows `Unsupported settings`;
- display filtering and inline `Not currently configured` rows do not mutate drafts or generations;
- mixed-generation copy says running agents pick up saved changes before their next genuinely new message;
- Settings functionality while Codex is disconnected;
- no source editor appears through Agent Permissions.

### Native controller

Create `CodexNativeSessionControllerUserMCPConfigTests.swift` or extend `CodexNativeSessionControllerGoalConfigTests.swift`:

- nested definitions on `thread/start`;
- nested definitions on fresh-controller `thread/resume`;
- complete values preserved;
- empty snapshot omits nested key;
- private flattened overrides and `RepoPromptCE` remain;
- a disk-private third-party server disabled by a flattened override remains disabled while the nested source map is present;
- same-controller turn/start/steer carry no config;
- application receipt commits only after success;
- timeout/cancellation/ambiguous failure retires transport;
- a Safe Managed run with authorized and runtime-enabled source servers omits the nested `mcp_servers` key and does not report those source servers pending or applied;
- an MCP-originated child with the same source authorization also omits the nested key and reports no imported source servers pending or applied;
- skill roots and provisioning ordering remain unchanged.

### Bootstrap readiness

Extend `CodexMCPBootstrapReadinessTests.swift`:

- source snapshot failure/cancellation cannot cross the process-launch boundary;
- successful order becomes runtime resolution → CE provisioning → source snapshot → process launch → skills → thread bind → receipt commit → routing admission → turn dispatch;
- the exact resolved runtime remains reused.

Extend `CodexMCPRoutingReadinessTests.swift`:

- a generation change while startup is suspended cannot admit a stale first turn;
- replacement failure admits no first turn and leaks no routing waiters or policies;
- cancellation during generation replacement cleans up routing admission and preserves the existing terminalization contract.

### Lifecycle and queue semantics

Create focused coordinator tests, for example `CodexUserMCPLifecycleGenerationTests.swift`:

- first bind and first-bind failure use `notStarted`/optional applied generation correctly;
- active turn keeps old generation;
- active message remains steer;
- idle message applies fresh generation then becomes a new turn;
- queued fallback drains on original controller;
- replacement abandons/restores existing queued input;
- waiting continuation and each pending interaction block replacement;
- hook/trust operation blocks replacement;
- stale receipt cannot update successor controller;
- a bridge notification arriving during binding leaves the session `updatePending` immediately after the older receipt commits;
- a literal source-definition revision marks the affected session pending;
- a Keychain-only rotation remains unchanged until the per-agent restart/refresh action is invoked;
- apply failure leaves reconnect needed;
- twenty mixed sessions keep exact state tab-local without global Settings aggregation;
- compact poll/wait status remains cached, native-Codex-only, and privacy-safe;
- opt-in detailed rows are capped at ten per requested session, include only approved fields plus truncation metadata, and never expose definition values;
- active Stop/Cancel → terminal settlement → same-session new turn refreshes before dispatch;
- ordinary queued follow-ups retain current behavior;
- running-agent copy states that saved changes apply before the next genuinely new message, not immediately on Save;
- refresh deferral, Apply Current MCP Configuration availability, and poll/wait blocking reason agree for every shared settlement blocker;
- every per-conversation Tools mutation control uses that same blocker and remains locked while passive status inspection and Stop/Cancel remain reachable;
- Apply Current MCP Configuration is unavailable without an existing thread reference or while any shared settlement blocker is present;
- rejected, timed-out, cancelled-after-dispatch, and ambiguous `thread/start` and fresh-controller `thread/resume` bindings make zero `turn/start` calls, commit no receipt, set `updateFailed`, retain reconnect-needed state, remove the optimistic user row, and restore draft text, images, tagged files, and workflow exactly once; newer composer edits remain authoritative;
- successful binding followed by an optional MCP child failure commits the receipt, keeps the application state `current`, dispatches the new turn once, retains the optimistic user item, keeps chat usable, and exposes only row-level `Failed` plus `Reconnect`;
- required-server failure and authoritative complete-binding rejection follow the pre-dispatch restoration path;
- optional row failure cannot select the section-level retry intent or “message not sent” copy;
- active-turn popover tests cover opening during streaming, locked mutations, reachable Stop, tab/provider identity changes, conversation-local snapshot isolation, and visible non-hover-only blocked-action help;
- MCP status is absent for non-Codex sessions, and detailed multi-session output respects the ten-row per-session and total response bounds;
- a run terminating with a pending generation publishes that application state and generation exactly once in its terminal snapshot before VM-owned cache cleanup;
- the real split-pane Tools popover remains usable at minimum width with reachable Apply/Refresh, or uses the text-only 2a fallback without changing semantics.

### Redaction

Create `CodexAppServerMCPDiagnosticRedactionTests.swift`:

- object-valued `mcp_servers` subtrees at outbound and arbitrary inbound nesting paths are wholly redacted, including command, args, env, headers, URL, unknown future fields, and sentinels;
- outer method/id/generation metadata remains;
- raw wire payload remains semantically identical;
- raw-event JSONL, provider errors, captured stdout/stderr JSON, and trace paths contain no sentinels;
- the assembled DEBUG `agent_perf_metrics` payload preserves safe lifecycle metadata while containing no imported-definition sentinel;
- malformed unstructured candidate suppresses the whole diagnostic line.

### Runtime authority and adjacent regressions

Extend or focus-run:

- `CodexRuntimeAuthorityTests`: ordinary source injection remains independent of isolated state.
- `CodexRuntimeAuthorityTests`: every accepted bundled or explicit external runtime uses the same bridge contract, while a newer-runtime binding rejection follows the ordinary authoritative failure path.
- `CodexCapabilityProviderBindingTests`: combined rows do not change capability flags.
- `MCP/AgentRunMCPToolServiceStartDefaultTests`: Agent Mode startup defaults and MCP routing remain.
- Existing safe-managed, bootstrap, goal/memory, hook, and skill-root suites.
- `CodexMCPRoutingReadinessTests`: existing admission behavior plus generation-replacement suspension, failure, and cancellation cases.

### Schema fixture rule

Run `make dev-codex-schema-check` regardless. Modify `Scripts/Fixtures/codex-app-server-contract.json` and `Scripts/test_codex_app_server_schema.py` only if implementation changes the expected app-server protocol contract. Adding values inside the already generic `thread/start`/`thread/resume` `config` bag should not require a fixture change unless the guard currently enumerates or rejects that nested shape.

---

# 5. Execution index

| Index | Goal | Done when | Key files | Dependencies | Size |
|---:|---|---|---|---|---|
| 1 | Lock the POC contract | Pinned Codex proves start/fresh-resume behavior, same-controller limitation, private-config byte identity, and observed inventory/tool call | New POC test/harness and docs evidence | None | M |
| 2 | Prove and adopt maintained TOML parsing | A bounded dependency/security POC and maintainer check pass; strict whole-document parsing produces complete safe MCP entries and deterministic revisions | Package metadata, source models/library adapter, parser tests | 1 | M |
| 3 | Add stable ordinary-source reads | Missing/symlink/concurrent-writer/error cases are deterministic and read-only | Source reader, reader tests | 2 | M |
| 4 | Add secure authorization authority | Schema v2 fails closed across version mismatch, preserves one permission authority, documents downgrade reauthorization, and supports revision-aware Save | Secure store, tool preferences, secure tests | 2 | M |
| 5 | Add bridge service | Source plus authorization produces one deduplicated desired generation, suppression-aware per-session snapshots, and safe notifications | Bridge service/tests, MCP façade | 3, 4 | L |
| 6 | Add structural redaction | Every diagnostic sink hides the whole nested subtree while wire data is unchanged | Sanitizer, app-server client, controller, redaction tests | 2 | M |
| 7 | Apply definitions natively | One suppression-aware snapshot reaches start/fresh-resume, receipts commit after success, routing admission remains authoritative, and exec remains unchanged | Native controller/client, controller and routing-readiness tests | 5, 6 | L |
| 8 | Integrate lifecycle generations | Active/idle/steer/queue/interaction semantics are deterministic, receipt commitment recomputes pending state, terminal status publishes before cleanup, and no input is silently lost | Coordinator, tab session, AgentModeViewModel, lifecycle tests | 7 | XL |
| 9 | Add canonical Settings drafts | Every detected server is visible; explicit Save persists consent; cross-window conflicts are safe | Settings VM, CLI Providers, SettingsView, Settings tests | 5 | L |
| 10 | Unify runtime UI semantics | Shared settings and input-bar rows distinguish source authorization from runtime availability; active turns allow read-only inspection while mutation controls stay locked, Stop remains reachable, tab/provider changes rebind or dismiss the popover, and each conversation renders from its own snapshot | Binding models/store, permission VM, shared controls, input bar | 5, 8, 9 | M |
| 11 | Run integration and adjacent constraints | Pinned runtime, 20-agent, Toolkit parity, hooks, skills, safe-managed, schema, merged-#906, and optional #837 compatibility checks pass | Test suites and disposable compatibility branch when needed | 1–10 | L |
| 12 | Prepare upstream submission | Current-main diff is #830-only, documented, reviewable, and checked against adjacent global-instructions work where seams overlap | Docs/PR description/future comment draft | 11 | M |

---

# 6. Risks and migration

## Migration

- Secure Codex permission schema moves from v1 to v2 as a hard cutover.
- Existing private MCP runtime toggles keep their current normalized behavior.
- Existing users start with no ordinary-source authorization and `userMCPSelectionCompleted == false`.
- No source definition is imported automatically on upgrade.
- An empty saved first-use choice is valid and remembered.
- Rollback to an older app encounters a future schema and fails closed; it must not automatically normalize or partially rewrite the v2 document. An explicit permission save on the downgraded build may replace the document and require reauthorization after upgrading again.
- Removing the feature leaves only inert exact-name authorization fields in the schema-v2 Keychain document.

## Principal risks

1. **TOML dependency compatibility:** a maintained parser can still differ from Codex's Rust TOML implementation or introduce supply-chain/toolchain cost. Mitigate with the bounded compatibility/security POC, pinned-runtime fixtures, version pinning, and maintainer acceptance before broad integration. If no dependency passes, stop with evidence for a maintainer decision; do not silently vendor or implement a custom parser.
2. **Case collision with existing normalized toggles:** keep source runtime state in exact-name fields and never reuse normalized private keys.
3. **Secret exposure:** nested definitions are uniquely sensitive. Redaction must land atomically with native emission.
4. **Mixed-generation misunderstanding:** global Settings must not imply application readiness; each tab remains authoritative for its own application state.
5. **Controller replacement loss:** do not replace with pinned fallback work or pending interactions; use existing abandonment restoration.
6. **App-server partial acceptance:** retire ambiguous fresh transports and commit receipts only on authoritative success.
7. **Transient source errors:** stable reread/debounce prevents flapping; latest unusable source fails closed for future controllers without interrupting current turns.
8. **Authorization by name:** same-name replacement inherits authorization. This accepted usability/security tradeoff requires clear Settings copy and tests proving definition revisions still synchronize and reapply without renewed consent.
9. **Adjacent runtime conflicts:** sync to upstream main containing merged PR #906 before implementation. If PR #837 remains open and overlaps the hook/quiescence seams, test a disposable combination without making #830 depend on it.
10. **Permission-profile bypass:** nested definitions do not participate in existing flattened server overrides. Mitigate by making snapshot capture suppression-aware and proving Safe Managed and MCP-originated sessions omit imported definitions entirely.

---

# 7. Staged delivery and upstream relationship

## Stage 1: local MP fork POC

1. Use injected isolated ordinary/private homes.
2. Evaluate one maintained Swift TOML library against representative and adversarial Codex MCP definitions, repository toolchain/platform constraints, safe diagnostics, licensing, maintenance, and package cost.
3. Ask the upstream maintainer whether the vetted dependency is acceptable before broad integration. If rejected or technically incompatible, stop with the POC evidence and request a maintainer architecture decision; do not vendor or silently build a custom fallback.
4. Send the library-adapted nested definitions to bundled signed Codex `0.149.0`.
5. Prove:
   - `thread/start` applies them;
   - fresh-controller `thread/resume` adds/changes/removes them and respawns children;
   - same-controller reuse does not replace them;
   - `RepoPromptCE` remains active;
   - CE private config hash/bytes remain unchanged;
   - app-server observes the expected MCP inventory;
   - a uniquely named test tool can be called.
   - a disk-private third-party server disabled through an existing flattened override stays disabled while the nested source map is present.
6. Record evidence under #830 planning material only; do not post yet.

## Stage 2: CE product integration

Implement parser, secure consent, bridge service, privacy, lifecycle, and UI on current main. Keep commits separable by workstream but use #830 as the only tracking issue.

## Stage 3: current-main upstream submission

Prepare one reviewable #830 PR without Toolkit, Classic, global instructions, private projection, or general config parity. Prefer a series of logically separated commits within the same PR if maintainers value reviewability.

## Stage 4: adjacent managed-runtime compatibility check

PR #906 merged upstream on 2026-08-30. Before implementation, sync the fork to current upstream main and develop/test #830 against those stable global-instructions interfaces.

If PR #837 remains open and overlaps the isolated-state hook or quiescence seams when #830 reaches integration:

- create a disposable branch combining current #830 work with the latest #837 head;
- compile and run native/bridge/hook/schema tests;
- record concrete conflicts privately;
- do not publish #830 on that branch or depend on branch-only types;
- repeat the focused checks on upstream main if #837 later merges.

## Explicit release validation

Because this change affects provider launch configuration, secure consent, and potential credential handling, perform release-build validation before shipping, even if the upstream PR is developed in Debug. Any visible app launch or relaunch requires approval first; prefer non-disruptive CLI tests and builds until that approval is obtained.

---

# 8. Task-specific validation strategies

## 8.1 Adversarial isolated homes, symlinks, secrets, and Toolkit parity

Combine source-safety and Toolkit parity into one fixture matrix:

- missing/unreadable/oversized/regular/symlinked/Nix-like target;
- atomic rename while reading;
- malformed and duplicate TOML;
- quoted/case-distinct/reserved/colliding names;
- literal secret sentinels in every value shape;
- equivalent MCP blocks surrounded by:
  - plain Codex-only content;
  - Claude Toolkit-authored surrounding content.

Expected result: identical MCP discovery for equivalent blocks, no writes to either fixture, no Toolkit changes, and no sentinel in diagnostics.

## 8.2 Pinned-runtime start/fresh-resume inventory matrix

Use bundled signed Codex `0.149.0` and isolated CE state:

1. start with definitions A/B;
2. fresh-resume with A modified, B removed, C added;
3. compare same-controller behavior;
4. verify child respawn/cleanup;
5. verify `RepoPromptCE` remains callable;
6. inspect app-server-observed inventory through a confirmed inventory request or lifecycle evidence;
7. invoke a unique test MCP tool to prove usability;
8. add a disk-private third-party server, disable it through the existing flattened override, inject a disjoint nested source map, and verify the private server remains disabled while the injected servers run;
9. byte-compare private config before and after.

This is the acceptance proof for the application mechanism.

## 8.3 Twenty-agent multi-window generation simulation

Simulate twenty sessions across multiple windows:

- current, active-old, idle-pending, queued-fallback, waiting, approval, elicitation, reconnecting, failed, and closed;
- multiple rapid source generations and authorization Saves;
- stale controller receipts;
- tab/window teardown.

Assert exact per-tab truth, no per-agent state leaking into global Settings, no leaked cached orchestrator entries, and no duplicate refresh.

## 8.4 Sentinel redaction with raw-wire equivalence

Build outbound and inbound-shaped JSON candidates containing object-valued `mcp_servers` subtrees at multiple nesting paths, with sentinels in commands, args, nested env, headers, URL, arrays, inline tables, and unknown fields.

Assert:

- captured raw frame decodes to the exact intended request;
- sanitized diagnostic copies preserve safe outer method/id metadata and remove every sentinel at every nesting path;
- stdout/stderr preview, raw-event JSONL, trace, request failure, transcript error, and fallback error contain no sentinel;
- malformed echoed JSON is fully suppressed.

---

# 9. Prepared community presentation — do not post

Audience: RepoPrompt users who are experienced with AI-agent workflows and the product, but should not need source-code familiarity. Lead with product behavior and the source → authorization → per-conversation applied set → server-runtime model. Keep files, symbols, and line numbers out of the presentation.

Post these as three consecutive messages so readers understand the existing architecture before reviewing the proposal.

**Message 1 — background:**

> I’m exploring a native Codex Agent Mode bridge for MCP servers already configured in `~/.codex/config.toml`. The goal is to bring back the Codex MCP servers that are missing inside RP’s native Agent Mode because the bundled Codex app-server runs from RP’s isolated Codex home.
>
> I initially considered syncing the normal Codex config into RP’s private Codex config. That would mean copying and maintaining another version of a file that can contain sensitive MCP settings, while also creating two sources of truth.
>
> Looking further, Codex app-server already lets its caller pass MCP configuration through `thread/start` and `thread/resume`. That gives us a narrower option: RP can read only the MCP section, ask which server names you authorize, and pass those definitions directly to that conversation in memory. Nothing needs to be written into RP’s private Codex config or changed in your normal Codex setup.
>
> Anyway, I’d like feedback on the product model before starting implementation, in case people have other ideas or think we should take a different direction.

**Message 2 — attach D1, D2, D3, D4, and D5 in that order:**

> Some details about the proposed behavior:
> - Settings shows the detected MCP server names and saves an explicit authorization choice. New names start unchecked.
> - Authorization follows the exact server name. If you later edit the definition behind an already authorized name, RP uses the updated definition automatically instead of asking you to authorize the same name again.
> - Each conversation has its own applied MCP set because app-server receives the MCP configuration when that conversation’s controller starts or resumes. An active turn keeps the set it started with. Once that turn fully settles, the next new message first applies the latest saved set and then sends.
> - The existing Tools popover stays inspectable during a turn so you can see which MCPs are actually in use. Its switches and actions remain locked because the running turn cannot swap to a different tool set halfway through.
> - At idle, a pending set offers **Apply now**. An up-to-date set has a quiet **Refresh** action for credential rotation or stuck servers. If one optional MCP server fails after the conversation starts, that row offers **Reconnect** while the conversation keeps working.
> - If RP cannot start or resume the conversation with the requested MCP set, it does not send the new message. The message returns to the composer so you can retry without retyping it.
> - Definitions are passed to native Codex in memory only. RepoPromptCE remains managed separately, and the UI and diagnostics never expose commands, arguments, URLs, headers, tokens, or raw definitions.
>
> The attached sheets separate product UI from purple design notes. D1–D3 cover Settings; D4 covers the normal per-conversation lifecycle; D5 covers failure, active-turn, settled-idle, mixed-generation, and server-row states.

**Message 3 — follow-up questions:**

> I’d especially value feedback on three things:
> 1. Does the Settings-versus-per-conversation ownership match how you expect this to work?
> 2. Are **Apply now**, **Refresh**, and per-server **Reconnect** clear, or does the overlap feel unnecessary?
> 3. Is inspecting MCP status during an active turn useful, knowing the controls stay locked because that turn cannot change tool sets halfway through?

---

# 10. Implementation order

1. **POC and protocol proof:** complete index item 1 before product code. Freeze the nested shape, same-controller limitation, and inventory evidence.
2. **TOML dependency gate and adapter:** run the bounded library POC and maintainer acceptance check, then land models, the library-backed MCP subtree adapter, and parser tests. If the gate fails, stop with evidence for a maintainer decision; do not vendor or silently build a custom parser.
3. **Safe source reader:** add injected location and stable file reads. No runtime consumer yet.
4. **Secure schema v2:** add authorization state and revision-aware APIs, prove v1→v2 migration, fail-closed downgrade behavior, and protection against automatic version-mismatch overwrite.
5. **Bridge service:** combine source and authorization into immutable native snapshots and generation notifications, with the effective session suppression input producing an empty imported map for Safe Managed and MCP-originated sessions.
6. **Redaction:** land sanitizer and all diagnostic sink changes. This must be atomic with step 7 in any branch that can emit real definitions.
7. **Native application:** capture the snapshot, merge nested definitions, settle failures, and record receipts. Validate start/resume, bootstrap, routing admission, and no-first-turn failure ordering.
8. **Lifecycle integration:** add first-bind plus desired/applied state, one shared settlement predicate, receipt-time desired-versus-applied recomputation, terminal-publication-before-cleanup ordering, and the lazy reconnect policy. Validate steer/new-turn/queue/interaction semantics and agreement across refresh, Restart, and poll/wait.
9. **Settings editor:** add drafts, explicit Save, cross-window CAS behavior, and source states.
10. **Runtime UI unification:** replace raw entry bindings with origin-aware rows in shared controls and AgentInputBar.
11. **Full integration matrix:** run the four special strategies and adjacent regression suites.
12. **Adjacent-change integration:** work from upstream main containing PR #906; test a disposable #837 combination only if that still-open work overlaps when #830 is implemented.
13. **Upstream preparation:** format, guardrails, contributor preflight, review future comment/PR text, and obtain approval before any visible app launch.

---

# 11. Contributor validation commands

Do not run these as part of planning. Use focused tests first, then broaden.

## Focused sequence

```bash
make dev-test FILTER=CodexUserMCPSourceParserTests
make dev-test FILTER=CodexUserMCPSourceReaderTests
make dev-test FILTER=AgentPermissionSecureStoreTests
make dev-test FILTER=CodexUserMCPBridgeServiceTests
make dev-test FILTER=CodexUserMCPSettingsViewModelTests
make dev-test FILTER=CodexAppServerMCPDiagnosticRedactionTests
make dev-test FILTER=CodexNativeSessionControllerUserMCPConfigTests
make dev-test FILTER=CodexMCPBootstrapReadinessTests
make dev-test FILTER=CodexMCPRoutingReadinessTests
make dev-test FILTER=CodexUserMCPLifecycleGenerationTests
make dev-test FILTER=CodexIntegrationConfigurationTests
make dev-test FILTER=CodexRuntimeAuthorityTests
make dev-test FILTER=CodexCapabilityProviderBindingTests
make dev-test FILTER=AgentRunMCPToolServiceStartDefaultTests
```

If native tests are added to the existing goal-config suite rather than a new class:

```bash
make dev-test FILTER=CodexNativeSessionControllerGoalConfigTests
```

## Build and provider validation

```bash
make dev-swift-build PRODUCT=RepoPrompt
make dev-swift-build PRODUCT=repoprompt-mcp
make dev-provider-test
make dev-codex-schema-check
```

Run `make dev-provider-test` when provider package or provider-facing contracts are affected; otherwise still run it before PR-ready because #830 changes native provider launch behavior.

## Repository gates

```bash
make dev-format-check
make dev-lint
make guardrails
make doctor
make dev-build
```

With approval and when available, use the non-disruptive smoke target:

```bash
make dev-smoke
```

Do not launch or relaunch the visible app without explicit approval. Before release, also validate a release configuration because Debug/Release isolated Codex homes differ.

## Contribution preflight

Run in order after the working tree and commit are ready:

```bash
./.agents/skills/rpce-contribution-check/scripts/preflight.sh commit
./.agents/skills/rpce-contribution-check/scripts/preflight.sh push
./.agents/skills/rpce-contribution-check/scripts/preflight.sh pr-ready
```

---

# 12. Accepted product and architecture direction

MP accepted the following product direction before design critique:

1. Global Codex Settings owns source discovery and saved authorization only. Exact application and runtime state is tab-local, with no cross-window aggregate or session list in Settings.
2. Authorization follows the exact case-preserved server name. Definition revisions synchronize without renewed consent; deletion retains authorization for the same name; a different name begins unchecked.
3. Normal valid rows use a checkbox without a status label. Exceptional rows use concise states for new, unsupported, reserved, colliding, source-disabled, saved-but-missing, or unavailable source data.
4. Each Agent Mode tab exposes configuration and runtime state in the existing Tools popover, plus an idle-safe Apply Current MCP Configuration/Refresh action and a non-color-only attention badge.
5. Existing steer and queued-follow-up semantics remain unchanged. A user who needs a newly changed MCP during an active turn stops or cancels, waits for terminal settlement, and sends a new message in the same session.
6. Poll/wait exposes a cached compact privacy-safe summary for native Codex sessions, with detailed read-only per-server state available only on explicit request and bounded to ten rows per requested session.
7. Stable symlinked ordinary Codex configurations are supported through a stable read-only final-file-descriptor snapshot.
8. Structural redaction of the complete nested MCP definition subtree is a release prerequisite.

Phase 6 resolved the remaining architecture choices:

1. V1 refreshes lazily before the next idle new turn. The explicit per-agent Apply Current MCP Configuration/Refresh action is the apply-now and credential-rotation path.
2. Tools → MCP Servers shows one section-level application state. Rows retain their runtime toggle and live connection state, plus a pending-change marker only when needed.
3. Existing `agent_run` poll/wait operations accept an optional bounded detail parameter; no separate status operation is added.
4. Use a maintained Swift TOML library, gated by an early compatibility/security POC and maintainer acceptance. If no dependency passes, stop for a maintainer decision; do not vendor or silently implement a custom parser.
5. Keep the narrow bridge service/model split, with one shared coordinator settlement predicate and path-agnostic structural redaction.
6. Use secure permission schema v2 as a hard cutover. A v1 document advances through existing optional-field normalization without an authorization-revision bump; a newer document fails closed before normalization, downgrade may require reauthorization, and no second secure authority is added.
7. Source definitions with `enabled = false` retain exact-name authorization but are excluded from the desired native map; changing to false is a semantic generation removal.
8. MP approved the hybrid 2c + restrained 2b visual direction. The current five-image packet remains a candidate until corrected Settings, exception, lifecycle, complete-conversation, and server-row boards pass `final/qa.md`; the September 3 review confirms the existing PNGs do not pass. The text-only 2a presentation is only a minimum-width fallback, and the passive cross-surface authorization-count hint is deferred from v1.
9. Snapshot capture accepts the session's effective third-party suppression state. Safe Managed and MCP-originated sessions omit the nested imported map entirely and do not report suppressed source servers pending or applied.
10. The existing runner readiness and routing-admission gates remain authoritative through first-turn dispatch. A binding or replacement failure cannot admit a first turn or leak routing waiters.
11. Receipt commitment re-runs desired-versus-applied comparison, and terminal MCP status publishes before VM-owned asynchronous cleanup.
12. Structural redaction covers DEBUG diagnostics both before `AgentModePerfDiagnostics` storage and before `agent_perf_metrics` response assembly.
13. V1 names `~/.codex/config.toml` in missing-source UI, treats a non-boolean source `enabled` as unsupported, and does not infer a relocated user `CODEX_HOME`.
14. The bridge applies to any bundled or explicit external Codex runtime accepted by `CodexRuntimeAuthority`; pinned proof remains version `0.149.0`, and newer-runtime drift follows authoritative binding failure.
