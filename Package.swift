// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Pladder",
    // The UI follows the macOS system language; English is the source
    // language, and the String Catalogs below need this to compile.
    defaultLocalization: "en",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "Pladder", targets: ["Pladder"]),
        .executable(name: "pladder-cli", targets: ["PladderCLI"]),
        .library(name: "PladderCore", targets: ["PladderCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/coreai-models.git", revision: "52c84ba874b2c57adcede08a671ce96ed1b3f433"),
    ],
    targets: [
        // Pure logic. Imports Foundation only, so tests stay fast and engines
        // remain swappable.
        .target(name: "PladderCore"),

        // Microphone capture and resampling.
        .target(name: "PladderAudio", dependencies: ["PladderCore"]),

        // Hotkey, pasteboard output, permissions. AppKit lives here.
        .target(
            name: "PladderSystem",
            dependencies: ["PladderCore"],
            // Key names, in their own table so the merged de.lproj can hold
            // this and the app's catalog side by side.
            resources: [.process("Resources/KeyNames.xcstrings")]
        ),

        // Concrete transcription engines.
        .target(
            name: "PladderEngines",
            dependencies: [
                "PladderCore",
                .product(name: "CoreAISpeech", package: "coreai-models"),
            ]
        ),

        // The polish models: Apple's on-device model, the only target that
        // imports FoundationModels, and S1-mini through llama.cpp.
        .target(name: "PladderRefine", dependencies: ["PladderCore", "llama"]),

        // llama.cpp's own prebuilt release, Metal included: a dynamic
        // framework that scripts/bundle.sh embeds in the app. Pinned by
        // release and checksum; bump both together.
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11191/llama-b11191-xcframework.zip",
            checksum: "c8f9af07555a15b00a87334e13a21320596178c58bbafa2d7c4915c574e7086e"
        ),

        // The menu bar app.
        .executableTarget(
            name: "Pladder",
            dependencies: ["PladderCore", "PladderAudio", "PladderSystem", "PladderEngines", "PladderRefine"],
            // Info.plist is copied into the .app by scripts/bundle.sh; SwiftPM
            // refuses to treat it as a resource, so keep it out of the bundle.
            exclude: ["Resources/Info.plist"],
            // Compiled to de.lproj/<Table>.strings inside the target's
            // resource bundle; bundle.sh merges those lproj folders into the
            // app's own Resources, so lookups go through Bundle.main.
            resources: [
                .process("Resources/Localizable.xcstrings"),
                .process("Resources/InfoPlist.xcstrings"),
                .copy("Resources/ThirdPartyNotices.txt"),
            ]
        ),

        // Benchmark helpers (word error rate). Only the CLI links this; the
        // app carries nothing benchmark-related.
        .target(name: "PladderBench"),

        // Developer tool: transcribe a file from the terminal to verify
        // engines, or run the benchmark (see docs/BENCHMARKS.md).
        .executableTarget(
            name: "PladderCLI",
            dependencies: ["PladderCore", "PladderEngines", "PladderAudio", "PladderBench", "PladderRefine", "PladderSystem"]
        ),

        .testTarget(name: "PladderEnginesTests", dependencies: ["PladderEngines"]),
        .testTarget(name: "PladderCoreTests", dependencies: ["PladderCore"]),
        .testTarget(name: "PladderAudioTests", dependencies: ["PladderAudio"]),
        .testTarget(name: "PladderBenchTests", dependencies: ["PladderBench"]),
        .testTarget(name: "PladderSystemTests", dependencies: ["PladderSystem"]),
        .testTarget(name: "PladderRefineTests", dependencies: ["PladderRefine"]),
    ]
)
