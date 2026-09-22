# cccu — Claude Code Computer Use

Claude Code plugin that drives Chrome and macOS apps through their **accessibility trees** instead of screenshots.

- `server/` — MCP server (TypeScript). Exposes `cu_*` tools.
- `ax_helpers/macos/` — Swift helper speaking the JSON-RPC protocol in `docs/PROTOCOL.md` over stdio.
- `docs/DESIGN.md` — architecture and milestones. `docs/PROTOCOL.md` — the helper contract.

## Platform support

macOS only for now. `bin/cccu-platform` reports `macos` / `linux` / `windows` / `unknown`; the installer, the MCP
launcher, and the server refuse anything but macOS with a clear message. The helper protocol is platform-neutral, so
Linux (AT-SPI) and Windows (UIA) helpers can be added under `ax_helpers/` later.

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

## Prebuilt helper (no Xcode needed)

Tags `v*` trigger `.github/workflows/release.yml`, which builds a universal `cccu-helper.app` on a macOS runner, signs
it, attaches a build-provenance attestation, and uploads `cccu-helper-<version>-macos-universal.tar.gz` to the GitHub
Release. The launcher uses it when `swift` is not installed (or when `CCCU_PREBUILT=1`): `bin/cccu-fetch-helper`
downloads the archive for the plugin version and refuses to install it unless `gh attestation verify --repo frodo821/cccu`
passes (needs the `gh` CLI; `CCCU_PREBUILT_UNVERIFIED=1` overrides, not recommended).

Signing in CI uses these repository secrets; without them the build is ad-hoc signed (Accessibility works, desktop
screenshots do not on macOS 15+):

| secret | content |
|---|---|
| `DEVELOPER_ID_P12` | base64 of a **Developer ID Application** certificate + private key exported as .p12 |
| `DEVELOPER_ID_P12_PASSWORD` | the .p12 password |
| `NOTARY_KEY_P8`, `NOTARY_KEY_ID`, `NOTARY_KEY_ISSUER` | optional: App Store Connect API key for notarization |

`scripts/package-helper.sh [version]` is the same script the workflow runs; it works locally too (output in `dist/`).

`scripts/setup-ci-signing.sh` fills those secrets: `create` makes a Developer ID Application certificate through the
App Store Connect API (`ASC_KEY_ID`, `ASC_ISSUER`, `ASC_KEY_PATH`), builds the .p12 and imports it into your login
keychain; `export "<identity name>"` uses an identity already in your keychain; `notary` registers the API key for
notarization. Notarization only runs when the build is signed with a Developer ID identity.

## Releasing

`claude plugin update` only picks up a new version number, so every release needs a bump:

```sh
bin/cccu bump 0.3.0        # sets version in plugin.json, package.json, marketplace.json
git commit -am "Release 0.3.0" && git tag v0.3.0 && git push && git push --tags   # the tag builds the prebuilt helper
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
  | ax_helpers/macos/.build/release/cccu-helper.app/Contents/MacOS/cccu-helper
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

## Permissions

The helper makes itself the responsible process for macOS privacy permissions, so they are granted to **cccu-helper**
itself, once, and apply no matter which app launches Claude Code (Terminal, iTerm, VS Code, Claude Desktop):

- **Accessibility** (required): the first tool call shows the system prompt; allow "cccu-helper".
- **Screen Recording** (only for `cu_screenshot` on the desktop): allow "cccu-helper" under
  System Settings > Privacy & Security > Screen Recording.

`bin/cccu install` and `bin/cccu update` request both permissions at the end (`bin/cccu permissions` re-runs that
step). The request is made by an instance of the helper launched through LaunchServices (`open -a`), because macOS
only shows the Screen Recording prompt, and creates the System Settings entry, for apps launched that way; once
granted, the normally spawned helper passes the check too. No terminal restart is needed after granting: the helper
restarts itself and retries. `cu_status` shows both states.

The helper is packaged as `cccu-helper.app` and signed by `bin/cccu-sign`, which picks the best identity available:

1. `CCCU_SIGN_IDENTITY` if set;
2. an Apple-issued certificate in your keychain (`Developer ID Application` or `Apple Development`; the free personal team
   you get by signing into Xcode is enough). **macOS 15+ only grants Screen Recording to binaries signed with an
   Apple certificate carrying a Team ID**, so this is what makes `cu_screenshot` work on the desktop;
3. otherwise a self-signed certificate `cccu-helper` created once in your login keychain (macOS may ask for your
   password to trust it). Accessibility works with it, desktop screenshots do not.

Either way the identity is stable, so permissions survive rebuilds and updates. An ad-hoc signature would be keyed by
the build hash instead, which is what causes duplicate "cccu-helper" entries in System Settings after every rebuild;
delete such stale entries if you see them.
