import CCCUHelperCore
import Foundation

// NDJSON ループ。stdin の各行を JSON-RPC リクエストとして処理し、stdout に応答を書く。
// AX API はメインスレッドから呼ぶ前提なので、読み取りはバックグラウンド、処理はメインで行う。

// TCC の責任プロセスを自分自身にする (権限が Terminal 等のホストではなくヘルパーに紐づく)
reexecAsResponsibleProcessIfNeeded()

// CLI モード (インストール時の権限セットアップ / 状態表示)
let args = CommandLine.arguments.dropFirst()
setvbuf(stdout, nil, _IOLBF, 0)   // パイプ越しでも進捗が逐次見えるように行バッファリングにする
if args.contains("--permissions") {
    let st = PermissionSetup.status()
    print(String(data: try! JSONSerialization.data(withJSONObject: st.merging(["responsible": ProcessInfo.processInfo.environment[disclaimedEnv] != nil]) { a, _ in a }, options: [.sortedKeys]), encoding: .utf8)!)
    exit(0)
}
if args.contains("--setup-permissions") {
    let timeout = args.first(where: { $0.hasPrefix("--timeout=") }).flatMap { Double($0.dropFirst("--timeout=".count)) } ?? 120
    exit(PermissionSetup.run(timeout: timeout, wantScreen: !args.contains("--no-screen")))
}

let dispatcher = makeDispatcher(shutdown: { exit(0) })

// リクエストはメインスレッドで処理するが、DispatchQueue.main.sync には載せない。
// メインキューのブロック内で処理すると、処理中はメインキューが塞がり、フォーカス変更などの通知
// (メインキュー経由で届く) が run loop を回しても処理されず、アクティブなアプリの状態が古いままになる。
// run loop のブロックとして実行すれば、ハンドラ内で run loop を回したときにメインキューも処理される
func onMainRunLoop(_ block: @escaping () -> Void) {
    CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue, block)
    CFRunLoopWakeUp(CFRunLoopGetMain())
}

let reader = Thread {
    while let line = readLine(strippingNewline: true) {
        let done = DispatchSemaphore(value: 0)
        onMainRunLoop {
            if let response = handleLine(line, dispatcher: dispatcher) { Transport.send(response) }
            done.signal()
        }
        done.wait()
    }
    onMainRunLoop { exit(0) }   // stdin EOF
}
reader.start()
Transport.log("started (protocol \(protocolVersion), helper \(helperVersion))")
RunLoop.main.run()
