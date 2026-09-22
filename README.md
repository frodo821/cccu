# cccu — Claude Code Computer Use

Claude Code plugin that drives Chrome and macOS apps through their **accessibility trees** instead of screenshots.

- `server/` — MCP server (TypeScript). Exposes `cu_*` tools.
- `ax_helpers/macos/` — Swift helper speaking the JSON-RPC protocol in `docs/PROTOCOL.md` over stdio.
- `docs/DESIGN.md` — architecture and milestones. `docs/PROTOCOL.md` — the helper contract.

## Build

```sh
(cd ax_helpers/macos && swift build -c release)
(cd server && bun install && bun run build)
```

## Test

```sh
(cd ax_helpers/macos && make test)    # Swift unit + binary integration tests (28 tests)
(cd server && bun run smoke)          # TypeScript client ↔ helper roundtrip
```

## Try the plugin

```sh
claude plugin validate .
claude --plugin-dir .                 # then: cu_status / cu_targets
```

Or talk to the helper by hand:

```sh
printf '%s\n' '{"id":1,"method":"sys.hello","params":{}}' '{"id":2,"method":"app.list"}' \
  | ax_helpers/macos/.build/release/cccu-helper
```

Accessibility permission must be granted to the app that launches Claude Code (Terminal, iTerm, VS Code, Claude Desktop). The helper inherits it as a child process.
