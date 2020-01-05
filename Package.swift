// swift-tools-version:5.0
import PackageDescription

let package = Package(
    name: "Fiber",
    products: [
        .library(name: "Fiber", targets: ["Fiber"])
    ],
    dependencies: [
        .package(path: "../Platform"),
        .package(path: "../LinkedList"),
        .package(path: "../Async"),
        .package(path: "../Time"),
        .package(path: "../Log"),
        .package(path: "../Test")
    ],
    targets: [
        .target(name: "CCoro"),
        .target(
            name: "Fiber",
            dependencies: [
                "CCoro",
                "LinkedList",
                "Platform",
                "Async",
                "Time",
                "Log"
            ]),
        .testTarget(name: "FiberTests", dependencies: ["Fiber", "Test"]),
    ]
)

#if os(Linux)
package.targets.append(.target(name: "CEpoll"))
package.targets[1].dependencies.append("CEpoll")
#endif
