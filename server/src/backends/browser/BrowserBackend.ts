import type { Backend, SnapshotOptions, TargetInfo, UIEvent, WaitCondition } from "../../core/backend.js";
import { CDPConnection, discover } from "../../core/cdp.js";
import { HelperError, type FindQuery, type Modifier, type Ref, type SnapshotResult } from "../../core/protocol.js";
import { buildTree, collapse, markMatches, matcher, prune, render, type AXNode, type CDPAXNode, type RefTarget } from "./axtree.js";
import { describeKey, editingCommands, modifierBits } from "./keys.js";
import { spawn } from "node:child_process";
import { existsSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

/** CDP セッション。page (トップ) と OOPIF (プロセス外 iframe) の 2 種 */
interface Session { targetId: string; sessionId: string; kind: "page" | "iframe"; page: Session; ready: Promise<void> }

/**
 * フレーム。同一プロセスの iframe はトップと同じセッションで frameId 指定、OOPIF は専用セッション。
 * owner はこのフレームを埋め込む <iframe> 要素 (親フレーム側)。
 */
interface Frame { session: Session; frameId?: string; owner?: { frame: Frame; backendNodeId: number } }
interface ElementRef { backendNodeId: number; frame: Frame }
interface Snapshot { targetId: string; refs: Map<string, ElementRef> }

const DEFAULT_CDP = "http://127.0.0.1:9222";
const KEEP_SNAPSHOTS = 8;
const MAX_EVENTS = 200;

/** ブラウザで購読できるイベント名 (cu_observe の notifications) */
export const BROWSER_NOTIFICATIONS = [
  "navigated", "loaded", "domContentLoaded", "dialogOpened", "dialogClosed",
  "consoleError", "console", "exception", "tabCreated", "tabDestroyed", "tabInfoChanged",
] as const;
export const DEFAULT_BROWSER_NOTIFICATIONS = [
  "navigated", "loaded", "dialogOpened", "dialogClosed", "consoleError", "exception", "tabCreated", "tabDestroyed",
];

interface BrowserSubscription { id: string; targetId: string; notifications: Set<string>; off: (() => void)[] }
export interface OpenDialog { type: string; message: string; defaultPrompt?: string }

export interface BrowserStatus {
  endpoint: string;
  connected: boolean;
  browser?: string;          // "Chrome/153.0.8010.53"
  tabs?: number;
  profile?: string;          // launch で使う専用プロファイル
  chromeRunningWithoutPort?: boolean;
  error?: string;
  hint?: string;
}

const CHROME_CANDIDATES = [
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  join(homedir(), "Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
  "/Applications/Chromium.app/Contents/MacOS/Chromium",
];

/**
 * Chrome を CDP で操作する backend。target は "tab:<targetId>"、snapshot id は "b<N>"。
 * ref は (frame, backendDOMNodeId) に対応する (ページ遷移で無効になる → STALE_REF)。
 */
export class BrowserBackend implements Backend {
  readonly kind = "browser" as const;
  private conn: CDPConnection | null = null;
  private sessions = new Map<string, Session>();        // targetId → page session
  private frameSessions = new Map<string, Session>();   // OOPIF の frameId (= targetId) → session
  private snapshots = new Map<string, Snapshot>();
  private snapshotCounter = 0;
  private subscriptions = new Map<string, BrowserSubscription>();
  private subscriptionCounter = 0;
  private eventBuffer: UIEvent[] = [];
  private openDialogs = new Map<string, OpenDialog>();   // targetId → 開いている JS ダイアログ
  private targetsDiscovered = false;
  private readonly cdpUrl: string;
  private readonly profileDir: string;
  private readonly activateApp?: () => Promise<void>;
  /** 通常の Chrome (デバッグポート無し) が動いているかを外から教えてもらう */
  private readonly isChromeRunning?: () => Promise<boolean>;

  constructor(opts: { cdpUrl?: string; profileDir?: string; activateApp?: () => Promise<void>; isChromeRunning?: () => Promise<boolean> } = {}) {
    this.cdpUrl = opts.cdpUrl ?? process.env.CCCU_CDP_URL ?? DEFAULT_CDP;
    this.profileDir = opts.profileDir ?? process.env.CCCU_CHROME_PROFILE ?? join(homedir(), ".cccu-chrome");
    this.activateApp = opts.activateApp;
    this.isChromeRunning = opts.isChromeRunning;
  }

  // MARK: 接続状態と起動

  async status(): Promise<BrowserStatus> {
    const st: BrowserStatus = { endpoint: this.cdpUrl, connected: false, profile: this.profileDir };
    try {
      const { targets } = await discover(this.cdpUrl);
      const v = await (await fetch(`${this.cdpUrl.replace(/\/$/, "")}/json/version`)).json() as { Browser?: string };
      st.connected = true;
      st.browser = v.Browser;
      st.tabs = targets.filter((t) => t.type === "page").length;
      return st;
    } catch (e) {
      st.error = e instanceof HelperError ? e.message : String(e);
    }
    st.chromeRunningWithoutPort = (await this.isChromeRunning?.().catch(() => false)) ?? false;
    st.hint = st.chromeRunningWithoutPort
      ? `Your Chrome is running without a DevTools port (Chrome 136+ refuses one on the default profile). You can still drive it through the accessibility tree: use its app:<pid> target with cu_find role=webarea / cu_snapshot within=<webarea ref>. For CDP, call cu_browser launch to start a separate Chrome (profile ${this.profileDir}, logins not shared).`
      : `No Chrome with a DevTools port. Call cu_browser launch to start one (profile ${this.profileDir}), or drive a normally started Chrome through its app:<pid> target (accessibility tree).`;
    return st;
  }

  /** 1 行の状態表示 (cu_targets / cu_status 用) */
  async statusLine(): Promise<string> {
    const st = await this.status();
    if (st.connected) return `browser: connected to ${st.browser ?? "Chrome"} at ${st.endpoint} (${st.tabs} tab${st.tabs === 1 ? "" : "s"})`;
    return `browser: NOT connected (${st.endpoint}). ${st.hint}`;
  }

  private port(): number {
    try { return Number(new URL(this.cdpUrl).port) || 9222; } catch { return 9222; }
  }

  /** 専用プロファイルで Chrome を起動し、CDP に繋がるまで待つ。既に繋がっていれば何もしない */
  async launch(opts: { headless?: boolean; url?: string; timeoutMs?: number } = {}): Promise<BrowserStatus> {
    const before = await this.status();
    if (before.connected) return before;
    const bin = (process.env.CCCU_CHROME_BINARY ? [process.env.CCCU_CHROME_BINARY] : []).concat(CHROME_CANDIDATES).find(existsSync);
    if (!bin) throw new HelperError("NOT_FOUND", "Google Chrome not found in /Applications (set CCCU_CHROME_BINARY)");
    mkdirSync(this.profileDir, { recursive: true });
    const args = [
      `--remote-debugging-port=${this.port()}`, `--user-data-dir=${this.profileDir}`,
      "--no-first-run", "--no-default-browser-check",
      ...(opts.headless ? ["--headless=new"] : []),
      opts.url ?? "about:blank",
    ];
    const child = spawn(bin, args, { detached: true, stdio: "ignore" });
    child.unref();
    const deadline = Date.now() + (opts.timeoutMs ?? 15000);
    while (Date.now() < deadline) {
      await sleep(200);
      const st = await this.status();
      if (st.connected) return st;
    }
    throw new HelperError("TIMEOUT", `Chrome did not expose DevTools on ${this.cdpUrl} within ${opts.timeoutMs ?? 15000}ms`);
  }

  ownsTarget(t: string) { return t.startsWith("tab:") || t === "tab" || t === "browser"; }
  ownsSnapshot(id: string) { return id.startsWith("b"); }

  // MARK: 接続とセッション

  private async connection(): Promise<CDPConnection> {
    if (this.conn?.isOpen) return this.conn;
    const { browserWs } = await discover(this.cdpUrl);
    const conn = await CDPConnection.connect(browserWs);
    this.conn = conn;
    this.sessions.clear();
    this.frameSessions.clear();
    this.subscriptions.clear();
    this.openDialogs.clear();
    this.targetsDiscovered = false;
    conn.on("Page.javascriptDialogOpening", (p, sid) => {
      const t = this.targetIdForSession(sid); if (t) this.openDialogs.set(t, { type: p.type, message: p.message, defaultPrompt: p.defaultPrompt });
    });
    conn.on("Page.javascriptDialogClosed", (_p, sid) => {
      const t = this.targetIdForSession(sid); if (t) this.openDialogs.delete(t);
    });
    conn.on("Target.detachedFromTarget", (p) => {
      for (const [k, s] of this.sessions) if (s.sessionId === p.sessionId) this.sessions.delete(k);
      for (const [k, s] of this.frameSessions) if (s.sessionId === p.sessionId) this.frameSessions.delete(k);
    });
    // OOPIF が自動アタッチされたら専用セッションとして登録する
    conn.on("Target.attachedToTarget", (p, parentSessionId) => {
      if (p.targetInfo?.type !== "iframe") return;
      const page = [...this.sessions.values()].find((s) => s.sessionId === parentSessionId)
        ?? [...this.frameSessions.values()].find((s) => s.sessionId === parentSessionId)?.page;
      if (!page) return;
      const s: Session = { targetId: p.targetInfo.targetId, sessionId: p.sessionId, kind: "iframe", page, ready: Promise.resolve() };
      s.ready = (async () => {
        await conn.send("DOM.enable", {}, s.sessionId);
        await conn.send("Accessibility.enable", {}, s.sessionId);
        await conn.send("Target.setAutoAttach", { autoAttach: true, waitForDebuggerOnStart: false, flatten: true }, s.sessionId).catch(() => {});
      })().catch(() => {});
      this.frameSessions.set(s.targetId, s);
    });
    return conn;
  }

  private targetIdForSession(sessionId?: string): string | undefined {
    for (const s of this.sessions.values()) if (s.sessionId === sessionId) return s.targetId;
    return undefined;
  }

  private targetIdOf(target: string): string {
    const m = /^tab:(.+)$/.exec(target);
    if (!m) throw new HelperError("INVALID_PARAMS", `browser target must be tab:<id>, got ${target}`);
    return m[1];
  }

  private async session(targetId: string): Promise<Session> {
    const conn = await this.connection();
    const existing = this.sessions.get(targetId);
    if (existing) return existing;
    let r: { sessionId: string };
    try {
      r = await conn.send("Target.attachToTarget", { targetId, flatten: true });
    } catch (e) {
      throw new HelperError("NOT_FOUND", `tab ${targetId} not found (${(e as Error).message})`);
    }
    const s = { targetId, sessionId: r.sessionId, kind: "page" } as Session;
    s.page = s;
    s.ready = Promise.resolve();
    this.sessions.set(targetId, s);
    await conn.send("Page.enable", {}, s.sessionId);
    await conn.send("DOM.enable", {}, s.sessionId);
    await conn.send("Accessibility.enable", {}, s.sessionId);
    await conn.send("Target.setAutoAttach", { autoAttach: true, waitForDebuggerOnStart: false, flatten: true }, s.sessionId);
    return s;
  }

  private async send<T = any>(s: Session, method: string, params: Record<string, unknown> = {}): Promise<T> {
    return (await this.connection()).send<T>(method, params, s.sessionId);
  }

  // MARK: Backend

  async listTargets(): Promise<TargetInfo[]> {
    const { targets } = await discover(this.cdpUrl);
    return targets.filter((t) => t.type === "page").map((t) => ({
      id: `tab:${t.id}`, kind: "tab", title: t.title, url: t.url, focused: false,
    }));
  }

  async activate(target: string): Promise<string> {
    const conn = await this.connection();
    await conn.send("Target.activateTarget", { targetId: this.targetIdOf(target) });
    await this.activateApp?.();
    return `activated ${target}`;
  }

  /** ブラウザ固有: URL を開く / 履歴移動 / 新規タブ */
  async navigate(target: string | undefined, url: string): Promise<string> {
    if ((!target || target === "new") && !(await this.status()).connected) await this.launch();   // 新規タブなら自動起動
    const conn = await this.connection();
    let targetId: string;
    if (!target || target === "new") {
      const r = await conn.send("Target.createTarget", { url: "about:blank" });
      targetId = r.targetId;
    } else {
      targetId = this.targetIdOf(target);
    }
    if (url === "close") {
      await conn.send("Target.closeTarget", { targetId });
      this.sessions.delete(targetId);
      return `closed tab:${targetId}`;
    }
    const s = await this.session(targetId);
    if (url === "back" || url === "forward") {
      const { currentIndex, entries } = await this.send(s, "Page.getNavigationHistory");
      const idx = currentIndex + (url === "back" ? -1 : 1);
      if (!entries[idx]) throw new HelperError("NOT_FOUND", `no history entry to go ${url}`);
      await this.send(s, "Page.navigateToHistoryEntry", { entryId: entries[idx].id });
    } else {
      const r = await this.send(s, "Page.navigate", { url });
      if (r.errorText) throw new HelperError("NOT_FOUND", `navigation failed: ${r.errorText}`);
    }
    try { await conn.once("Page.loadEventFired", 15000, (_p, sid) => sid === s.sessionId); } catch { /* SPA など */ }
    const { title, url: finalUrl } = await this.pageInfo(s);
    return `tab:${targetId}\t"${title}"\t${finalUrl}`;
  }

  private async pageInfo(s: Session): Promise<{ title: string; url: string }> {
    const r = await this.send(s, "Runtime.evaluate", { expression: "JSON.stringify({title: document.title, url: location.href})", returnByValue: true });
    return JSON.parse(r.result.value);
  }

  // MARK: ツリー (フレーム横断)

  /** フレームの AX ツリーを取り、iframe ノードには子フレームのツリーをぶら下げる */
  private async frameTree(frame: Frame, depth = 0): Promise<AXNode | null> {
    await frame.session.ready;
    const params = frame.frameId ? { frameId: frame.frameId } : {};
    let nodes: CDPAXNode[];
    try {
      ({ nodes } = await this.send<{ nodes: CDPAXNode[] }>(frame.session, "Accessibility.getFullAXTree", params));
    } catch { return null; }
    const root = buildTree(nodes, frame);
    if (!root || depth >= 8) return root;
    await this.attachChildFrames(root, frame, depth);
    return root;
  }

  private async attachChildFrames(node: AXNode, frame: Frame, depth: number): Promise<void> {
    if (node.role === "iframe" && node.backendNodeId !== undefined && node.children.length === 0) {
      let contentFrameId: string | undefined;
      try {
        const { node: dom } = await this.send(frame.session, "DOM.describeNode", { backendNodeId: node.backendNodeId });
        contentFrameId = dom.frameId ?? dom.contentDocument?.frameId;
      } catch { /* 取れなければ空のまま */ }
      if (contentFrameId) {
        const owner = { frame, backendNodeId: node.backendNodeId };
        const oopif = this.frameSessions.get(contentFrameId);
        const child: Frame = oopif ? { session: oopif, owner } : { session: frame.session, frameId: contentFrameId, owner };
        const sub = await this.frameTree(child, depth + 1);
        if (sub) node.children = [sub];
      }
      return;
    }
    for (const c of node.children) await this.attachChildFrames(c, frame, depth);
  }

  private async tree(s: Session, within?: Ref): Promise<AXNode | null> {
    const root = await this.frameTree({ session: s });
    if (!root || !within) return root;
    const el = this.resolve(within);
    const found = findNode(root, (n) => n.backendNodeId === el.backendNodeId && n.frame === el.frame);
    if (!found) throw new HelperError("STALE_REF", `${within.snapshot}/${within.ref} is no longer in the page`);
    return found;
  }

  private register(targetId: string, refs: Map<string, ElementRef>): string {
    const id = `b${++this.snapshotCounter}`;
    this.snapshots.set(id, { targetId, refs });
    while (this.snapshots.size > KEEP_SNAPSHOTS) this.snapshots.delete(this.snapshots.keys().next().value!);
    return id;
  }

  async snapshot(target: string, opts: SnapshotOptions = {}): Promise<SnapshotResult> {
    const s = await this.session(this.targetIdOf(target));
    const root = await this.tree(s, opts.within);
    if (!root) return { snapshot: this.register(s.targetId, new Map()), text: "", refCount: 0, truncated: false };
    const forest = opts.interestingOnly === false ? [root] : collapse(root);
    return this.finish(s, forest, opts);
  }

  async find(target: string, query: FindQuery, opts: SnapshotOptions = {}): Promise<SnapshotResult> {
    const s = await this.session(this.targetIdOf(target));
    const root = await this.tree(s, opts.within);
    if (!root) throw new HelperError("NOT_FOUND", "page has no accessibility tree");
    markMatches(root, matcher(query));
    return this.finish(s, prune(root), { ...opts, maxNodes: opts.maxNodes ?? 5000 });
  }

  private finish(s: Session, forest: AXNode[], opts: SnapshotOptions): SnapshotResult {
    const refs = new Map<string, ElementRef>();
    const texts: string[] = [];
    let truncated = false;
    for (const n of forest) {
      const r = render(n, { maxDepth: opts.maxDepth ?? 40, maxNodes: (opts.maxNodes ?? 800) - refs.size });
      const offset = refs.size;
      for (const [, v] of r.refs) refs.set(`e${refs.size + 1}`, toElementRef(v));
      texts.push(offset === 0 ? r.text : r.text.replace(/\[ref=e(\d+)\]/g, (_m, d) => `[ref=e${Number(d) + offset}]`));
      truncated ||= r.truncated;
    }
    return { snapshot: this.register(s.targetId, refs), text: texts.join("\n"), refCount: refs.size, truncated };
  }

  async waitFor(target: string, cond: WaitCondition, timeoutMs: number, within?: Ref): Promise<SnapshotResult> {
    const deadline = Date.now() + timeoutMs;
    const opts = { within };
    if ("stable" in cond) {
      let last = (await this.snapshot(target, opts)).text, since = Date.now();
      while (Date.now() < deadline) {
        await sleep(100);
        const now = (await this.snapshot(target, opts)).text;
        if (now !== last) { last = now; since = Date.now(); }
        else if (Date.now() - since >= cond.stable) return this.snapshot(target, opts);
      }
      throw new HelperError("TIMEOUT", `page did not settle within ${timeoutMs}ms`);
    }
    const wantExists = "exists" in cond;
    const query = wantExists ? cond.exists : cond.gone;
    while (true) {
      const r = await this.find(target, query, opts);
      if ((r.refCount > 0) === wantExists) return wantExists ? r : this.snapshot(target, opts);
      if (Date.now() >= deadline) throw new HelperError("TIMEOUT", `condition not met within ${timeoutMs}ms`);
      await sleep(150);
    }
  }

  // MARK: 要素操作

  private resolve(ref: Ref): ElementRef {
    const snap = this.snapshots.get(ref.snapshot);
    if (!snap) throw new HelperError("STALE_REF", `snapshot ${ref.snapshot} is no longer available (keep the latest ${KEEP_SNAPSHOTS})`);
    const el = snap.refs.get(ref.ref);
    if (!el) throw new HelperError("NOT_FOUND", `ref ${ref.ref} not in snapshot ${ref.snapshot}`);
    return el;
  }

  /** 要素の左上と中心を、トップページの viewport 座標で返す */
  private async absoluteBox(el: ElementRef): Promise<{ x: number; y: number; cx: number; cy: number }> {
    const oopifOwner = el.frame.session.kind === "iframe" ? el.frame.owner : undefined;
    // OOPIF: 先に埋め込み元 <iframe> を親側で表示領域に入れておく
    if (oopifOwner) await this.absoluteBox({ backendNodeId: oopifOwner.backendNodeId, frame: oopifOwner.frame });
    try {
      await this.send(el.frame.session, "DOM.scrollIntoViewIfNeeded", { backendNodeId: el.backendNodeId });
    } catch (e) {
      throw new HelperError("STALE_REF", `element no longer exists or has no box: ${(e as Error).message}`);
    }
    // 子フレーム内の scrollIntoView は親のスクロールも非同期に動かすので、位置が落ち着くまで読み直す
    let last = "";
    for (let i = 0; i < 10; i++) {
      const box = await this.viewportBox(el);
      const owner = oopifOwner ? await this.absoluteBoxNoScroll({ backendNodeId: oopifOwner.backendNodeId, frame: oopifOwner.frame }) : { x: 0, y: 0 };
      const key = JSON.stringify([box, owner]);
      if (key === last) return { x: box.x + owner.x, y: box.y + owner.y, cx: box.cx + owner.x, cy: box.cy + owner.y };
      last = key;
      await sleep(30);
    }
    throw new HelperError("TIMEOUT", "element position did not settle");
  }

  /** スクロールせずに絶対座標を求める (入れ子 OOPIF 用の再帰) */
  private async absoluteBoxNoScroll(el: ElementRef): Promise<{ x: number; y: number; cx: number; cy: number }> {
    const box = await this.viewportBox(el);
    const owner = el.frame.session.kind === "iframe" && el.frame.owner
      ? await this.absoluteBoxNoScroll({ backendNodeId: el.frame.owner.backendNodeId, frame: el.frame.owner.frame })
      : { x: 0, y: 0 };
    return { x: box.x + owner.x, y: box.y + owner.y, cx: box.cx + owner.x, cy: box.cy + owner.y };
  }

  /**
   * そのフレームの viewport 基準の位置。DOM.getContentQuads を使う
   * (DOM.getBoxModel はスクロール量込みのドキュメント座標を返すので使わない)
   */
  private async viewportBox(el: ElementRef): Promise<{ x: number; y: number; cx: number; cy: number }> {
    let quads: number[][];
    try {
      ({ quads } = await this.send(el.frame.session, "DOM.getContentQuads", { backendNodeId: el.backendNodeId }));
    } catch (e) {
      throw new HelperError("STALE_REF", `element no longer exists or has no box: ${(e as Error).message}`);
    }
    const q = quads[0];
    if (!q) throw new HelperError("UNSUPPORTED", "element is not rendered (no content quads)");
    return {
      x: Math.min(q[0], q[6]), y: Math.min(q[1], q[3]),
      cx: (q[0] + q[2] + q[4] + q[6]) / 4, cy: (q[1] + q[3] + q[5] + q[7]) / 4,
    };
  }

  private async callOn(el: ElementRef, fn: string, args: unknown[] = []): Promise<any> {
    let objectId: string;
    try {
      ({ object: { objectId } } = await this.send(el.frame.session, "DOM.resolveNode", { backendNodeId: el.backendNodeId }));
    } catch {
      throw new HelperError("STALE_REF", "element no longer exists; take a new snapshot");
    }
    const r = await this.send(el.frame.session, "Runtime.callFunctionOn", {
      objectId, functionDeclaration: fn, arguments: args.map((value) => ({ value })), returnByValue: true, awaitPromise: true,
    });
    if (r.exceptionDetails) throw new HelperError("AX_ERROR", r.exceptionDetails.exception?.description ?? "script error");
    return r.result.value;
  }

  async click(ref: Ref, opts: { button?: "left" | "right"; count?: number; modifiers?: Modifier[] }): Promise<string> {
    const el = this.resolve(ref);
    const { cx: x, cy: y } = await this.absoluteBox(el);
    const page = el.frame.session.page;
    const button = opts.button ?? "left";
    const modifiers = modifierBits(opts.modifiers);
    await this.send(page, "Input.dispatchMouseEvent", { type: "mouseMoved", x, y, modifiers });
    for (let i = 1; i <= (opts.count ?? 1); i++) {
      await this.send(page, "Input.dispatchMouseEvent", { type: "mousePressed", x, y, button, clickCount: i, modifiers });
      await this.send(page, "Input.dispatchMouseEvent", { type: "mouseReleased", x, y, button, clickCount: i, modifiers });
    }
    return "cdp";
  }

  async focus(ref: Ref): Promise<void> {
    const el = this.resolve(ref);
    try { await this.send(el.frame.session, "DOM.focus", { backendNodeId: el.backendNodeId }); }
    catch (e) { throw new HelperError("UNSUPPORTED", `cannot focus: ${(e as Error).message}`); }
  }

  async type(ref: Ref | undefined, text: string, opts: { clear?: boolean; submit?: boolean }): Promise<string> {
    let page: Session;
    if (ref) {
      const el = this.resolve(ref);
      await this.send(el.frame.session, "DOM.focus", { backendNodeId: el.backendNodeId });
      if (opts.clear) {
        await this.callOn(el, `function() {
          if ('value' in this) { this.value = ''; this.dispatchEvent(new Event('input', {bubbles: true})); }
          else if (this.isContentEditable) { this.textContent = ''; }
        }`);
      }
      page = el.frame.session.page;
      await this.send(el.frame.session, "Input.insertText", { text });
    } else {
      const last = [...this.sessions.values()].at(-1);
      if (!last) throw new HelperError("INVALID_PARAMS", "no browser tab in use; pass a ref");
      page = last;
      await this.send(page, "Input.insertText", { text });
    }
    if (opts.submit) await this.key(`tab:${page.targetId}`, "Enter");
    return "insertText";
  }

  async key(target: string | undefined, key: string, modifiers: Modifier[] = []): Promise<void> {
    const s = target ? await this.session(this.targetIdOf(target)) : [...this.sessions.values()].at(-1);
    if (!s) throw new HelperError("INVALID_PARAMS", "no browser tab in use; pass a target");
    const d = describeKey(key);
    const mods = modifierBits(modifiers);
    const base = { key: d.key, code: d.code, windowsVirtualKeyCode: d.windowsVirtualKeyCode, nativeVirtualKeyCode: d.windowsVirtualKeyCode, modifiers: mods };
    const commands = editingCommands(key, modifiers);
    const printable = d.text && !(mods & ~8);   // shift 以外の修飾がなければ文字入力
    await this.send(s, "Input.dispatchKeyEvent", {
      type: printable ? "keyDown" : "rawKeyDown", ...base,
      ...(printable ? { text: d.text, unmodifiedText: d.text } : {}),
      ...(commands ? { commands } : {}),
    });
    await this.send(s, "Input.dispatchKeyEvent", { type: "keyUp", ...base });
  }

  async scroll(ref: Ref, dx: number, dy: number): Promise<void> {
    const el = this.resolve(ref);
    const { cx: x, cy: y } = await this.absoluteBox(el);
    await this.send(el.frame.session.page, "Input.dispatchMouseEvent", { type: "mouseWheel", x, y, deltaX: dx, deltaY: dy });
  }

  async setValue(ref: Ref, value: string | number | boolean): Promise<void> {
    const el = this.resolve(ref);
    const ok = await this.callOn(el, `function(v) {
      const fire = (t) => this.dispatchEvent(new Event(t, { bubbles: true }));
      if (this instanceof HTMLInputElement && (this.type === 'checkbox' || this.type === 'radio')) {
        if (this.checked !== Boolean(v)) this.click();
        return true;
      }
      if (this instanceof HTMLSelectElement) {
        const opt = [...this.options].find(o => o.value == v || o.text == v);
        if (!opt) return false;
        this.value = opt.value; fire('input'); fire('change'); return true;
      }
      if ('value' in this) { this.focus(); this.value = String(v); fire('input'); fire('change'); return true; }
      if (this.isContentEditable) { this.textContent = String(v); fire('input'); return true; }
      if (this.getAttribute('role') === 'checkbox' || this.getAttribute('role') === 'switch') {
        if ((this.getAttribute('aria-checked') === 'true') !== Boolean(v)) this.click();
        return true;
      }
      return false;
    }`, [value]);
    if (!ok) throw new HelperError("UNSUPPORTED", "element does not accept a value");
  }

  async attributes(ref: Ref, names?: string[]): Promise<Record<string, unknown>> {
    const el = this.resolve(ref);
    const dom = await this.callOn(el, `function(names) {
      const out = { tag: this.tagName.toLowerCase() };
      for (const a of this.attributes) if (!names || names.includes(a.name)) out[a.name] = a.value;
      if ('value' in this) out.value = this.value;
      if ('checked' in this) out.checked = this.checked;
      out.text = (this.innerText || '').slice(0, 200);
      const r = this.getBoundingClientRect(); out.rect = { x: r.x, y: r.y, w: r.width, h: r.height };
      return out;
    }`, [names ?? null]);
    if (el.frame.owner) dom.frame = el.frame.session.kind === "iframe" ? "oopif" : "iframe";
    const ax = await this.send(el.frame.session, "Accessibility.getPartialAXTree", { backendNodeId: el.backendNodeId, fetchRelatives: false }).catch(() => null);
    const node = ax?.nodes?.[0];
    if (node) {
      dom.role = node.role?.value; dom.name = node.name?.value;
      for (const p of node.properties ?? []) dom[`aria:${p.name}`] = p.value?.value;
    }
    return dom;
  }

  async action(ref: Ref, action: string): Promise<void> {
    const el = this.resolve(ref);
    switch (action) {
      case "AXPress": case "click": await this.click(ref, {}); return;
      case "hover": { const { cx: x, cy: y } = await this.absoluteBox(el); await this.send(el.frame.session.page, "Input.dispatchMouseEvent", { type: "mouseMoved", x, y }); return; }
      case "AXShowMenu": case "contextmenu": await this.click(ref, { button: "right" }); return;
      case "submit": await this.callOn(el, "function(){ (this.form || this).requestSubmit?.(); }"); return;
      case "scrollIntoView": await this.send(el.frame.session, "DOM.scrollIntoViewIfNeeded", { backendNodeId: el.backendNodeId }); return;
      default: throw new HelperError("UNSUPPORTED", `browser action ${action} (try click, hover, contextmenu, submit, scrollIntoView)`);
    }
  }

  async screenshot(target: string, _opts: { maxWidth?: number } = {}) {
    const s = await this.session(this.targetIdOf(target));
    const { data } = await this.send(s, "Page.captureScreenshot", { format: "png" });
    return { pngBase64: data };
  }

  // MARK: イベント購読

  /** 開いている JS ダイアログ (alert / confirm / prompt / beforeunload)。開いている間はページ操作がブロックされる */
  dialog(target: string): OpenDialog | undefined { return this.openDialogs.get(this.targetIdOf(target)); }

  async handleDialog(target: string, accept: boolean, promptText?: string): Promise<string> {
    const s = await this.session(this.targetIdOf(target));
    const d = this.openDialogs.get(s.targetId);
    if (!d) throw new HelperError("NOT_FOUND", "no open dialog on this tab");
    await this.send(s, "Page.handleJavaScriptDialog", { accept, ...(promptText !== undefined ? { promptText } : {}) });
    this.openDialogs.delete(s.targetId);
    return `${accept ? "accepted" : "dismissed"} ${d.type}: ${d.message}`;
  }

  async observe(target: string, notifications?: string[]): Promise<{ subscription: string; notifications: string[] }> {
    const conn = await this.connection();
    const s = await this.session(this.targetIdOf(target));
    const wanted = new Set(notifications ?? DEFAULT_BROWSER_NOTIFICATIONS);
    const unknown = [...wanted].filter((n) => !(BROWSER_NOTIFICATIONS as readonly string[]).includes(n));
    if (unknown.length) throw new HelperError("INVALID_PARAMS", `unknown browser notifications: ${unknown.join(", ")} (known: ${BROWSER_NOTIFICATIONS.join(", ")})`);
    if (wanted.has("console") || wanted.has("consoleError") || wanted.has("exception")) await this.send(s, "Runtime.enable");
    if ((wanted.has("tabCreated") || wanted.has("tabDestroyed") || wanted.has("tabInfoChanged")) && !this.targetsDiscovered) {
      await conn.send("Target.setDiscoverTargets", { discover: true });
      this.targetsDiscovered = true;
    }

    const sub: BrowserSubscription = { id: `w${++this.subscriptionCounter}`, targetId: s.targetId, notifications: wanted, off: [] };
    const target_ = `tab:${s.targetId}`;
    const push = (notification: string, title?: string, value?: unknown, targetOverride?: string) => {
      if (!wanted.has(notification)) return;
      this.eventBuffer.push({ subscription: sub.id, notification, element: { title, value }, time: Date.now() / 1000, target: targetOverride ?? target_ });
      if (this.eventBuffer.length > MAX_EVENTS) this.eventBuffer.splice(0, this.eventBuffer.length - MAX_EVENTS);
    };
    const mine = (sid?: string) => sid === s.sessionId;
    const on = (event: string, handler: (p: any, sid?: string) => void) => sub.off.push(conn.on(event, handler));

    on("Page.frameNavigated", (p, sid) => { if (mine(sid) && !p.frame.parentId) push("navigated", p.frame.url, p.frame.unreachableUrl ? { unreachable: true } : undefined); });
    on("Page.loadEventFired", (_p, sid) => { if (mine(sid)) push("loaded"); });
    on("Page.domContentEventFired", (_p, sid) => { if (mine(sid)) push("domContentLoaded"); });
    on("Page.javascriptDialogOpening", (p, sid) => { if (mine(sid)) push("dialogOpened", p.message, { type: p.type, defaultPrompt: p.defaultPrompt, hint: "use cu_dialog to accept or dismiss" }); });
    on("Page.javascriptDialogClosed", (p, sid) => { if (mine(sid)) push("dialogClosed", undefined, { result: p.result, userInput: p.userInput }); });
    on("Runtime.consoleAPICalled", (p, sid) => {
      if (!mine(sid)) return;
      const text = (p.args ?? []).map((a: any) => a.value !== undefined ? String(a.value) : a.description ?? a.type).join(" ").slice(0, 300);
      push("console", text, { level: p.type });
      if (p.type === "error" || p.type === "warning" || p.type === "assert") push("consoleError", text, { level: p.type });
    });
    on("Runtime.exceptionThrown", (p, sid) => {
      if (!mine(sid)) return;
      const d = p.exceptionDetails;
      push("exception", (d.exception?.description ?? d.text ?? "").split("\n")[0].slice(0, 300), { url: d.url, line: d.lineNumber });
    });
    on("Target.targetCreated", (p) => { if (p.targetInfo.type === "page") push("tabCreated", p.targetInfo.url, undefined, `tab:${p.targetInfo.targetId}`); });
    on("Target.targetDestroyed", (p) => push("tabDestroyed", undefined, undefined, `tab:${p.targetId}`));
    on("Target.targetInfoChanged", (p) => { if (p.targetInfo.type === "page") push("tabInfoChanged", p.targetInfo.title, { url: p.targetInfo.url }, `tab:${p.targetInfo.targetId}`); });

    this.subscriptions.set(sub.id, sub);
    return { subscription: sub.id, notifications: [...wanted] };
  }

  async unobserve(subscription: string): Promise<void> {
    const sub = this.subscriptions.get(subscription);
    if (!sub) throw new HelperError("NOT_FOUND", `subscription ${subscription}`);
    for (const off of sub.off) off();
    this.subscriptions.delete(subscription);
  }

  events(): UIEvent[] { const out = this.eventBuffer; this.eventBuffer = []; return out; }

  async dispose(): Promise<void> {
    this.conn?.close();
    this.conn = null;
    this.sessions.clear();
    this.frameSessions.clear();
  }
}

function findNode(n: AXNode, pred: (n: AXNode) => boolean): AXNode | null {
  if (pred(n)) return n;
  for (const c of n.children) { const f = findNode(c, pred); if (f) return f; }
  return null;
}

function toElementRef(v: RefTarget): ElementRef {
  return { backendNodeId: v.backendNodeId, frame: v.frame as Frame };
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
