// swift-tools-version:5.8
import PackageDescription

let package = Package(
    name: "OVPNSpeedTest",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "OVPNCore", targets: ["OVPNCore"]),
        .executable(name: "ovpn-test", targets: ["ovpn-test"]),
        .executable(name: "OVPNSpeedTestApp", targets: ["OVPNSpeedTestApp"]),
    ],
    targets: [
        .target(
            name: "OVPNCore"
        ),
        .executableTarget(
            name: "ovpn-test",
            dependencies: ["OVPNCore"]
        ),
        .executableTarget(
            name: "OVPNSpeedTestApp",
            dependencies: ["OVPNCore"]
        ),
    ]
)
