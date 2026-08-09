// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "Pinshift",
  platforms: [
    .iOS(.v18),
    .macOS(.v15),
  ],
  products: [
    .library(name: "LocationDomain", targets: ["LocationDomain"]),
    .library(name: "SimulationDiagnostics", targets: ["SimulationDiagnostics"]),
    .library(name: "ControllerLink", targets: ["ControllerLink"]),
    .library(name: "SimulationController", targets: ["SimulationController"]),
    .library(name: "ControllerCLI", targets: ["ControllerCLI"]),
    .executable(
      name: "pinshift-controller",
      targets: ["PinshiftController"]
    ),
  ],
  dependencies: [
    .package(
      url: "https://github.com/apple/swift-argument-parser.git",
      from: "1.5.0"
    )
  ],
  targets: [
    .target(name: "LocationDomain"),
    .target(name: "SimulationDiagnostics"),
    .target(
      name: "ControllerLink",
      dependencies: ["SimulationDiagnostics"]
    ),
    .target(
      name: "SimulationController",
      dependencies: ["LocationDomain", "SimulationDiagnostics"]
    ),
    .target(
      name: "ControllerCLI",
      dependencies: [
        "ControllerLink",
        "LocationDomain",
        "SimulationController",
        "SimulationDiagnostics",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
    .executableTarget(
      name: "PinshiftController",
      dependencies: ["ControllerCLI"]
    ),
    .testTarget(
      name: "LocationDomainTests",
      dependencies: ["LocationDomain"]
    ),
    .testTarget(
      name: "SimulationDiagnosticsTests",
      dependencies: ["SimulationDiagnostics"]
    ),
    .testTarget(
      name: "ControllerLinkTests",
      dependencies: ["ControllerLink", "SimulationDiagnostics"]
    ),
    .testTarget(
      name: "SimulationControllerTests",
      dependencies: ["SimulationController", "SimulationDiagnostics"]
    ),
    .testTarget(
      name: "ControllerCLITests",
      dependencies: ["ControllerCLI"]
    ),
  ]
)
