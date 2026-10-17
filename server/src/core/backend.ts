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

export type BrowserScope = "page" | "app";
/** desktop: 操作後の変化の報告 (none | diff | full) と、その行の文字数上限 */
export interface ActionReportOptions { report?: "none" | "diff" | "full"; textLimit?: number; reportWaitMs?: number }
export interface SnapshotOptions { maxDepth?: number; maxNodes?: number; interestingOnly?: boolean; within?: Ref; textLimit?: number; scope?: BrowserScope }
export type WaitCondition = { exists: FindQuery; count?: number } | { gone: FindQuery } | { stable: number };

export interface Backend {
  readonly kind: "desktop" | "browser";
  /** この backend が扱う target / snapshot id か */
  ownsTarget(target: string): boolean;
  ownsSnapshot(snapshotId: string): boolean;

  listTargets(): Promise<TargetInfo[]>;
  /** URL を開く / back / forward / close。desktop ではブラウザアプリのアドレスバー経由 */
  navigate?(target: string | undefined, url: string): Promise<string>;
  /** 操作セッション: 対象アプリを前面に保ちユーザー入力を遮断する (desktop) */
  inputSession?(action: "begin" | "extend" | "end" | "status", target?: string, opts?: { blockInput?: boolean; maxSeconds?: number }): Promise<string>;
  activate(target: string): Promise<string>;
  snapshot(target: string, opts?: SnapshotOptions): Promise<SnapshotResult>;
  find(target: string, query: FindQuery, opts?: SnapshotOptions): Promise<SnapshotResult>;
  /** CSS セレクタ風の構造クエリ (desktop) */
  query?(target: string, selector: string, opts?: SnapshotOptions): Promise<SnapshotResult>;
  waitFor(target: string, cond: WaitCondition, timeoutMs: number, within?: Ref, textLimit?: number, scope?: BrowserScope, tree?: { maxDepth?: number; maxNodes?: number }): Promise<SnapshotResult>;

  /** foreground: 効かなかった操作を「一瞬前面化して実行し、元のアプリへ戻す」でやり直すための指定 (desktop のみ意味を持つ) */
  /** desktop: 画面座標をクリック (AX ツリーが使えないときのフォールバック) */
  clickAt?(x: number, y: number, opts: { button?: "left" | "right"; count?: number; modifiers?: Modifier[]; pointer?: "human" | "warp" }): Promise<string>;
  click(ref: Ref, opts: { button?: "left" | "right"; count?: number; modifiers?: Modifier[]; foreground?: boolean; pointer?: "human" | "warp"; force?: boolean } & ActionReportOptions): Promise<string>;
  type(ref: Ref | undefined, text: string, opts: { clear?: boolean; submit?: boolean; foreground?: boolean } & ActionReportOptions): Promise<string>;
  key(target: string | undefined, key: string, modifiers?: Modifier[], opts?: { foreground?: boolean } & ActionReportOptions): Promise<string>;
  scroll(ref: Ref, dx: number, dy: number, opts?: { foreground?: boolean; pointer?: "human" | "warp" }): Promise<string>;
  setValue(ref: Ref, value: string | number | boolean, opts?: ActionReportOptions): Promise<string | void>;
  focus(ref: Ref): Promise<void>;
  attributes(ref: Ref, names?: string[]): Promise<Record<string, unknown>>;
  action(ref: Ref, action: string, opts?: ActionReportOptions): Promise<string | void>;
  /** PNG スクリーンショット (補助情報)。desktop は Screen Recording 権限が要る */
  screenshot(target: string, opts?: { maxWidth?: number; grid?: number }): Promise<{ pngBase64: string; width?: number; height?: number; frame?: { x: number; y: number; w: number; h: number }; scale?: number }>;

  /** UI イベント購読 (desktop: AXObserver)。events() はバッファを返して空にする */
  observe(target: string, notifications?: string[]): Promise<{ subscription: string; notifications: string[] }>;
  unobserve(subscription: string): Promise<void>;
  events(): UIEvent[];

  dispose(): Promise<void>;
}
