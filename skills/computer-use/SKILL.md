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

Working alongside the user
- For a run of actions on one app (filling a form, working through a page), bracket it with `cu_session begin target=<app> maxSeconds=<N>` and `cu_session end`. During the session the app stays in front and the user's keyboard and mouse are blocked, so their input cannot land in your target or move the cursor you are using. Declare a realistic maxSeconds (the session ends by itself after it; `cu_session extend` adds time) and always end the session when done, including after errors.
- Without a session, each real click or key press briefly activates the app, blocks user input for that instant, and returns focus. If a result carries `WARNING: ... user input ...`, the user was typing or moving the mouse at that moment: verify the result before continuing. `BUSY` means the user is actively using the machine; wait a few seconds and retry.
- The user can end a session at any time by pressing Escape three times; the next result tells you so.

Browser notes
- Two ways to work with Chrome. Check `cu_targets` first: its first line says whether a DevTools (CDP) Chrome is connected.
  - The user's normal Chrome shows up as an app (`app:<pid>`, bundle com.google.Chrome). Open your own tab first (`cu_key target=com.google.Chrome key=t modifiers=[cmd]`) instead of navigating the tab the user is looking at. Drive it through the accessibility tree: snapshots of a browser app are scoped to the page automatically; pass `scope: "app"` to `cu_snapshot` / `cu_find` / `cu_wait` when you need the tab strip, toolbar, address bar or menu bar; it leaves out the page content (or target the window, `window:<pid>:<n>`). To open a URL in your tab, `cu_navigate target=com.google.Chrome url=https://…` (it goes through the address bar of the current tab; `url: "back"`, `"forward"`, `"close"` and `"new"` also work). New tab: `cu_key target=com.google.Chrome key=t modifiers=[cmd]`; close your tab with `key=w` the same way when done. Logins are the user's own, so be careful with what you click.
  - A CDP Chrome (`tab:<id>` targets) gives faster snapshots, `cu_navigate`, dialogs, and console events, but always runs in a separate profile without the user's logins. `cu_browser launch` starts one; `cu_navigate` to a new tab does so automatically. Do not tell the user to restart their Chrome with a debugging port: Chrome 136+ ignores it on the default profile.
- CDP refs look like `b2/e5`. They die on navigation: after `cu_navigate` or a click that loads a page, take a new snapshot.
- `cu_set_value` handles selects (by option value or label), checkboxes and inputs with proper input/change events. `cu_key` supports cmd+A/C/V/X/Z in text fields.
- Content inside iframes (including cross-site ones) appears under the `iframe` node and can be acted on like anything else.

Reading pages
- Long text is cut at 80 characters. Pass `textLimit` (for example 400) to `cu_snapshot` / `cu_find` when you need to read a passage or an explanation.
- When the accessibility tree is unusable (empty webarea, canvas apps, remote desktops), fall back to vision: `cu_screenshot target=window:<pid>:<n> grid=100` overlays labelled screen-coordinate lines; read the target's coordinates off the image and `cu_click x=… y=…` (desktop). Verify with another screenshot or snapshot afterwards.
- Unnamed controls show `[at x,y wxh]` (screen coordinates). Take `cu_screenshot` of the window, map those coordinates onto the image (the screenshot result tells you the captured area and scale) and decide what the control does from its icon.
- Clicking scrolls off-screen elements into view automatically, including elements inside scrollable panels. If a click still reports success but nothing changed, click the same ref again (a smooth scroll that was still running can swallow the press), then verify.
- `cu_scroll` with a ref that is off-screen scrolls at its nearest visible ancestor instead (the result says so). Prefer a ref that is visible, such as the page or a visible heading.
- When `cu_wait` times out, the error includes the last tree it saw (without refs), so you can usually tell why without another snapshot.
- A real click fails with `OBSTRUCTED` when the point is covered by something else, typically a modal dialog or its backdrop; the error names the covering element and the dialog it belongs to. Snapshot again and act on the dialog (its buttons, or the dialog element itself when "click anywhere to continue"). Use `force: true` only when you know the cover is harmless.

Tips
- `enabled: true` on `cu_find` / `cu_wait` picks only enabled controls: the current question's 確認 button among many, or "wait until 次へ進む becomes enabled" (`cu_wait exists: {role: "button", text: "次へ進む", enabled: true}`).
- Do not batch clicks from one snapshot when a click can scroll or change the page; re-find right before each click.
- `cu_wait exists` with `count: N` waits until the N-th match appears (the N-th feedback block on a one-question-at-a-time page). `cu_find text=` also matches sentences that are split into several text nodes by formatting.
- Desktop actions (`cu_click`, `cu_type`, `cu_set_value`, `cu_action`; `cu_key` with `report: "diff"`) report what changed on the page right after the action: added and removed lines with fresh refs, the whole new tree when the change is large, or "no visible change". Read that instead of taking another snapshot; the refs in it are usable. Pass `report: "none"` when you batch many actions and will verify once at the end, and `reportWaitMs` (e.g. 3500) when the page reacts a few seconds after the action (audio playback unlocking the next item).
- `cu_query` takes a CSS-like selector when role/text alone is not enough: `group:has("正解は") button` (buttons inside the feedback block), `heading[name^=Q3] ~ group button:enabled` (the enabled button after heading Q3), `link[name$=スタート]`, `button[name*=確認]:enabled`. Use descendant combinators (space); the raw tree has anonymous group wrappers.
- `[offscreen]` on a control means it is outside the viewport; clicking it scrolls it into view first.
- Roles are lower-case AX roles without the prefix: `button`, `textfield`, `textarea`, `checkbox`, `popupbutton`, `menuitem`, `sheet`, `window`.
- `cu_type` with a ref focuses the element and inserts text at the caret through the accessibility API. `clear: true` replaces the content, `submit: true` presses Enter afterwards.
- Menu shortcuts: `cu_key` with `target` set, e.g. `key: "n", modifiers: ["cmd"]` for a new document. Shortcuts run through the app's menu in the background when possible; otherwise the app is brought to the front briefly. Without `target` the key goes to whatever app is in front, so always pass one.
- Checkboxes and sliders: `cu_set_value` writes the value directly. `cu_attributes` shows raw attributes and available actions when something does not behave.
- Sheets and dialogs appear as `sheet` children of the window; wait for them with `cu_wait exists: {role: "sheet"}`.

Events
- `cu_observe` on an app subscribes to accessibility notifications (window created, focus changed, sheet opened, menu opened, title changed). On a tab it subscribes to `navigated`, `loaded`, `dialogOpened`, `dialogClosed`, `consoleError`, `exception`, `tabCreated`, `tabDestroyed` (plus `domContentLoaded`, `console`, `tabInfoChanged` on request).
- `cu_events` returns and clears everything that arrived since the last call, across apps and tabs. Use it to notice dialogs, new windows or tabs, navigations, and page errors that happened as a side effect of an action, then snapshot to act on them. `cu_unobserve` when done.
- A JavaScript dialog (alert / confirm / prompt / beforeunload) blocks every other action on that tab. When an event or a hanging call suggests one is open, call `cu_dialog` to accept or dismiss it (with `promptText` for prompt()).

Screenshots
- `cu_screenshot` is supplementary: read UI through snapshots, and take a screenshot only to confirm visual state (layout, images, colors). Desktop capture needs Screen Recording permission; on `NOT_TRUSTED` with `permission: screenRecording`, tell the user and continue with snapshots.

Background operation
- Actions avoid leaving the app in front of the user. Accessibility presses, value changes, text insertion and menu shortcuts stay in the background; real keys, `submit: true` typing, clicks on web content and scrolling activate the app for a moment and then return focus (`...+restore`). Each action reports the path it took (`ax`, `menu`, `keys+restore`, `cg+restore`, ...).
- Keep the flicker low: batch text with `cu_type` instead of sending keys one by one, and use `submit: true` rather than a separate Enter.
- Real clicks and scrolls move the cursor like a hand (Fitts's-law timing, slight curve, landing near the centre) and leave it there; a click costs roughly 0.3 to 1 second. Pass `pointer: "warp"` only when speed matters more than realism (for example on your own test pages).
- Some things only work when the app is active (formatting toggles, anything that acts on the key window). After an action, check the result (snapshot / `cu_find` / `cu_wait`). If nothing changed, repeat the same action with `foreground: true`: it activates the app briefly, acts, and gives focus back.
- Prefer elements over keystrokes when both exist: a window's `closebutton`, a sheet's buttons and menu items work in the background; cmd+W needs a brief activation.
- `cu_type` without a ref types into whatever currently has keyboard focus, which is the user's app, not your target. In the background always pass a ref.
- Only use `cu_activate` when the user asked to see the app or a screenshot needs the window on top.

Rules
- Never guess refs. If an element is missing from the snapshot, snapshot again or `cu_find` it.
- If a tool returns `NOT_TRUSTED`, tell the user to allow "cccu-helper" in System Settings > Privacy & Security (Accessibility, or Screen Recording for desktop screenshots). No restart is needed; retry the tool once they have done it.
- Do not perform irreversible actions (send, delete, purchase, save over a file) without confirming with the user first.
- Button titles follow the system language (e.g. 削除 vs Delete); read them from the snapshot rather than assuming English.
