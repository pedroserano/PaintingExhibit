// swift-tools-version: 5.9

// Painting Exhibit for the Mac, built from the same source files as the iPhone and iPad app
// (PaintingExhibit.swiftpm/App). Build the app with: scripts/make-mac-app.sh
// The iPhone and iPad app is built from PaintingExhibit.swiftpm in Xcode.

import PackageDescription

let package = Package(
    name: "PaintingExhibitMac",
    platforms: [.macOS("14.0")],
    targets: [
        .executableTarget(name: "PaintingExhibit", path: "PaintingExhibit.swiftpm/App",
                         exclude: ["Assets.xcassets"], // the Mac icon is Mac/AppIcon.icns
                         // Apple's MobileCLIP model, fetched by scripts/fetch-model.sh (not kept in the repository).
                         resources: [.copy("Models/mobileclip_s0_image.mlmodelc"), .copy("Models/LICENSE-MobileCLIP.txt"),
                                     .copy("Models/famous-paintings.json")])
    ]
)
