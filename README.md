# cccu — Claude Code Computer Use

Claude Code plugin that drives Chrome and macOS apps through their **accessibility trees** instead of screenshots.

- `server/` — MCP server (TypeScript). Exposes `cu_*` tools.
- `ax_helpers/macos/` — Swift helper speaking the JSON-RPC protocol in `docs/PROTOCOL.md` over stdio.
- `docs/DESIGN.md` — architecture and milestones. `docs/PROTOCOL.md` — the helper contract.

## Build

```sh
make setup            # swift build + bun install + bundle
```

The MCP entry point `bin/cccu-server` also builds anything missing on first start, so `claude --plugin-dir .`
works on a fresh checkout as long as `swift`, `bun` and `node` are installed.

## Test

```sh
(cd ax_helpers/macos && make test)    # Swift unit + binary integration tests (no UI touched)
(cd ax_helpers/macos && make e2e)     # drives TextEdit for real (types, closes without saving)
(cd server && bun run smoke)          # TypeScript client ↔ helper roundtrip
(cd server && bun test)               # browser backend against headless Chrome (temp profile)
```

## Try the plugin

```sh
claude plugin validate .
claude --plugin-dir .                 # then: cu_targets → cu_snapshot → cu_click / cu_type …
```

Or talk to the helper by hand:

```sh
printf '%s\n' '{"id":1,"method":"sys.hello","params":{}}' '{"id":2,"method":"app.list"}' \
  | ax_helpers/macos/.build/release/cccu-helper
```

## Status

- macOS desktop: snapshot, find, click, type, keys, scroll, set value, wait — done (milestone 2)
- Chrome via CDP: tabs, navigate, snapshot, find, click, type, keys, set value, wait — done (milestone 3)
- Screenshot (`cu_screenshot`): windows, apps, display, tabs — done (desktop needs Screen Recording permission)
- UI events (`cu_observe` / `cu_events`): AXObserver notifications for desktop apps — done
- iframes in browser snapshots: same-process frames and out-of-process (cross-site) frames are included and clickable — done

## Browser setup

The browser backend attaches to a running Chrome through the DevTools protocol. Start Chrome with a debugging port
(a separate profile keeps your normal session untouched):

```sh
open -na "Google Chrome" --args --remote-debugging-port=9222 --user-data-dir="$HOME/.cccu-chrome"
```

Override the endpoint with `CCCU_CDP_URL` (default `http://127.0.0.1:9222`). Tabs appear in `cu_targets` as `tab:<id>`
and use snapshot ids prefixed with `b` (desktop snapshots use `s`).

Accessibility permission must be granted to the app that launches Claude Code (Terminal, iTerm, VS Code, Claude Desktop). The helper inherits it as a child process.
