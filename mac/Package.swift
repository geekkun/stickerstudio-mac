// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StickerStudio",
    defaultLocalization: "ru",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // Портируемое ядро: геометрия, хромакей, EBML-патчер, ffmpeg-пайплайн.
        // Только Foundation — собирается и тестируется в том числе на Linux.
        .target(
            name: "StickerCore",
            path: "Sources/StickerCore"
        ),
        // Консольный экспортёр (аналог `StickerStudio.exe /export`) — для
        // автотестов пайплайна без UI.
        .executableTarget(
            name: "stickerctl",
            dependencies: ["StickerCore"],
            path: "Sources/stickerctl"
        ),
        // SwiftUI-приложение (только macOS; файлы внутри обёрнуты в #if os(macOS)).
        .executableTarget(
            name: "StickerStudio",
            dependencies: ["StickerCore"],
            path: "Sources/StickerStudio"
        ),
        .testTarget(
            name: "StickerCoreTests",
            dependencies: ["StickerCore"],
            path: "Tests/StickerCoreTests"
        ),
    ]
)
