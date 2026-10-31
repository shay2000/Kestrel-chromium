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
let appDependencies: [Target.Dependency] = [
    .product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS])),
    .product(name: "CefKit", package: "CefSwift"),
    .product(name: "CefSwiftUI", package: "CefSwift")
]
#else
let packageDependencies: [Package.Dependency] = []
let appDependencies: [Target.Dependency] = []
#endif

let package = Package(
    name: "KestrelChromium",
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
            dependencies: appDependencies,
            path: ".",
            exclude: [
                "KestrelWebKit/KestrelWebKitApp.swift",
                "KestrelWebKit/BrowserOperator.swift",
                "KestrelWebKit/BrowserStore.swift",
                "KestrelWebKit/BrowserView.swift",
                "KestrelWebKit/BrowserExtensionHost.swift",
                "KestrelWebKit/TabStore.swift",
                "KestrelWebKit/WebKitConfiguration.swift",
                "KestrelWebKit/Info.plist",
                "KestrelWebKit/Entitlements",
                "KestrelWebKit/Kestrel.icns"
            ],
            sources: ["KestrelWebKit", "KestrelChromium"],
            resources: [.process("KestrelWebKit/Assets.xcassets")],
            swiftSettings: [
                // The UI and Chromium page lifecycle are main-thread work. Keep
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
