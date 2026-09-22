# cccu helper protocol v1.1

MCP サーバー (クライアント) と OS 別アクセシビリティヘルパー (サーバー) の間の契約。
`ax_helpers/*` の実装はすべてこの文書に従う。設計背景は `DESIGN.md` §4。

## 1. トランスポート

- クライアントがヘルパー実行ファイルを子プロセスとして起動する
- **JSON-RPC 2.0 / NDJSON**: stdin → リクエスト、stdout → レスポンス・通知。1 行 1 メッセージ、UTF-8、改行は `\n`
- stderr はログ専用。クライアントはこれをプロトコルとして解釈しない
- ヘルパーは stdin の EOF でクリーンに終了する
- リクエストは順不同で処理してよいが、初版ヘルパーは直列処理する

```jsonc
// request
{"jsonrpc":"2.0","id":1,"method":"sys.hello","params":{"clientVersion":"0.1.0"}}
// response
{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"1.0","helperVersion":"0.1.0","trusted":true,"capabilities":["sys.hello","app.list"]}}
// error
{"jsonrpc":"2.0","id":2,"error":{"code":-32001,"message":"Accessibility not trusted","data":{"kind":"NOT_TRUSTED","hint":"System Settings > Privacy & Security > Accessibility"}}}
// notification (helper → client, id なし)
{"jsonrpc":"2.0","method":"ax.event","params":{"pid":123,"notification":"AXFocusedWindowChanged"}}
```

## 2. バージョニング

- `protocolVersion` は `"MAJOR.MINOR"` 文字列
- クライアントは起動直後に必ず `sys.hello` を送る。MAJOR 不一致なら接続を捨てる。MINOR はヘルパー側が同じか大きければ互換
- 追加のみ (新メソッド、任意パラメータ、結果フィールド追加) → MINOR up
- 既存メソッドの削除・必須パラメータ追加・意味変更 → MAJOR up
- クライアントは `capabilities` でメソッドの有無を判定し、無ければ代替 (別メソッド or 非対応エラー) にフォールバックする

## 3. 共通型

```jsonc
Ref       = { "snapshot": "s7", "ref": "e12" }
Point     = { "x": 100.0, "y": 200.0 }           // スクリーン座標、左上原点、pt
Rect      = { "x": 0, "y": 0, "w": 800, "h": 600 }
Modifier  = "cmd" | "shift" | "alt" | "ctrl" | "fn"
Scope     = { "pid": 123 } | { "pid": 123, "windowNumber": 45 } | { "ref": Ref }
FindQuery = { "role"?: string, "title"?: string, "value"?: string, "exact"?: boolean }
           // role は AX ロール名から "AX" を除いた小文字 ("button", "textfield" …)
           // title/value は部分一致 (exact=true で完全一致)。複数条件は AND
```

## 4. エラー

`error.code` は −32000 〜 −32099。`error.data.kind` を必ず含める。

| code   | kind             | 意味 |
|--------|------------------|------|
| -32001 | `NOT_TRUSTED`    | Accessibility 権限なし。`data.hint` に案内 |
| -32002 | `STALE_REF`      | snapshot が破棄済み、または要素が消滅 |
| -32003 | `NOT_FOUND`      | pid / window / 要素が見つからない |
| -32004 | `UNSUPPORTED`    | その要素がそのアクション/属性に非対応 |
| -32005 | `AX_ERROR`       | OS API の失敗。`data.axError` に生の数値 |
| -32006 | `TIMEOUT`        | `ui.waitFor` 期限切れ |
| -32602 | `INVALID_PARAMS` | 引数不正 (JSON-RPC 標準コード) |
| -32601 | `METHOD_NOT_FOUND` | (JSON-RPC 標準) |
| -32700 | `PARSE_ERROR`    | (JSON-RPC 標準) |

## 5. メソッド

### sys

| method | params | result |
|--------|--------|--------|
| `sys.hello` | `{clientVersion: string}` | `{protocolVersion, helperVersion, platform: "macos", trusted: boolean, capabilities: string[]}` |
| `sys.requestTrust` | `{}` | `{trusted: boolean}` — OS の権限ダイアログを出す |
| `sys.shutdown` | `{}` | `{}` — 応答後に終了 |

### app / window

| method | params | result |
|--------|--------|--------|
| `app.list` | `{}` | `{apps: [{pid, name, bundleId?, frontmost, hidden}]}` |
| `app.activate` | `{pid}` \| `{bundleId}` | `{pid}` — 未起動なら起動して待つ。前面化は AXFrontmost 属性で行う (非 GUI プロセスからの NSRunningApplication.activate は macOS 14+ で無視される) |
| `window.list` | `{pid?}` | `{windows: [{pid, windowNumber, title, frame: Rect, focused, minimized}]}` |
| `window.raise` | `{pid, windowNumber}` | `{}` |

### ui

| method | params | result |
|--------|--------|--------|
| `ui.snapshot` | `{scope: Scope, maxDepth?: int, maxNodes?: int, interestingOnly?: boolean}` | `{snapshot: string, text: string, refCount: int, truncated: boolean}` |
| `ui.find` | `{scope: Scope, query: FindQuery, maxNodes?: int}` | `{snapshot, text, refCount}` — 一致要素 (子孫を含む) とそこへ至る祖先のみ |
| `ui.attributes` | `{ref: Ref, names?: string[]}` | `{attributes: {[AXName]: value}}` |
| `ui.setAttribute` | `{ref: Ref, name: string, value: any}` | `{}` |
| `ui.performAction` | `{ref: Ref, action: string}` | `{}` — `AXPress` など AX アクション名そのまま |
| `ui.click` | `{ref?: Ref, point?: Point, button?: "left"\|"right", count?: int, modifiers?: Modifier[]}` | `{method: "ax"\|"cg"}` |
| `ui.focus` | `{ref: Ref}` | `{}` |
| `ui.waitFor` | `{scope: Scope, condition: {exists: FindQuery} \| {gone: FindQuery} \| {stable: int}, timeoutMs: int}` | `{snapshot, text, refCount}` |

### input

| method | params | result |
|--------|--------|--------|
| `input.type` | `{ref?: Ref, text: string, clear?: boolean, submit?: boolean}` | `{method: "selectedText"\|"value"\|"keys"}` — ref 省略時はフォーカス中の要素。AXSelectedText 挿入 → AXValue 置換 → 打鍵 の順に試す |
| `input.key` | `{key: string, modifiers?: Modifier[], pid?: int}` | `{}` — `key` は W3C `KeyboardEvent.key` 名。`pid` 指定時はそのアプリを前面にしてから送る |
| `input.scroll` | `{ref?: Ref, point?: Point, dx: number, dy: number}` | `{}` |
| `input.mouse` | `{point: Point, action: "move"\|"down"\|"up"\|"drag", to?: Point, button?: "left"\|"right"}` | `{}` |

### screen

| method | params | result |
|--------|--------|--------|
| `screen.capture` | `{pid?: int, windowNumber?: int, display?: int, maxWidth?: int}` | `{pngBase64: string, scale: number, frame: Rect, width: int, height: int}` — `pid` のみならメインウィンドウ、どちらも無ければメインディスプレイ。`maxWidth` (既定 1600) に縮小。Screen Recording 未許可なら `NOT_TRUSTED` + `data.permission = "screenRecording"` (v1.1) |

## 6. スナップショット記法

```
- window "Untitled — TextEdit" [ref=e1] [focused]
  - toolbar [ref=e2]
    - button "Bold" [ref=e3]
    - popupbutton "Helvetica" [ref=e4]
  - textarea [ref=e5] [focused]: "Hello, wor…"
  - group "Status"
    - text "Line 3"
```

- 1 行 1 ノード、インデント 2 スペース、`- role "title"` の順。title がなければ省略
- ref は操作可能または識別に有用なノードにのみ付与。`e1` から連番
- 状態フラグ: `[focused] [disabled] [selected] [checked] [expanded] [collapsed]`
- 値は `: "…"` を末尾に。80 文字で切り詰め、末尾に `…`
- `interestingOnly=true` (既定) では title も value も ref もない `group`/`generic` は子を親に繰り上げる
- `truncated=true` は `maxNodes` / `maxDepth` で打ち切ったことを示す

## 7. ref のライフサイクル

- `ui.snapshot` / `ui.find` / `ui.waitFor` は新しい snapshot id を発行する (`s1` から連番、プロセス内で一意)
- ヘルパーは直近 8 スナップショットの `ref → 要素ハンドル` 表を保持し、それ以前は破棄する
- ref 使用時、要素の生存確認に失敗したら `STALE_REF`
- スナップショットを跨いだ同一性は保証しない

## 8. 通知 (予約、v1.2 以降)

`ax.event` `{pid, notification: string, ref?: Ref}` — 購読 API (`ui.observe`) と併せて追加予定。クライアントは未知の通知を無視しなければならない。

## 9. 変更履歴

- 1.1: `screen.capture` 実装、`maxWidth` / `width` / `height` 追加
- 1.0: 初版
