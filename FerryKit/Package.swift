// swift-tools-version: 6.2
// FerryKit: everything in Ferry that isn't UI, kept free of UIKit so the Mac app can use it too and `swift test` runs it
// on the Mac without a simulator. FerryServer is the computer's side of the protocol, which the Mac app runs.
import PackageDescription

let package = Package(
    name: "FerryKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "FerryKit", targets: ["FerryKit"]),
        .library(name: "FerryServer", targets: ["FerryServer"]),
    ],
    targets: [
        .target(name: "FerryKit"),
        .target(name: "FerryServer", dependencies: ["FerryKit"]),
        .testTarget(name: "FerryKitTests", dependencies: ["FerryKit"], resources: [.copy("Fixtures")]),
        .testTarget(name: "FerryServerTests", dependencies: ["FerryServer", "FerryKit"], resources: [.copy("Fixtures")]),
    ]
)
