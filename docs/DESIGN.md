# cccu — Claude Code Computer Use plugin: 設計書

アクセシビリティツリーを介してブラウザと macOS デスクトップを操作する Claude Code プラグイン。
スクリーンショット + 座標クリックではなく、**構造化されたツリー + 安定した参照 (ref)** で操作する。

## 1. ゴール / 非ゴール

ゴール
- Chrome (既存プロセスに CDP でアタッチ) と macOS ネイティブアプリ (AXUIElement) を **同じ操作モデル** で扱う
- LLM が読みやすいテキスト形式のスナップショット (Playwright の aria snapshot 互換の記法) を返す
- スナップショット内の `[ref=e12]` を使って click / type / press などを行う
- Swift ヘルパーとの境界を **バージョン付きの明示的プロトコル** にし、後からメソッドを足せる

非ゴール (初版)
- Windows / Linux 対応
- 画像認識ベースの操作 (screenshot は補助情報として提供するのみ)
- Chrome 以外のブラウザ (Safari は AX ツリー経由で「デスクトップアプリ」として扱える)

## 2. アーキテクチャ

```
Claude Code
  └─ plugin: cccu
       ├─ .mcp.json ──► MCP server (TypeScript, stdio)
       │                  ├─ core/        統一モデル (Target, Snapshot, Ref, Action)
       │                  ├─ backends/
       │                  │    ├─ browser/   CDP 直接 (Accessibility.* / DOM.* / Input.*)
       │                  │    └─ desktop/   Swift ヘルパーを子プロセスとして起動し JSON-RPC で会話
       │                  └─ tools/       MCP ツール定義 (薄いアダプタ)
       ├─ helper/  (Swift Package: `cccu-helper` 実行ファイル)
       └─ skills/  使い方・ワークフロー (SKILL.md)
```

設計原則
1. **Backend インタフェース**を TS 側に置き、browser / desktop はその実装。MCP ツールは Backend を呼ぶだけ
2. **Swift ヘルパーは「AX API の薄い RPC 化」**に徹する。ポリシー (何を省くか、待ち方など) は極力 TS 側に置く。
   ただしツリー走査はプロセス境界を跨ぐと遅いので、フィルタ済みツリーの生成はヘルパー側で行う
3. **ref はスナップショット単位**で有効。`snapshotId` + `ref` の組で指定し、古い参照は明示エラーにする
4. 新しい AX 属性/アクションはプロトコル変更なしで使えるよう、**汎用パススルー** (`ui.attributes` / `ui.setAttribute` / `ui.performAction`) を最初から用意する

## 3. 統一モデル (TS `core/`)

```ts
type TargetId = string;             // "browser:<targetId>" | "app:<pid>" | "window:<pid>:<windowNumber>"

interface Target {
  id: TargetId;
  kind: "browser-page" | "app" | "window";
  title: string;
  url?: string;                     // browser のみ
  bundleId?: string;                // app のみ
  focused: boolean;
}

interface Snapshot {
  id: string;                       // "s7" など。backend ごとに単調増加
  target: TargetId;
  text: string;                     // LLM 向けテキスト (下記 3.1)
  refCount: number;
  truncated: boolean;
}

type Ref = { snapshot: string; ref: string };   // { snapshot: "s7", ref: "e12" }

interface Backend {
  readonly kind: "browser" | "desktop";
  listTargets(): Promise<Target[]>;
  activate(target: TargetId): Promise<void>;
  snapshot(target: TargetId, opts?: SnapshotOptions): Promise<Snapshot>;
  find(target: TargetId, query: FindQuery): Promise<Snapshot>;   // 部分木スナップショット
  click(ref: Ref, opts?: ClickOptions): Promise<void>;
  type(ref: Ref | null, text: string, opts?: { submit?: boolean; clear?: boolean }): Promise<void>;
  key(target: TargetId, key: string, modifiers?: Modifier[]): Promise<void>;
  scroll(ref: Ref | TargetId, dx: number, dy: number): Promise<void>;
  focus(ref: Ref): Promise<void>;
  setValue(ref: Ref, value: string | number | boolean): Promise<void>;
  screenshot(target: TargetId): Promise<{ png: Buffer; scale: number }>;
  waitFor(target: TargetId, cond: WaitCondition, timeoutMs: number): Promise<Snapshot>;
  dispose(): Promise<void>;
}
```

### 3.1 スナップショット記法 (両 backend 共通)

Playwright aria snapshot と同じ YAML 風の記法。既存の LLM が読み慣れている形式を流用する。

```
- window "Untitled — TextEdit" [ref=e1] [focused]
  - toolbar [ref=e2]
    - button "Bold" [ref=e3]
    - popupbutton "Helvetica" [ref=e4]
  - textarea [ref=e5] [focused]: "Hello, wor…"
  - group "Status"
    - text "Line 3"
```

- ref が付くのは **操作可能 (actionable) または識別に有用な要素**のみ。`text` などの葉ノードは ref なし
- `[focused]` `[disabled]` `[selected]` `[checked]` `[expanded]` を状態として付ける
- 値は `: "..."` で末尾に。長い値は 80 文字で切り `…` を付ける
- `interestingOnly` (既定 true) で `group`/`generic` の無名ノードは畳み込む

## 4. Swift ヘルパープロトコル (境界インタフェース)

**これがこのプラグインの拡張ポイントの中心。** 以下を契約として固定する。

### 4.1 トランスポート

- 実行ファイル `cccu-helper` を MCP サーバーが子プロセスとして起動、stdin/stdout で会話
- **JSON-RPC 2.0、改行区切り (NDJSON)**。1 行 1 メッセージ、UTF-8
- stderr はログ専用 (プロトコルには使わない)
- ヘルパー → サーバーの一方向通知 (`id` なし) を許可する (将来 AXObserver イベント用)
- 起動直後、サーバーは `sys.hello` を送り、`protocolVersion` の互換性を確認する

### 4.2 バージョニング

- `protocolVersion` は `MAJOR.MINOR`。MAJOR 不一致は起動失敗、MINOR はヘルパー側が大きければ後方互換
- 新メソッド追加 = MINOR up。既存メソッドの引数削除/意味変更 = MAJOR up
- クライアントは `sys.hello` の `capabilities` (メソッド名の配列) を見て機能検出する

### 4.3 共通型

```jsonc
// Ref: スナップショット由来の要素参照
{ "snapshot": "s7", "ref": "e12" }

// Point / Rect: スクリーン座標 (左上原点、pt 単位)
{ "x": 100, "y": 200 }
{ "x": 0, "y": 0, "w": 800, "h": 600 }

// Modifier: "cmd" | "shift" | "alt" | "ctrl" | "fn"
```

### 4.4 エラー

JSON-RPC の `error.code` は独自範囲 (−32000 以下) を使う。`error.data.kind` に文字列コードを必ず入れる。

| kind               | 意味 |
|--------------------|------|
| `NOT_TRUSTED`      | Accessibility 権限なし。`data.hint` に System Settings への案内 |
| `STALE_REF`        | snapshotId が古い、または要素が既に存在しない |
| `NOT_FOUND`        | pid / window / 要素が見つからない |
| `UNSUPPORTED`      | その要素がそのアクション/属性をサポートしない |
| `AX_ERROR`         | AXError をそのまま。`data.axError` に数値 |
| `TIMEOUT`          | `ui.waitFor` の期限切れ |
| `INVALID_PARAMS`   | 引数不正 |

### 4.5 メソッド一覧 (v1.0)

| method              | params → result | 備考 |
|---------------------|-----------------|------|
| `sys.hello`         | `{clientVersion}` → `{protocolVersion, helperVersion, trusted, capabilities: string[]}` | 最初に必ず呼ぶ |
| `sys.requestTrust`  | `{}` → `{trusted}` | `AXIsProcessTrustedWithOptions(prompt: true)` |
| `app.list`          | `{}` → `{apps: [{pid, name, bundleId, frontmost, hidden}]}` | activationPolicy == .regular のみ |
| `app.activate`      | `{pid}` または `{bundleId}` → `{pid}` | 未起動なら起動 |
| `window.list`       | `{pid?}` → `{windows: [{pid, windowNumber, title, frame, focused, minimized}]}` | |
| `window.raise`      | `{pid, windowNumber}` → `{}` | `AXRaise` |
| `ui.snapshot`       | `{scope, maxDepth?, maxNodes?, interestingOnly?}` → `{snapshot: "s7", text, refCount, truncated}` | `scope` = `{pid}` \| `{pid, windowNumber}` \| `{ref}` (部分木) |
| `ui.find`           | `{scope, role?, title?, value?, exact?}` → `{snapshot, text, refCount}` | 条件に合う要素 + 祖先パスだけのスナップショット |
| `ui.attributes`     | `{ref, names?}` → `{attributes: {AXRole:..., AXFrame:..., ...}}` | `names` 省略で全属性。汎用パススルー |
| `ui.setAttribute`   | `{ref, name, value}` → `{}` | `AXValue`, `AXFocused`, `AXSelectedTextRange` など |
| `ui.performAction`  | `{ref, action}` → `{}` | `AXPress`, `AXShowMenu`, `AXIncrement`, `AXConfirm`, `AXCancel`, `AXRaise`, `AXPick` … |
| `ui.click`          | `{ref?, point?, button?: "left"\|"right", count?: 1\|2, modifiers?}` → `{method: "ax"\|"cg"}` | `ref` なら `AXPress` を試し、不可なら中心座標に CGEvent |
| `ui.focus`          | `{ref}` → `{}` | `AXFocused = true`。必要なら親ウィンドウを raise |
| `ui.waitFor`        | `{scope, condition, timeoutMs}` → `{snapshot, text, refCount}` | `condition` = `{exists: FindQuery}` \| `{gone: FindQuery}` \| `{stable: ms}`。初版はポーリング実装 |
| `input.type`        | `{ref?, text, clear?, submit?}` → `{}` | `ref` があれば focus 後、`AXValue` 設定を優先。不可なら CGEvent でキー入力 |
| `input.key`         | `{key, modifiers?, pid?}` → `{}` | `key` は `"a"`, `"Enter"`, `"Escape"`, `"ArrowDown"`, `"F5"` など W3C 名 |
| `input.scroll`      | `{ref?, point?, dx, dy}` → `{}` | CGEvent scroll wheel |
| `input.mouse`       | `{point, action: "move"\|"down"\|"up"\|"drag", to?, button?}` → `{}` | 低レベル操作。逃げ道として用意 |
| `screen.capture`    | `{pid?, windowNumber?, display?}` → `{pngBase64, scale, frame}` | `ScreenCaptureKit` (14+) 、失敗時は `CGWindowListCreateImage` |
| `sys.shutdown`      | `{}` → `{}` | |

通知 (将来、v1.1 以降): `ax.event` `{pid, notification: "AXValueChanged" | "AXFocusedWindowChanged" | ..., ref?}`

### 4.6 ref のライフサイクル (ヘルパー内部)

- `ui.snapshot` / `ui.find` / `ui.waitFor` は新しい `snapshotId` を発行し、`ref → AXUIElement` の表を保持する
- 直近 **8 スナップショット**を保持、それ以前は破棄 (→ `STALE_REF`)
- ref 利用時は `AXRole` を読んで生存確認。`kAXErrorInvalidUIElement` なら `STALE_REF`
- 同じ要素が複数スナップショットに出ても ref は再割当て (`e1` から振り直す)。「同じ要素か」の判定は行わない

## 5. Browser backend (CDP 直接)

Playwright には依存せず、`chrome-remote-interface` で CDP を叩く (依存が軽く、Swift 側と同じ「素の AX ツリー」思想で揃う)。

- 接続: `http://127.0.0.1:9222` (環境変数 `CCCU_CDP_URL` で変更可)。未起動なら `--remote-debugging-port` 付きで起動する案内を返す (勝手に起動しない)
- ツリー: `Accessibility.getFullAXTree` → `interestingOnly` フィルタ → 3.1 の記法に整形。ref は `backendDOMNodeId` にマップ
- 操作:
  - click → `DOM.getBoxModel` で中心座標 → `Input.dispatchMouseEvent` (フレーム/iframe は `DOM.getFrameOwner` で辿る)
  - type → `DOM.focus` → `Input.insertText` / `Input.dispatchKeyEvent`
  - setValue → `Runtime.callFunctionOn` で `value` 設定 + `input` イベント発火
  - navigate / back / tabs → `Page.navigate`, `Target.*`
- ページ遷移で backendDOMNodeId は無効化されるので、ref 解決失敗は `STALE_REF` として統一

## 6. MCP ツール (初版)

ツール名は短く、`target` 引数で browser / desktop を切り替える。個別ツールを 2 系統に分けない。

| tool | 主な引数 | 説明 |
|------|----------|------|
| `cu_targets` | `kind?` | 開いているタブ・アプリ・ウィンドウの一覧 |
| `cu_snapshot` | `target, scope?, maxDepth?` | アクセシビリティツリーのスナップショット |
| `cu_find` | `target, role?, text?` | 条件に合う要素だけを抜き出す |
| `cu_click` | `ref, button?, count?` | |
| `cu_type` | `ref?, text, submit?, clear?` | |
| `cu_key` | `target, key, modifiers?` | |
| `cu_scroll` | `ref \| target, dx, dy` | |
| `cu_set_value` | `ref, value` | slider / checkbox / select / textfield |
| `cu_wait` | `target, condition, timeoutMs?` | |
| `cu_screenshot` | `target` | 補助用。画像を返す |
| `cu_navigate` | `target, url` / `back` | browser のみ |
| `cu_activate` | `target` | アプリ/タブを前面に |
| `cu_raw` | `target, method, params` | ヘルパー/CDP メソッドへの生パススルー (上級者用、既定でオフ) |

`ref` 引数は `"s7/e12"` の文字列 1 つで受ける (snapshotId とのペアを強制するため)。

## 7. リポジトリ構成 (モノレポ)

```
cccu/
├─ .claude-plugin/plugin.json
├─ .mcp.json                       # ${CLAUDE_PLUGIN_ROOT}/server/dist/index.js を起動
├─ server/                         # TypeScript MCP server (bun でビルド、node で実行)
│   ├─ src/core/                   # 型・スナップショット整形・ref パーサ
│   ├─ src/backends/browser/
│   ├─ src/backends/desktop/       # helper クライアント (JSON-RPC)
│   ├─ src/tools/
│   └─ src/index.ts
├─ ax_helpers/                     # OS ごとのアクセシビリティヘルパー
│   └─ macos/                      # Swift Package (`make test` / `make release`)
│       ├─ Package.swift
│       ├─ Sources/cccu-helper/main.swift      # 実行ファイル: NDJSON ループのみ
│       ├─ Sources/CCCUHelperCore/             # ライブラリ (テスト対象)
│       │   ├─ Protocol/           # JSON-RPC 型・ディスパッチ・エラー・handleLine (§4 の契約)
│       │   ├─ Methods/            # sys.* app.* window.* ui.* input.* screen.*
│       │   ├─ AX/                 # AXUIElement ラッパー・ツリー走査・ref 表
│       │   └─ Input/              # CGEvent
│       └─ Tests/CCCUHelperCoreTests/
│           ├─ ProtocolTests.swift            # 権限不要の単体テスト
│           ├─ AppMethodsTests.swift          # NSWorkspace 依存
│           └─ BinaryIntegrationTests.swift   # ビルド済みバイナリを spawn して stdio 往復
├─ skills/computer-use/SKILL.md    # 使い方・ワークフロー
├─ docs/DESIGN.md                  # 本書
└─ docs/PROTOCOL.md                # §4 の契約書 (正本はこちら)
```

将来 `ax_helpers/windows` (UIA) や `ax_helpers/linux` (AT-SPI) を足しても、同じ §4 プロトコルを話せば TS 側は無変更で済む。

## 8. マイルストーン

1. ✅ **Protocol first**: `docs/PROTOCOL.md` と Swift 側 `Protocol/` (型 + ディスパッチ + `sys.hello`) + TS 側クライアント。`sys.hello` / `app.list` が往復するところまで
2. ✅ Desktop: `ui.snapshot` → `ui.click` → `input.type` → `ui.find` の順で実装。TextEdit で「新規書類を開いて文字を打つ」を通す (`make e2e`)
3. ✅ Browser: CDP 接続 → snapshot → click/type。フィクスチャページでフォーム入力・送信・遷移・STALE_REF を `bun test` で検証
4. ✅ MCP ツール層 + SKILL.md + plugin.json、`claude --plugin-dir` で動作確認 (`claude -p --plugin-dir .` で cu_status / cu_targets 呼び出しを確認)
5. ✅ `ui.waitFor`、screenshot、ヘルパーのビルド配布 (`bin/cccu-server` が初回起動時に `swift build` / `bun build` する)
6. ✅ AXObserver 通知: `ui.observe` / `ax.event` (v1.2)、TS 側はイベントバッファ + `cu_observe` / `cu_events` / `cu_unobserve`
7. ✅ iframe / OOPIF のスナップショット: 同一プロセス iframe は `getFullAXTree({frameId})`、OOPIF は `Target.setAutoAttach` で得た専用セッション。ref は (frame, backendDOMNodeId) で、OOPIF 内の座標は埋め込み元 `<iframe>` の位置を足してトップページの viewport 座標に変換する
8. ✅ ブラウザのイベント購読 (ナビゲーション、ロード、ダイアログ、コンソール、例外、タブ) と `cu_dialog`
9. 今後: Windows (UIA) / Linux (AT-SPI) ヘルパー

## 9. 既知の制約・前提

実装で判明したこと (マイルストーン 3)
- **CDP クライアント**: Node 22+ / Bun のグローバル WebSocket で自前実装 (`core/cdp.ts`)。ブラウザ接続 1 本 + flatten セッション
- **ref の名前空間**: snapshot id の先頭文字で backend を判別する (`s` = desktop, `b` = browser)。ツール層はこれだけで振り分ける
- **編集ショートカット**: macOS の Chrome は合成キーイベントの cmd+A 等を編集コマンドに変換しない。`Input.dispatchKeyEvent` の `commands` (selectAll など) を明示する
- **AX ツリーの整形**: `generic` / `labeltext` / `menulistpopup` などの無名ラッパーは畳み、親と同じ静的テキストの子は落とす
- **iframe**: `getFullAXTree` は 1 フレーム分しか返さない。`iframe` ノードごとに `DOM.describeNode` で content frame の id を引き、同一プロセスなら同じセッションで `frameId` 指定、OOPIF (`Target.attachedToTarget` で type=iframe) なら専用セッションで取得して子としてぶら下げる。入力イベントは常にトップページのセッションへ送る
- **座標**: `DOM.getBoxModel` はスクロール量込みのドキュメント座標を返すので、クリックには使えない (scrollY が 0 のときだけ偶然合う)。viewport 基準の `DOM.getContentQuads` を使う。OOPIF 内の要素は、子フレームの viewport 座標に親側で取った `<iframe>` の viewport 座標を足す。子フレームでの scrollIntoView は親のスクロールも非同期に動かすので、両方の位置が安定するまで読み直してからクリックする
- **ブラウザのイベント**: `Page.frameNavigated` / `loadEventFired` / `javascriptDialogOpening` / `Runtime.consoleAPICalled` / `exceptionThrown` / `Target.targetCreated` などを購読し、desktop と同じ `UIEvent` 形にしてバッファする。購読 id の先頭文字で振り分ける (`o` = desktop, `w` = browser)。JS ダイアログは開いている間ページ操作をブロックするので、購読の有無に関係なく追跡し `cu_dialog` で処理できるようにする
- **AXObserver**: コールバックはメイン run loop で来る。`RunLoop.main.run()` 中に `DispatchQueue.main.sync` でリクエストを処理しているので、応答と通知は同じスレッドで直列化される

実装で判明したこと (マイルストーン 2)
- **前面化**: 非 GUI プロセスからの `NSRunningApplication.activate` は macOS 14+ で無視される。AX の `AXFrontmost` 属性設定で行い、ダメなら `NSWorkspace.openApplication` で再オープンする
- **frontmost 判定**: `NSRunningApplication.isActive` は非 GUI プロセスでは更新されない。`NSWorkspace.frontmostApplication` と `AXMain` を使う
- **キー送信**: `CGEvent.postToPid` はメニューショートカットに届かない。前面化してから HID タップに流す
- **文字入力**: Unicode 打鍵イベント (`keyboardSetUnicodeString`) は新規ウィンドウ直後などに丸ごと落ちることがある。`AXSelectedText` 設定によるキャレット挿入を第一手段にし、打鍵は最後の手段にする

- Accessibility 権限は **Claude Code を起動しているホストアプリ** (Terminal / iTerm / VS Code / Claude Desktop) に付与する必要がある。ヘルパーはその子プロセスとして権限を継承する
- Chrome の AX ツリーは AX API 経由だとレンダラ内容が出ないことがあるため、ブラウザは CDP を使う (Safari は AX でよく動く)
- Electron / Web ベースのネイティブアプリは AX ツリーが巨大になりがち。`maxNodes` と `interestingOnly` で制御
