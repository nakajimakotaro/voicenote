// swift-tools-version: 6.0
import PackageDescription

// 音声の入出力だけを受け持つ（デコード、VAD、ピーク抽出、mp3書き出し）。
// 分割やカットの判断はDomainに置く
let package = Package(
    name: "AudioIO",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AudioIO", targets: ["AudioIO"]),
    ],
    dependencies: [
        .package(path: "../Domain"),
    ],
    targets: [
        .target(
            name: "AudioIO",
            dependencies: ["Domain"],
            // Tools/convert_silero_vad.py で作ったコンパイル済みモデル
            resources: [.copy("Resources/SileroVAD.mlmodelc")]
        ),
        .testTarget(
            name: "AudioIOTests",
            dependencies: ["AudioIO"],
            // 日本語の読み上げ2文を無音でつないだ17.8秒の音声（発話 2.0〜7.4秒、11.4〜15.8秒）
            resources: [.copy("Fixtures/speech.m4a")]
        ),
    ]
)
