// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FolderSensei",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "FolderSenseiCore",
            targets: ["FolderSenseiCore"]
        ),
    ],
    targets: [
        .target(
            name: "FolderSenseiCore",
            path: "Sources/FolderSenseiCore"
        ),
    ]
)
