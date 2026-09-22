import CCCUHelperCore
import Foundation

// NDJSON ループ。stdin の各行を JSON-RPC リクエストとして処理し、stdout に応答を書く。
// AX API はメインスレッドから呼ぶ前提なので、読み取りはバックグラウンド、処理はメインで行う。

let dispatcher = makeDispatcher(shutdown: { exit(0) })

let reader = Thread {
    while let line = readLine(strippingNewline: true) {
        DispatchQueue.main.sync {
            if let response = handleLine(line, dispatcher: dispatcher) { Transport.send(response) }
        }
    }
    DispatchQueue.main.async { exit(0) }   // stdin EOF
}
reader.start()
Transport.log("started (protocol \(protocolVersion), helper \(helperVersion))")
RunLoop.main.run()
