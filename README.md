# cccu — Claude Code Computer Use

Claude Code plugin that drives Chrome and macOS apps through their **accessibility trees** instead of screenshots.

- `server/` — MCP server (TypeScript). Exposes `cu_*` tools.
- `ax_helpers/macos/` — Swift helper speaking the JSON-RPC protocol in `docs/PROTOCOL.md` over stdio.
- `docs/DESIGN.md` — architecture and milestones. `docs/PROTOCOL.md` — the helper contract.

## Install

```sh
claude plugin marketplace add frodo821/cccu
claude plugin install cccu@cccu
```

Or, from a checkout: `make install` (from GitHub) / `make install-local` (this directory). Update with
`make update` (`claude plugin marketplace update cccu && claude plugin update cccu@cccu`), remove with `make uninstall`,
inspect with `make status`. Restart Claude Code after installing or updating.

Requirements on the machine: `swift` (Xcode Command Line Tools), `bun`, `node` 22+. The helper and server bundle are
built on the first tool call.

`make install-local` copies the whole checkout (including `node_modules` and `.build`) into the plugin cache; run
`make clean` first if you want a lean copy.

## Releasing

`claude plugin update` only picks up a new version number, so every release needs a bump:

```sh
bin/cccu bump 0.2.0        # sets version in plugin.json, package.json, marketplace.json
git commit -am "Release 0.2.0" && git push
```

Users then run `make update` (or `claude plugin marketplace update cccu && claude plugin update cccu@cccu`).

## Build (development)

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
- UI events (`cu_observe` / `cu_events`): AXObserver notifications for desktop apps, and navigation / load / dialog / console / exception / tab events for Chrome tabs — done
- JavaScript dialogs (`cu_dialog`): accept or dismiss alert / confirm / prompt — done
- iframes in browser snapshots: same-process frames and out-of-process (cross-site) frames are included and clickable — done

## Browsers: two ways

**Your normal Chrome (no setup).** Chrome exposes page content in the macOS accessibility tree, so the desktop backend
can read and drive it like any other app, with your logins intact: `cu_targets` → `app:<pid>` of Chrome →
`cu_find role=webarea` → `cu_snapshot within=<that ref>` → `cu_click` / `cu_type`. Navigate by typing a URL into the
address bar with `submit: true`. Refs are AX elements and survive scrolling; iframes are included. This is the default
way to work with the browser you are already using.

**A dedicated Chrome over DevTools (CDP).** Faster snapshots, JavaScript dialogs, console/exception events, per-tab
targets (`tab:<id>`, snapshot ids prefixed `b`). Chrome 136+ refuses a DevTools port on the default profile, so this
always runs a separate profile: `cu_browser launch` starts it (`~/.cccu-chrome`, override with `CCCU_CHROME_PROFILE`),
or start it yourself:

```sh
open -na "Google Chrome" --args --remote-debugging-port=9222 --user-data-dir="$HOME/.cccu-chrome"
```

`cu_navigate` to a new tab launches it automatically when nothing is connected. Endpoint: `CCCU_CDP_URL`
(default `http://127.0.0.1:9222`). `cu_browser status` explains the current state either way.

Accessibility permission must be granted to the app that launches Claude Code (Terminal, iTerm, VS Code, Claude Desktop). The helper inherits it as a child process.
