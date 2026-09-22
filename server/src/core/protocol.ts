// docs/PROTOCOL.md の型定義 (TS 側の正本)。ヘルパー実装とはこのファイル経由でのみ会話する。

export const PROTOCOL_MAJOR = 1;
export const PROTOCOL_MIN_MINOR = 0;

export type Ref = { snapshot: string; ref: string };
export type Point = { x: number; y: number };
export type Rect = { x: number; y: number; w: number; h: number };
export type Modifier = "cmd" | "shift" | "alt" | "ctrl" | "fn";
export type Scope = { pid: number } | { pid: number; windowNumber: number } | { ref: Ref };
export type FindQuery = { role?: string; title?: string; value?: string; exact?: boolean };

export type ErrorKind =
  | "NOT_TRUSTED" | "STALE_REF" | "NOT_FOUND" | "UNSUPPORTED" | "AX_ERROR"
  | "TIMEOUT" | "INVALID_PARAMS" | "METHOD_NOT_FOUND" | "PARSE_ERROR" | "INTERNAL";

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

export interface HelloResult {
  protocolVersion: string;
  helperVersion: string;
  platform: string;
  trusted: boolean;
  capabilities: string[];
}

export interface AppInfo {
  pid: number; name: string; bundleId?: string; frontmost: boolean; hidden: boolean;
}
export interface WindowInfo {
  pid: number; windowNumber: number; title: string; frame: Rect; focused: boolean; minimized: boolean;
}
export interface SnapshotResult {
  snapshot: string; text: string; refCount: number; truncated: boolean;
}

/** method 名 → { params, result } の対応表。呼び出し側はこの表で型が付く。 */
export interface Methods {
  "sys.hello": { params: { clientVersion: string }; result: HelloResult };
  "sys.requestTrust": { params: Record<string, never>; result: { trusted: boolean } };
  "sys.shutdown": { params: Record<string, never>; result: Record<string, never> };
  "app.list": { params: Record<string, never>; result: { apps: AppInfo[] } };
  "app.activate": { params: { pid: number } | { bundleId: string }; result: { pid: number } };
  "window.list": { params: { pid?: number }; result: { windows: WindowInfo[] } };
  "window.raise": { params: { pid: number; windowNumber: number }; result: Record<string, never> };
  "ui.snapshot": {
    params: { scope: Scope; maxDepth?: number; maxNodes?: number; interestingOnly?: boolean };
    result: SnapshotResult;
  };
  "ui.find": { params: { scope: Scope; query: FindQuery; maxNodes?: number }; result: SnapshotResult };
  "ui.attributes": { params: { ref: Ref; names?: string[] }; result: { attributes: Record<string, unknown> } };
  "ui.setAttribute": { params: { ref: Ref; name: string; value: unknown }; result: Record<string, never> };
  "ui.performAction": { params: { ref: Ref; action: string }; result: Record<string, never> };
  "ui.click": {
    params: { ref?: Ref; point?: Point; button?: "left" | "right"; count?: number; modifiers?: Modifier[] };
    result: { method: "ax" | "cg" };
  };
  "ui.focus": { params: { ref: Ref }; result: Record<string, never> };
  "ui.waitFor": {
    params: { scope: Scope; condition: { exists: FindQuery } | { gone: FindQuery } | { stable: number }; timeoutMs: number };
    result: SnapshotResult;
  };
  "input.type": { params: { ref?: Ref; text: string; clear?: boolean; submit?: boolean }; result: { method: "selectedText" | "value" | "keys" } };
  "input.key": { params: { key: string; modifiers?: Modifier[]; pid?: number }; result: Record<string, never> };
  "input.scroll": { params: { ref?: Ref; point?: Point; dx: number; dy: number }; result: Record<string, never> };
  "input.mouse": {
    params: { point: Point; action: "move" | "down" | "up" | "drag"; to?: Point; button?: "left" | "right" };
    result: Record<string, never>;
  };
  "screen.capture": {
    params: { pid?: number; windowNumber?: number; display?: number; maxWidth?: number };
    result: { pngBase64: string; scale: number; frame: Rect; width: number; height: number };
  };
}
export type MethodName = keyof Methods;

export function parseProtocolVersion(v: string): { major: number; minor: number } {
  const m = /^(\d+)\.(\d+)$/.exec(v);
  if (!m) throw new HelperError("INTERNAL", `bad protocolVersion: ${v}`);
  return { major: Number(m[1]), minor: Number(m[2]) };
}
