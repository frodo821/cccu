import type { AXEvent, FindQuery, Modifier, Ref, SnapshotResult } from "./protocol.js";

export interface UIEvent extends Omit<AXEvent, "pid"> { target: string }

/** ツール層が見る統一インタフェース。desktop / browser が実装する (DESIGN.md §3)。 */
export interface TargetInfo {
  id: string;            // "app:123" | "window:123:45" | "tab:ABC"
  kind: "app" | "window" | "tab";
  title: string;
  url?: string;
  bundleId?: string;
  focused: boolean;
  extra?: string[];      // "[hidden]" など表示用フラグ
}

export interface SnapshotOptions { maxDepth?: number; maxNodes?: number; interestingOnly?: boolean }
export type WaitCondition = { exists: FindQuery } | { gone: FindQuery } | { stable: number };

export interface Backend {
  readonly kind: "desktop" | "browser";
  /** この backend が扱う target / snapshot id か */
  ownsTarget(target: string): boolean;
  ownsSnapshot(snapshotId: string): boolean;

  listTargets(): Promise<TargetInfo[]>;
  activate(target: string): Promise<string>;
  snapshot(target: string, opts?: SnapshotOptions): Promise<SnapshotResult>;
  find(target: string, query: FindQuery, opts?: SnapshotOptions): Promise<SnapshotResult>;
  waitFor(target: string, cond: WaitCondition, timeoutMs: number): Promise<SnapshotResult>;

  click(ref: Ref, opts: { button?: "left" | "right"; count?: number; modifiers?: Modifier[] }): Promise<string>;
  type(ref: Ref | undefined, text: string, opts: { clear?: boolean; submit?: boolean }): Promise<string>;
  key(target: string | undefined, key: string, modifiers?: Modifier[]): Promise<void>;
  scroll(ref: Ref, dx: number, dy: number): Promise<void>;
  setValue(ref: Ref, value: string | number | boolean): Promise<void>;
  focus(ref: Ref): Promise<void>;
  attributes(ref: Ref, names?: string[]): Promise<Record<string, unknown>>;
  action(ref: Ref, action: string): Promise<void>;
  /** PNG スクリーンショット (補助情報)。desktop は Screen Recording 権限が要る */
  screenshot(target: string, opts?: { maxWidth?: number }): Promise<{ pngBase64: string; width?: number; height?: number }>;

  /** UI イベント購読 (desktop: AXObserver)。events() はバッファを返して空にする */
  observe(target: string, notifications?: string[]): Promise<{ subscription: string; notifications: string[] }>;
  unobserve(subscription: string): Promise<void>;
  events(): UIEvent[];

  dispose(): Promise<void>;
}
