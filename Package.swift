// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Driveway",
    platforms: [.macOS("15.4")],
    products: [
        .executable(name: "Driveway", targets: ["Driveway"]),
        .executable(name: "DrivewayAgent", targets: ["DrivewayAgent"]),
        .executable(name: "DrivewayHelper", targets: ["DrivewayHelper"]),
    ],
    targets: [
        .target(name: "DrivewayCore"),
        .target(name: "DrivewayIPC", dependencies: ["DrivewayCore"]),
        .target(
            name: "DrivewayHelperKit",
            dependencies: ["DrivewayCore", "DrivewayIPC"],
            linkerSettings: [
                .linkedFramework("DiskArbitration"),
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(name: "DrivewayHelper", dependencies: ["DrivewayHelperKit"]),
        .executableTarget(name: "DrivewayAgent", dependencies: ["DrivewayCore", "DrivewayIPC"]),
        .executableTarget(
            name: "Driveway",
            dependencies: ["DrivewayCore", "DrivewayIPC"],
            linkerSettings: [.linkedFramework("Security")]
        ),
        .testTarget(name: "DrivewayCoreTests", dependencies: ["DrivewayCore"]),
        .testTarget(
            name: "DrivewayHelperKitTests",
            dependencies: ["DrivewayHelperKit", "DrivewayIPC", "DrivewayCore"]
        ),
    ]
)
