// swift-tools-version: 5.9

// Painting Exhibit — phase 1 prototype.
// Open this .swiftpm folder in Xcode, choose your Personal Team under
// Signing & Capabilities, pick your iPhone or iPad, and press Run.

import PackageDescription
import AppleProductTypes

let package = Package(
    name: "PaintingExhibit",
    platforms: [
        .iOS("17.0")
    ],
    products: [
        .iOSApplication(
            name: "Painting Exhibit",
            targets: ["App"],
            bundleIdentifier: "com.pedroserano.PaintingExhibit",
            displayVersion: "0.1",
            bundleVersion: "1",
            appIcon: .asset("AppIcon"),
            accentColor: .presetColor(.orange),
            supportedDeviceFamilies: [
                .pad,
                .phone
            ],
            supportedInterfaceOrientations: [
                .portrait,
                .landscapeRight,
                .landscapeLeft,
                .portraitUpsideDown(.when(deviceFamilies: [.pad]))
            ],
            capabilities: [
                .photoLibrary(purposeString: "Painting Exhibit reads the paintings album you choose so it can crop, correct and display each painting. It changes photos only if you turn on Save Edits to Photos, and Photos keeps the originals.")
            ]
        )
    ],
    targets: [
        .executableTarget(
            name: "App",
            path: "App"
        )
    ]
)
