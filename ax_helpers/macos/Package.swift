// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "cccu-helper",
    platforms: [.macOS(.v13)],
    targets: [
        // プロトコル・メソッド実装。テスト対象はこちら
        .target(
            name: "CCCUHelperCore",
            path: "Sources/CCCUHelperCore"
        ),
        // stdio ループだけの薄い実行ファイル
        .executableTarget(
            name: "cccu-helper",
            dependencies: ["CCCUHelperCore"],
            path: "Sources/cccu-helper",
            // CLI バイナリに Info.plist を埋め込む (TCC のダイアログ / 設定画面での名前と識別子)
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Info.plist"])]
        ),
        .testTarget(
            name: "CCCUHelperCoreTests",
            dependencies: ["CCCUHelperCore"],
            path: "Tests/CCCUHelperCoreTests"
        ),
    ]
)
