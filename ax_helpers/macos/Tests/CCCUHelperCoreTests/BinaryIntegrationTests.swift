import XCTest

/// ビルド済み `cccu-helper` 実行ファイルを子プロセスとして起動し、stdio 経由で NDJSON を往復させる。
/// TS 側 HelperClient と同じ経路を通す結合テスト。
final class BinaryIntegrationTests: XCTestCase {
    private var proc: Process!
    private var stdinPipe: Pipe!
    private var stdoutHandle: FileHandle!
    private var buffer = Data()

    override func setUpWithError() throws {
        // テストバンドルと同じビルドディレクトリにある実行ファイルを使う
        let buildDir = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let bin = buildDir.appendingPathComponent("cccu-helper")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: bin.path), "cccu-helper not built at \(bin.path)")

        proc = Process()
        proc.executableURL = bin
        stdinPipe = Pipe()
        let out = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        stdoutHandle = out.fileHandleForReading
        try proc.run()
    }

    override func tearDown() {
        if proc.isRunning { proc.terminate() }
        proc.waitUntilExit()
    }

    private func send(_ line: String) {
        stdinPipe.fileHandleForWriting.write((line + "\n").data(using: .utf8)!)
    }

    private func readLine(timeout: TimeInterval = 5) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                return try JSONSerialization.jsonObject(with: line) as! [String: Any]
            }
            let chunk = stdoutHandle.availableData   // ブロッキング読み
            if chunk.isEmpty { break }
            buffer.append(chunk)
        }
        throw XCTSkip("no response within \(timeout)s")
    }

    func testHelloThenListThenShutdown() throws {
        send(#"{"jsonrpc":"2.0","id":1,"method":"sys.hello","params":{"clientVersion":"test"}}"#)
        let hello = try readLine()
        XCTAssertEqual(hello["id"] as? Int, 1)
        let res = hello["result"] as! [String: Any]
        XCTAssertTrue((res["protocolVersion"] as? String)?.hasPrefix("1.") == true)
        XCTAssertTrue((res["capabilities"] as! [String]).contains("app.list"))

        send(#"{"jsonrpc":"2.0","id":2,"method":"app.list","params":{}}"#)
        let list = try readLine()
        XCTAssertEqual(list["id"] as? Int, 2)
        XCTAssertFalse(((list["result"] as! [String: Any])["apps"] as! [Any]).isEmpty)

        // 通知 (id なし) には応答が返らず、次の応答が乱れないこと
        send(#"{"jsonrpc":"2.0","method":"sys.hello","params":{}}"#)
        send(#"{"jsonrpc":"2.0","id":3,"method":"sys.shutdown","params":{}}"#)
        let bye = try readLine()
        XCTAssertEqual(bye["id"] as? Int, 3)
        XCTAssertNotNil(bye["result"])

        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0)
    }

    func testStdoutContainsOnlyJSON() throws {
        send(#"{"id":1,"method":"sys.hello"}"#)
        _ = try readLine()
        send("garbage")
        let err = try readLine()
        XCTAssertTrue(err["id"] is NSNull)
        XCTAssertEqual(((err["error"] as! [String: Any])["code"] as? Int), -32700)
    }

    func testEOFTerminatesProcess() throws {
        send(#"{"id":1,"method":"sys.hello"}"#)
        _ = try readLine()
        try stdinPipe.fileHandleForWriting.close()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0)
    }
}
