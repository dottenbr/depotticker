// swift-tools-version:5.10
import PackageDescription

// Builds the direct-download Mac app (see build.sh). The App Store and iOS builds use the Xcode
// project generated from project.yml and do not include Sparkle.
let package = Package(
    name: "Depotticker",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Depotticker",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Depotticker",
            swiftSettings: [.unsafeFlags(["-swift-version", "5"])],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ]
)
