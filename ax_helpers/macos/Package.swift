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
            path: "Sources/cccu-helper"
        ),
        .testTarget(
            name: "CCCUHelperCoreTests",
            dependencies: ["CCCUHelperCore"],
            path: "Tests/CCCUHelperCoreTests"
        ),
    ]
)
