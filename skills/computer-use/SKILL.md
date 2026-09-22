---
name: computer-use
description: Operate macOS apps and Chrome tabs through their accessibility trees using the cu_* tools. Use when asked to click, type, read, navigate, or automate something in a desktop app or a web page.
---

# Computer use via accessibility tree

Workflow (always in this order):
1. `cu_targets` to find the app (`app:<pid>`), window (`window:<pid>:<n>`) or Chrome tab (`tab:<id>`). A bundle id such as `com.apple.TextEdit` also works as a target and launches the app if needed. `cu_navigate` with `target: "new"` opens a fresh tab.
2. `cu_snapshot` on the target to read the accessibility tree. Actionable elements carry `[ref=eN]`. On big apps prefer `cu_find` with a role and/or text.
3. Act with `cu_click` / `cu_type` / `cu_key` / `cu_set_value` / `cu_action`, passing refs as `"<snapshot>/<ref>"` (e.g. `s3/e12`).
4. After any action that changes the UI, take a new snapshot or use `cu_wait` (`exists` / `gone` / `stableMs`). Refs from an old snapshot fail with `STALE_REF`.

Browser notes
- Chrome must run with `--remote-debugging-port=9222`; if `cu_targets` reports no DevTools endpoint, show the user the command from the README instead of trying to launch Chrome yourself.
- Browser refs look like `b2/e5`. They die on navigation: after `cu_navigate` or a click that loads a page, take a new snapshot.
- `cu_set_value` handles selects (by option value or label), checkboxes and inputs with proper input/change events. `cu_key` supports cmd+A/C/V/X/Z in text fields.
- Content inside iframes is not part of the snapshot yet.

Tips
- Roles are lower-case AX roles without the prefix: `button`, `textfield`, `textarea`, `checkbox`, `popupbutton`, `menuitem`, `sheet`, `window`.
- `cu_type` with a ref focuses the element and inserts text at the caret through the accessibility API. `clear: true` replaces the content, `submit: true` presses Enter afterwards.
- Menu shortcuts: `cu_key` with `target` set, e.g. `key: "n", modifiers: ["cmd"]` for a new document. The app is brought to the front first.
- Checkboxes and sliders: `cu_set_value` writes the value directly. `cu_attributes` shows raw attributes and available actions when something does not behave.
- Sheets and dialogs appear as `sheet` children of the window; wait for them with `cu_wait exists: {role: "sheet"}`.

Rules
- Never guess refs. If an element is missing from the snapshot, snapshot again or `cu_find` it.
- If a tool returns `NOT_TRUSTED`, tell the user to grant Accessibility permission to the app hosting Claude Code (Terminal, iTerm, VS Code, ...) and stop.
- Do not perform irreversible actions (send, delete, purchase, save over a file) without confirming with the user first.
- Button titles follow the system language (e.g. 削除 vs Delete); read them from the snapshot rather than assuming English.
