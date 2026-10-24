// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TermHub",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.20.0")
    ],
    targets: [
        .executableTarget(
            name: "TermHub",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")]
        )
    ]
)
