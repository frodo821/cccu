// docs/PROTOCOL.md の型定義 (TS 側の正本)。ヘルパー実装とはこのファイル経由でのみ会話する。

export const PROTOCOL_MAJOR = 1;
export const PROTOCOL_MIN_MINOR = 0;

export type Ref = { snapshot: string; ref: string };
export type Point = { x: number; y: number };
export type Rect = { x: number; y: number; w: number; h: number };
export type Modifier = "cmd" | "shift" | "alt" | "ctrl" | "fn";
export type ReportMode = "none" | "diff" | "full";
export type Scope = { pid: number } | { pid: number; windowNumber: number } | { pid: number; webarea: true } | { ref: Ref };
export type FindQuery = { role?: string; title?: string; value?: string; exact?: boolean; enabled?: boolean };

export type ErrorKind =
  | "NOT_TRUSTED" | "STALE_REF" | "NOT_FOUND" | "UNSUPPORTED" | "AX_ERROR"
  | "TIMEOUT" | "OBSTRUCTED" | "BUSY" | "INVALID_PARAMS" | "METHOD_NOT_FOUND" | "PARSE_ERROR" | "INTERNAL";

export class HelperError extends Error {
  constructor(
    public readonly kind: ErrorKind,
    message: string,
    public readonly data: Record<string, unknown> = {},
  ) {
    super(message);
    this.name = "HelperError";
  }
}

/** 操作後の変化 (report: diff|full) */
export interface Changes { snapshot: string; refCount: number; changed: boolean; waitMs?: number; added?: number; removed?: number; addedLines?: string[]; removedLines?: string[]; full?: string }
export interface SessionStatus { active: boolean; pid?: number; blocking?: boolean; remainingSeconds?: number }
export interface HelloResult {
  protocolVersion: string;
  helperVersion: string;
  platform: string;
  trusted: boolean;            // Accessibility
  screenRecording?: boolean;   // v1.3
  responsible?: boolean;       // v1.3: ヘルパー自身が TCC の責任プロセスか
  activation?: "background" | "restore" | "foreground";   // v1.4: 前面化ポリシー
  pointer?: "human" | "warp";                             // v1.5: ポインタの動かし方
  capabilities: string[];
}

export interface AppInfo {
  pid: number; name: string; bundleId?: string; frontmost: boolean; hidden: boolean;
}
export interface WindowInfo {
  pid: number; windowNumber: number; title: string; frame: Rect; focused: boolean; minimized: boolean;
}
export interface SnapshotResult {
  snapshot: string; text: string; refCount: number; truncated: boolean; truncatedBy?: "nodes" | "depth";
  matches?: number;   // find / waitFor: 一致数 (祖先の ref は含まない)
}

/** method 名 → { params, result } の対応表。呼び出し側はこの表で型が付く。 */
export interface Methods {
  "sys.hello": { params: { clientVersion: string }; result: HelloResult };
  "sys.requestTrust": { params: Record<string, never>; result: { trusted: boolean } };
  "sys.shutdown": { params: Record<string, never>; result: Record<string, never> };
  "app.list": { params: Record<string, never>; result: { apps: AppInfo[] } };
  "app.activate": { params: { pid: number } | { bundleId: string }; result: { pid: number } };
  "app.launch": { params: { bundleId: string; activate?: boolean }; result: { pid: number; launched: boolean } };
  "window.list": { params: { pid?: number }; result: { windows: WindowInfo[] } };
  "window.raise": { params: { pid: number; windowNumber: number }; result: Record<string, never> };
  "ui.snapshot": {
    params: { scope: Scope; maxDepth?: number; maxNodes?: number; interestingOnly?: boolean; textLimit?: number; skipWebContent?: boolean };
    result: SnapshotResult;
  };
  "ui.query": { params: { scope: Scope; selector: string; maxNodes?: number; textLimit?: number; skipWebContent?: boolean }; result: SnapshotResult };
  "ui.find": { params: { scope: Scope; query: FindQuery; maxNodes?: number; textLimit?: number; skipWebContent?: boolean }; result: SnapshotResult };
  "ui.attributes": { params: { ref: Ref; names?: string[] }; result: { attributes: Record<string, unknown> } };
  "ui.setAttribute": { params: { ref: Ref; name: string; value: unknown; report?: ReportMode; textLimit?: number; reportWaitMs?: number }; result: { changes?: Changes; warning?: string } };
  "ui.performAction": { params: { ref: Ref; action: string; report?: ReportMode; textLimit?: number; reportWaitMs?: number }; result: { changes?: Changes; warning?: string } };
  "ui.click": {
    params: { ref?: Ref; point?: Point; button?: "left" | "right"; count?: number; modifiers?: Modifier[]; foreground?: boolean; pointer?: "human" | "warp"; force?: boolean; report?: ReportMode; textLimit?: number; reportWaitMs?: number };
    result: { method: string; warning?: string; changes?: Changes };
  };
  "ui.focus": { params: { ref: Ref }; result: Record<string, never> };
  "ui.waitFor": {
    params: { scope: Scope; condition: { exists: FindQuery; count?: number } | { gone: FindQuery } | { stable: number }; timeoutMs: number; textLimit?: number; maxDepth?: number; maxNodes?: number; skipWebContent?: boolean };
    result: SnapshotResult;
  };
  "input.type": { params: { ref?: Ref; pid?: number; text: string; clear?: boolean; submit?: boolean; method?: "auto" | "keys" | "ax"; foreground?: boolean; report?: ReportMode; textLimit?: number; reportWaitMs?: number }; result: { method: string; warning?: string; changes?: Changes } };
  "input.key": { params: { key: string; modifiers?: Modifier[]; pid?: number; foreground?: boolean; report?: ReportMode; textLimit?: number; reportWaitMs?: number }; result: { method: string; item?: string; warning?: string; changes?: Changes } };
  "session.begin": { params: { pid?: number; bundleId?: string; blockInput?: boolean; maxSeconds: number }; result: { pid: number; previousPid?: number; blocking: boolean; maxSeconds: number; warning?: string } };
  "session.extend": { params: { maxSeconds: number }; result: SessionStatus };
  "session.end": { params: Record<string, never>; result: { active: false; blockedInputs?: number; seconds?: number; warning?: string } };
  "session.status": { params: Record<string, never>; result: SessionStatus };
  "input.scroll": { params: { ref?: Ref; point?: Point; dx: number; dy: number; foreground?: boolean; pointer?: "human" | "warp" }; result: { method: string; anchor?: string; warning?: string } };
  "input.mouse": {
    params: { point: Point; action: "move" | "down" | "up" | "drag"; to?: Point; button?: "left" | "right" };
    result: Record<string, never>;
  };
  "screen.capture": { // grid: 画面座標のグリッド線の間隔 (px)。省略で無し

    params: { pid?: number; windowNumber?: number; display?: number; maxWidth?: number; grid?: number};
    result: { pngBase64: string; scale: number; frame: Rect; width: number; height: number };
  };
  "ui.observe": { params: { pid: number; notifications?: string[]; ref?: Ref }; result: { subscription: string; notifications: string[] } };
  "ui.unobserve": { params: { subscription: string }; result: Record<string, never> };
}
export type MethodName = keyof Methods;

/** ヘルパー → クライアントの `ax.event` 通知 */
export interface AXEvent {
  subscription: string; pid: number; notification: string;
  element: { role?: string; title?: string; value?: unknown }; time: number;
}

export function parseProtocolVersion(v: string): { major: number; minor: number } {
  const m = /^(\d+)\.(\d+)$/.exec(v);
  if (!m) throw new HelperError("INTERNAL", `bad protocolVersion: ${v}`);
  return { major: Number(m[1]), minor: Number(m[2]) };
}
