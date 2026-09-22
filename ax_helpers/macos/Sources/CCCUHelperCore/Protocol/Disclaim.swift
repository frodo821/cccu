import Darwin
import Foundation

// 非公開 API: posix_spawn 属性に「責任の放棄」を設定する。これを付けて spawn した子プロセスは
// TCC (プライバシー権限) 上で親ではなく自分自身が責任プロセスになる (Chrome / Electron が使用)。
@_silgen_name("responsibility_spawnattrs_setdisclaim")
private func responsibility_spawnattrs_setdisclaim(_ attrs: UnsafeMutablePointer<posix_spawnattr_t?>, _ disclaim: Int32) -> Int32

public let disclaimedEnv = "CCCU_HELPER_DISCLAIMED"

/// 自分自身を責任プロセスとして再起動し、その終了コードで exit する。
/// 既に再起動後 (環境変数あり) か、CCCU_NO_DISCLAIM が設定されていれば何もしない。
public func reexecAsResponsibleProcessIfNeeded() {
    let env = ProcessInfo.processInfo.environment
    if env[disclaimedEnv] != nil || env["CCCU_NO_DISCLAIM"] != nil { return }

    var attrs: posix_spawnattr_t? = nil
    posix_spawnattr_init(&attrs)
    defer { posix_spawnattr_destroy(&attrs) }
    guard responsibility_spawnattrs_setdisclaim(&attrs, 1) == 0 else {
        Transport.log("disclaim unavailable; running as child of the host app")
        return
    }
    // stdio はそのまま継承する (posix_spawn の既定)。環境変数で再帰を止める
    var newEnv = env
    newEnv[disclaimedEnv] = "1"
    var envp: [UnsafeMutablePointer<CChar>?] = newEnv.map { strdup("\($0.key)=\($0.value)") }
    envp.append(nil)
    var argv: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.map { strdup($0) }
    argv.append(nil)
    let path = CommandLine.arguments[0]
    var pid: pid_t = 0
    let rc = posix_spawn(&pid, path, nil, &attrs, argv, envp)
    argv.forEach { free($0) }; envp.forEach { free($0) }
    guard rc == 0 else {
        Transport.log("re-exec failed (\(rc)); running as child of the host app")
        return
    }
    // 親はシグナルを子へ転送しつつ待つ
    signal(SIGTERM) { _ in }   // SIGTERM で自分が落ちる前に子へ伝える
    signal(SIGINT) { _ in }
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0 && errno == EINTR {
        kill(pid, SIGTERM)
    }
    exit(WIFEXITED(status) ? WEXITSTATUS(status) : 1)
}

private func WIFEXITED(_ s: Int32) -> Bool { (s & 0x7f) == 0 }
private func WEXITSTATUS(_ s: Int32) -> Int32 { (s >> 8) & 0xff }
