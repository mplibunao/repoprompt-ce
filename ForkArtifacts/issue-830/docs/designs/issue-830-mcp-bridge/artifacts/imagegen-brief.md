# Imagegen brief — issue #830 MCP bridge

Create a high-fidelity dark macOS product UI concept sheet grounded in the supplied real RepoPrompt CE screenshots. Preserve the current native shell, typography scale, charcoal surfaces, orange composer accent, card density, existing Codex Settings card, and existing Tools popover.

Show two large panels side by side:

1. **CLI Providers → Codex Settings**. Extend the existing MCP area with a compact section titled “MCP servers from your Codex config.” Show a read-only source line for `~/.codex/config.toml`, a Refresh control, three rows (`github`, `slack`, `legacy.server`), checkboxes for saved authorization, a small “New” label on `github`, an “Unsupported name” label on `legacy.server`, and quiet Save Selection / Discard actions. Do not show per-agent Ready/current status here.
2. **Agent Mode Tools popover**. Preserve the existing popover. Expand its MCP Servers group with “Update pending,” rows for `slack — Connected — Pending` and `github — Not present`, plus a compact “Refresh servers” action. Add a small non-color-only attention badge to the existing Tools button.

Use concise legible text. Use icons and words together; color is secondary. No gradients, analytics dashboard, session counts, second MCP editor, commands, URLs, arguments, environment values, headers, tokens, or credentials. The concept should look like an incremental RepoPrompt CE feature, not a redesign.
