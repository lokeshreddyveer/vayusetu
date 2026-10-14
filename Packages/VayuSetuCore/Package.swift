// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "VayuSetuCore", platforms: [.iOS(.v17), .macOS(.v14)], products: [.library(name: "VayuSetuCore", targets: ["VayuSetuCore"])], targets: [.target(name: "VayuSetuCore"), .testTarget(name: "VayuSetuCoreTests", dependencies: ["VayuSetuCore"])])
