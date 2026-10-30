// swift-tools-version: 6.0

import PackageDescription

#if os(macOS)
let packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
]
let updaterDependencies: [Target.Dependency] = [
    .product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS]))
]
#else
let packageDependencies: [Package.Dependency] = []
let updaterDependencies: [Target.Dependency] = []
#endif

#if os(macOS)
let kestrelExcludes = ["Info.plist", "Entitlements", "Kestrel.icns"]
let kestrelResources: [Resource] = [.process("Assets.xcassets")]
#else
let kestrelExcludes = ["Info.plist", "Entitlements", "Assets.xcassets", "Kestrel.icns"]
let kestrelResources: [Resource] = []
#endif

let package = Package(
    name: "KestrelWebKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "Kestrel",
            targets: ["KestrelWebKit"]
        )
    ],
    dependencies: packageDependencies,
    targets: [
        .executableTarget(
            name: "KestrelWebKit",
            dependencies: updaterDependencies,
            path: "KestrelWebKit",
            exclude: kestrelExcludes,
            resources: kestrelResources,
            swiftSettings: [
                // The UI and WebKit page lifecycle are main-thread work. Keep
                // Swift 6's toolchain while avoiding needless strict-isolation
                // ceremony until the tab model is in place.
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "KestrelWebKitTests",
            dependencies: ["KestrelWebKit"],
            path: "Tests/KestrelWebKitTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
