// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Qingcai",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Qingcai", targets: ["Qingcai"])],
    targets: [
        .target(name: "QingcaiCore"),
        .systemLibrary(name: "CSQLite"),
        .target(name: "QingcaiGatewayKit", dependencies: ["QingcaiCore", "CSQLite"]),
        .executableTarget(name: "QingcaiGateway", dependencies: ["QingcaiGatewayKit"]),
        .executableTarget(name: "Qingcai", dependencies: ["QingcaiCore"]),
        .executableTarget(name: "QingcaiChecks", dependencies: ["QingcaiCore", "QingcaiGatewayKit"], path: "Tests/QingcaiCoreTests")
    ]
)
