# Claude Design brief — issue #830 MCP bridge

Use **Claude Design with Opus 5 and Extra reasoning**. Do not use Fable. Use the UI Mockups template in a private, owner-only project. The supplied RepoPrompt CE screenshots are the visual source of truth; do not apply company templates or external branding.

## Goal

Design an incremental native macOS workflow for choosing which MCP servers from `~/.codex/config.toml` RepoPrompt may make available to native Codex agents, while honestly showing that individual agent tabs can run different saved generations.

## Fixed product boundaries

- CLI Providers → Codex is the only global editor. It shows source discovery and saved authorization, never per-agent Ready/application claims or cross-session counts.
- Tools → MCP Servers in each Agent Mode tab shows that tab's exact application and runtime state.
- New names default off. Exact case-preserved names and semantic definition revisions are tracked separately. Every definition edit must synchronize; whether it also requires reauthorization is an open product choice that the alternatives may compare, not assume.
- An active turn and its steers keep the old generation. If the user needs a new MCP immediately, they stop/cancel, wait for settlement, then send a new message in the same session.
- Lazy refresh occurs before the next idle new turn. A per-agent Refresh action is available only at settled idle; reconnect is the safe mechanism.
- Never reveal commands, URLs, args, environment values, headers, tokens, or full definitions.
- Use text plus icons/shapes for every state; color alone is insufficient.

## First deliverable: three compact alternatives

Create three named directions with one Settings frame and one Agent Tools frame each. State the product tradeoff of each:

1. **Quiet native extension** — closest to today's row patterns and density.
2. **Status rail** — a restrained section-level visual rail distinguishes global authorization from per-agent application.
3. **Progressive disclosure** — the default view stays minimal; exceptional/source states and runtime detail expand on demand.

All three must preserve the real shell and avoid dashboards, duplicate editors, and global session aggregates. Critique the earlier ideas of green “Ready” on every Settings row and one global “Agent Mode will resume after the current turn” banner: those claims are misleading when twenty agents can use different generations and active steers must remain on the old generation.

## Refinement deliverable

Recommend one direction, but do not treat the recommendation as MP's decision. Produce a designer-grade responsive prototype/storyboard with:

- a state model;
- source/authorization/application ownership diagram;
- message-semantics flow;
- first review, saved, unsaved, new, removed, invalid, collision, source-error, mixed-generation, pending, refreshing, and failed states;
- per-agent connected, starting, failed, unavailable, and not-present rows;
- active-turn Stop/Cancel guidance;
- Refresh available/blocked/failed;
- wide, medium, narrow, horizontal-split, and vertical-split layouts;
- keyboard focus, tooltip, icon, copy, and accessibility annotations.

Keep server definitions and credentials out of all visible artifacts and annotations.
