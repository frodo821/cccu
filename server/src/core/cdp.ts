import { HelperError } from "./protocol.js";

/**
 * 最小限の Chrome DevTools Protocol クライアント (ブラウザ接続 1 本、flatten セッション)。
 * Node 22+ / Bun のグローバル WebSocket を使うので依存なし。
 */
type Pending = { resolve: (v: any) => void; reject: (e: Error) => void; method: string };
type EventHandler = (params: any, sessionId?: string) => void;

export class CDPConnection {
  private ws: WebSocket;
  private nextId = 1;
  private pending = new Map<number, Pending>();
  private handlers = new Map<string, Set<EventHandler>>();
  private closed = false;

  private constructor(ws: WebSocket) {
    this.ws = ws;
    ws.addEventListener("message", (ev) => this.onMessage(String(ev.data)));
    ws.addEventListener("close", () => this.onClose());
    ws.addEventListener("error", () => this.onClose());
  }

  static async connect(wsUrl: string): Promise<CDPConnection> {
    const ws = new WebSocket(wsUrl);
    await new Promise<void>((resolve, reject) => {
      ws.addEventListener("open", () => resolve(), { once: true });
      ws.addEventListener("error", () => reject(new HelperError("NOT_FOUND", `cannot connect to ${wsUrl}`)), { once: true });
    });
    return new CDPConnection(ws);
  }

  get isOpen() { return !this.closed && this.ws.readyState === WebSocket.OPEN; }

  send<T = any>(method: string, params: Record<string, unknown> = {}, sessionId?: string): Promise<T> {
    if (!this.isOpen) return Promise.reject(new HelperError("NOT_FOUND", "CDP connection closed"));
    const id = this.nextId++;
    return new Promise<T>((resolve, reject) => {
      this.pending.set(id, { resolve, reject, method });
      this.ws.send(JSON.stringify({ id, method, params, sessionId }));
    });
  }

  on(event: string, handler: EventHandler): () => void {
    let set = this.handlers.get(event);
    if (!set) this.handlers.set(event, (set = new Set()));
    set.add(handler);
    return () => set!.delete(handler);
  }

  /** イベントを 1 回待つ */
  once(event: string, timeoutMs: number, filter?: (params: any, sessionId?: string) => boolean): Promise<any> {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { off(); reject(new HelperError("TIMEOUT", `waiting for ${event}`)); }, timeoutMs);
      const off = this.on(event, (params, sessionId) => {
        if (filter && !filter(params, sessionId)) return;
        clearTimeout(timer); off(); resolve(params);
      });
    });
  }

  close() {
    this.closed = true;
    try { this.ws.close(); } catch { /* ignore */ }
  }

  private onMessage(text: string) {
    const msg = JSON.parse(text);
    if (msg.id != null) {
      const p = this.pending.get(msg.id);
      if (!p) return;
      this.pending.delete(msg.id);
      if (msg.error) p.reject(new HelperError("AX_ERROR", `${p.method}: ${msg.error.message}`, { cdp: msg.error }));
      else p.resolve(msg.result);
      return;
    }
    if (msg.method) {
      for (const h of this.handlers.get(msg.method) ?? []) h(msg.params, msg.sessionId);
    }
  }

  private onClose() {
    if (this.closed) return;
    this.closed = true;
    const err = new HelperError("NOT_FOUND", "CDP connection closed");
    for (const p of this.pending.values()) p.reject(err);
    this.pending.clear();
  }
}

export interface CDPTargetInfo { id: string; type: string; title: string; url: string; webSocketDebuggerUrl?: string }

/** http://host:port/json/* の薄いラッパー */
export async function discover(httpUrl: string): Promise<{ browserWs: string; targets: CDPTargetInfo[] }> {
  const base = httpUrl.replace(/\/$/, "");
  let version: any;
  try {
    version = await (await fetch(`${base}/json/version`)).json();
  } catch {
    throw new HelperError("NOT_FOUND", `no Chrome DevTools endpoint at ${base}`, {
      hint: 'Start Chrome with --remote-debugging-port=9222 (e.g. open -na "Google Chrome" --args --remote-debugging-port=9222), or set CCCU_CDP_URL',
    });
  }
  const targets = (await (await fetch(`${base}/json/list`)).json()) as CDPTargetInfo[];
  return { browserWs: version.webSocketDebuggerUrl, targets };
}
