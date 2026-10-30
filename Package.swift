// swift-tools-version: 6.0

import PackageDescription

#if os(macOS)
let packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    // CefSwift is pinned to a reviewed commit because its only tagged release
    // predates the current CEF API used by the macOS build.
    .package(
        url: "https://github.com/Rajaniraiyn/CefSwift.git",
        revision: "b18cceef8afaf6686147e19a9239f31c2dd81541"
    )
]
let updaterDependencies: [Target.Dependency] = [
    .product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS]))
]
let chromiumDependencies: [Target.Dependency] = [
    .product(name: "CefKit", package: "CefSwift"),
    .product(name: "CefSwiftUI", package: "CefSwift")
]
#else
let packageDependencies: [Package.Dependency] = []
let updaterDependencies: [Target.Dependency] = []
let chromiumDependencies: [Target.Dependency] = []
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
            name: "KestrelWebKit",
            targets: ["KestrelWebKit"]
        ),
        .executable(
            name: "Kestrel",
            targets: ["Kestrel"]
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
        .executableTarget(
            name: "Kestrel",
            dependencies: chromiumDependencies,
            path: "KestrelChromium",
            exclude: ["cefapp.json"],
            swiftSettings: [.swiftLanguageMode(.v5)]
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
