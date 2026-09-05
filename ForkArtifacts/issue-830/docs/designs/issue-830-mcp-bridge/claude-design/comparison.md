# Issue #830 visual alternatives — comparison

Status: Phase 5 comparison evidence. The selected direction is 2c global Settings plus a restrained 2b per-tab Tools treatment.

## Inputs

- Real RepoPrompt CE Settings and Agent Mode captures: `../baseline/`
- Product state, ownership, lifecycle, responsive, and accessibility model: `../artifacts/design-system.md`
- Image-generation direction: `../artifacts/imagegen-brief.md`
- Claude Design direction: `../artifacts/claude-design-brief.md`
- Editable alternatives and refined hybrid: `mcp-bridge-final-hybrid-project.zip`

The Claude Design project is owner-only Private and used Opus 5 Extra. The downloaded archive was cleaned of an unrelated launcher file that was accidentally selected during file-picker navigation. It contains only the design pages, design-system bundle, and the two relevant RepoPrompt screenshots.

## Comparison

| Direction | Strongest outcome | Main cost | Best fit |
| --- | --- | --- | --- |
| Imagegen concept | Immediately communicates the global Settings versus per-agent Tools split in one polished frame | Too idealized for a state-complete specification; the generated MCP heading has a malformed first character | Executive/product overview |
| 2a — Quiet native extension | Closest to today's RepoPrompt rows, controls, density, and learning model | Authorization versus application is distinguished mostly by copy; a hurried user may still interpret Settings as runtime truth | Lowest-risk incremental implementation |
| 2b — Status rail | Gives authorization and per-tab application distinct visual structures; pending, blocked, and failed states are unmistakable without color alone | Introduces a new visual device that can expand into a cross-session dashboard if its scope is not kept strictly local | Per-agent runtime state and lifecycle emphasis |
| 2c — Progressive disclosure | Calmest default state; handles invalid, removed, collision, and source-error details without making the Codex card permanently tall | Exceptional states and their causes are one interaction deeper; disclosure summaries must remain honest and keyboard accessible | Global Settings discovery and authorization |

## Direct critique

### Imagegen

The concept correctly corrected its first structural draft: the MCP editor now lives inside the expanded Codex card, and the Agent Tools state remains in the existing popover. The generated text defect means it should be treated as a composition reference, not final UI copy or a pixel-perfect implementation target.

### 2a — Quiet native extension

This direction is visually conservative and likely cheapest to maintain. Its weakness is conceptual: the same ordinary row pattern carries source presence, saved authorization, and runtime-adjacent language. Copy can explain the difference, but the interface does not make the ownership boundary self-evident.

### 2b — Status rail

The rail is strongest in Agent Tools because every state belongs to one tab. It gives Current, pending, running-turn blocked, reconnect failed, and a different tab's different generation distinct non-color cues. The same rail is less valuable in global Settings, where it can imply a live application timeline that Settings does not own.

### 2c — Progressive disclosure

This is the strongest global editor. Ordinary names remain compact; invalid names, collisions, removed authorizations, and source errors expand only when relevant. The collapsed summary must never collapse distinct causes into a misleading single “ready” or “healthy” claim.

## Selected hybrid

Use a hybrid:

- **Global Settings:** 2c's progressive disclosure inside the existing Codex MCP subsection. The default view shows the source, saved authorization, draft changes, and concise exceptional summaries. It does not show per-agent state, counts, or a global rail.
- **Per-agent Tools:** a restrained form of 2b's status rail. It represents only the current tab's applied generation and runtime state. The rail appears for pending, refreshing, blocked, or failed states and recedes when the tab is current.
- **Overview communication:** use the clean focused exports under `../final/discord/` as the product-story sequence.

This hybrid gives the ownership split a structural cue exactly where it is truthful, without turning global Settings into a session dashboard.

## Remaining copy and protocol refinement

1. **Exceptional negative-state copy:** ordinary unchecked rows receive no redundant label. Plain-language labels are reserved for exceptional source/runtime states and must distinguish source-level `enabled = false` from authorization.
2. **Per-agent query details:** the final mockup uses the accepted compact privacy-safe summary plus bounded optional detail; exact wire names remain an implementation-design concern.

## Refinement result

The final prototype set follows the state matrix in `../artifacts/design-system.md` and includes:

- wide, medium, narrow, horizontal-split, and vertical-split layouts;
- Settings first review, saved, unsaved, new, removed, unsupported, reserved, collision, source-disabled, source-error, and externally changed states;
- per-tab not-started, current, pending, refreshing, and failed states;
- connected, starting, failed, unavailable, and not-present server rows;
- active-turn Stop/Cancel guidance and settled-idle Refresh behavior;
- keyboard focus, tooltip, icon, non-color, and responsive annotations;
- a final deterministic copy pass for exceptional source/runtime states and protocol-facing field names.

## Verification evidence

1. Each direction was inspected at 100% zoom against the real Settings and Agent Tools captures.
2. The Claude Design project was verified Private and owner-only before the Agent Mode screenshot was uploaded.
3. The project used Opus 5 Extra; Fable was not used.
4. Visible concepts and the cleaned archive contain server names and state text, but no commands, URLs, args, environment/header names, tokens, hashes, or raw definitions.
