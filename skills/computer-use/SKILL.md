---
name: computer-use
description: Operate macOS apps and Chrome through their accessibility trees using the cu_* tools. Use when asked to click, type, read, or automate something in a desktop app or browser.
---

# Computer use via accessibility tree

Workflow (always in this order):
1. `cu_targets` to find the app or tab. Use `cu_activate` if it must be frontmost.
2. `cu_snapshot` on the target to read the accessibility tree. Elements you can act on carry `[ref=eN]`.
3. Act with `cu_click` / `cu_type` / `cu_key` / `cu_set_value` using `"<snapshotId>/<ref>"` (e.g. `s3/e12`).
4. Re-snapshot after any action that changes the UI. Refs from an old snapshot fail with `STALE_REF`.

Rules
- Prefer `cu_find` over a full snapshot on large windows (Electron apps, big web pages).
- Never guess refs. If an element is missing from the snapshot, snapshot again or find it.
- If a tool returns `NOT_TRUSTED`, tell the user to grant Accessibility permission to the app hosting Claude Code (Terminal, iTerm, VS Code, ...) and stop.
- Do not perform irreversible actions (send, delete, purchase) without confirming with the user first.

Status: v0.1 provides `cu_status`, `cu_targets`, `cu_activate`. Snapshot and actions are being implemented (see docs/DESIGN.md milestones).
