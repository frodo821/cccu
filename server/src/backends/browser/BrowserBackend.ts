import type { Backend, SnapshotOptions, TargetInfo, WaitCondition } from "../../core/backend.js";
import { CDPConnection, discover } from "../../core/cdp.js";
import { HelperError, type FindQuery, type Modifier, type Ref, type SnapshotResult } from "../../core/protocol.js";
import { buildTree, collapse, markMatches, matcher, prune, render, type AXNode, type CDPAXNode } from "./axtree.js";
import { describeKey, editingCommands, modifierBits } from "./keys.js";

interface Session { targetId: string; sessionId: string }
interface Snapshot { targetId: string; refs: Map<string, number> }

const DEFAULT_CDP = "http://127.0.0.1:9222";
const KEEP_SNAPSHOTS = 8;

/**
 * Chrome を CDP で操作する backend。target は "tab:<targetId>"、snapshot id は "b<N>"。
 * ref は backendDOMNodeId に対応する (ページ遷移で無効になる → STALE_REF)。
 */
export class BrowserBackend implements Backend {
  readonly kind = "browser" as const;
  private conn: CDPConnection | null = null;
  private sessions = new Map<string, Session>();
  private snapshots = new Map<string, Snapshot>();
  private snapshotCounter = 0;
  private readonly cdpUrl: string;
  /** デスクトップ側でブラウザを前面化するためのフック (任意) */
  private readonly activateApp?: () => Promise<void>;

  constructor(opts: { cdpUrl?: string; activateApp?: () => Promise<void> } = {}) {
    this.cdpUrl = opts.cdpUrl ?? process.env.CCCU_CDP_URL ?? DEFAULT_CDP;
    this.activateApp = opts.activateApp;
  }

  ownsTarget(t: string) { return t.startsWith("tab:") || t === "tab" || t === "browser"; }
  ownsSnapshot(id: string) { return id.startsWith("b"); }

  // MARK: 接続

  private async connection(): Promise<CDPConnection> {
    if (this.conn?.isOpen) return this.conn;
    const { browserWs } = await discover(this.cdpUrl);
    this.conn = await CDPConnection.connect(browserWs);
    this.sessions.clear();
    this.conn.on("Target.detachedFromTarget", (p) => {
      for (const [k, s] of this.sessions) if (s.sessionId === p.sessionId) this.sessions.delete(k);
    });
    return this.conn;
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
    const s = { targetId, sessionId: r.sessionId };
    this.sessions.set(targetId, s);
    await conn.send("Page.enable", {}, s.sessionId);
    await conn.send("DOM.enable", {}, s.sessionId);
    await conn.send("Accessibility.enable", {}, s.sessionId);
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

  private async tree(s: Session): Promise<AXNode | null> {
    const { nodes } = await this.send<{ nodes: CDPAXNode[] }>(s, "Accessibility.getFullAXTree");
    return buildTree(nodes);
  }

  private register(targetId: string, refs: Map<string, number>): string {
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
    const refs = new Map<string, number>();
    const texts: string[] = [];
    let truncated = false;
    for (const n of forest) {
      const r = render(n, { maxDepth: opts.maxDepth ?? 40, maxNodes: (opts.maxNodes ?? 800) - refs.size });
      // render は e1 から振るので、複数ルートのときはずらす
      for (const [k, v] of r.refs) refs.set(`e${refs.size + 1}`, v);
      texts.push(refs.size === r.refs.size ? r.text : r.text.replace(/\[ref=e(\d+)\]/g, (_m, d) => `[ref=e${Number(d) + refs.size - r.refs.size}]`));
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

  private resolve(ref: Ref): { s: Promise<Session>; backendNodeId: number } {
    const snap = this.snapshots.get(ref.snapshot);
    if (!snap) throw new HelperError("STALE_REF", `snapshot ${ref.snapshot} is no longer available (keep the latest ${KEEP_SNAPSHOTS})`);
    const backendNodeId = snap.refs.get(ref.ref);
    if (backendNodeId === undefined) throw new HelperError("NOT_FOUND", `ref ${ref.ref} not in snapshot ${ref.snapshot}`);
    return { s: this.session(snap.targetId), backendNodeId };
  }

  /** 要素を可視化して中心座標 (CSS px, viewport 基準) を返す */
  private async center(s: Session, backendNodeId: number): Promise<{ x: number; y: number }> {
    try {
      await this.send(s, "DOM.scrollIntoViewIfNeeded", { backendNodeId });
      const { model } = await this.send(s, "DOM.getBoxModel", { backendNodeId });
      const q: number[] = model.content;
      return { x: (q[0] + q[2] + q[4] + q[6]) / 4, y: (q[1] + q[3] + q[5] + q[7]) / 4 };
    } catch (e) {
      throw new HelperError("STALE_REF", `element no longer exists or has no box: ${(e as Error).message}`);
    }
  }

  private async callOn(s: Session, backendNodeId: number, fn: string, args: unknown[] = []): Promise<any> {
    let objectId: string;
    try {
      ({ object: { objectId } } = await this.send(s, "DOM.resolveNode", { backendNodeId }));
    } catch {
      throw new HelperError("STALE_REF", "element no longer exists; take a new snapshot");
    }
    const r = await this.send(s, "Runtime.callFunctionOn", {
      objectId, functionDeclaration: fn, arguments: args.map((value) => ({ value })), returnByValue: true, awaitPromise: true,
    });
    if (r.exceptionDetails) throw new HelperError("AX_ERROR", r.exceptionDetails.exception?.description ?? "script error");
    return r.result.value;
  }

  async click(ref: Ref, opts: { button?: "left" | "right"; count?: number; modifiers?: Modifier[] }): Promise<string> {
    const { s: sp, backendNodeId } = this.resolve(ref);
    const s = await sp;
    const { x, y } = await this.center(s, backendNodeId);
    const button = opts.button ?? "left";
    const modifiers = modifierBits(opts.modifiers);
    await this.send(s, "Input.dispatchMouseEvent", { type: "mouseMoved", x, y, modifiers });
    for (let i = 1; i <= (opts.count ?? 1); i++) {
      await this.send(s, "Input.dispatchMouseEvent", { type: "mousePressed", x, y, button, clickCount: i, modifiers });
      await this.send(s, "Input.dispatchMouseEvent", { type: "mouseReleased", x, y, button, clickCount: i, modifiers });
    }
    return "cdp";
  }

  async focus(ref: Ref): Promise<void> {
    const { s: sp, backendNodeId } = this.resolve(ref);
    const s = await sp;
    try { await this.send(s, "DOM.focus", { backendNodeId }); }
    catch (e) { throw new HelperError("UNSUPPORTED", `cannot focus: ${(e as Error).message}`); }
  }

  async type(ref: Ref | undefined, text: string, opts: { clear?: boolean; submit?: boolean }): Promise<string> {
    let s: Session;
    if (ref) {
      const r = this.resolve(ref);
      s = await r.s;
      await this.send(s, "DOM.focus", { backendNodeId: r.backendNodeId });
      if (opts.clear) {
        await this.callOn(s, r.backendNodeId, `function() {
          if ('value' in this) { this.value = ''; this.dispatchEvent(new Event('input', {bubbles: true})); }
          else if (this.isContentEditable) { this.textContent = ''; }
        }`);
      }
    } else {
      // ref なし: 最後に使ったセッションのフォーカス要素へ
      const last = [...this.sessions.values()].at(-1);
      if (!last) throw new HelperError("INVALID_PARAMS", "no browser tab in use; pass a ref");
      s = last;
    }
    await this.send(s, "Input.insertText", { text });
    if (opts.submit) await this.key(`tab:${s.targetId}`, "Enter");
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
    const { s: sp, backendNodeId } = this.resolve(ref);
    const s = await sp;
    const { x, y } = await this.center(s, backendNodeId);
    await this.send(s, "Input.dispatchMouseEvent", { type: "mouseWheel", x, y, deltaX: dx, deltaY: dy });
  }

  async setValue(ref: Ref, value: string | number | boolean): Promise<void> {
    const { s: sp, backendNodeId } = this.resolve(ref);
    const s = await sp;
    const ok = await this.callOn(s, backendNodeId, `function(v) {
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
    const { s: sp, backendNodeId } = this.resolve(ref);
    const s = await sp;
    const dom = await this.callOn(s, backendNodeId, `function(names) {
      const out = { tag: this.tagName.toLowerCase() };
      for (const a of this.attributes) if (!names || names.includes(a.name)) out[a.name] = a.value;
      if ('value' in this) out.value = this.value;
      if ('checked' in this) out.checked = this.checked;
      out.text = (this.innerText || '').slice(0, 200);
      const r = this.getBoundingClientRect(); out.rect = { x: r.x, y: r.y, w: r.width, h: r.height };
      return out;
    }`, [names ?? null]);
    const ax = await this.send(s, "Accessibility.getPartialAXTree", { backendNodeId, fetchRelatives: false }).catch(() => null);
    const node = ax?.nodes?.[0];
    if (node) {
      dom.role = node.role?.value; dom.name = node.name?.value;
      for (const p of node.properties ?? []) dom[`aria:${p.name}`] = p.value?.value;
    }
    return dom;
  }

  async action(ref: Ref, action: string): Promise<void> {
    const { s: sp, backendNodeId } = this.resolve(ref);
    const s = await sp;
    switch (action) {
      case "AXPress": case "click": await this.click(ref, {}); return;
      case "hover": { const { x, y } = await this.center(s, backendNodeId); await this.send(s, "Input.dispatchMouseEvent", { type: "mouseMoved", x, y }); return; }
      case "AXShowMenu": case "contextmenu": await this.click(ref, { button: "right" }); return;
      case "submit": await this.callOn(s, backendNodeId, "function(){ (this.form || this).requestSubmit?.(); }"); return;
      case "scrollIntoView": await this.send(s, "DOM.scrollIntoViewIfNeeded", { backendNodeId }); return;
      default: throw new HelperError("UNSUPPORTED", `browser action ${action} (try click, hover, contextmenu, submit, scrollIntoView)`);
    }
  }

  async screenshot(target: string, _opts: { maxWidth?: number } = {}) {
    const s = await this.session(this.targetIdOf(target));
    const { data } = await this.send(s, "Page.captureScreenshot", { format: "png" });
    return { pngBase64: data };
  }

  async dispose(): Promise<void> {
    this.conn?.close();
    this.conn = null;
    this.sessions.clear();
  }
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
