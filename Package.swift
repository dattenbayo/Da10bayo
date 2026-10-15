// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Da10bayo",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Da10bayo",
            path: "Sources/Da10bayo",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("IOKit"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("EventKit"),
                .linkedFramework("QuickLookThumbnailing"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)
