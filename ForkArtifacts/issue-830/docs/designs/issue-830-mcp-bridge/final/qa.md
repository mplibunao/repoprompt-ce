# Final hybrid visual QA

## Outcome

The selected hybrid remains the working visual direction: progressive disclosure in global CLI Providers / Codex Settings and a restrained per-tab status rail in Tools → MCP Servers. The six-image packet passes the bounded fidelity review and is ready to guide product work. This is design evidence, not a product-code decision record or packaged-runtime acceptance evidence.

## Direct visual review

- We opened all six files in the current `final/discord/` review sequence at their exported resolutions after the final correction. They contain no Claude Desktop chrome, clipped content, missing Tools inventory rows, or incomplete conversation frames.
- The focused review sequence separates Settings workflow, Settings exceptions, source failures, and per-tab lifecycle so each image remains readable at Discord preview scale.
- Global Settings reports only source and saved authorization state. It doesn't claim that every agent is current or show cross-session totals.
- Per-tab Tools owns applied-generation and runtime state, including not started, current, pending, refreshing, failed, blocked by an active turn, settled-idle refresh, and mixed-generation examples.
- The lifecycle preserves active steering and queued-follow-up behavior. Its one-delivery guarantee applies only to an idle new-turn send that refreshes before dispatch. Version 1 doesn't add a generation-bound queue-after-refresh handoff.
- Ordinary unchecked Settings rows have no redundant negative label. Plain-language negative copy appears only for names or sources that need attention.
- The design system specifies wide, medium, narrow, horizontal-split, and vertical-split behavior. The focused exports and their mirrored source specimens passed the final clipping and wrapper-boundary checks.
- Icons and words carry state independently of color. The design annotates focus order, screen-reader descriptions, live-region behavior, help text, reduced-motion behavior, contrast, and hit targets.

## September 3, 2026 reconciliation

The corrected packet resolves the August 31 fidelity findings:

- Settings uses “MCP servers from your Codex config,” consistent case-only conflict guidance, and `Discard` for unsaved-selection changes.
- The not-started explanation says “These take effect on your first message,” and pending-enabled rows use an on-position toggle with explicit pending words.
- Binding failure and optional-server failure are separate specimens. The active-turn explanation is anchored to the disabled action in a complete Agent Mode frame.
- Mixed generations appear as two complete RepoPrompt conversation frames rather than abstract comparison cards.
- Every full Tools popover uses the complete inventory order: Bash, Search, Goals, Reasoning Summaries, Local Memories, MCP Servers, required RepoPromptCE, then user-authorized servers.
- The source and six mirrored export sheets report no vertical clipping. Their expected 2× dimensions are 2000×2312, 2000×1798, 2000×848, 2000×2168, 2000×3748, and 2000×2962 pixels.

## Privacy review

The design exposes only MCP names, authorization/application relationships, privacy-safe runtime state, pending reason, last transition, and symbolic error codes. It explicitly excludes commands, URLs, arguments, environment/header names, tokens, credentials, complete definitions, and hashes from Settings, per-tab status, notifications, and orchestrator output.

The orchestrator card is per-tab cached state, not a live poll or cross-session aggregate. Optional detail is bounded to ten rows.

## Archive review

- `mcp-bridge-final-hybrid-project.zip` passes `unzip -t`.
- The archive retains the corrected final design, earlier comparison pages, two relevant product baselines, and the Claude Design system assets needed for further editing.
- The archive also contains the unrelated `Launch RepoPrompt CE.command` upload. Keep the archive private; removing that remote project asset requires explicit approval.
- The final page contains no general pending-message handoff, queued-message migration, waiting-continuation handoff, or separate Allow None control.

## Minor copy polish

“Remove from authorized” is understandable but slightly awkward. Before product copy is final, compare it with “Remove authorization” in context. This doesn't block the visual direction.

## MP review checkpoint

Approved copy and naming:

- Use **MCP servers from your Codex config** for the imported-server disclosure and **MCP Servers** for the parent section.
- Use the same case-only conflict guidance in both examples: “These names differ only by capital letters, so neither can be used. Rename, comment out or remove one in your Codex config and the other becomes available again.”
- Use “These take effect on your first message.” for the not-started explanation.

Settled mechanics:

- Action-intent precedence is `updateFailed > updatePending > current`. Working labels are `Try again`, `Apply now`, and `Refresh`; the visible words remain provisional until final copy review. A failed optional child leaves the section `Current`, keeps the section action at `Refresh`, and uses row-level `Reconnect`.

Open review items:

- Finalize a visible inline blocked-action explanation and accessibility hint. Hover/focus help may supplement the explanation but can't be the only place it appears.
- Compare “Remove from authorized” with “Remove authorization” in the implemented Settings layout before product copy is final.
