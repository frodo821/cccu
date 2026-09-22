import { spawn, type ChildProcessByStdio } from "node:child_process";
import { createInterface } from "node:readline";
import type { Readable, Writable } from "node:stream";
import { existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  HelperError, PROTOCOL_MAJOR, PROTOCOL_MIN_MINOR, parseProtocolVersion,
  type HelloResult, type MethodName, type Methods,
} from "../../core/protocol.js";

const CLIENT_VERSION = "0.1.0";

type Pending = { resolve: (v: unknown) => void; reject: (e: Error) => void; method: string };

export interface HelperClientOptions {
  helperPath?: string;
  onNotification?: (method: string, params: unknown) => void;
  log?: (msg: string) => void;
}

/** ヘルパープロセスを起動し JSON-RPC (NDJSON) で会話するクライアント。 */
export class HelperClient {
  private proc: ChildProcessByStdio<Writable, Readable, Readable> | null = null;
  private nextId = 1;
  private pending = new Map<number, Pending>();
  private hello: HelloResult | null = null;
  private readonly log: (msg: string) => void;
  private readonly onNotification?: (method: string, params: unknown) => void;
  private readonly helperPath: string;

  constructor(opts: HelperClientOptions = {}) {
    this.helperPath = opts.helperPath ?? resolveHelperPath();
    this.log = opts.log ?? ((m) => process.stderr.write(`[cccu] ${m}\n`));
    this.onNotification = opts.onNotification;
  }

  get info(): HelloResult {
    if (!this.hello) throw new HelperError("INTERNAL", "helper not started");
    return this.hello;
  }

  has(method: MethodName): boolean {
    return this.hello?.capabilities.includes(method) ?? false;
  }

  async start(): Promise<HelloResult> {
    if (this.proc) return this.info;
    if (!existsSync(this.helperPath)) {
      throw new HelperError("INTERNAL", `helper binary not found: ${this.helperPath}`, {
        hint: "cd ax_helpers/macos && swift build -c release, or set CCCU_HELPER_PATH",
      });
    }
    const proc = spawn(this.helperPath, [], { stdio: ["pipe", "pipe", "pipe"] });
    this.proc = proc;
    proc.stderr.on("data", (d: Buffer) => this.log(d.toString().trimEnd()));
    proc.on("exit", (code, signal) => {
      const err = new HelperError("INTERNAL", `helper exited (code=${code}, signal=${signal})`);
      for (const p of this.pending.values()) p.reject(err);
      this.pending.clear();
      this.proc = null;
      this.hello = null;
    });
    const rl = createInterface({ input: proc.stdout });
    rl.on("line", (line) => this.onLine(line));

    const hello = await this.call("sys.hello", { clientVersion: CLIENT_VERSION });
    const v = parseProtocolVersion(hello.protocolVersion);
    if (v.major !== PROTOCOL_MAJOR || v.minor < PROTOCOL_MIN_MINOR) {
      await this.stop();
      throw new HelperError(
        "INTERNAL",
        `incompatible helper protocol ${hello.protocolVersion} (client needs ${PROTOCOL_MAJOR}.${PROTOCOL_MIN_MINOR}+)`,
      );
    }
    this.hello = hello;
    return hello;
  }

  async stop(): Promise<void> {
    const proc = this.proc;
    if (!proc) return;
    try { await this.call("sys.shutdown", {}); } catch { /* already gone */ }
    proc.stdin.end();
    this.proc = null;
    this.hello = null;
  }

  call<M extends MethodName>(method: M, params: Methods[M]["params"]): Promise<Methods[M]["result"]> {
    const proc = this.proc;
    if (!proc) return Promise.reject(new HelperError("INTERNAL", "helper not running"));
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve: resolve as (v: unknown) => void, reject, method });
      proc.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
    });
  }

  private onLine(line: string) {
    if (!line.trim()) return;
    let msg: any;
    try { msg = JSON.parse(line); } catch { this.log(`non-JSON line from helper: ${line}`); return; }
    if (msg.id == null && typeof msg.method === "string") {
      this.onNotification?.(msg.method, msg.params);   // v1.0: 未知の通知は無視
      return;
    }
    const p = this.pending.get(msg.id);
    if (!p) { this.log(`response for unknown id ${msg.id}`); return; }
    this.pending.delete(msg.id);
    if (msg.error) {
      const { kind = "INTERNAL", ...data } = msg.error.data ?? {};
      p.reject(new HelperError(kind, `${p.method}: ${msg.error.message}`, data));
    } else {
      p.resolve(msg.result);
    }
  }
}

function resolveHelperPath(): string {
  if (process.env.CCCU_HELPER_PATH) return process.env.CCCU_HELPER_PATH;
  // server/dist/index.js または server/src/backends/desktop/HelperClient.ts から repo root を辿る
  const here = dirname(fileURLToPath(import.meta.url));
  const candidates = [
    resolve(here, "../../ax_helpers/macos/.build/release/cccu-helper"),          // dist/
    resolve(here, "../../../../ax_helpers/macos/.build/release/cccu-helper"),    // src/backends/desktop/
  ];
  return candidates.find(existsSync) ?? candidates[0];
}
