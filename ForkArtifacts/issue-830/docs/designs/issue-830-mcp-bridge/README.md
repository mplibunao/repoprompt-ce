# Issue #830 MCP bridge visual-design packet

Status: The hybrid direction and bounded design critiques are complete. The corrected six-image packet passes visual-fidelity review and guides product work. Packaged-runtime captures remain the pull-request acceptance evidence. No product integration code has been written.

## Product evidence

- [`artifacts/design-system.md`](artifacts/design-system.md) covers state ownership, lifecycle semantics, responsive behavior, accessibility, copy, and the complete state matrix.
- [`artifacts/imagegen-brief.md`](artifacts/imagegen-brief.md): grounded image-generation direction.
- [`artifacts/claude-design-brief.md`](artifacts/claude-design-brief.md): Opus comparison brief.

## Real UI baselines

The `baseline/` directory contains current RepoPrompt CE Debug captures for Settings and Agent Mode. `agent-tools-single-pane.png` is the valid narrow-layout baseline.

## Claude Design

- [`claude-design/comparison.md`](claude-design/comparison.md): direct comparison and advisory hybrid recommendation.
- `claude-design/mcp-bridge-final-hybrid-project.zip`: editable source for the three alternatives and final hybrid, with the relevant baselines and design-system assets.

The Claude Design project is private to its owner and used Opus 5 Extra.

## Current decision gate

The selected visual direction is 2c progressive disclosure for global Settings plus a restrained 2b rail for each Agent Tools popover. The design system covers the ownership model, message lifecycle, twelve Settings states, eight per-tab Tools states, seven server-row states, five responsive layouts, accessibility annotations, a privacy-bounded orchestrator summary, and an exact copy inventory. The focused six-image packet demonstrates that coverage at passing design fidelity.

Discord-sized review sequence:

- [`final/discord/README.md`](final/discord/README.md): local review order for the six PNG exports.
- [`final/discord/01-settings-normal-flow.png`](final/discord/01-settings-normal-flow.png): ordinary Settings workflow.
- [`final/discord/02-settings-name-exceptions.png`](final/discord/02-settings-name-exceptions.png): authorization and name exceptions.
- [`final/discord/03-settings-source-failures.png`](final/discord/03-settings-source-failures.png): source-level failure states.
- [`final/discord/04-agent-lifecycle-current-and-pending.png`](final/discord/04-agent-lifecycle-current-and-pending.png): first four per-tab lifecycle states.
- [`final/discord/05-agent-lifecycle-failure-and-active-turn.png`](final/discord/05-agent-lifecycle-failure-and-active-turn.png): binding and optional-server failures, active-turn blocking, and settled-idle refresh.
- [`final/discord/06-agent-separate-conversations-and-server-rows.png`](final/discord/06-agent-separate-conversations-and-server-rows.png): complete mixed-generation conversation frames and server-row catalog.
- [`final/qa.md`](final/qa.md): current fidelity status and remaining copy-review items, backed by direct visual evidence.

## Cleanup requiring approval

An unrelated, non-secret `Launch RepoPrompt CE.command` launcher was uploaded to the private Claude Design project during file-picker navigation. The downloaded editable archive includes it. Deleting the remote project asset still requires user approval and doesn't block local design work; keep the archive private.
