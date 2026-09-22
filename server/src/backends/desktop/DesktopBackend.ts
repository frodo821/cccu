import type { Backend, SnapshotOptions, TargetInfo, UIEvent, WaitCondition } from "../../core/backend.js";
import { HelperError, type AXEvent, type FindQuery, type Modifier, type Ref, type SnapshotResult } from "../../core/protocol.js";
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
    if (!this.client) {
      this.client = this.factory ? this.factory() : new HelperClient({ onNotification: this.onNotification });
      await this.client.start();
    }
    return this.client;
  }

  private async resolveTarget(target: string): Promise<ParsedTarget> {
    const t = parseTarget(target);
    if (t.kind === "bundle") {
      const h = await this.helper();
      return { kind: "app", pid: (await h.call("app.activate", { bundleId: t.bundleId })).pid };
    }
    return t;
  }
  private async scope(target: string, within?: Ref) {
    return within ? { ref: within } : scopeOf(await this.resolveTarget(target));
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
    await h.call("app.activate", { pid: t.pid });
    return `activated app:${t.pid}`;
  }

  async snapshot(target: string, opts: SnapshotOptions = {}): Promise<SnapshotResult> {
    const { within, ...rest } = opts;
    return this.withPermissionRetry(async () => (await this.helper()).call("ui.snapshot", { scope: await this.scope(target, within), ...rest }));
  }
  async find(target: string, query: FindQuery, opts: SnapshotOptions = {}): Promise<SnapshotResult> {
    return (await this.helper()).call("ui.find", { scope: await this.scope(target, opts.within), query, maxNodes: opts.maxNodes });
  }
  async waitFor(target: string, condition: WaitCondition, timeoutMs: number, within?: Ref): Promise<SnapshotResult> {
    return (await this.helper()).call("ui.waitFor", { scope: await this.scope(target, within), condition, timeoutMs });
  }
  async click(ref: Ref, opts: { button?: "left" | "right"; count?: number; modifiers?: Modifier[] }): Promise<string> {
    return (await (await this.helper()).call("ui.click", { ref, ...opts })).method;
  }
  async type(ref: Ref | undefined, text: string, opts: { clear?: boolean; submit?: boolean }): Promise<string> {
    return (await (await this.helper()).call("input.type", { ref, text, ...opts })).method;
  }
  async key(target: string | undefined, key: string, modifiers?: Modifier[]): Promise<void> {
    const h = await this.helper();
    const pid = target ? (await this.scope(target) as { pid: number }).pid : undefined;
    await h.call("input.key", { key, modifiers, pid });
  }
  async scroll(ref: Ref, dx: number, dy: number): Promise<void> {
    await (await this.helper()).call("input.scroll", { ref, dx, dy });
  }
  async setValue(ref: Ref, value: string | number | boolean): Promise<void> {
    await (await this.helper()).call("ui.setAttribute", { ref, name: "AXValue", value });
  }
  async focus(ref: Ref): Promise<void> { await (await this.helper()).call("ui.focus", { ref }); }
  async attributes(ref: Ref, names?: string[]): Promise<Record<string, unknown>> {
    return (await (await this.helper()).call("ui.attributes", { ref, names })).attributes;
  }
  async action(ref: Ref, action: string): Promise<void> {
    await (await this.helper()).call("ui.performAction", { ref, action });
  }
  async screenshot(target: string, opts: { maxWidth?: number } = {}) {
    return this.withPermissionRetry(async () => {
      const h = await this.helper();
      if (!h.has("screen.capture")) throw new HelperError("UNSUPPORTED", "helper does not support screen.capture (rebuild ax_helpers/macos)");
      const t = await this.resolveTarget(target);
      const params = t.kind === "window" ? { pid: t.pid, windowNumber: t.windowNumber } : t.kind === "app" ? { pid: t.pid } : {};
      const r = await h.call("screen.capture", { ...params, maxWidth: opts.maxWidth });
      return { pngBase64: r.pngBase64, width: r.width, height: r.height };
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
