import type { ActionReportOptions, Backend, BrowserScope, SnapshotOptions, TargetInfo, UIEvent, WaitCondition } from "../../core/backend.js";
import { HelperError, type AXEvent, type Changes, type FindQuery, type Modifier, type Ref, type SnapshotResult } from "../../core/protocol.js";
import { parseTarget, scopeOf, type ParsedTarget } from "../../core/targets.js";
import { HelperClient } from "./HelperClient.js";

/** macOS ヘルパー (PROTOCOL.md) を Backend に適合させる。target は app:<pid> / window:<pid>:<n> / bundle id。 */
export class DesktopBackend implements Backend {
  readonly kind = "desktop" as const;
  private client: HelperClient | null = null;
  private eventBuffer: UIEvent[] = [];
  private static readonly MAX_EVENTS = 200;

  constructor(private readonly factory?: () => HelperClient) {}

  private onNotification = (method: string, params: unknown) => {
    if (method !== "ax.event") return;
    const e = params as AXEvent;
    this.eventBuffer.push({ subscription: e.subscription, notification: e.notification, element: e.element, time: e.time, target: `app:${e.pid}` });
    if (this.eventBuffer.length > DesktopBackend.MAX_EVENTS) this.eventBuffer.splice(0, this.eventBuffer.length - DesktopBackend.MAX_EVENTS);
  };

  ownsTarget(t: string) { const k = parseTarget(t).kind; return k === "app" || k === "window" || k === "bundle"; }
  ownsSnapshot(id: string) { return id.startsWith("s"); }

  /** ヘルパーは最初の利用時に遅延起動する (権限ダイアログを不用意に出さないため) */
  async helper(): Promise<HelperClient> {
    if (this.client && !this.client.running) {
      // ヘルパーが落ちた (クラッシュ、kill) 後は新しいプロセスを起こす。古い ref は使えなくなる (STALE_REF)
      try { await this.client.stop(); } catch { /* 既に終了 */ }
      this.client = null;
      this.restarted = true;
    }
    if (!this.client) {
      this.client = this.factory ? this.factory() : new HelperClient({ onNotification: this.onNotification });
      await this.client.start();
      if (this.restarted) process.stderr.write("[cccu] helper restarted after it exited; refs from before are no longer valid\n");
    }
    return this.client;
  }
  private restarted = false;

  private async resolveTarget(target: string): Promise<ParsedTarget> {
    const t = parseTarget(target);
    if (t.kind === "bundle") {
      // bundle id → pid。起動していなければ起動するが、前面化はしない (読み取りや背面操作のたびに最前面へ出さない)
      const h = await this.helper();
      if (h.has("app.launch")) return { kind: "app", pid: (await h.call("app.launch", { bundleId: t.bundleId })).pid };
      return { kind: "app", pid: (await h.call("app.activate", { bundleId: t.bundleId })).pid };
    }
    return t;
  }
  private async scope(target: string, within?: Ref, scope?: BrowserScope) {
    if (within) return { ref: within };
    const t = await this.resolveTarget(target);
    // ブラウザは既定でページ (webarea) に絞る。タブバーや拡張機能、メニューバーで ref が埋まるのを避ける。
    // ブラウザ UI が必要なときは scope: "app" か、within にウィンドウの ref を渡す
    if (scope !== "app" && t.kind === "app" && (await this.isBrowser(t.pid))) {
      // 新しいヘルパーはページ (webarea) を自分で解決する (スナップショットを 1 回節約し、読み込み直後は短く待つ)
      const h = await this.helper();
      if (parseInt(h.info.protocolVersion.split(".")[1] ?? "0", 10) >= 12) return { pid: t.pid, webarea: true };
      const page = await this.focusedWebArea(t.pid);
      if (page) return { ref: page };
    }
    return scopeOf(t);
  }
  /** scope: "app" のブラウザではページの中身を省く (巨大なページが maxNodes を食い潰してタブ列が出なくなるため) */
  private async extraOptions(target: string, scope?: BrowserScope): Promise<{ skipWebContent?: boolean }> {
    if (scope !== "app") return {};
    const t = await this.resolveTarget(target);
    return t.kind === "app" && (await this.isBrowser(t.pid)) ? { skipWebContent: true } : {};
  }

  private static readonly BROWSER_BUNDLES = new Set([
    "com.google.Chrome", "com.google.Chrome.canary", "com.apple.Safari", "com.microsoft.edgemac",
    "com.brave.Browser", "company.thebrowser.Browser", "org.mozilla.firefox", "com.vivaldi.Vivaldi", "org.chromium.Chromium",
  ]);
  private bundleCache = new Map<number, string | undefined>();
  private async isBrowser(pid: number): Promise<boolean> {
    if (!this.bundleCache.has(pid)) {
      const { apps } = await (await this.helper()).call("app.list", {});
      for (const a of apps) this.bundleCache.set(a.pid, a.bundleId);
    }
    const b = this.bundleCache.get(pid);
    return !!b && DesktopBackend.BROWSER_BUNDLES.has(b);
  }

  /** 最前面ウィンドウの webarea (フォーカス中のものを優先) の ref。見つからなければ undefined */
  private async focusedWebArea(pid: number): Promise<Ref | undefined> {
    const r = await (await this.helper()).call("ui.find", { scope: { pid }, query: { role: "webarea" }, maxNodes: 2000 });
    const lines = r.text.split("\n").filter((l) => /^\s*- webarea\b/.test(l) && l.includes("[ref="));
    // 入れ子の webarea (Chrome の新しいタブなど) は最初 = 最も外側を使う。フォーカス中のウィンドウのものを優先
    const pick = lines.find((l) => l.includes("[focused]")) ?? lines[0];
    if (!pick) return undefined;
    return { snapshot: r.snapshot, ref: pick.split("[ref=")[1].split("]")[0] };
  }

  async listTargets(): Promise<TargetInfo[]> {
    return this.withPermissionRetry(() => this.listTargetsOnce());
  }
  private async listTargetsOnce(): Promise<TargetInfo[]> {
    const h = await this.helper();
    const { apps } = await h.call("app.list", {});
    const { windows } = await h.call("window.list", {});
    const out: TargetInfo[] = [];
    for (const a of apps) {
      out.push({ id: `app:${a.pid}`, kind: "app", title: a.name, bundleId: a.bundleId, focused: a.frontmost, extra: a.hidden ? ["hidden"] : [] });
      for (const w of windows.filter((w) => w.pid === a.pid && w.windowNumber !== 0)) {
        out.push({ id: `window:${w.pid}:${w.windowNumber}`, kind: "window", title: w.title, focused: w.focused, extra: w.minimized ? ["minimized"] : [] });
      }
    }
    return out;
  }

  async activate(target: string): Promise<string> {
    const h = await this.helper();
    const t = await this.resolveTarget(target);
    if (t.kind === "window") { await h.call("window.raise", { pid: t.pid, windowNumber: t.windowNumber }); return `raised ${target}`; }
    if (t.kind !== "app") throw new HelperError("UNSUPPORTED", `cannot activate ${target}`);
    // cu_activate は明示的な前面化の依頼なので、ここだけは必ず最前面にする
    await h.call("app.activate", { pid: t.pid });
    return `activated app:${t.pid}`;
  }

  async snapshot(target: string, opts: SnapshotOptions = {}): Promise<SnapshotResult> {
    const { within, scope, ...rest } = opts;
    return this.withPermissionRetry(async () => (await this.helper()).call("ui.snapshot", { scope: await this.scope(target, within, scope), ...rest, ...(await this.extraOptions(target, scope)) }));
  }
  async find(target: string, query: FindQuery, opts: SnapshotOptions = {}): Promise<SnapshotResult> {
    return (await this.helper()).call("ui.find", { scope: await this.scope(target, opts.within, opts.scope), query, maxNodes: opts.maxNodes, textLimit: opts.textLimit, ...(await this.extraOptions(target, opts.scope)) });
  }
  async waitFor(target: string, condition: WaitCondition, timeoutMs: number, within?: Ref, textLimit?: number, scope?: BrowserScope): Promise<SnapshotResult> {
    return (await this.helper()).call("ui.waitFor", { scope: await this.scope(target, within, scope), condition, timeoutMs, textLimit, ...(await this.extraOptions(target, scope)) });
  }
  async query(target: string, selector: string, opts: SnapshotOptions = {}): Promise<SnapshotResult> {
    const h = await this.helper();
    if (!h.has("ui.query")) throw new HelperError("UNSUPPORTED", "helper does not support ui.query (rebuild ax_helpers/macos)");
    return h.call("ui.query", { scope: await this.scope(target, opts.within, opts.scope), selector, maxNodes: opts.maxNodes, textLimit: opts.textLimit, ...(await this.extraOptions(target, opts.scope)) });
  }
  /** 操作結果の method 文字列に、ヘルパーの警告 (ユーザー入力の遮断・重なり、セッション終了) を添える */
  private static withWarning(method: string, r: { warning?: string; changes?: Changes }): string {
    let out = r.warning ? `${method} — WARNING: ${r.warning}` : method;
    if (r.changes) out += "\n" + DesktopBackend.formatChanges(r.changes);
    return out;
  }
  /** 操作後の変化を読みやすく: 変化なし / 追加・削除行 / 大きな変化は全体 */
  private static formatChanges(c: Changes): string {
    if (!c.changed) return `no visible change within ${((c.waitMs ?? 1200) / 1000).toFixed(1)}s (snapshot=${c.snapshot})`;
    if (c.full !== undefined) return `changed a lot (+${c.added} -${c.removed} lines); new tree (snapshot=${c.snapshot} refs=${c.refCount}):\n${c.full}`;
    const lines = [...(c.addedLines ?? []).map((l) => "+ " + l.trimStart()), ...(c.removedLines ?? []).map((l) => "- " + l.trimStart())];
    return `changes (snapshot=${c.snapshot} refs=${c.refCount}): +${c.added} -${c.removed}\n${lines.join("\n")}`;
  }
  async clickAt(x: number, y: number, opts: { button?: "left" | "right"; count?: number; modifiers?: Modifier[]; pointer?: "human" | "warp" }): Promise<string> {
    const r = await (await this.helper()).call("ui.click", { point: { x, y }, ...opts });
    return DesktopBackend.withWarning(r.method, r);
  }
  async click(ref: Ref, opts: { button?: "left" | "right"; count?: number; modifiers?: Modifier[]; foreground?: boolean; pointer?: "human" | "warp"; force?: boolean } & ActionReportOptions): Promise<string> {
    const r = await (await this.helper()).call("ui.click", { ref, ...opts });
    return DesktopBackend.withWarning(r.method, r);
  }
  async type(ref: Ref | undefined, text: string, opts: { clear?: boolean; submit?: boolean; foreground?: boolean } & ActionReportOptions): Promise<string> {
    const r = await (await this.helper()).call("input.type", { ref, text, ...opts });
    return DesktopBackend.withWarning(r.method, r);
  }
  async inputSession(action: "begin" | "extend" | "end" | "status", target?: string, opts: { blockInput?: boolean; maxSeconds?: number } = {}): Promise<string> {
    const h = await this.helper();
    if (!h.has("session.begin")) throw new HelperError("UNSUPPORTED", h.running ? "helper does not support sessions (rebuild ax_helpers/macos)" : "helper is not running");
    switch (action) {
      case "begin": {
        if (!target) throw new HelperError("INVALID_PARAMS", "begin needs a target (app:<pid> or bundle id)");
        if (opts.maxSeconds === undefined) throw new HelperError("INVALID_PARAMS", "begin needs maxSeconds: declare how long the session may last (1..3600)");
        const t = await this.resolveTarget(target);
        if (t.kind !== "app" && t.kind !== "window") throw new HelperError("UNSUPPORTED", `cannot start a session on ${target}`);
        const r = await h.call("session.begin", { pid: t.pid, blockInput: opts.blockInput ?? true, maxSeconds: opts.maxSeconds });
        return `session started on pid ${r.pid}: app kept in front, user input ${r.blocking ? "blocked" : "not blocked"}, ends automatically after ${r.maxSeconds}s or when the user presses Escape three times. Call cu_session end when done.`;
      }
      case "extend": {
        if (opts.maxSeconds === undefined) throw new HelperError("INVALID_PARAMS", "extend needs maxSeconds");
        const r = await h.call("session.extend", { maxSeconds: opts.maxSeconds });
        return `session extended: ${r.remainingSeconds}s remaining`;
      }
      case "end": {
        const r = await h.call("session.end", {});
        return DesktopBackend.withWarning(`session ended after ${r.seconds ?? 0}s; ${r.blockedInputs ?? 0} user input event(s) were blocked; focus returned to the previous app`, r);
      }
      case "status": {
        const r = await h.call("session.status", {});
        return r.active ? `session active on pid ${r.pid}, input ${r.blocking ? "blocked" : "not blocked"}, ${r.remainingSeconds}s remaining` : "no active session";
      }
    }
  }
  async key(target: string | undefined, key: string, modifiers?: Modifier[], opts: { foreground?: boolean } & ActionReportOptions = {}): Promise<string> {
    const h = await this.helper();
    // scope() はブラウザだと webarea の ref を返し pid を持たないので、ターゲット解決から直接 pid を取る
    const pid = target ? (await this.resolveTarget(target) as { pid?: number }).pid : undefined;
    const r = await h.call("input.key", { key, modifiers, pid, ...opts });
    return DesktopBackend.withWarning(r.item ? `${r.method} "${r.item}"` : r.method, r);
  }
  /** ユーザーの Chrome など AX で操作するブラウザで URL を開く: cmd+L でアドレスバーへ、フォーカス要素に URL を打って Enter */
  async navigate(target: string | undefined, url: string): Promise<string> {
    if (!target) throw new HelperError("INVALID_PARAMS", "desktop navigate needs a browser target (bundle id or app:<pid>)");
    const h = await this.helper();
    const t = await this.resolveTarget(target);
    if (t.kind !== "app" || !(await this.isBrowser(t.pid))) throw new HelperError("UNSUPPORTED", `${target} is not a browser app`);
    const shortcut = async (key: string) => (await h.call("input.key", { key, modifiers: ["cmd"], pid: t.pid })).method;
    if (url === "back") return `back via ${await shortcut("[")}`;
    if (url === "forward") return `forward via ${await shortcut("]")}`;
    if (url === "close") return `closed tab via ${await shortcut("w")}`;
    if (url === "new") return `new tab via ${await shortcut("t")}`;
    const k = await shortcut("l");
    const r = await h.call("input.type", { pid: t.pid, text: url, clear: true, submit: true });
    return `opened ${url} via ${k}, ${r.method}`;
  }
  async scroll(ref: Ref, dx: number, dy: number, opts: { foreground?: boolean; pointer?: "human" | "warp" } = {}): Promise<string> {
    const r = await (await this.helper()).call("input.scroll", { ref, dx, dy, ...opts });
    return DesktopBackend.withWarning(r.anchor ? `${r.method} (element is off-screen; scrolled at its ${r.anchor})` : r.method, r);
  }
  async setValue(ref: Ref, value: string | number | boolean, opts: ActionReportOptions = {}): Promise<string> {
    const r = await (await this.helper()).call("ui.setAttribute", { ref, name: "AXValue", value, ...opts });
    return DesktopBackend.withWarning("ok", r);
  }
  async focus(ref: Ref): Promise<void> { await (await this.helper()).call("ui.focus", { ref }); }
  async attributes(ref: Ref, names?: string[]): Promise<Record<string, unknown>> {
    return (await (await this.helper()).call("ui.attributes", { ref, names })).attributes;
  }
  async action(ref: Ref, action: string, opts: ActionReportOptions = {}): Promise<string> {
    const r = await (await this.helper()).call("ui.performAction", { ref, action, ...opts });
    return DesktopBackend.withWarning("ok", r);
  }
  async screenshot(target: string, opts: { maxWidth?: number; grid?: number } = {}) {
    return this.withPermissionRetry(async () => {
      const h = await this.helper();
      if (!h.has("screen.capture")) throw new HelperError("UNSUPPORTED", "helper does not support screen.capture (rebuild ax_helpers/macos)");
      const t = await this.resolveTarget(target);
      const params = t.kind === "window" ? { pid: t.pid, windowNumber: t.windowNumber } : t.kind === "app" ? { pid: t.pid } : {};
      const r = await h.call("screen.capture", { ...params, maxWidth: opts.maxWidth, grid: opts.grid });
      return { pngBase64: r.pngBase64, width: r.width, height: r.height, frame: r.frame, scale: r.scale };
    });
  }

  /**
   * 権限 (Accessibility / Screen Recording) は付与後、責任プロセスの再起動で有効になる。
   * ヘルパーは自分自身が責任プロセスなので、NOT_TRUSTED のときは一度だけ再起動して再試行する。
   */
  private async withPermissionRetry<T>(fn: () => Promise<T>): Promise<T> {
    try {
      return await fn();
    } catch (e) {
      if (!(e instanceof HelperError) || e.kind !== "NOT_TRUSTED") throw e;
      await this.client?.stop();
      this.client = null;
      try {
        return await fn();
      } catch (e2) {
        if (e2 instanceof HelperError && e2.kind === "NOT_TRUSTED") {
          throw new HelperError("NOT_TRUSTED", e2.message, {
            ...e2.data,
            hint: `Grant the permission to "cccu-helper" in System Settings > Privacy & Security; no restart of the terminal is needed, the helper restarts itself. ${e2.data.hint ?? ""}`.trim(),
          });
        }
        throw e2;
      }
    }
  }

  /** 権限状態 (cu_status 用) */
  async permissions(): Promise<{ accessibility: boolean; screenRecording?: boolean; responsibleProcess?: boolean }> {
    const h = await this.helper();
    return { accessibility: h.info.trusted, screenRecording: h.info.screenRecording, responsibleProcess: h.info.responsible };
  }
  async observe(target: string, notifications?: string[]) {
    const h = await this.helper();
    if (!h.has("ui.observe")) throw new HelperError("UNSUPPORTED", "helper does not support ui.observe (rebuild ax_helpers/macos)");
    const t = await this.resolveTarget(target);
    if (t.kind !== "app" && t.kind !== "window") throw new HelperError("UNSUPPORTED", `cannot observe ${target}`);
    return h.call("ui.observe", { pid: t.pid, notifications });
  }
  async unobserve(subscription: string) { await (await this.helper()).call("ui.unobserve", { subscription }); }
  events(): UIEvent[] { const out = this.eventBuffer; this.eventBuffer = []; return out; }

  async dispose(): Promise<void> { await this.client?.stop(); this.client = null; }
}
