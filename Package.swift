// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacDou",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "MacDou", targets: ["MacDou"])],
    targets: [.executableTarget(name: "MacDou")],
    swiftLanguageModes: [.v5]
)
