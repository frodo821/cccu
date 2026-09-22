import type { Backend, SnapshotOptions, TargetInfo, WaitCondition } from "../../core/backend.js";
import { CDPConnection, discover } from "../../core/cdp.js";
import { HelperError, type FindQuery, type Modifier, type Ref, type SnapshotResult } from "../../core/protocol.js";
import { buildTree, collapse, markMatches, matcher, prune, render, type AXNode, type CDPAXNode, type RefTarget } from "./axtree.js";
import { describeKey, editingCommands, modifierBits } from "./keys.js";

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
  private readonly cdpUrl: string;
  private readonly activateApp?: () => Promise<void>;

  constructor(opts: { cdpUrl?: string; activateApp?: () => Promise<void> } = {}) {
    this.cdpUrl = opts.cdpUrl ?? process.env.CCCU_CDP_URL ?? DEFAULT_CDP;
    this.activateApp = opts.activateApp;
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
    const conn = await this.connection();
    let targetId: string;
    if (!target || target === "new") {
      const r = await conn.send("Target.createTarget", { url: "about:blank" });
      targetId = r.targetId;
    } else {
      targetId = this.targetIdOf(target);
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

  private async tree(s: Session): Promise<AXNode | null> {
    return this.frameTree({ session: s });
  }

  private register(targetId: string, refs: Map<string, ElementRef>): string {
    const id = `b${++this.snapshotCounter}`;
    this.snapshots.set(id, { targetId, refs });
    while (this.snapshots.size > KEEP_SNAPSHOTS) this.snapshots.delete(this.snapshots.keys().next().value!);
    return id;
  }

  async snapshot(target: string, opts: SnapshotOptions = {}): Promise<SnapshotResult> {
    const s = await this.session(this.targetIdOf(target));
    const root = await this.tree(s);
    if (!root) return { snapshot: this.register(s.targetId, new Map()), text: "", refCount: 0, truncated: false };
    const forest = opts.interestingOnly === false ? [root] : collapse(root);
    return this.finish(s, forest, opts);
  }

  async find(target: string, query: FindQuery, opts: SnapshotOptions = {}): Promise<SnapshotResult> {
    const s = await this.session(this.targetIdOf(target));
    const root = await this.tree(s);
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

  async waitFor(target: string, cond: WaitCondition, timeoutMs: number): Promise<SnapshotResult> {
    const deadline = Date.now() + timeoutMs;
    if ("stable" in cond) {
      let last = (await this.snapshot(target)).text, since = Date.now();
      while (Date.now() < deadline) {
        await sleep(100);
        const now = (await this.snapshot(target)).text;
        if (now !== last) { last = now; since = Date.now(); }
        else if (Date.now() - since >= cond.stable) return this.snapshot(target);
      }
      throw new HelperError("TIMEOUT", `page did not settle within ${timeoutMs}ms`);
    }
    const wantExists = "exists" in cond;
    const query = wantExists ? cond.exists : cond.gone;
    while (true) {
      const r = await this.find(target, query);
      if ((r.refCount > 0) === wantExists) return wantExists ? r : this.snapshot(target);
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

  /** 要素の content box の左上と中心を、トップページの viewport 座標で返す */
  private async absoluteBox(el: ElementRef): Promise<{ x: number; y: number; cx: number; cy: number }> {
    let quad: number[];
    try {
      await this.send(el.frame.session, "DOM.scrollIntoViewIfNeeded", { backendNodeId: el.backendNodeId });
      ({ model: { content: quad } } = await this.send(el.frame.session, "DOM.getBoxModel", { backendNodeId: el.backendNodeId }));
    } catch (e) {
      throw new HelperError("STALE_REF", `element no longer exists or has no box: ${(e as Error).message}`);
    }
    let x = Math.min(quad[0], quad[6]), y = Math.min(quad[1], quad[3]);
    let cx = (quad[0] + quad[2] + quad[4] + quad[6]) / 4, cy = (quad[1] + quad[3] + quad[5] + quad[7]) / 4;
    // OOPIF の座標はそのフレームの viewport 基準なので、埋め込み元 <iframe> の位置を足す
    if (el.frame.session.kind === "iframe" && el.frame.owner) {
      const o = await this.absoluteBox({ backendNodeId: el.frame.owner.backendNodeId, frame: el.frame.owner.frame });
      const inset = await this.frameInset(el.frame.owner);
      x += o.x + inset.x; y += o.y + inset.y; cx += o.x + inset.x; cy += o.y + inset.y;
    }
    return { x, y, cx, cy };
  }

  /** <iframe> の content box 左上から実際の描画領域までのずれ (border/padding は content 外なので通常 0) */
  private async frameInset(_owner: { frame: Frame; backendNodeId: number }): Promise<{ x: number; y: number }> {
    return { x: 0, y: 0 };
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

  async observe(): Promise<{ subscription: string; notifications: string[] }> {
    throw new HelperError("UNSUPPORTED", "event subscriptions are not available for browser tabs yet; use cu_wait");
  }
  async unobserve(subscription: string): Promise<void> { throw new HelperError("NOT_FOUND", `subscription ${subscription}`); }
  events() { return []; }

  async dispose(): Promise<void> {
    this.conn?.close();
    this.conn = null;
    this.sessions.clear();
    this.frameSessions.clear();
  }
}

function toElementRef(v: RefTarget): ElementRef {
  return { backendNodeId: v.backendNodeId, frame: v.frame as Frame };
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
