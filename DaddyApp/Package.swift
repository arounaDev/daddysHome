// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DaddyApp",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(
            name: "DaddyApp",
            targets: ["DaddyApp"]
        ),
    ],
    dependencies: [
        .package(path: "../daddycore-spm"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", branch: "main"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.16.1"),
    ],
    targets: [
        .executableTarget(
            name: "DaddyApp",
            dependencies: [
                .product(name: "DaddyCore", package: "daddycore-spm"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            // The provider logos. `.process` rather than `.copy` so they are
            // flattened into the generated resource bundle without the
            // `Resources/` prefix, which is what `Bundle.module` looks for.
            resources: [
                .process("Resources")
            ]
        ),
    ]
)
